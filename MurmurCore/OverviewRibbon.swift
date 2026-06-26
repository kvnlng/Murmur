//
//  OverviewRibbon.swift
//  Murmur
//
//  Whole-recording envelope strip rendered under each ECG canvas. Shows the
//  channel's full-extent pyramid envelope, a colored tick lane for every
//  surviving finding, the current viewport indicator, and a scale strip with
//  the recording's total duration and the current window. Click/drag the
//  ribbon to scrub.
//
//  Lives in its own file (extracted from BedsideView) so BedsideView stays
//  under the file-length lint limit. Internal access is intentional — used
//  only by ChannelPanel in BedsideView.swift.
//

import Charts
import SwiftUI

struct OverviewRibbon: View {
    let channel: Channel
    let directory: URL
    let viewport: RecordingViewport
    /// Findings to show as colored ticks across the full-recording overview.
    /// Filtered by the same `FindingFilter` as the canvas, so toggling a
    /// category chip dims its ticks here in lock-step.
    var annotations: [Annotation] = []

    @State private var bins: [PyramidBin] = []
    @State private var loadError: String?

    /// Minimum on-screen width for the viewport indicator. At deep zoom (e.g.
    /// 10 s of a 30-min recording, ~0.5%), the proportional width is a few
    /// pixels — too thin to see. We floor at this so the user can always
    /// perceive where they are. Anything wider than this stays proportional.
    private static let minIndicatorPx: CGFloat = 18
    private static let ribbonHeight: CGFloat = 56
    /// Minimum on-screen width for a finding tick. Point findings have zero
    /// width by definition; floor them at 2pt so they actually render. Range
    /// findings stay proportional once they exceed this width.
    private static let minTickPx: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    envelopeChart
                    annotationTicks(width: geo.size.width, height: geo.size.height)
                    viewportIndicator(width: geo.size.width)
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: Self.ribbonHeight)
            scaleStrip
        }
        .padding(.top, 4)
        .accessibilityIdentifier("overview-ribbon-\(channel.name)")
        .task { await loadOverview() }
    }

    /// Thin colored ticks for each annotation at its fractional sample
    /// position. Drawn between the envelope (background) and the viewport
    /// indicator (foreground) so the indicator never obscures a tick, and
    /// the envelope's gray fill stays the dominant visual under everything.
    /// Points are minTickPx wide; ranges stay proportional once they exceed
    /// that width.
    private func annotationTicks(width: CGFloat, height: CGFloat) -> some View {
        let totalSamples = Double(viewport.totalSamples)
        // Render nothing if we don't yet know the recording's total length
        // (loadOverview hasn't completed) or if there are no findings.
        guard totalSamples > 0, !annotations.isEmpty else {
            return AnyView(EmptyView())
        }
        return AnyView(
            ZStack(alignment: .topLeading) {
                ForEach(annotations) { ann in
                    let startFrac = Double(ann.sampleIndex) / totalSamples
                    let endSample = ann.endSampleIndex ?? ann.sampleIndex
                    let endFrac   = Double(endSample) / totalSamples
                    let leftPx    = CGFloat(max(0, min(1, startFrac))) * width
                    let propWidth = CGFloat(max(0, endFrac - startFrac)) * width
                    let tickWidth = max(Self.minTickPx, propWidth)
                    let color     = CategoryPalette.swiftUIColor(for: ann.category)
                    Rectangle()
                        .fill(color.opacity(ann.kind == .point ? 0.85 : 0.45))
                        .frame(width: tickWidth, height: height)
                        .offset(x: leftPx)
                        .allowsHitTesting(false)
                }
            }
        )
    }

    /// "0s ──── 5.2 min — 5.5 min ──── 30.0 min" style scale strip. Shows the
    /// recording's total extent at the edges and the current viewport in the
    /// middle so the analyst sees both "how much we're looking at" and "where
    /// we are" at a glance.
    private var scaleStrip: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(formatDuration(0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(currentWindowLabel)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(formatDuration(totalDurationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: 12)
    }

    private var totalDurationSeconds: Double {
        guard viewport.sampleRate > 0 else { return 0 }
        return Double(viewport.totalSamples) / viewport.sampleRate
    }

    private var currentWindowLabel: String {
        guard viewport.sampleRate > 0 else { return "—" }
        let startSec = Double(viewport.startSample) / viewport.sampleRate
        let endSec   = Double(viewport.endSample)   / viewport.sampleRate
        let widthSec = endSec - startSec
        return "\(formatDuration(startSec)) – \(formatDuration(endSec))  •  \(formatDuration(widthSec)) window"
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return seconds < 10
                ? String(format: "%.1f s", seconds)
                : String(format: "%.0f s", seconds)
        }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }

    @ViewBuilder
    private var envelopeChart: some View {
        if let loadError {
            Text(loadError)
                .font(.caption2)
                .foregroundStyle(.red)
        } else if bins.isEmpty {
            Rectangle().fill(.quaternary)
        } else {
            Chart {
                ForEach(Array(bins.enumerated()), id: \.offset) { idx, bin in
                    if !bin.isNaN {
                        AreaMark(
                            x: .value("Bin", idx),
                            yStart: .value("Min", bin.min),
                            yEnd: .value("Max", bin.max)
                        )
                        .foregroundStyle(.secondary.opacity(0.55))
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...Double(max(1, bins.count - 1)))
        }
    }

    private func viewportIndicator(width: CGFloat) -> some View {
        let totalSamples = Double(viewport.totalSamples)
        guard totalSamples > 0 else { return AnyView(EmptyView()) }
        let leftFrac  = Double(viewport.startSample) / totalSamples
        let widthFrac = Double(viewport.endSample - viewport.startSample) / totalSamples
        // Proportional width, but never thinner than minIndicatorPx so the
        // indicator stays perceivable at deep zoom. The indicator's center
        // still tracks the viewport center after the floor kicks in, so the
        // user can see where they are in the recording.
        let propWidth = CGFloat(widthFrac) * width
        let visibleWidth = max(Self.minIndicatorPx, propWidth)
        let centerFrac = leftFrac + widthFrac / 2
        let centerX = CGFloat(centerFrac) * width
        let leftX = max(0, min(width - visibleWidth, centerX - visibleWidth / 2))
        return AnyView(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 1.25)
                )
                .frame(width: visibleWidth)
                .offset(x: leftX)
                .allowsHitTesting(false)
        )
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                let fraction = Double(value.location.x / width)
                viewport.jump(toFraction: fraction)
            }
    }

    private func loadOverview() async {
        guard let level = selectLevel() else { return }
        let url = directory.appendingPathComponent(level.storageFileName)
        do {
            let access = try PyramidLevelFile.mappedAccess(url: url)
            let allBins = access.bins(range: 0..<access.binCount)
            await MainActor.run { bins = allBins }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
        }
    }

    private func selectLevel() -> PyramidLevel? {
        guard !channel.pyramid.isEmpty else { return nil }
        let target: Int64 = 400
        return channel.pyramid.min(by: { abs($0.binCount - target) < abs($1.binCount - target) })
    }
}
