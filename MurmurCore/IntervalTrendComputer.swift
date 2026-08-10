//
//  IntervalTrendComputer.swift
//  MurmurCore
//
//  Aggregates the fiducial store's per-beat intervals into fixed-width
//  time bins for the interval trend lane. Pure aggregation — the
//  interval values themselves (PR / QRS / QT / QTc in ms) come from
//  MurmurMetrics via IntervalMarkingsContext; this file only bins,
//  medians, and IQR-ribbons them.
//
//  Following project_interval_trend_lanes_design.md:
//    - Median + IQR ribbon per bin, NOT a single smoothed line.
//    - Per-bin "confidence-fails" flag when too many beats in a bin
//      carried a low-confidence T-offset (QTc's fragile fiducial).
//      Failed bins render dimmed / hatched, never plotted as
//      confident values.
//    - Bins are placed on a monotonic clock-time grid so consecutive
//      bins are directly comparable; short trailing bins get dropped
//      rather than diluted.
//

import Foundation

/// Which interval metric a trend lane is showing. QTc is the default
/// per the design spec (drug-induced QT prolongation is the named use
/// case); PR and QRS are switchable/stackable trends.
public enum IntervalTrendMetric: String, CaseIterable, Sendable, Codable {
    case qtc
    case pr
    case qrs

    public var displayName: String {
        switch self {
        case .qtc: return "QTc"
        case .pr:  return "PR"
        case .qrs: return "QRS-width"
        }
    }

    public var unit: String { "ms" }

    /// Metrics exposed in the trend-lane picker at LAUNCH. Per the
    /// measurement-layer gating decision (project_measurement_layer_gating.md,
    /// 2026-07-04): the lane is built trend-agnostic and picker
    /// multi-capable, but only QTc is exposed at launch — PR and
    /// QRS-width are Phase 4b fast-follow once QTc is validated on
    /// real recordings. `allCases` stays complete so the compute
    /// pipeline can still run PR / QRS for internal testing without
    /// this list gating the enum's expressiveness.
    public static let launchVisible: [IntervalTrendMetric] = [.qtc]
}

/// How the lane draws each bin — median-only for a clean read, median
/// plus IQR ribbon for honesty about noise, or per-beat scatter at
/// high zoom.
public enum IntervalTrendShowMode: String, CaseIterable, Sendable, Codable {
    case medianOnly
    case medianAndIQR
    case perBeatScatter

    public var displayName: String {
        switch self {
        case .medianOnly:     return "median only"
        case .medianAndIQR:   return "median + IQR"
        case .perBeatScatter: return "per-beat scatter"
        }
    }
}

/// Representation policy for the trend lane.
///
/// X88 retired X41's zoom-band system: the lane is a LOCATION FINDER, like
/// the RMSSD and LF/HF lanes, so its x-domain is ALWAYS the whole recording
/// and never follows the viewport ("The QTc track is changing length when
/// zooming … they should not change length, as they are location finders").
/// With a permanent whole-record domain, per-beat scatter is always the
/// illegible wall X41 coerced away at map scale — so the coercion is now
/// unconditional. The `perBeatScatter` case survives only so persisted
/// Show preferences keep decoding; the picker no longer offers it.
public enum IntervalTrendRepresentation {
    public static func effectiveMode(
        preferred: IntervalTrendShowMode
    ) -> IntervalTrendShowMode {
        preferred == .perBeatScatter ? .medianAndIQR : preferred
    }
}

/// One bin's worth of aggregated values.
public struct IntervalTrendBin: Sendable, Equatable, Identifiable {
    /// Start of the bin (seconds from recording start).
    public let startSeconds: Double
    /// End of the bin (seconds from recording start).
    public let endSeconds: Double
    /// Median of the metric across every eligible beat in the bin.
    /// NaN when the bin has zero eligible beats.
    public let median: Double
    /// Lower quartile.
    public let q1: Double
    /// Upper quartile.
    public let q3: Double
    /// Bootstrap CI on the MEDIAN — MEASUREMENT uncertainty (how well we
    /// know the trend point), NOT physiological spread. Renders as a
    /// tight band tucked INSIDE the IQR ribbon. Kept visually distinct
    /// from the IQR per project_qtc_trend_uncertainty_wireup_spec.md —
    /// bands 2 and 3 are DIFFERENT quantities, do not merge or draw one
    /// as the other.
    public let bandLowerMs: Double
    public let bandUpperMs: Double
    /// True when at least one beat in the bin has a right-censored
    /// T-offset (walk clipped at the physiological search-window
    /// ceiling — true T-offset is ≥ reported value). Drives the
    /// "open-top / QT ≥" rendering. Distinct from `!isEligible`, which
    /// covers low-confidence-but-measured beats.
    public let hasCensoredBeats: Bool
    /// True when the bin passed the confidence floor. False bins
    /// render dimmed / hatched.
    public let isEligible: Bool
    /// How many beats contributed. Zero when the delineator found
    /// nothing in the bin (gap in fiducials); such bins are dropped
    /// entirely rather than plotted as ineligible.
    public let beatCount: Int
    /// Every eligible per-beat sample in the bin — powers the
    /// per-beat scatter show-mode. Ineligible bins carry an empty
    /// array.
    public let perBeatValues: [Double]
    /// Coefficient of variation of the beat-to-beat R–R interval in the bin
    /// (SD/mean × 100), or nil when there are too few R–R samples. Surfaced
    /// next to QTc as the R–R steadiness the rate correction ASSUMES — a
    /// factual input measurement, never a validity verdict, and NO threshold
    /// is applied (the analyst judges). C8 / X30.
    public let rrCVPercent: Double?

    /// Max deviation (bpm) of heart rate from its mean over the ~2-min window
    /// PRECEDING this bin — the QT/RR hysteresis window (X42/X43). `nil` when
    /// there wasn't enough preceding history to judge. Populated by the paid
    /// qualifying-window compute; the free viewer leaves it nil. A statement
    /// about the rate-correction INPUT, never a validity verdict.
    public let rateMaxDeviationBpm: Double?
    /// Max deviation of a SUB-WINDOW MEAN rate from the preceding window's
    /// overall mean — the quantity `rateStable` is actually decided on, and so
    /// the figure the X43 marker quotes. `nil` when not computed.
    public let rateDriftBpm: Double?
    /// Whether the preceding-window rate held within `rateStabilityToleranceBpm`.
    /// Defaults true (no marker) for bins that were never evaluated.
    public let rateStable: Bool
    /// The ±bpm tolerance the stability boolean was taken against (echoed for
    /// the marker text + provenance). Default is Malik 2008's ±2 bpm.
    public let rateStabilityToleranceBpm: Double
    /// Fraction (0…1) of beats in the bin excluded as artifact/ectopic (X42),
    /// or nil when not computed (free viewer). Stated alongside the
    /// percent-above-guide read (X46) so a fraction is never reported blind.
    public let excludedBeatFraction: Double?

    /// Fraction (0…1) of beats in the bin whose QT measurement was physically
    /// IMPOSSIBLE (X53 / `QTPlausibilityFilter`) and therefore withheld from
    /// this bin's median — noise cannot be allowed to drag the trend point.
    /// Distinct from `excludedBeatFraction` (RR-artifact/ectopic, X42): that is
    /// about beat DETECTION, this is about MEASUREMENT possibility. `nil` in the
    /// free viewer (no delineation). A bin whose beats were ALL impossible is
    /// carried ineligible with this = 1 rather than dropped, so "excluded" stays
    /// distinct from "not computed" (K9).
    public let qtImplausibleFraction: Double?

    /// Fraction (0…1) of beats in the bin whose T-OFFSET the delineator
    /// flagged as unreliable (X58/X79) and whose QT/QTc were therefore
    /// withheld from this bin's median. Only the repolarisation interval is
    /// withheld — the beat still contributes RR steadiness, and PR/QRS bins
    /// carry `nil` here (the flag is about the T-offset, not the beat).
    /// `nil` in the free viewer and for bins with no beats.
    public let qtUnreliableFraction: Double?

    /// A bin qualifies for rate-sensitive reads (X46 percent-above, X47 QTVI)
    /// when it's eligible and its preceding-rate was stable. In the free viewer
    /// (no rate compute) `rateStable` defaults true, so every eligible bin
    /// qualifies until the paid layer narrows it.
    public var isQualifying: Bool { isEligible && rateStable }

    /// The rate-stability validity marker (X43) shows only when the rate was
    /// evaluated AND found unstable — never on unknown history.
    public var showsRateUnstableMarker: Bool {
        rateMaxDeviationBpm != nil && !rateStable
    }

    /// The figure the X43 marker quotes: mean-rate DRIFT, which is what
    /// `rateStable` is decided on. Falls back to the instantaneous deviation
    /// only for bins computed before drift existed — quoting a number that had
    /// nothing to do with the verdict is how the marker read "Δ17 bpm" on
    /// perfectly ordinary sinus rhythm.
    public var rateUnstableMarkerBpm: Double? {
        rateDriftBpm ?? rateMaxDeviationBpm
    }

    public init(
        startSeconds: Double,
        endSeconds: Double,
        median: Double,
        q1: Double,
        q3: Double,
        bandLowerMs: Double,
        bandUpperMs: Double,
        hasCensoredBeats: Bool,
        isEligible: Bool,
        beatCount: Int,
        perBeatValues: [Double],
        rrCVPercent: Double? = nil,
        rateMaxDeviationBpm: Double? = nil,
        rateDriftBpm: Double? = nil,
        rateStable: Bool = true,
        rateStabilityToleranceBpm: Double = 2,
        excludedBeatFraction: Double? = nil,
        qtImplausibleFraction: Double? = nil,
        qtUnreliableFraction: Double? = nil
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.median = median
        self.q1 = q1
        self.q3 = q3
        self.bandLowerMs = bandLowerMs
        self.bandUpperMs = bandUpperMs
        self.hasCensoredBeats = hasCensoredBeats
        self.isEligible = isEligible
        self.beatCount = beatCount
        self.perBeatValues = perBeatValues
        self.rrCVPercent = rrCVPercent
        self.rateMaxDeviationBpm = rateMaxDeviationBpm
        self.rateDriftBpm = rateDriftBpm
        self.rateStable = rateStable
        self.rateStabilityToleranceBpm = rateStabilityToleranceBpm
        self.excludedBeatFraction = excludedBeatFraction
        self.qtImplausibleFraction = qtImplausibleFraction
        self.qtUnreliableFraction = qtUnreliableFraction
    }

    public var id: Double { (startSeconds + endSeconds) / 2 }

    public var centerSeconds: Double { (startSeconds + endSeconds) / 2 }
}

/// Pure-value output type for a trend-lane render pass. Callers keep
/// the parameters echoed in the caption / citation caption stable
/// across the render so the citation "Copy" affordance echoes them
/// verbatim.
public struct IntervalTrendData: Sendable, Equatable {
    public let bins: [IntervalTrendBin]
    /// Baseline band derived from the per-patient template: (low, high)
    /// covering median ± IQR/2 (or median±IQR when only median+IQR
    /// combined is available). Nil when the template hasn't produced
    /// a stable value for the selected metric yet.
    public let baselineBand: ClosedRange<Double>?
    /// Baseline median (the line inside the band) — powers the
    /// caption's "patient normal · X ms" readout.
    public let baselineMedian: Double?
    /// Repro caption. Echoes formula (for QTc), bin length, template
    /// N. Used verbatim by CitationBuilder / Copy citation.
    public let reproCaption: String

    public init(
        bins: [IntervalTrendBin],
        baselineBand: ClosedRange<Double>?,
        baselineMedian: Double?,
        reproCaption: String
    ) {
        self.bins = bins
        self.baselineBand = baselineBand
        self.baselineMedian = baselineMedian
        self.reproCaption = reproCaption
    }
}

public enum IntervalTrendComputer {

    /// Compute a full render pass. Pure over its inputs — no side
    /// effects, no shared-context reads.
    ///
    /// - Parameters:
    ///   - beats: Fiducial-store beats, sorted ascending by R-peak
    ///     sample index. Empty produces an empty output.
    ///   - template: Patient normal template for the baseline band /
    ///     median. Nil is fine — the lane still renders bins.
    ///   - sampleRate: Recording sample rate. Zero disables output.
    ///   - metric: Which interval to trend.
    ///   - binSeconds: Bin length in seconds. 120 (2 min) is the
    ///     design default.
    ///   - templateBeatCount: The `sampleCount` field on
    ///     `MarkingsTemplate` — echoed into the repro caption.
    ///   - qtcFormulaName: For QTc mode, the formula name to echo
    ///     into the repro caption ("Fridericia", "Bazett", …).
    ///     Ignored for PR / QRS trends.
    ///   - confidenceFloor: Fraction (0…1) of beats in a bin that
    ///     must have a "high-confidence" fragile fiducial for the bin
    ///     to be eligible. Defaults to 0.60 — matches the RR
    ///     artifact-ratio floor's spirit ("dim if more than 40% are
    ///     bad"). QTc bins gate on T-offset confidence; PR gates on
    ///     P-onset/-offset; QRS gates on the QRS on/off pair.
    public static func compute(
        beats: [MarkingsBeat],
        template: MarkingsTemplate?,
        sampleRate: Double,
        metric: IntervalTrendMetric,
        binSeconds: Double,
        templateBeatCount: Int?,
        qtcFormulaName: String,
        templateSelectionBasis: String? = nil,
        qualifiers: [IntervalBinQualifier] = [],
        confidenceFloor: Double = 0.60,
        tOffsetGateCaption: String? = nil
    ) -> IntervalTrendData {
        // Join the paid per-bin qualifying facts (X42) by bin index — both the
        // qualifiers and the bins below start at k·binSeconds, so the index is
        // an exact key.
        let qualifierByBinIndex: [Int: IntervalBinQualifier] = binSeconds > 0
            ? Dictionary(
                qualifiers.map { (Int(($0.startSeconds / binSeconds).rounded()), $0) },
                uniquingKeysWith: { first, _ in first }
              )
            : [:]
        // Baseline band comes from the template independently of the
        // bins — even the empty-beats state still shows where the
        // patient's normal falls on the y-axis.
        let (baselineBand, baselineMedian) = baseline(for: metric, template: template)
        let caption = reproCaption(
            metric: metric,
            binSeconds: binSeconds,
            templateBeatCount: templateBeatCount ?? template?.sampleCount,
            qtcFormulaName: qtcFormulaName,
            sourceLead: template?.sourceLead,
            templateSelectionBasis: templateSelectionBasis,
            spanStartSample: template?.spanStartSample,
            spanEndSample: template?.spanEndSample,
            sampleRate: sampleRate,
            excludedImplausibleCount: template?.excludedImplausibleCount ?? 0,
            excludedUnreliableCount: template?.excludedUnreliableCount ?? 0,
            tOffsetGateCaption: tOffsetGateCaption
        )

        guard sampleRate > 0, binSeconds > 0, !beats.isEmpty else {
            return IntervalTrendData(
                bins: [],
                baselineBand: baselineBand,
                baselineMedian: baselineMedian,
                reproCaption: caption
            )
        }

        // Recording span in seconds — from first beat to last beat.
        let firstSec = Double(beats.first!.rPeakSampleIndex) / sampleRate
        let lastSec  = Double(beats.last!.rPeakSampleIndex)  / sampleRate

        // Align bin starts to zero-offset so consecutive renders stay
        // stable across viewport changes.
        let firstBinStart = floor(firstSec / binSeconds) * binSeconds
        let lastBinStart  = floor(lastSec  / binSeconds) * binSeconds

        var bins: [IntervalTrendBin] = []
        var binStart = firstBinStart
        // Two-pointer walk — beats are sorted, so we scan once.
        var beatIdx = 0
        while binStart <= lastBinStart {
            let binEnd = binStart + binSeconds

            var values: [Double] = []
            var rrValues: [Double] = []
            var confidenceHits = 0
            var totalBeatsInBin = 0
            var implausibleInBin = 0
            var unreliableInBin = 0
            var censoredHit = false

            while beatIdx < beats.count {
                let beat = beats[beatIdx]
                let beatSec = Double(beat.rPeakSampleIndex) / sampleRate
                if beatSec < binStart { beatIdx += 1; continue }
                if beatSec >= binEnd { break }
                totalBeatsInBin += 1
                // X53: a physically impossible beat is withheld from EVERY
                // aggregate in this bin — its garbage value never reaches the
                // median, the RR steadiness, or the confidence floor. It is
                // counted so the excluded fraction can be surfaced.
                if beat.isImplausible {
                    implausibleInBin += 1
                    beatIdx += 1
                    continue
                }
                // X79: an unreliable T-OFFSET withholds only the QT/QTc value
                // — biased-long false terminations must not drag the QTc
                // median any more than they may poison the template (X58).
                // Unlike X53's whole-beat exclusion, the beat still counts
                // toward RR steadiness: its R-peak is sound. On rec 212 this
                // is what makes the lane's bins agree with the template
                // instead of drawing the ~625 ms the template had rejected.
                let withholdsValue = metric == .qtc && beat.isUnreliable
                if withholdsValue {
                    unreliableInBin += 1
                } else if let value = value(for: metric, beat: beat) {
                    values.append(value)
                }
                if let rr = beat.precedingRRMs, rr.isFinite, rr > 0 {
                    rrValues.append(rr)
                }
                if !withholdsValue, hasFragileFiducialsHighConfidence(beat: beat, metric: metric) {
                    confidenceHits += 1
                }
                // Only QTc trends against a T-offset; PR / QRS bins
                // don't carry a censored notion.
                if metric == .qtc, beat.tOffsetCensored, !withholdsValue {
                    censoredHit = true
                }
                beatIdx += 1
            }

            // Surfaced per bin, never hidden. `nil` for a bin with no beats at
            // all (so "no data" stays distinct from "0% excluded").
            let qtImplausibleFraction: Double? = totalBeatsInBin > 0
                ? Double(implausibleInBin) / Double(totalBeatsInBin)
                : nil
            // Meaningful only where a T-offset feeds the median; PR/QRS bins
            // carry nil rather than an implied "0% withheld".
            let qtUnreliableFraction: Double? = metric == .qtc && totalBeatsInBin > 0
                ? Double(unreliableInBin) / Double(totalBeatsInBin)
                : nil

            if !values.isEmpty {
                let stats = quartiles(of: values)
                // The confidence floor is measured over the CONTRIBUTING beats,
                // not the bin total — an excluded (impossible or unreliable)
                // beat is not "low confidence", it is not used at all, so it
                // must not drag the eligibility denominator.
                let contributingBeats = totalBeatsInBin - implausibleInBin - unreliableInBin
                let confidenceFraction = contributingBeats > 0
                    ? Double(confidenceHits) / Double(contributingBeats)
                    : 0.0
                let eligible = confidenceFraction >= confidenceFloor
                // Bootstrap CI on the median — measurement uncertainty,
                // distinct from IQR (physiological spread). Deterministic
                // seed derived from bin start so re-renders stay stable.
                let ci = bootstrapMedianCI(values: values, seed: UInt64(bitPattern: Int64(binStart * 1000)))
                // Stamp the paid qualifying facts for this bin, if present.
                let q = qualifierByBinIndex[Int((binStart / binSeconds).rounded())]
                bins.append(
                    IntervalTrendBin(
                        startSeconds: binStart,
                        endSeconds: binEnd,
                        median: stats.median,
                        q1: stats.q1,
                        q3: stats.q3,
                        bandLowerMs: ci.lower,
                        bandUpperMs: ci.upper,
                        hasCensoredBeats: censoredHit,
                        isEligible: eligible,
                        beatCount: totalBeatsInBin,
                        perBeatValues: eligible ? values : [],
                        rrCVPercent: coefficientOfVariationPercent(rrValues),
                        rateMaxDeviationBpm: q?.rateMaxDeviationBpm,
                        rateDriftBpm: q?.rateDriftBpm,
                        rateStable: q?.rateStable ?? true,
                        excludedBeatFraction: q?.excludedBeatFraction,
                        qtImplausibleFraction: qtImplausibleFraction,
                        qtUnreliableFraction: qtUnreliableFraction
                    )
                )
            } else if implausibleInBin > 0 || unreliableInBin > 0 {
                // K9: a bin whose beats were ALL excluded (physically
                // impossible, unreliable T-offset, or both) is EXCLUDED, not
                // "not computed" — carry it ineligible (a hatched region, no
                // plotted point) with the fractions set, rather than dropping
                // it to a gap the analyst would read as missing data.
                bins.append(
                    IntervalTrendBin(
                        startSeconds: binStart,
                        endSeconds: binEnd,
                        median: .nan, q1: .nan, q3: .nan,
                        bandLowerMs: .nan, bandUpperMs: .nan,
                        hasCensoredBeats: false,
                        isEligible: false,
                        beatCount: totalBeatsInBin,
                        perBeatValues: [],
                        qtImplausibleFraction: qtImplausibleFraction,
                        qtUnreliableFraction: qtUnreliableFraction
                    )
                )
            }
            binStart = binEnd
        }

        return IntervalTrendData(
            bins: bins,
            baselineBand: baselineBand,
            baselineMedian: baselineMedian,
            reproCaption: caption
        )
    }

    // MARK: - Per-metric field extraction

    private static func value(for metric: IntervalTrendMetric, beat: MarkingsBeat) -> Double? {
        switch metric {
        case .qtc: return beat.qtcMs
        case .pr:  return beat.prMs
        case .qrs: return beat.qrsMs
        }
    }

    /// A beat contributes a "confidence hit" for the metric when the
    /// fragile fiducials the metric depends on all report a
    /// confidence at or above 0.60. This is deliberately conservative
    /// — the design spec says T-offset (for QTc) is the wobbly one
    /// and low-confidence bins should NOT be plotted as confident.
    private static func hasFragileFiducialsHighConfidence(
        beat: MarkingsBeat,
        metric: IntervalTrendMetric
    ) -> Bool {
        switch metric {
        case .qtc:
            return (beat.tOffset?.confidence ?? 0) >= 0.60
                && (beat.qrsOnset?.confidence ?? 0) >= 0.60
        case .pr:
            return (beat.pOnset?.confidence ?? 0) >= 0.60
                && (beat.qrsOnset?.confidence ?? 0) >= 0.60
        case .qrs:
            return (beat.qrsOnset?.confidence ?? 0) >= 0.60
                && (beat.qrsOffset?.confidence ?? 0) >= 0.60
        }
    }

    // MARK: - Baseline extraction (from template)

    private static func baseline(
        for metric: IntervalTrendMetric,
        template: MarkingsTemplate?
    ) -> (ClosedRange<Double>?, Double?) {
        guard let t = template else { return (nil, nil) }
        let median: Double?
        let iqr: Double?
        switch metric {
        case .qtc: median = t.medianQTcMs; iqr = t.iqrQTcMs
        case .pr:  median = t.medianPRMs;  iqr = t.iqrPRMs
        case .qrs: median = t.medianQRSMs; iqr = t.iqrQRSMs
        }
        guard let m = median, let i = iqr, i.isFinite, m.isFinite else {
            return (nil, median)
        }
        let half = i / 2
        return ((m - half)...(m + half), m)
    }

    // MARK: - Repro caption

    /// Internal (not private) so the wording — a methods statement the
    /// analyst copies verbatim — is pinned by unit tests.
    static func reproCaption(
        metric: IntervalTrendMetric,
        binSeconds: Double,
        templateBeatCount: Int?,
        qtcFormulaName: String,
        sourceLead: String?,
        templateSelectionBasis: String?,
        spanStartSample: Int64?,
        spanEndSample: Int64?,
        sampleRate: Double,
        excludedImplausibleCount: Int = 0,
        excludedUnreliableCount: Int = 0,
        tOffsetGateCaption: String? = nil
    ) -> String {
        let binLabel = binLabel(seconds: binSeconds)
        // X48 §4(b): the template figure must disclose what the beats were
        // selected BY and over what SPAN — a departure is uninterpretable
        // otherwise, and a bare "N beats" reads as if the app authored the
        // grouping. No template stays "no template" (absent, not a zero).
        let templateFragment: String
        if let count = templateBeatCount {
            var frag = "normal template = \(count) beats"
            if let basis = templateSelectionBasis, !basis.isEmpty {
                frag += " · \(basis)"
            }
            if let start = spanStartSample, let end = spanEndSample, sampleRate > 0 {
                let span = ViewportTimeFormat.window(
                    startSeconds: Double(start) / sampleRate,
                    endSeconds: Double(end) / sampleRate
                )
                frag += " · spanning \(span)"
            }
            // X58: exclude-AND-COUNT, per reason. A single total attributed to
            // "physically impossible" would mislabel the reliability
            // exclusions, so both causes are named whenever either fired.
            let excludedTotal = excludedImplausibleCount + excludedUnreliableCount
            if excludedTotal > 0 {
                frag += " (\(excludedTotal) excluded: \(excludedImplausibleCount) physically impossible · \(excludedUnreliableCount) unreliable T-offset)"
            }
            templateFragment = frag
        } else {
            templateFragment = "no template"
        }
        // X58: the gate setting is a methods fact — the aggregates cannot be
        // reproduced without it. QTc only; the gate touches no other metric.
        let gateFragment = metric == .qtc
            ? (tOffsetGateCaption.map { " · \($0)" } ?? "")
            : ""
        // C3: disclose the lead the intervals were measured in — a methods
        // reviewer requires it, and this caption is copied verbatim into the
        // citation payload. Appended (not prefixed) so the metric stays the
        // leading token the analyst scans for.
        let leadFragment = sourceLead.map { " · measured in \($0)" } ?? ""
        switch metric {
        case .qtc:
            return "QTc · \(qtcFormulaName) · \(binLabel) bins · \(templateFragment)\(leadFragment)\(gateFragment)"
        case .pr:
            return "PR · \(binLabel) bins · \(templateFragment)\(leadFragment)"
        case .qrs:
            return "QRS-width · \(binLabel) bins · \(templateFragment)\(leadFragment)"
        }
    }

    private static func binLabel(seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f-s", seconds) }
        let mins = seconds / 60
        if abs(mins - mins.rounded()) < 1e-3 {
            return "\(Int(mins))-min"
        }
        return String(format: "%.1f-min", mins)
    }

    /// Coefficient of variation (%) of a sample — SD/mean × 100 — or nil for
    /// fewer than 3 values or a non-positive mean. Population SD (÷N): a
    /// descriptive spread of the bin's R–R intervals, not an inferential
    /// estimate. Used to surface how steady the R–R was (C8), no threshold.
    private static func coefficientOfVariationPercent(_ values: [Double]) -> Double? {
        guard values.count >= 3 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (variance.squareRoot() / mean) * 100
    }

    // MARK: - Bootstrap CI on the median

    /// Block-bootstrap 2.5th/97.5th percentile of the median. Mirrors
    /// `TrendBinAggregator` in MurmurMetrics but stays local so
    /// MurmurCore doesn't cross the paid-extension import boundary. The
    /// deterministic seed makes re-renders stable across viewport
    /// changes; block-resampling (block length 5) preserves the
    /// short-scale error autocorrelation the aggregator design memo
    /// calls out.
    private static func bootstrapMedianCI(values: [Double], seed: UInt64) -> (lower: Double, upper: Double) {
        let n = values.count
        guard n >= 3 else {
            // Too few beats for a bootstrap — collapse to the point
            // estimate so the band is degenerate (invisible) rather
            // than misleading.
            let m = values.sorted()[n / 2]
            return (m, m)
        }
        let iterations = 400          // enough for 2.5/97.5 with ~1 ms noise
        let blockLen = min(5, n)
        var rng = SplitMix64(state: seed &+ 0x9E37_79B9_7F4A_7C15)
        var medians: [Double] = []
        medians.reserveCapacity(iterations)
        for _ in 0..<iterations {
            var sample: [Double] = []
            sample.reserveCapacity(n)
            while sample.count < n {
                let start = Int(rng.next() % UInt64(n))
                for j in 0..<blockLen where sample.count < n {
                    sample.append(values[(start + j) % n])
                }
            }
            let sorted = sample.sorted()
            medians.append(sorted[n / 2])
        }
        medians.sort()
        let loIdx = Int((0.025 * Double(iterations)).rounded(.down))
        let hiIdx = min(iterations - 1, Int((0.975 * Double(iterations)).rounded(.up)))
        return (medians[loIdx], medians[hiIdx])
    }

    /// Small deterministic RNG so the bootstrap is reproducible across
    /// re-renders + snapshot tests.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z &>> 31)
        }
    }

    // MARK: - Quartiles

    /// Linear-interpolation quartiles (type 7 in R's terminology —
    /// same as numpy's default). Cheap for the tens-to-hundreds of
    /// values per bin we see here.
    private static func quartiles(of values: [Double]) -> (q1: Double, median: Double, q3: Double) {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return (0, 0, 0) }
        if n == 1 { return (sorted[0], sorted[0], sorted[0]) }
        func percentile(_ p: Double) -> Double {
            let h = p * Double(n - 1)
            let lo = Int(floor(h))
            let hi = Int(ceil(h))
            if lo == hi { return sorted[lo] }
            let frac = h - Double(lo)
            return sorted[lo] + frac * (sorted[hi] - sorted[lo])
        }
        return (percentile(0.25), percentile(0.5), percentile(0.75))
    }
}
