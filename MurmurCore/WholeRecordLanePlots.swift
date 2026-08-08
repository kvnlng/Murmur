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

    var body: some View {
        GeometryReader { geo in
            let columns = LaneBinning.bin(
                samples: samples,
                sampleRate: sampleRate,
                range: recordingRange,
                targetColumns: Int(geo.size.width.rounded())
            )
            Canvas { ctx, size in
                guard !columns.isEmpty else { return }
                let finite = columns.compactMap { $0 }
                guard let lo = finite.map(\.min).min(),
                      let hi = finite.map(\.max).max(), hi > lo else { return }
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
