//
//  WholeRecordLanePlots.swift
//  MurmurCore
//
//  Plot-only lane bodies for the shared-axis trend stack (X74): heart rate,
//  and signal quality, both across the WHOLE recording.
//
//  Both were viewport-scoped before this. `ChannelTrendStrip` sliced its
//  samples to the current window and `QualityStrip` drew one cell per sample
//  — fine for a 30-minute record in a 10-second window, and wrong for the
//  stack, where every lane has to answer "what does the whole recording look
//  like, and where am I in it".
//
//  ## Binning, and why it is not optional
//
//  A 25-hour record at 1/60 Hz is ~1,500 trend samples: drawable. The same
//  record's quality channel is one cell per sample, and at 72 hours that is
//  4,300 cells across ~700 points — six cells per pixel, each drawn as a
//  rounded rect. So both plots bin to roughly one column per available point
//  and draw the aggregate. Binning also changes what is TRUE of a column: a
//  quality column now reports the WORST ratio it covers, not an average,
//  because a lane whose job is "which stretches to distrust" must not average
//  a bad minute away against fifty-nine good ones.
//

import Charts
import SwiftUI

/// Heart-rate trend across the whole recording, as a min/max band with a mean
/// line — not a single polyline.
///
/// At whole-record scale a mean line alone hides the thing an analyst is
/// looking for: a column covering a minute of tachycardia and a minute of rest
/// has an unremarkable mean. The band shows the excursion, the line shows the
/// centre.
struct HeartRateLanePlot: View {
    let samples: [Float]
    let sampleRate: Double
    let recordingRange: ClosedRange<Double>

    /// The drawn domain, computed from the samples rather than from the binned
    /// columns so the gutter labels and the Canvas cannot disagree — binning
    /// preserves the overall min and max, so the two are the same numbers.
    private var domain: (lo: Double, hi: Double)? {
        let finite = samples.filter(\.isFinite).map(Double.init)
        guard let lo = finite.min(), let hi = finite.max(), hi > lo else { return nil }
        return (lo, hi)
    }

    var body: some View {
        // #210: the gutter is the lane's half of the stack's plot-geometry
        // contract. It also gives this lane a y-scale for the first time —
        // reported as "HR (and effectively LF/HF) carry no y-scale at all".
        HStack(spacing: 0) {
            TrendLaneScaleGutter(ticks: ticks)
            plot
        }
    }

    private var ticks: [(fraction: Double, label: String)] {
        guard let domain else { return [] }
        return [0.0, 0.5, 1.0].map { f in
            (f, String(format: "%.0f", domain.lo + f * (domain.hi - domain.lo)))
        }
    }

    private var plot: some View {
        GeometryReader { geo in
            let columns = LaneBinning.bin(
                samples: samples,
                sampleRate: sampleRate,
                range: recordingRange,
                targetColumns: Int(geo.size.width.rounded())
            )
            Canvas { ctx, size in
                guard !columns.isEmpty, let (lo, hi) = domain else { return }
                let scale = size.height / CGFloat(hi - lo)
                func y(_ v: Double) -> CGFloat { size.height - CGFloat(v - lo) * scale }
                let step = size.width / CGFloat(max(1, columns.count))

                var band = Path()
                var mean = Path()
                var started = false
                for (i, column) in columns.enumerated() {
                    guard let column else { continue }
                    let x = CGFloat(i) * step
                    let top = CGPoint(x: x, y: y(column.max))
                    let bottom = CGPoint(x: x, y: y(column.min))
                    band.move(to: top)
                    band.addLine(to: CGPoint(x: bottom.x, y: max(bottom.y, top.y + 0.75)))
                    let centre = CGPoint(x: x, y: y(column.mean))
                    if started { mean.addLine(to: centre) } else { mean.move(to: centre); started = true }
                }
                ctx.stroke(band, with: .color(.accentColor.opacity(0.28)), lineWidth: max(1, step))
                ctx.stroke(mean, with: .color(.accentColor.opacity(0.85)), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Every lane reserves the same leading gutter, including the ones with
/// nothing to put in it — an empty gutter is what keeps a scale-less lane on
/// the same x-mapping as the rest (#210).
struct TrendLaneEmptyGutter<Plot: View>: View {
    @ViewBuilder var plot: () -> Plot

    var body: some View {
        HStack(spacing: 0) {
            TrendLaneScaleGutter(ticks: [])
            plot()
        }
    }
}

/// Artifact-ratio heat band across the whole recording.
///
/// Each column reports the WORST ratio in the stretch it covers. A lane whose
/// job is telling the analyst which parts of every other trend to distrust
/// must not average one bad minute away against fifty-nine good ones.
struct QualityLanePlot: View {
    let samples: [Float]
    let sampleRate: Double
    let recordingRange: ClosedRange<Double>
    /// Cells strictly above this get an outline. Medallion's default is 0.1.
    var threshold: Double = 0.1

    var body: some View {
        // A heat band has no scale to print, but it still reserves the gutter:
        // its columns must line up with the lanes above it (#210).
        TrendLaneEmptyGutter { plot }
    }

    private var plot: some View {
        GeometryReader { geo in
            let columns = LaneBinning.bin(
                samples: samples,
                sampleRate: sampleRate,
                range: recordingRange,
                targetColumns: Int(geo.size.width.rounded())
            )
            Canvas { ctx, size in
                let step = size.width / CGFloat(max(1, columns.count))
                for (i, column) in columns.enumerated() {
                    guard let column else { continue }
                    let worst = column.max
                    let rect = CGRect(x: CGFloat(i) * step, y: 0,
                                      width: max(1, step), height: size.height)
                    ctx.fill(Path(rect), with: .color(.secondary.opacity(0.10 + 0.7 * worst)))
                    if worst > threshold {
                        ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                                   with: .color(.orange.opacity(0.85)), lineWidth: 1)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.06)))
        }
        .accessibilityHidden(true)
    }
}

/// Rolling LF/HF across the whole recording (X76), as a single line with
/// gaps.
///
/// The samples arrive already computed (App-target orchestrator; MurmurCore
/// does no arithmetic on measurements) and already sparse: a window the
/// analyzer declined is ABSENT, and the line breaks there rather than
/// bridging it — a bridge would draw a ratio where the method said there
/// isn't one.
///
/// X92: rendered with Swift Charts so the lane carries a leading y-scale —
/// the same 3-tick treatment as the RMSSD lane. A dimensionless ratio with
/// no scale was a shape, not a measurement ("The LF / HF track needs a
/// scale"). The previous `Canvas` renderer's autoscale + gap-breaking rules
/// carry over unchanged.
struct LFHFLanePlot: View {
    /// Rolling windows, `windowStartSeconds…windowEndSeconds` in recording
    /// seconds, `value` = LF/HF ratio.
    let samples: [VariabilityLaneSample]
    let recordingRange: ClosedRange<Double>
    /// Windows are contiguous at `stepSeconds` spacing; a hole wider than
    /// this many steps breaks the line.
    let stepSeconds: Double

    /// Eligible samples chunked into contiguous runs — one LineMark series
    /// per run, so the line breaks across holes exactly as the Canvas did.
    private var runs: [[VariabilityLaneSample]] {
        var out: [[VariabilityLaneSample]] = []
        var current: [VariabilityLaneSample] = []
        var previousCenter: Double?
        for sample in samples.filter(\.isEligible) {
            let center = sample.windowCenterSeconds
            if let prev = previousCenter, center - prev > stepSeconds * 1.5 {
                if !current.isEmpty { out.append(current) }
                current = []
            }
            current.append(sample)
            previousCenter = center
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Autoscale padded so a flat series doesn't hug an edge — the same
    /// rule the Canvas renderer used.
    private var yDomain: ClosedRange<Double> {
        let values = samples.filter(\.isEligible).map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = Swift.max((hi - lo) * 0.1, 0.05)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        Chart {
            ForEach(runs.indices, id: \.self) { idx in
                ForEach(runs[idx]) { sample in
                    LineMark(
                        x: .value("t", sample.windowCenterSeconds),
                        y: .value("lfhf", sample.value),
                        series: .value("run", idx)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: recordingRange)
        // The y-scale, in the stack's shared gutter. X92 added the axis and it
        // was invisible on screen: at this lane's 46 pt height Charts rendered
        // a single tick whose self-sized label spilled left out of the plot
        // cell and landed on the rail's subtitle — the stray "5" in
        // "Lomb–Scargle · 5-min window". A fixed label box cannot spill.
        // One decimal: this is a ratio around 1–3, and "2" vs "2.2" is the
        // difference between a scale and a decoration.
        .trendLaneYAxis(decimals: 1, desiredCount: 2)
        .chartYScale(domain: yDomain)
        .accessibilityHidden(true)
    }
}

/// Shared column reduction for the whole-record lane plots.
enum LaneBinning {

    struct Column {
        let min: Double
        let max: Double
        let mean: Double
    }

    /// Reduce `samples` to about `targetColumns` columns over `range`.
    ///
    /// A column with no finite sample is `nil`, not zero. A gap in a trend
    /// channel is an absence of data, and drawing it as a value would put a
    /// heart rate of 0 on the lane — which reads as asystole rather than as
    /// "the sensor was off".
    static func bin(
        samples: [Float],
        sampleRate: Double,
        range: ClosedRange<Double>,
        targetColumns: Int
    ) -> [Column?] {
        let columns = Swift.max(1, Swift.min(targetColumns, 2000))
        guard !samples.isEmpty, sampleRate > 0,
              range.upperBound > range.lowerBound else { return [] }

        let span = range.upperBound - range.lowerBound
        var out = [Column?](repeating: nil, count: columns)
        var mins = [Double](repeating: .greatestFiniteMagnitude, count: columns)
        var maxes = [Double](repeating: -.greatestFiniteMagnitude, count: columns)
        var sums = [Double](repeating: 0, count: columns)
        var counts = [Int](repeating: 0, count: columns)

        for (index, sample) in samples.enumerated() {
            guard sample.isFinite else { continue }
            let t = Double(index) / sampleRate
            guard t >= range.lowerBound, t <= range.upperBound else { continue }
            let column = Swift.min(columns - 1, Int((t - range.lowerBound) / span * Double(columns)))
            let v = Double(sample)
            mins[column] = Swift.min(mins[column], v)
            maxes[column] = Swift.max(maxes[column], v)
            sums[column] += v
            counts[column] += 1
        }
        for i in 0..<columns where counts[i] > 0 {
            out[i] = Column(min: mins[i], max: maxes[i], mean: sums[i] / Double(counts[i]))
        }
        return out
    }

    /// Contiguous stretches whose worst ratio exceeds `threshold`, in seconds.
    ///
    /// These shade every lane in the stack, so they are computed once here
    /// rather than by each lane deciding for itself what "low quality" means.
    static func lowQualitySpans(
        samples: [Float],
        sampleRate: Double,
        threshold: Double
    ) -> [ClosedRange<Double>] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        var spans: [ClosedRange<Double>] = []
        var start: Double?
        for (index, sample) in samples.enumerated() {
            let t = Double(index) / sampleRate
            let bad = sample.isFinite && Double(sample) > threshold
            if bad, start == nil {
                start = t
            } else if !bad, let s = start {
                spans.append(s...t)
                start = nil
            }
        }
        if let s = start {
            spans.append(s...(Double(samples.count) / sampleRate))
        }
        return spans
    }
}
