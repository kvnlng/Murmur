//
//  QualityStrip.swift
//  Murmur
//
//  Quality / artifact-ratio heat band below the canvas. One cell per
//  per-frame sample, gray opacity proportional to the producer-reported
//  ratio (0…1). Cells above a configurable threshold get an orange
//  outline so the analyst can scan for "definitely problematic" minutes
//  at a glance without losing the underlying gradient.
//
//  Detection is name-pattern based — anything ending in `_ratio` or
//  whose name contains `artifact_ratio` lands in the quality bucket. The
//  Medallion `silver_cardio_features_1min` table contributes
//  `ecg_artifact_ratio`; future producers can add more rows by following
//  the same naming convention.
//

import SwiftUI

struct QualityStrip: View {
    let channels: [Channel]
    let recordingDirectory: URL
    let totalSamplesPrimary: Int64
    let primarySampleRate: Double
    let viewport: RecordingViewport
    /// Cells with ratio strictly greater than this get an outline. Per the
    /// Medallion paper the default sits at 0.1 — researchers can pick their
    /// own in cohort selection; the viewer just flags the same default.
    var threshold: Double = 0.1

    @State private var samplesByChannel: [Channel.ID: [Float]] = [:]

    private static let cellHeight: CGFloat = 14
    private static let labelWidth: CGFloat = 110

    var body: some View {
        if channels.isEmpty {
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
            .accessibilityIdentifier("quality-strip")
            .task(id: channels.map(\.id)) {
                await loadAll()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Quality")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("outline @ \(Int(threshold * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func row(for channel: Channel) -> some View {
        HStack(spacing: 8) {
            Text(displayLabel(for: channel))
                .font(.caption.monospaced())
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            heatBody(for: channel)
        }
        .accessibilityIdentifier("quality-lane-\(channel.name)")
    }

    private func heatBody(for channel: Channel) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.10))
                Canvas { ctx, size in
                    paint(channel: channel, into: ctx, size: size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let fraction = max(0, min(1, Double(location.x / max(geo.size.width, 1))))
                viewport.animateJump(toFraction: fraction)
            }
        }
        .frame(height: Self.cellHeight)
    }

    private func paint(channel: Channel, into ctx: GraphicsContext, size: CGSize) {
        guard let samples = samplesByChannel[channel.id], !samples.isEmpty else { return }
        guard channel.sampleRate > 0 else { return }
        let totalSec = primarySampleRate > 0
            ? Double(totalSamplesPrimary) / primarySampleRate
            : Double(samples.count) / channel.sampleRate
        guard totalSec > 0 else { return }
        let dt = 1.0 / channel.sampleRate

        for (idx, value) in samples.enumerated() {
            guard value.isFinite else { continue }
            let clamped = max(0.0, min(1.0, Double(value)))
            let startSec = Double(idx) * dt
            let endSec   = Double(idx + 1) * dt
            let x0 = CGFloat(startSec / totalSec) * size.width
            let x1 = CGFloat(min(1.0, endSec / totalSec)) * size.width
            let width = max(1, x1 - x0)

            // Filled gray with opacity proportional to the ratio. Lower
            // floor (0.05) keeps a faint baseline so the analyst can see
            // the strip exists even when everything's clean.
            let opacity = 0.05 + 0.85 * clamped
            ctx.fill(
                Path(CGRect(x: x0, y: 0, width: width, height: size.height)),
                with: .color(Color(white: 0.20).opacity(opacity))
            )

            if clamped > threshold {
                // Thin orange outline draws attention to cells that crossed
                // the analyst's "stop and look" threshold.
                let strokeRect = CGRect(x: x0 + 0.5, y: 0.5, width: max(1, width - 1), height: size.height - 1)
                ctx.stroke(
                    Path(strokeRect),
                    with: .color(.orange.opacity(0.85)),
                    lineWidth: 1
                )
            }
        }
    }

    @MainActor
    private func loadAll() async {
        await withTaskGroup(of: (Channel.ID, [Float]).self) { group in
            for channel in channels where samplesByChannel[channel.id] == nil {
                group.addTask(priority: .utility) {
                    let url = recordingDirectory.appendingPathComponent(channel.storageFileName)
                    guard let access = try? BinaryRecordingFile.mappedAccess(url: url),
                          channel.sampleCount > 0 else {
                        return (channel.id, [])
                    }
                    return (channel.id, access.samples(range: 0..<channel.sampleCount))
                }
            }
            for await (id, samples) in group {
                samplesByChannel[id] = samples
            }
        }
    }

    /// Trim the common `_ratio` suffix so the lane label reads tighter
    /// (`ecg_artifact` instead of `ecg_artifact_ratio`).
    private func displayLabel(for channel: Channel) -> String {
        var s = channel.name
        if s.hasSuffix("_ratio") { s.removeLast(6) }
        return s
    }
}
