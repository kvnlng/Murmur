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
        rrCVPercent: Double? = nil
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
        confidenceFloor: Double = 0.60
    ) -> IntervalTrendData {
        // Baseline band comes from the template independently of the
        // bins — even the empty-beats state still shows where the
        // patient's normal falls on the y-axis.
        let (baselineBand, baselineMedian) = baseline(for: metric, template: template)
        let caption = reproCaption(
            metric: metric,
            binSeconds: binSeconds,
            templateBeatCount: templateBeatCount ?? template?.sampleCount,
            qtcFormulaName: qtcFormulaName,
            sourceLead: template?.sourceLead
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
            var censoredHit = false

            while beatIdx < beats.count {
                let beat = beats[beatIdx]
                let beatSec = Double(beat.rPeakSampleIndex) / sampleRate
                if beatSec < binStart { beatIdx += 1; continue }
                if beatSec >= binEnd { break }
                totalBeatsInBin += 1
                if let value = value(for: metric, beat: beat) {
                    values.append(value)
                }
                if let rr = beat.precedingRRMs, rr.isFinite, rr > 0 {
                    rrValues.append(rr)
                }
                if hasFragileFiducialsHighConfidence(beat: beat, metric: metric) {
                    confidenceHits += 1
                }
                // Only QTc trends against a T-offset; PR / QRS bins
                // don't carry a censored notion.
                if metric == .qtc, beat.tOffsetCensored {
                    censoredHit = true
                }
                beatIdx += 1
            }

            if !values.isEmpty {
                let stats = quartiles(of: values)
                let confidenceFraction = totalBeatsInBin > 0
                    ? Double(confidenceHits) / Double(totalBeatsInBin)
                    : 0.0
                let eligible = confidenceFraction >= confidenceFloor
                // Bootstrap CI on the median — measurement uncertainty,
                // distinct from IQR (physiological spread). Deterministic
                // seed derived from bin start so re-renders stay stable.
                let ci = bootstrapMedianCI(values: values, seed: UInt64(bitPattern: Int64(binStart * 1000)))
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
                        rrCVPercent: coefficientOfVariationPercent(rrValues)
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

    private static func reproCaption(
        metric: IntervalTrendMetric,
        binSeconds: Double,
        templateBeatCount: Int?,
        qtcFormulaName: String,
        sourceLead: String?
    ) -> String {
        let binLabel = binLabel(seconds: binSeconds)
        let templateFragment = templateBeatCount.map { "normal template = \($0) beats" } ?? "no template"
        // C3: disclose the lead the intervals were measured in — a methods
        // reviewer requires it, and this caption is copied verbatim into the
        // citation payload. Appended (not prefixed) so the metric stays the
        // leading token the analyst scans for.
        let leadFragment = sourceLead.map { " · measured in \($0)" } ?? ""
        switch metric {
        case .qtc:
            return "QTc · \(qtcFormulaName) · \(binLabel) bins · \(templateFragment)\(leadFragment)"
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
