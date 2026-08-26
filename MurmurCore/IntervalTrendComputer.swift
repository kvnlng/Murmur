//
//  IntervalTrendComputer.swift
//  MurmurCore
//
//  Assembles the interval trend lane's render pass from PRODUCED bins.
//  Since #380 the per-bin production — grouping, the X53/X79 exclusion
//  policy, the estimators (quartiles, bootstrap CI, R–R CV), the K9
//  carry rule and the X42 qualifier join — lives in MurmurMetrics'
//  `TrendBinComputer` and reaches this side as finished
//  `IntervalTrendBin` values via `TrendBinsContext`
//  (project_metrics_module_boundaries.md: no arithmetic on
//  measurements in MurmurCore). This file keeps the data types, the
//  template baseline band, and the repro-caption composition.
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

/// How the lane draws each bin — one independent dot-and-range mark
/// per bin (the 13a canonical, and the default), median-only for a
/// clean connected read, median plus IQR ribbon for honesty about
/// noise, or per-beat scatter at high zoom.
public enum IntervalTrendShowMode: String, CaseIterable, Sendable, Codable {
    /// 13a / #261: dot at the bin median on a thick IQR segment and a
    /// thin full-range segment; excluded bins reduce to a grey stub.
    /// Chosen as the default because QTc is read against thresholds
    /// (500 ms Torsades window, >60 ms drift) and the range segment is
    /// the only mark that shows an excursion the bin median hides. A
    /// connected line would also fabricate values between bins — each
    /// 2-min bin is an independent measurement.
    case dotAndRange
    case medianOnly
    case medianAndIQR
    case perBeatScatter

    public var displayName: String {
        switch self {
        case .dotAndRange:    return "dot + range"
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

    /// Extremes of the bin's per-beat values — the 13a thin range
    /// segment. Falls back to the IQR edges when the per-beat list is
    /// empty (free-viewer fixtures), so the thin segment degrades to
    /// coinciding with the thick one rather than inventing a range.
    public var rangeMinMs: Double {
        perBeatValues.lazy.filter(\.isFinite).min() ?? q1
    }

    public var rangeMaxMs: Double {
        perBeatValues.lazy.filter(\.isFinite).max() ?? q3
    }
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
    /// #371: the repro caption travels SPLIT — prefix (metric · formula ·
    /// bins · template), the declaration-FREE lead fragment, and the suffix
    /// (the T-offset gate) — so a render-time surface can swap the lead
    /// fragment for a declaration-aware one (`IntervalTrendLane.
    /// renderedReproCaption`) without the compute path ever touching the
    /// placement map. Compute and the memo key stay placement-free; only
    /// sentence assembly moved.
    public let captionPrefix: String
    public let captionLeadFragment: String
    public let captionSuffix: String
    /// Raw as-recorded template source lead (#357's `sourceLead`), carried
    /// so the renderer can resolve a declaration for it. `nil` when the
    /// template has none — the caption then has no lead fragment either.
    public let sourceLead: String?

    /// The declaration-free repro caption — byte-identical to the pre-#371
    /// stored sentence. Surfaces that can consult the placement map render
    /// `IntervalTrendLane.renderedReproCaption` instead.
    public var reproCaption: String { captionPrefix + captionLeadFragment + captionSuffix }

    public init(
        bins: [IntervalTrendBin],
        baselineBand: ClosedRange<Double>?,
        baselineMedian: Double?,
        captionPrefix: String,
        captionLeadFragment: String,
        captionSuffix: String,
        sourceLead: String?
    ) {
        self.bins = bins
        self.baselineBand = baselineBand
        self.baselineMedian = baselineMedian
        self.captionPrefix = captionPrefix
        self.captionLeadFragment = captionLeadFragment
        self.captionSuffix = captionSuffix
        self.sourceLead = sourceLead
    }

    /// Convenience for callers carrying a finished sentence (tests,
    /// fixtures): the whole caption is the prefix, no swappable fragment.
    public init(
        bins: [IntervalTrendBin],
        baselineBand: ClosedRange<Double>?,
        baselineMedian: Double?,
        reproCaption: String
    ) {
        self.init(
            bins: bins,
            baselineBand: baselineBand,
            baselineMedian: baselineMedian,
            captionPrefix: reproCaption,
            captionLeadFragment: "",
            captionSuffix: "",
            sourceLead: nil
        )
    }
}

public enum IntervalTrendComputer {

    /// Assemble a full render pass from PRODUCED bins. Pure over its
    /// inputs — no side effects, no shared-context reads, and since #380
    /// no arithmetic on measurements: the bins arrive finished from the
    /// App orchestrator (`TrendBinComputer` via `TrendBinsContext`), and
    /// this function only marries them to the baseline band and the
    /// repro caption.
    ///
    /// - Parameters:
    ///   - bins: Produced trend bins (paid compute). Empty is fine — the
    ///     caption and baseline still render.
    ///   - template: Patient normal template for the baseline band /
    ///     median. Nil is fine.
    ///   - sampleRate: Recording sample rate — caption span formatting.
    ///   - metric: Which interval the bins trend.
    ///   - binSeconds: Bin length in seconds, echoed into the caption.
    ///   - templateBeatCount: The `sampleCount` field on
    ///     `MarkingsTemplate` — echoed into the repro caption.
    ///   - qtcFormulaName: For QTc mode, the formula name to echo
    ///     into the repro caption ("Fridericia", "Bazett", …).
    ///     Ignored for PR / QRS trends.
    public static func compute(
        bins: [IntervalTrendBin],
        template: MarkingsTemplate?,
        sampleRate: Double,
        metric: IntervalTrendMetric,
        binSeconds: Double,
        templateBeatCount: Int?,
        qtcFormulaName: String,
        templateSelectionBasis: String? = nil,
        tOffsetGateCaption: String? = nil
    ) -> IntervalTrendData {
        // Baseline band comes from the template independently of the
        // bins — even the empty state still shows where the patient's
        // normal falls on the y-axis.
        let (baselineBand, baselineMedian) = baseline(for: metric, template: template)
        let caption = reproCaptionParts(
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
        return IntervalTrendData(
            bins: bins,
            baselineBand: baselineBand,
            baselineMedian: baselineMedian,
            captionPrefix: caption.prefix,
            captionLeadFragment: caption.leadFragment,
            captionSuffix: caption.suffix,
            sourceLead: template?.sourceLead
        )
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
    /// analyst copies verbatim — is pinned by unit tests. Joins the split
    /// parts; the declaration-free sentence, byte-identical to pre-#371.
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
        let parts = reproCaptionParts(
            metric: metric,
            binSeconds: binSeconds,
            templateBeatCount: templateBeatCount,
            qtcFormulaName: qtcFormulaName,
            sourceLead: sourceLead,
            templateSelectionBasis: templateSelectionBasis,
            spanStartSample: spanStartSample,
            spanEndSample: spanEndSample,
            sampleRate: sampleRate,
            excludedImplausibleCount: excludedImplausibleCount,
            excludedUnreliableCount: excludedUnreliableCount,
            tOffsetGateCaption: tOffsetGateCaption
        )
        return parts.prefix + parts.leadFragment + parts.suffix
    }

    /// #371: the caption in its three parts — everything before the lead
    /// fragment, the declaration-free lead fragment itself, and everything
    /// after it — so `IntervalTrendData` can carry them split and a render
    /// surface can swap the middle for a declaration-aware fragment without
    /// re-ordering the sentence.
    static func reproCaptionParts(
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
    ) -> (prefix: String, leadFragment: String, suffix: String) {
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
        //
        // #357 §1.5: the lead attribution is true for EVERY metric (they all
        // come from the analysis lead), but "not a conventional QT lead
        // (II/V5)" is a QT-specific disclosure — convention names II/V5 for
        // the T offset, not for PR or QRS width. So only the QT-bearing
        // metric carries the clause, and it comes from `QTLeadDisclosure`
        // rather than a second spelling of the sentence.
        //
        // #358 ruling, upheld — still NO `declaredPlacement:` argument here.
        // This fragment is composed in the COMPUTE path, memoised by
        // `IntervalTrendComputeMemo`, and the jurisdiction bars giving an
        // orchestrator a placement dependence (nothing may recompute when a
        // declaration changes), so what compute produces is the
        // declaration-FREE default. What #371 changed is where the finished
        // sentence is assembled: the parts travel split on
        // `IntervalTrendData` and `IntervalTrendLane.renderedReproCaption`
        // swaps this fragment for a declaration-aware one at render time —
        // the same pattern as the beat-caliper provenance footer (#370).
        let citedLead = sourceLead.map {
            metric == .qtc ? QTLeadDisclosure.citedLeadName(for: $0) : $0
        }
        let leadFragment = citedLead.map { " · measured in \($0)" } ?? ""
        switch metric {
        case .qtc:
            return ("QTc · \(qtcFormulaName) · \(binLabel) bins · \(templateFragment)", leadFragment, gateFragment)
        case .pr:
            return ("PR · \(binLabel) bins · \(templateFragment)", leadFragment, "")
        case .qrs:
            return ("QRS-width · \(binLabel) bins · \(templateFragment)", leadFragment, "")
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
}
