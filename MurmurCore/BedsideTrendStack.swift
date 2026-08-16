//
//  BedsideTrendStack.swift
//  MurmurCore
//
//  Assembles the shared-axis trend stack (X74) from the lanes the recording
//  actually carries, and owns the sample loading the whole-record plots need.
//
//  Kept out of `BedsideView` because it has real work of its own — loading two
//  low-rate channels, deriving the low-quality spans every lane shades against,
//  and deciding which lanes exist — and `BedsideView` is where that kind of
//  thing accumulates until nobody can find it.
//

import SwiftUI

struct BedsideTrendStack: View {
    let heartRateChannel: Channel?
    let qualityChannels: [Channel]
    let directory: URL
    let recordingRange: ClosedRange<Double>
    let viewportRange: ClosedRange<Double>
    /// Which lanes the analyst has switched on. Lanes absent from the record
    /// never appear regardless.
    let visibleLanes: Set<String>
    /// X89 — the delineator's beats, for the beat-derived HR lane. Empty in
    /// the free viewer (delineation is Studio-gated upstream) and on records
    /// not yet delineated; the lane simply doesn't exist then.
    let beats: [MarkingsBeat]
    /// The ECG sample rate `beats`' R-peak indices are expressed in.
    let beatSampleRate: Double
    var onSeek: ((Double) -> Void)?

    /// These lanes are supplied by the caller, because they carry their own
    /// contexts (and, for RMSSD and the interval trend, control chips) that
    /// belong to the lane rather than to the stack.
    let rmssdLane: TrendStackLane?
    let intervalLane: TrendStackLane?
    /// X76 — rolling LF/HF. Sits between the interval trend and quality,
    /// per the wireframe's lane order.
    let lfhfLane: TrendStackLane?

    @State private var heartRate: [Float] = []
    @State private var heartRateRate: Double = 0
    @State private var quality: [Float] = []
    @State private var qualityRate: Double = 0
    /// X89 — computed off the render path: `lanes` re-evaluates on every
    /// viewport change, and a 24 h record's beat list is ~10⁵ elements.
    @State private var beatHR: BeatHeartRateSeries.Series = .empty

    static let hrLaneID = "hr"
    static let beatHRLaneID = "hr-beats"
    static let lfhfLaneID = "lfhf"
    static let qualityLaneID = "quality"

    var body: some View {
        // The load task hangs off the OUTER view, not off `TrendStack`.
        //
        // Attached inside the populated branch it deadlocks: with no samples
        // loaded there are no lanes, so `EmptyView` renders, so the task never
        // runs, so no samples ever load. The stack rendered nothing at all and
        // every accessibility assertion about a lane simply found nothing —
        // which reads as "this record has no lanes" rather than as a bug.
        // A VStack with a real frame, not `Group { EmptyView() }`: SwiftUI can
        // treat a Group whose content resolves to EmptyView as nothing at all,
        // and a `.task` on nothing never runs — which is the same deadlock in
        // a different disguise.
        VStack(spacing: 0) {
            if !lanes.isEmpty {
                TrendStack(
                    lanes: lanes,
                    recordingRange: recordingRange,
                    viewportRange: viewportRange,
                    lowQualitySpans: lowQualitySpans,
                    caption: caption,
                    hint: "Click the HR or quality lane to move the trace.",
                    onSeek: onSeek
                )
            }
        }
        .task(id: loadKey) { await load() }
    }

    private var loadKey: String {
        // Beats key on count + endpoints, not the whole array — an element-wise
        // key would put an O(n) comparison on every render for a task id.
        "\(heartRateChannel?.id.uuidString ?? "-")|\(qualityChannels.map(\.name).joined(separator: ","))"
            + "|\(beats.count)-\(beats.first?.rPeakSampleIndex ?? 0)-\(beats.last?.rPeakSampleIndex ?? 0)-\(beatSampleRate)"
    }

    private var lanes: [TrendStackLane] {
        var out: [TrendStackLane] = []
        if let hr = heartRateChannel, visibleLanes.contains(Self.hrLaneID), !heartRate.isEmpty {
            out.append(TrendStackLane(
                id: Self.hrLaneID,
                title: "Trends · HR",
                subtitle: "\(hr.unit.isEmpty ? "bpm" : hr.unit) · trend channel only",
                value: currentValue(of: heartRate, rate: heartRateRate),
                unit: hr.unit.isEmpty ? "bpm" : hr.unit,
                height: 86,
                seekable: true,
                accent: TrendStackLane.hrAccent
            ) {
                HeartRateLanePlot(
                    samples: heartRate,
                    sampleRate: heartRateRate,
                    recordingRange: recordingRange
                )
            })
        }
        // X89 — beat-derived HR, right under the channel lane it complements:
        // same quantity, different population (detected beats vs a device's
        // trend channel), and the subtitles say which is which.
        if !beatHR.samples.isEmpty, visibleLanes.contains(Self.beatHRLaneID) {
            out.append(TrendStackLane(
                id: Self.beatHRLaneID,
                title: "HR · beat-derived",
                subtitle: "bpm · median per \(Int(BeatHeartRateSeries.defaultBinSeconds)) s · from R–R",
                value: currentValue(of: beatHR.samples, rate: beatHR.sampleRate),
                unit: "bpm",
                height: 86,
                seekable: true,
                accent: TrendStackLane.hrAccent
            ) {
                HeartRateLanePlot(
                    samples: beatHR.samples,
                    sampleRate: beatHR.sampleRate,
                    recordingRange: recordingRange
                )
            })
        }
        if let rmssdLane, visibleLanes.contains(rmssdLane.id) { out.append(rmssdLane) }
        if let intervalLane, visibleLanes.contains(intervalLane.id) { out.append(intervalLane) }
        if let lfhfLane, visibleLanes.contains(lfhfLane.id) { out.append(lfhfLane) }
        if !quality.isEmpty, visibleLanes.contains(Self.qualityLaneID) {
            out.append(TrendStackLane(
                id: Self.qualityLaneID,
                title: "Quality",
                subtitle: "artifact ratio · outline over 10%",
                value: currentValue(of: quality, rate: qualityRate, decimals: 2),
                unit: "ratio",
                height: 26,
                seekable: true,
                accent: TrendStackLane.qualityAccent
            ) {
                QualityLanePlot(
                    samples: quality,
                    sampleRate: qualityRate,
                    recordingRange: recordingRange
                )
            })
        }
        return out
    }

    /// The lanes a record COULD show, for the `Lanes` menu. Distinct from
    /// `lanes`: a lane switched off still exists, and one the record cannot
    /// produce must not be offered as if toggling it would do something.
    static func availableLanes(
        heartRate: Channel?,
        quality: [Channel],
        beatHR: Bool,
        rmssd: Bool,
        interval: Bool,
        lfhf: Bool
    ) -> [(id: String, label: String)] {
        var out: [(String, String)] = []
        if heartRate != nil { out.append((hrLaneID, "Trends · HR")) }
        if beatHR { out.append((beatHRLaneID, "HR · beat-derived")) }
        if rmssd { out.append(("rmssd", "RMSSD")) }
        if interval { out.append(("interval-trend", "Interval trend")) }
        if lfhf { out.append((lfhfLaneID, "LF / HF")) }
        if !quality.isEmpty { out.append((qualityLaneID, "Quality")) }
        return out
    }

    /// The reading at the viewport's start — the lane's value column answers
    /// "what is it HERE", not "what is it on average", which the metrics block
    /// above already answers.
    private func currentValue(of samples: [Float], rate: Double, decimals: Int = 1) -> String? {
        guard rate > 0, !samples.isEmpty else { return nil }
        let index = Int(viewportRange.lowerBound * rate)
        guard index >= 0, index < samples.count, samples[index].isFinite else { return nil }
        return String(format: "%.\(decimals)f", samples[index])
    }

    private var lowQualitySpans: [ClosedRange<Double>] {
        guard !quality.isEmpty, qualityRate > 0 else { return [] }
        return LaneBinning.lowQualitySpans(samples: quality, sampleRate: qualityRate, threshold: 0.1)
    }

    /// Provenance. Names the population each lane measured, because the lanes
    /// come from different channels at different rates and a stack that looks
    /// like one chart invites the assumption that it is one.
    private var caption: String? {
        var parts: [String] = []
        if let hr = heartRateChannel {
            parts.append("HR from \(hr.name) at \(rateLabel(heartRateRate))")
        }
        if !beatHR.samples.isEmpty {
            parts.append("beat HR from \(beatHR.beatCount) detected beats")
        }
        if let q = qualityChannels.first {
            parts.append("quality from \(q.name) at \(rateLabel(qualityRate))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
            + " · one axis spanning \(ViewportTimeFormat.elapsed(recordingRange.upperBound, tenths: false))"
    }

    private func rateLabel(_ rate: Double) -> String {
        guard rate > 0 else { return "unknown rate" }
        if rate >= 1 { return String(format: "%.0f Hz", rate) }
        return String(format: "1/%.0f Hz", 1 / rate)
    }

    private func load() async {
        if let hr = heartRateChannel {
            let loaded = Self.samples(of: hr, in: directory)
            await MainActor.run {
                heartRate = loaded
                heartRateRate = hr.sampleRate
            }
        }
        if let q = qualityChannels.first {
            let loaded = Self.samples(of: q, in: directory)
            await MainActor.run {
                quality = loaded
                qualityRate = q.sampleRate
            }
        }
        // X89 — pure arithmetic over the published beats; recomputes only
        // when `loadKey` moves (a new record, or the delineator republishes).
        let series = BeatHeartRateSeries.compute(
            beats: beats,
            sampleRate: beatSampleRate,
            recordingDurationSeconds: recordingRange.upperBound - recordingRange.lowerBound
        )
        await MainActor.run { beatHR = series }
    }

    /// Trend channels are tiny by design — a 72-hour record at 1/60 Hz is
    /// ~4,300 samples — so the whole buffer is read once rather than sliced
    /// per viewport the way the old viewport-scoped strips did.
    private static func samples(of channel: Channel, in directory: URL) -> [Float] {
        let url = directory.appendingPathComponent(channel.storageFileName)
        guard channel.sampleCount > 0,
              let access = try? BinaryRecordingFile.mappedAccess(url: url) else { return [] }
        return access.samples(range: 0..<channel.sampleCount)
    }
}
