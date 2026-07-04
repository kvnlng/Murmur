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
        guard sampleRate > 0, binSeconds > 0, !beats.isEmpty else {
            return IntervalTrendData(
                bins: [],
                baselineBand: nil,
                baselineMedian: nil,
                reproCaption: reproCaption(
                    metric: metric,
                    binSeconds: binSeconds,
                    templateBeatCount: templateBeatCount,
                    qtcFormulaName: qtcFormulaName
                )
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
            var confidenceHits = 0
            var totalBeatsInBin = 0

            while beatIdx < beats.count {
                let beat = beats[beatIdx]
                let beatSec = Double(beat.rPeakSampleIndex) / sampleRate
                if beatSec < binStart { beatIdx += 1; continue }
                if beatSec >= binEnd { break }
                totalBeatsInBin += 1
                if let value = value(for: metric, beat: beat) {
                    values.append(value)
                }
                if hasFragileFiducialsHighConfidence(beat: beat, metric: metric) {
                    confidenceHits += 1
                }
                beatIdx += 1
            }

            if !values.isEmpty {
                let stats = quartiles(of: values)
                let confidenceFraction = totalBeatsInBin > 0
                    ? Double(confidenceHits) / Double(totalBeatsInBin)
                    : 0.0
                let eligible = confidenceFraction >= confidenceFloor
                bins.append(
                    IntervalTrendBin(
                        startSeconds: binStart,
                        endSeconds: binEnd,
                        median: stats.median,
                        q1: stats.q1,
                        q3: stats.q3,
                        isEligible: eligible,
                        beatCount: totalBeatsInBin,
                        perBeatValues: eligible ? values : []
                    )
                )
            }
            binStart = binEnd
        }

        let (baselineBand, baselineMedian) = baseline(for: metric, template: template)
        return IntervalTrendData(
            bins: bins,
            baselineBand: baselineBand,
            baselineMedian: baselineMedian,
            reproCaption: reproCaption(
                metric: metric,
                binSeconds: binSeconds,
                templateBeatCount: templateBeatCount ?? template?.sampleCount,
                qtcFormulaName: qtcFormulaName
            )
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
        qtcFormulaName: String
    ) -> String {
        let binLabel = binLabel(seconds: binSeconds)
        let templateFragment = templateBeatCount.map { "normal template = \($0) beats" } ?? "no template"
        switch metric {
        case .qtc:
            return "QTc · \(qtcFormulaName) · \(binLabel) bins · \(templateFragment)"
        case .pr:
            return "PR · \(binLabel) bins · \(templateFragment)"
        case .qrs:
            return "QRS-width · \(binLabel) bins · \(templateFragment)"
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
