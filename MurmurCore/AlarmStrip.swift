//
//  AlarmStrip.swift
//  Murmur
//
//  Per-channel alarm / status lanes spanning the full recording.
//  Each alarm channel (`had_high_priority_alarm`, `had_suction_alarm`,
//  `nebulizer_status`, `had_alarm_silenced`, …) gets its own row; every
//  contiguous "on" run of that channel renders as a colored bar at the
//  appropriate fractional position. Tap a bar to jump the viewport.
//
//  Channels feed in pre-loaded — `BedsideView` already keeps trend
//  channel sample buffers warm; we share that work via the loader
//  closure injected at the call site.
//

import SwiftUI

struct AlarmStrip: View {
    let channels: [Channel]
    let recordingDirectory: URL
    let totalSamplesPrimary: Int64
    let primarySampleRate: Double
    let viewport: RecordingViewport

    @State private var rangesByChannel: [Channel.ID: [ClosedRange<Int64>]] = [:]

    private static let laneHeight: CGFloat = 12
    private static let labelWidth: CGFloat = 110

    var body: some View {
        if channels.isEmpty || nothingActive {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                header
                VStack(spacing: 3) {
                    ForEach(channels) { channel in
                        row(for: channel)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("alarm-strip")
            .task(id: channels.map(\.id)) {
                await loadAll()
            }
        }
    }

    /// Hide the strip entirely when every alarm channel is silent. Keeps
    /// the bedside layout from acquiring empty chrome on calm records.
    private var nothingActive: Bool {
        guard !rangesByChannel.isEmpty else { return false }  // not loaded yet
        return channels.allSatisfy { rangesByChannel[$0.id]?.isEmpty ?? true }
    }

    private var header: some View {
        HStack {
            Text("Alarms")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func row(for channel: Channel) -> some View {
        HStack(spacing: 8) {
            Text(displayLabel(for: channel))
                .font(.caption.monospaced())
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            laneBody(for: channel)
        }
        .accessibilityIdentifier("alarm-lane-\(channel.name)")
    }

    private func laneBody(for channel: Channel) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.10))
                ForEach(Array(activeRanges(for: channel).enumerated()), id: \.offset) { _, range in
                    bar(for: range, channel: channel, in: geo.size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let fraction = max(0, min(1, Double(location.x / max(geo.size.width, 1))))
                viewport.animateJump(toFraction: fraction)
            }
        }
        .frame(height: Self.laneHeight)
    }

    private func bar(for range: ClosedRange<Int64>, channel: Channel, in size: CGSize) -> some View {
        // Convert the channel-local sample range into a fractional position
        // on the recording's primary-rate timeline, then onto pixels.
        let channelRate = channel.sampleRate
        let startSec = Double(range.lowerBound) / channelRate
        let endSec   = Double(range.upperBound + 1) / channelRate
        let totalSec = primarySampleRate > 0
            ? Double(totalSamplesPrimary) / primarySampleRate
            : max(1, endSec)
        let x0 = CGFloat(max(0.0, startSec / totalSec)) * size.width
        let x1 = CGFloat(min(1.0, endSec   / totalSec)) * size.width
        let width = max(2, x1 - x0)
        return RoundedRectangle(cornerRadius: 2)
            .fill(color(for: channel))
            .frame(width: width, height: size.height)
            .offset(x: x0)
    }

    private func activeRanges(for channel: Channel) -> [ClosedRange<Int64>] {
        rangesByChannel[channel.id] ?? []
    }

    @MainActor
    private func loadAll() async {
        await withTaskGroup(of: (Channel.ID, [ClosedRange<Int64>]).self) { group in
            for channel in channels where rangesByChannel[channel.id] == nil {
                group.addTask(priority: .utility) {
                    let url = recordingDirectory.appendingPathComponent(channel.storageFileName)
                    guard let access = try? BinaryRecordingFile.mappedAccess(url: url),
                          channel.sampleCount > 0 else {
                        return (channel.id, [])
                    }
                    let samples = access.samples(range: 0..<channel.sampleCount)
                    return (channel.id, BooleanChannelScanner.scan(samples: samples))
                }
            }
            for await (id, ranges) in group {
                rangesByChannel[id] = ranges
            }
        }
    }

    /// Trim conventional Medallion prefixes/suffixes so the lane label reads
    /// `high_priority` instead of `had_high_priority_alarm`. Keeps the lane
    /// width tight without losing meaning.
    private func displayLabel(for channel: Channel) -> String {
        var s = channel.name
        if s.hasPrefix("had_") { s.removeFirst(4) }
        if s.hasSuffix("_alarm") { s.removeLast(6) }
        if s.hasSuffix("_status") { s.removeLast(7) }
        if s.hasSuffix("_silenced") { s = "silenced" }
        return s
    }

    /// Color by intent: critical-sounding channel names get red, others get
    /// the category palette's fallback (deterministic by name).
    private func color(for channel: Channel) -> Color {
        let n = channel.name.lowercased()
        if n.contains("high_priority") || n.contains("critical") { return .red }
        if n.contains("alarm_silenced") || n.contains("silenced") { return .secondary }
        return CategoryPalette.swiftUIColor(for: channel.name)
    }
}
