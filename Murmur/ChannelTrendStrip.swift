//
//  ChannelTrendStrip.swift
//  Murmur
//
//  Stacked sparklines for low-rate ("trend") channels — HR, SpO₂, etCO₂,
//  tidal volume, P(spontaneous), and anything else the producer drops in
//  at 1/60 Hz or similar. Time-locked to the shared `RecordingViewport`
//  so panning the ECG canvas also pans the vitals.
//
//  Each trend channel's full sample buffer is loaded once at panel mount
//  (≪ thousands of samples even for multi-hour records) and re-sliced per
//  viewport change. No GPU work — Swift Charts is sufficient at this
//  cardinality.
//

import Charts
import SwiftUI

struct ChannelTrendStrip: View {
    let channels: [Channel]
    let recordingDirectory: URL
    let viewport: RecordingViewport

    /// Loaded sample buffers keyed by channel id. Populated on the first
    /// `.task` and untouched after — these channels are tiny by design.
    @State private var samplesByChannel: [Channel.ID: [Float]] = [:]

    var body: some View {
        if channels.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header
                ForEach(channels) { channel in
                    TrendRow(
                        channel: channel,
                        samples: samplesByChannel[channel.id] ?? [],
                        viewportStartSec: viewportStartSec,
                        viewportEndSec: viewportEndSec
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("channel-trend-strip")
            .task(id: channels.map(\.id)) {
                await loadAll()
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Trends")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(rangeLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Time math

    private var viewportStartSec: Double {
        viewport.sampleRate > 0
            ? Double(viewport.startSample) / viewport.sampleRate
            : 0
    }

    private var viewportEndSec: Double {
        viewport.sampleRate > 0
            ? Double(viewport.endSample) / viewport.sampleRate
            : 0
    }

    private var rangeLabel: String {
        let span = viewportEndSec - viewportStartSec
        return ChipDuration.format(seconds: span) + " window"
    }

    // MARK: - Loading

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
}

// MARK: - One trend row

/// Renders one trend channel's sparkline + side label. NaN samples are
/// dropped from the line so contiguous data segments render normally;
/// long sparse gaps appear as straight inter-segment lines today
/// (acceptable for v1 — fix when real producer data shows pathological
/// gap shapes).
private struct TrendRow: View {
    let channel: Channel
    let samples: [Float]
    let viewportStartSec: Double
    let viewportEndSec: Double

    private static let rowHeight: CGFloat = 44
    private static let labelWidth: CGFloat = 140

    var body: some View {
        HStack(spacing: 16) {
            label
            Divider()
            sparkline
        }
        .frame(height: Self.rowHeight)
        .accessibilityIdentifier("trend-row-\(channel.name)")
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(channel.name)
                .font(.caption.weight(.semibold).monospaced())
                .lineLimit(1)
            HStack(spacing: 4) {
                if let v = midValue {
                    Text(formatValue(v))
                        .font(.caption2.monospacedDigit())
                } else {
                    Text("—")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if !channel.unit.isEmpty {
                    Text(channel.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: Self.labelWidth, alignment: .leading)
    }

    @ViewBuilder
    private var sparkline: some View {
        if visiblePoints.isEmpty {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.10))
                Text("no data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Chart {
                ForEach(visiblePoints) { point in
                    LineMark(
                        x: .value("t", point.t),
                        y: .value(channel.name, point.v)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: viewportStartSec...max(viewportStartSec + 0.001, viewportEndSec))
            .chartYScale(domain: yDomain)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.06))
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private struct Point: Identifiable {
        let t: Double
        let v: Double
        var id: Double { t }
    }

    /// Slice the channel's samples to the viewport window, drop NaNs, and
    /// convert each retained sample to a `Point(t: seconds, v: value)`.
    private var visiblePoints: [Point] {
        guard !samples.isEmpty, channel.sampleRate > 0 else { return [] }
        let totalCount = samples.count
        let lo = max(0, Int((viewportStartSec * channel.sampleRate).rounded(.down)))
        let hi = min(totalCount, Int((viewportEndSec * channel.sampleRate).rounded(.up)) + 1)
        guard lo < hi else { return [] }
        var pts: [Point] = []
        pts.reserveCapacity(hi - lo)
        for i in lo..<hi {
            let v = samples[i]
            guard v.isFinite else { continue }
            let t = Double(i) / channel.sampleRate
            pts.append(Point(t: t, v: Double(v)))
        }
        return pts
    }

    /// Numeric value at the middle of the viewport window, used by the
    /// side label. Returns nil when no finite sample falls in window.
    private var midValue: Double? {
        guard !visiblePoints.isEmpty else { return nil }
        return visiblePoints[visiblePoints.count / 2].v
    }

    /// Y-axis range padded around the visible min/max to keep the line off
    /// the chart edges. Empty / flat data collapses to a benign [0,1].
    private var yDomain: ClosedRange<Double> {
        guard !visiblePoints.isEmpty else { return 0...1 }
        let values = visiblePoints.map(\.v)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if abs(hi - lo) < 1e-9 {
            let pad = max(abs(lo) * 0.1, 1)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.10
        return (lo - pad)...(hi + pad)
    }

    private func formatValue(_ v: Double) -> String {
        if abs(v) >= 100 { return String(format: "%.0f", v) }
        if abs(v) >= 10  { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}
