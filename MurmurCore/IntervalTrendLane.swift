//
//  IntervalTrendLane.swift
//  MurmurCore
//
//  The interval trend lane — hours-scale trend of an interval metric
//  (QTc default, PR / QRS switchable) rendered beneath the ECG, sharing
//  the same time axis as the pinned trace and the variability lane.
//  Named use case: catching drug-induced QT prolongation across hours.
//
//  Reads from `IntervalMarkingsContext` (beats + template + QTc formula)
//  and `IntervalTrendLaneContext` (metric, bin length, show mode). Both
//  are shared @Observable singletons wired by the App target's
//  orchestrator, so the view has no incoming data dependencies from
//  its parent — like `VariabilityLane`, it hides itself when the
//  context has nothing to show.
//
//  Rendering follows project_interval_trend_lanes_design.md:
//    - Median + IQR ribbon per bin (never a single smoothed line).
//    - Patient-normal baseline band from the fiducial-store template.
//    - Low-confidence bins render dimmed + hatched, never plotted as
//      confident values.
//    - Hover a bin → publishes the time to VariabilityLaneContext so
//      the ECG canvas above can draw the "window on signal" overlay;
//      likewise reads the ECG's hover for the reverse direction.
//    - Click a bin → focuses the beat closest to the bin center via
//      IntervalMarkingsContext.requestJump(...), which drives the
//      viewport to the beat and opens the caliper readout.
//    - Threshold guides are user-set only — the app never ships built-
//      in clinical cutoffs. Guides live in @State on the view for now
//      (persisting them is a follow-up when analyst authoring lands).
//

import Charts
import SwiftUI

struct IntervalTrendLane: View {

    /// Absolute time range (seconds from recording start) for the
    /// x-axis. Matches the pinned trace's viewport so the trend lines
    /// up beat-for-beat with what's on screen.
    let timeRangeSeconds: ClosedRange<Double>

    /// Optional external hover coordinate (seconds from recording
    /// start), published by the shared variability context. When
    /// non-nil, the lane draws a vertical rule + highlighted bin at
    /// that time.
    let externalHoverTimeSeconds: Double?

    /// Called whenever the lane's own hover captures a time (or `nil`
    /// on exit). BedsideView forwards to the shared context so the
    /// ECG canvas above can respond.
    let onLaneHover: ((Double?) -> Void)?

    /// Fires when the analyst clicks a bin. Passes the bin's center
    /// time (seconds from recording start). BedsideView translates
    /// this into a focus-beat + viewport jump.
    let onBinClick: ((Double) -> Void)?

    /// Precomputed data — passed in so the view stays trivially
    /// snapshot-testable. In the live app the wrapper below reads
    /// beats + template + config from the shared contexts and
    /// computes this on demand.
    let data: IntervalTrendData

    /// Selected metric label ("QTc", "PR", "QRS-width") — echoed into
    /// the caption + control chip.
    let metric: IntervalTrendMetric

    /// Show-mode ("median + IQR", etc.). Drives the ribbon rendering.
    let showMode: IntervalTrendShowMode

    /// Callbacks for the control-chip menus. Nil hides the picker.
    let onPickMetric: ((IntervalTrendMetric) -> Void)?
    let onPickBinPreset: ((IntervalTrendBinPreset) -> Void)?
    let onPickShowMode: ((IntervalTrendShowMode) -> Void)?

    /// Analyst-placed threshold guides for the current metric.
    /// Rendered as dashed horizontal lines with tags — never asserted
    /// by the app.
    let guides: [IntervalTrendGuide]

    /// Add a guide at a user-picked value + label. Non-nil enables the
    /// "+ guide" chip in the caption row.
    let onAddGuide: ((Double, String) -> Void)?

    /// Remove a guide by id. Non-nil enables the guide's tap-to-remove
    /// context menu on the lane.
    let onRemoveGuide: ((UUID) -> Void)?

    /// Currently-selected bin-length preset — displayed on the chip.
    let selectedBinPreset: IntervalTrendBinPreset

    private static let laneHeight: CGFloat = 84

    @State private var internalHoverTime: Double?

    private var hoverTime: Double? { externalHoverTimeSeconds ?? internalHoverTime }

    init(
        timeRangeSeconds: ClosedRange<Double>,
        data: IntervalTrendData,
        metric: IntervalTrendMetric,
        showMode: IntervalTrendShowMode,
        selectedBinPreset: IntervalTrendBinPreset,
        guides: [IntervalTrendGuide] = [],
        externalHoverTimeSeconds: Double? = nil,
        onLaneHover: ((Double?) -> Void)? = nil,
        onBinClick: ((Double) -> Void)? = nil,
        onPickMetric: ((IntervalTrendMetric) -> Void)? = nil,
        onPickBinPreset: ((IntervalTrendBinPreset) -> Void)? = nil,
        onPickShowMode: ((IntervalTrendShowMode) -> Void)? = nil,
        onAddGuide: ((Double, String) -> Void)? = nil,
        onRemoveGuide: ((UUID) -> Void)? = nil
    ) {
        self.timeRangeSeconds = timeRangeSeconds
        self.data = data
        self.metric = metric
        self.showMode = showMode
        self.selectedBinPreset = selectedBinPreset
        self.guides = guides
        self.externalHoverTimeSeconds = externalHoverTimeSeconds
        self.onLaneHover = onLaneHover
        self.onBinClick = onBinClick
        self.onPickMetric = onPickMetric
        self.onPickBinPreset = onPickBinPreset
        self.onPickShowMode = onPickShowMode
        self.onAddGuide = onAddGuide
        self.onRemoveGuide = onRemoveGuide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            captionRow
            chart
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("interval-trend-lane")
    }

    // MARK: - Caption row

    private var captionRow: some View {
        HStack(spacing: 6) {
            Text(metric.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("interval-trend-lane-label")
            Text("·")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(metric.unit)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            if let baseline = data.baselineMedian {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("normal " + String(format: "%.0f", baseline))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let hover = hoveredBin {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(hoverValueString(hover))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("interval-trend-lane-hover-value")
            }

            Spacer()

            metricPicker
            binPicker
            showModePicker
            addGuideChip
        }
    }

    @ViewBuilder
    private var addGuideChip: some View {
        if let onAdd = onAddGuide {
            Menu {
                Section("Add guide (\(metric.displayName), ms)") {
                    ForEach([300, 350, 400, 450, 500, 550, 600], id: \.self) { value in
                        Button("\(value) ms — user-set") {
                            onAdd(Double(value), "\(value) ms (user-set)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text("guide")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("interval-trend-lane-add-guide")
        }
    }

    @ViewBuilder
    private var metricPicker: some View {
        if let onPick = onPickMetric {
            controlChip(label: metric.displayName, identifier: "interval-trend-lane-metric-picker") {
                Menu {
                    ForEach(IntervalTrendMetric.allCases, id: \.self) { option in
                        Button(option.displayName) { onPick(option) }
                    }
                } label: {
                    chipContent(text: metric.displayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var binPicker: some View {
        if let onPick = onPickBinPreset {
            controlChip(label: selectedBinPreset.shortLabel, identifier: "interval-trend-lane-bin-picker") {
                Menu {
                    ForEach(IntervalTrendBinPreset.allCases, id: \.self) { option in
                        Button(option.shortLabel) { onPick(option) }
                    }
                } label: {
                    chipContent(text: selectedBinPreset.shortLabel)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var showModePicker: some View {
        if let onPick = onPickShowMode {
            controlChip(label: showMode.displayName, identifier: "interval-trend-lane-show-picker") {
                Menu {
                    ForEach(IntervalTrendShowMode.allCases, id: \.self) { option in
                        Button(option.displayName) { onPick(option) }
                    }
                } label: {
                    chipContent(text: showMode.displayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func controlChip<Content: View>(
        label: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .accessibilityIdentifier(identifier)
    }

    private func chipContent(text: String) -> some View {
        HStack(spacing: 2) {
            Text(text)
                .font(.caption2.monospacedDigit())
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private func hoverValueString(_ bin: IntervalTrendBin) -> String {
        if !bin.isEligible {
            return "low conf."
        }
        return String(format: "%.0f", bin.median)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        if data.bins.isEmpty {
            emptyState
        } else {
            Chart {
                // Baseline band (template range) — behind everything so
                // the trend reads AGAINST the patient's normal.
                if let band = data.baselineBand {
                    RectangleMark(
                        xStart: .value("t0", timeRangeSeconds.lowerBound),
                        xEnd: .value("t1", timeRangeSeconds.upperBound),
                        yStart: .value("baseline-lo", band.lowerBound),
                        yEnd: .value("baseline-hi", band.upperBound)
                    )
                    .foregroundStyle(Color.green.opacity(0.14))
                }

                // Analyst-placed threshold guides — dashed horizontal
                // lines with a right-anchored label. The "(user-set)"
                // string on every label makes it impossible to mistake
                // for a built-in clinical cutoff.
                ForEach(guides) { guide in
                    RuleMark(y: .value("guide", guide.valueMs))
                        .foregroundStyle(Color.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .annotation(position: .topTrailing, alignment: .trailing, spacing: 2) {
                            Text(guide.label)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                                )
                                .overlay(
                                    Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                                )
                                .contextMenu {
                                    if let remove = onRemoveGuide {
                                        Button(role: .destructive) {
                                            remove(guide.id)
                                        } label: {
                                            Label("Remove guide", systemImage: "trash")
                                        }
                                    }
                                }
                                .accessibilityIdentifier("interval-trend-lane-guide-\(guide.id.uuidString)")
                        }
                }

                // IQR ribbon — one AreaMark per eligible run so the
                // ribbon never bridges across ineligible / gap bins.
                if showMode == .medianAndIQR {
                    ForEach(eligibleRuns.indices, id: \.self) { idx in
                        let run = eligibleRuns[idx]
                        ForEach(run) { bin in
                            AreaMark(
                                x: .value("t", bin.centerSeconds),
                                yStart: .value("q1", bin.q1),
                                yEnd: .value("q3", bin.q3),
                                series: .value("run", idx)
                            )
                            .foregroundStyle(Color.accentColor.opacity(0.16))
                            .interpolationMethod(.monotone)
                        }
                    }
                }

                // Per-beat scatter mode — every underlying beat as a
                // faint point. Only makes sense at moderate zoom, but
                // the view doesn't gate — the analyst asked for it.
                if showMode == .perBeatScatter {
                    ForEach(scatterPoints, id: \.id) { pt in
                        PointMark(
                            x: .value("t", pt.time),
                            y: .value("beat", pt.value)
                        )
                        .symbol(.circle)
                        .symbolSize(10)
                        .foregroundStyle(Color.accentColor.opacity(0.35))
                    }
                }

                // Median line — always drawn. Chunked into eligible
                // runs so the line breaks across low-confidence gaps.
                ForEach(eligibleRuns.indices, id: \.self) { idx in
                    let run = eligibleRuns[idx]
                    ForEach(run) { bin in
                        LineMark(
                            x: .value("t", bin.centerSeconds),
                            y: .value("median", bin.median),
                            series: .value("run", idx)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                    }
                }

                // Ineligible bins — dimmed points at the median, so
                // the analyst sees WHERE the confidence failed rather
                // than a gap they'd have to guess about.
                ForEach(ineligibleBins) { bin in
                    PointMark(
                        x: .value("t", bin.centerSeconds),
                        y: .value("dim", bin.median)
                    )
                    .symbol(.circle)
                    .symbolSize(18)
                    .foregroundStyle(Color.secondary.opacity(0.35))
                }

                // Hover highlight — rule + emphasized point at the
                // hovered bin's center. Also fires when the ECG is the
                // hover source.
                if let hover = hoveredBin {
                    RuleMark(x: .value("hover", hover.centerSeconds))
                        .foregroundStyle(Color.accentColor.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    if hover.median.isFinite {
                        PointMark(
                            x: .value("hover", hover.centerSeconds),
                            y: .value("hover-y", hover.median)
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
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
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
                        .onTapGesture { location in
                            let plotOrigin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                            let localX = location.x - plotOrigin.x
                            if let t: Double = proxy.value(atX: localX) {
                                onBinClick?(t)
                            }
                        }
                }
            }
            // Repro caption emitted verbatim to the citation menu.
            Text(data.reproCaption)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .accessibilityIdentifier("interval-trend-lane-repro-caption")
        }
    }

    private var emptyState: some View {
        ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
            Text("Interval trend unavailable — no fiducials in this recording")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(height: Self.laneHeight)
        .accessibilityIdentifier("interval-trend-lane-empty")
    }


    // MARK: - Bin partitioning

    private var eligibleRuns: [[IntervalTrendBin]] {
        var runs: [[IntervalTrendBin]] = []
        var current: [IntervalTrendBin] = []
        for b in data.bins {
            if b.isEligible && b.median.isFinite {
                current.append(b)
            } else if !current.isEmpty {
                runs.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private var ineligibleBins: [IntervalTrendBin] {
        data.bins.filter { !$0.isEligible }
    }

    private struct ScatterPoint: Identifiable {
        let id: String
        let time: Double
        let value: Double
    }

    private var scatterPoints: [ScatterPoint] {
        var points: [ScatterPoint] = []
        for bin in data.bins where bin.isEligible {
            for (idx, v) in bin.perBeatValues.enumerated() {
                points.append(
                    ScatterPoint(
                        id: "\(bin.centerSeconds)-\(idx)",
                        time: bin.centerSeconds,
                        value: v
                    )
                )
            }
        }
        return points
    }

    private var hoveredBin: IntervalTrendBin? {
        guard let t = hoverTime else { return nil }
        var best: IntervalTrendBin?
        var bestDist = Double.infinity
        for b in data.bins where t >= b.startSeconds && t <= b.endSeconds {
            let d = abs(t - b.centerSeconds)
            if d < bestDist {
                bestDist = d
                best = b
            }
        }
        return best
    }

    // MARK: - Y-axis math

    private var yDomain: ClosedRange<Double> {
        let values = data.bins
            .filter { $0.isEligible && $0.median.isFinite }
            .flatMap { [$0.q1, $0.q3, $0.median] }
        guard let lo = values.min(), let hi = values.max() else {
            // Fall back to the baseline band if we have it.
            if let band = data.baselineBand {
                let pad = max((band.upperBound - band.lowerBound) * 0.5, 20)
                return (band.lowerBound - pad)...(band.upperBound + pad)
            }
            return 0.0...1.0
        }
        if abs(hi - lo) < 1e-9 {
            let pad = max(abs(lo) * 0.1, 10)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.15
        return (lo - pad)...(hi + pad)
    }
}
