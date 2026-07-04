//
//  VariabilityLane.swift
//  MurmurCore
//
//  The time-resolved HRV lane rendered directly BENEATH the ECG canvas,
//  sharing the same time axis so pan / zoom / scrub stay locked to the
//  waveform. Consumes primitive `VariabilityLaneSample` values — the
//  paid MurmurMetrics framework does the arithmetic; MurmurCore stays
//  read-only, no arithmetic on measurements, per the module-boundary
//  decision. The App target orchestrates the handoff.
//
//  Rendering:
//    - **Eligible samples** connect as a `LineMark`, broken into
//      contiguous runs so the line does not bridge across ineligible
//      windows (which would be visually deceptive).
//    - **Ineligible windows** render as dimmed `PointMark`s. The spec
//      explicitly forbids silently dropping them — visible honesty
//      beats false precision.
//    - **Hover** (via `VariabilityLaneContext`) draws a vertical rule
//      + emphasized point at the hovered sample's center, and adds the
//      live value to the caption. The lane also captures its own
//      hovers and publishes them to the shared context — the ECG-side
//      of the linkage reads that state and draws its own band overlay.
//    - Time axis is hidden — the ECG canvas above owns axis labeling.
//    - Y axis carries the metric's own scale, auto-fit around the
//      eligible samples with a small pad; empty / all-ineligible data
//      falls back to a benign [0, 1].
//

import Charts
import SwiftUI

/// A single sample on the variability lane. Carries both the window
/// bounds (for the window-on-signal hover linkage) and the scalar
/// metric value.
///
/// Public because this is the wire type between the App target's
/// orchestrator (which computes samples via MurmurMetrics) and this
/// view. Callers that don't need window bounds can construct with
/// `windowStartSeconds == windowEndSeconds == center`; the view uses
/// `windowCenterSeconds` for rendering positions.
public struct VariabilityLaneSample: Sendable, Equatable, Codable, Identifiable {

    /// Start of the aggregation window (seconds from recording start).
    public let windowStartSeconds: Double

    /// End of the aggregation window (seconds from recording start).
    public let windowEndSeconds: Double

    /// The metric value in the window. `.nan` is allowed and treated
    /// as "no value" — such a sample is only rendered if `isEligible`
    /// is `false` (dimmed point) and is otherwise dropped.
    public let value: Double

    /// `true` when the window met the caller's quality / adequacy
    /// floor. Ineligible windows render as dimmed points; eligible
    /// ones join the line.
    public let isEligible: Bool

    public init(
        windowStartSeconds: Double,
        windowEndSeconds: Double,
        value: Double,
        isEligible: Bool
    ) {
        self.windowStartSeconds = windowStartSeconds
        self.windowEndSeconds = windowEndSeconds
        self.value = value
        self.isEligible = isEligible
    }

    /// Center of the window — the x-coordinate the lane renders at.
    public var windowCenterSeconds: Double {
        (windowStartSeconds + windowEndSeconds) / 2.0
    }

    /// Stable identity for `Chart` `ForEach`; the window center is
    /// unique per sample by construction (windows placed on a
    /// monotonic stride).
    public var id: Double { windowCenterSeconds }
}

/// A rolling HRV metric rendered as a lane under the ECG. Time bounds
/// are passed as a `ClosedRange<Double>` in seconds so the caller can
/// derive them from a `RecordingViewport` (main app) or a fixed pair
/// (snapshot tests) without dragging a MainActor observable across
/// the boundary.
struct VariabilityLane: View {

    /// Samples to render. Callers are responsible for filtering to
    /// (roughly) the visible window; the view further clips
    /// out-of-domain values in `chartXScale`, so overshoot is safe.
    let samples: [VariabilityLaneSample]

    /// Absolute time range (seconds from recording start) for the
    /// x-axis. Matches the ECG canvas's viewport range for shared-axis
    /// alignment.
    let timeRangeSeconds: ClosedRange<Double>

    /// Metric name to display in the caption ("RMSSD", "pNN50", …).
    let metricLabel: String

    /// Unit string appended after the value ("ms", "%", "bpm").
    let unit: String

    /// Window length, purely for the caption ("5-min window"). Nil
    /// when the caller doesn't want to advertise it.
    let windowCaption: String?

    /// Optional external hover coordinate (seconds from recording
    /// start). When non-nil, the lane draws a highlight ruler +
    /// emphasized point at that time. Passed by BedsideView from
    /// `VariabilityLaneContext.shared.hoveredTimeSeconds` — enables
    /// the ECG-hover-to-lane-highlight direction without the lane
    /// having to know about the context singleton.
    let externalHoverTimeSeconds: Double?

    /// Called whenever the lane's own hover captures a time (or `nil`
    /// on exit). BedsideView forwards to
    /// `VariabilityLaneContext.setHover(...)`. Optional — snapshot
    /// tests and previews pass `nil`.
    let onLaneHover: ((Double?) -> Void)?

    /// Optional preset-picker action attached to the caption. When
    /// non-nil, a "Menu" chip appears in the caption row.
    let onPickWindowPreset: ((VariabilityWindowPreset) -> Void)?

    /// The currently-selected preset — displayed on the picker chip.
    let selectedPreset: VariabilityWindowPreset?

    private static let laneHeight: CGFloat = 60

    init(
        samples: [VariabilityLaneSample],
        timeRangeSeconds: ClosedRange<Double>,
        metricLabel: String,
        unit: String,
        windowCaption: String? = nil,
        externalHoverTimeSeconds: Double? = nil,
        selectedPreset: VariabilityWindowPreset? = nil,
        onLaneHover: ((Double?) -> Void)? = nil,
        onPickWindowPreset: ((VariabilityWindowPreset) -> Void)? = nil
    ) {
        self.samples = samples
        self.timeRangeSeconds = timeRangeSeconds
        self.metricLabel = metricLabel
        self.unit = unit
        self.windowCaption = windowCaption
        self.externalHoverTimeSeconds = externalHoverTimeSeconds
        self.selectedPreset = selectedPreset
        self.onLaneHover = onLaneHover
        self.onPickWindowPreset = onPickWindowPreset
    }

    /// Effective hover coord — the external one, if the parent gave
    /// one; otherwise the lane's own captured hover.
    private var hoverTime: Double? { externalHoverTimeSeconds ?? internalHoverTime }

    /// Locally-captured hover coord from the lane's own overlay.
    /// Kept private — parents that want the value should read the
    /// shared context (populated by `onLaneHover`).
    @State private var internalHoverTime: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            captionRow
            chart
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("variability-lane")
    }

    // MARK: - Caption

    private var captionRow: some View {
        HStack(spacing: 8) {
            Text(metricLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("variability-lane-label")
            if let caption = windowCaption, !caption.isEmpty {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let hoverSample = hoveredSample, hoverSample.value.isFinite {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(hoverValueString(hoverSample))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("variability-lane-hover-value")
            }
            Spacer()
            if let picker = onPickWindowPreset, let selected = selectedPreset {
                windowPresetPicker(selected: selected, pick: picker)
            }
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func hoverValueString(_ sample: VariabilityLaneSample) -> String {
        // Always one decimal — matches the ECG Metrics report format
        // ("50.0 ms") so copy-paste stays consistent.
        String(format: "%.1f", sample.value)
    }

    private func windowPresetPicker(
        selected: VariabilityWindowPreset,
        pick: @escaping (VariabilityWindowPreset) -> Void
    ) -> some View {
        Menu {
            ForEach(VariabilityWindowPreset.allCases, id: \.self) { preset in
                Button(preset.shortLabel) { pick(preset) }
                    .accessibilityIdentifier("variability-lane-preset-\(preset.rawValue)")
            }
        } label: {
            HStack(spacing: 2) {
                Text(selected.shortLabel)
                    .font(.caption2.monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("variability-lane-preset-picker")
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        if samples.isEmpty {
            emptyState
        } else {
            Chart {
                // Eligible line — chunked into contiguous runs so the
                // line never bridges across ineligible / gap regions.
                ForEach(eligibleRuns.indices, id: \.self) { idx in
                    let run = eligibleRuns[idx]
                    ForEach(run) { sample in
                        LineMark(
                            x: .value("t", sample.windowCenterSeconds),
                            y: .value(metricLabel, sample.value),
                            series: .value("run", idx)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                // Ineligible marks — dimmed, at the window center. The
                // value coordinate may be NaN when the computer had
                // nothing to plot; place them on the y-axis floor in
                // that case so they remain visible.
                ForEach(ineligibleMarks) { sample in
                    PointMark(
                        x: .value("t", sample.windowCenterSeconds),
                        y: .value("ineligible", ineligibleYPosition(for: sample))
                    )
                    .symbol(.circle)
                    .symbolSize(18)
                    .foregroundStyle(Color.secondary.opacity(0.35))
                }
                // Hover highlight — vertical rule at the hovered time
                // + emphasized point at the sample's center. Rendered
                // only when a sample was located; drawing a ruler at
                // an empty time would be visual noise.
                if let hover = hoveredSample {
                    RuleMark(x: .value("hover", hover.windowCenterSeconds))
                        .foregroundStyle(Color.accentColor.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    if hover.value.isFinite {
                        PointMark(
                            x: .value("hover", hover.windowCenterSeconds),
                            y: .value("hover-y", hover.value)
                        )
                        .symbol(.circle)
                        .symbolSize(60)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: timeRangeSeconds)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel().font(.caption2.monospacedDigit())
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                }
            }
            .chartYScale(domain: yDomain)
            .frame(height: Self.laneHeight)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.06))
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // Hover capture — `.chartOverlay` gives us the proxy
            // needed to convert pointer x to a time coord. On exit
            // clear both local + shared state so downstream views
            // stop rendering stale highlights.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                // `plotFrame` supersedes `plotAreaFrame`
                                // (macOS 14+); the origin is what we
                                // need to map from view-local x to
                                // chart-local x.
                                let plotOrigin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                                let localX = point.x - plotOrigin.x
                                if let t: Double = proxy.value(atX: localX) {
                                    internalHoverTime = t
                                    onLaneHover?(t)
                                }
                            case .ended:
                                internalHoverTime = nil
                                onLaneHover?(nil)
                            }
                        }
                }
            }
        }
    }

    private var emptyState: some View {
        ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
            Text("No metric samples in this window")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(height: Self.laneHeight)
        .accessibilityIdentifier("variability-lane-empty")
    }

    // MARK: - Sample partitioning

    /// Split eligible-and-finite samples into runs separated by any
    /// ineligible sample. Each run renders as its own `series`, so the
    /// line does not bridge gaps.
    private var eligibleRuns: [[VariabilityLaneSample]] {
        var runs: [[VariabilityLaneSample]] = []
        var current: [VariabilityLaneSample] = []
        for s in samples {
            if s.isEligible && s.value.isFinite {
                current.append(s)
            } else if !current.isEmpty {
                runs.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Samples the caller flagged ineligible. These emit as dimmed
    /// points; the caller can render a NaN value and we'll place the
    /// point at the y-domain floor.
    private var ineligibleMarks: [VariabilityLaneSample] {
        samples.filter { !$0.isEligible }
    }

    /// The sample that best contains the current hover time.
    /// Duplicates the lookup logic in `VariabilityLaneContext` but
    /// operates on the view's local `samples` slice — the view
    /// doesn't otherwise depend on the context singleton, so previews
    /// / snapshot tests can drive `externalHoverTimeSeconds` directly.
    private var hoveredSample: VariabilityLaneSample? {
        guard let t = hoverTime else { return nil }
        var best: VariabilityLaneSample?
        var bestDist = Double.infinity
        for s in samples where t >= s.windowStartSeconds && t <= s.windowEndSeconds {
            let d = abs(t - s.windowCenterSeconds)
            if d < bestDist {
                bestDist = d
                best = s
            }
        }
        return best
    }

    // MARK: - Y-axis math

    private var yDomain: ClosedRange<Double> {
        let eligibleValues = samples
            .filter { $0.isEligible && $0.value.isFinite }
            .map(\.value)
        guard let lo = eligibleValues.min(), let hi = eligibleValues.max() else {
            return 0.0...1.0
        }
        if abs(hi - lo) < 1e-9 {
            let pad = max(abs(lo) * 0.1, 1)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    private func ineligibleYPosition(for sample: VariabilityLaneSample) -> Double {
        if sample.value.isFinite { return sample.value }
        return yDomain.lowerBound
    }
}
