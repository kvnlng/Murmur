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

/// Vertical event marker for the trend lane. Analyst-authored (drug
/// administration, dose change, procedural event, etc.). Sourced by
/// the caller from any `Annotation` whose category the reviewer has
/// promoted to "event-worthy" — no built-in classification.
public struct IntervalTrendEvent: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timeSeconds: Double
    public let label: String

    public init(id: UUID = UUID(), timeSeconds: Double, label: String) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.label = label
    }
}

/// Analyst-authored range finding overlaid on the trend lane. Amber
/// is the RESERVED accent for these — no other layer on the lane
/// carries the token (ratified B-RUO, project_mockup_review_pass.md).
/// Sourced from a MurmurCore `Annotation` the reviewer promoted to a
/// range finding; authoring UX (drag to select on the lane) is a
/// follow-up wire-up.
public struct IntervalTrendRangeFinding: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startSeconds: Double
    public let endSeconds: Double
    public let label: String

    public init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double, label: String) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.label = label
    }
}

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

    /// Analyst-authored events (drug administration, dose change,
    /// etc.) surfaced as vertical markers on the axis so a drift can
    /// be read against WHAT CHANGED. Sourced from the recording's
    /// annotations by the caller — the lane makes no policy about
    /// which annotations count as events.
    let events: [IntervalTrendEvent]

    /// Analyst-authored range findings — the ONLY amber-tinted layer
    /// on the lane. Renders as a translucent orange overlay + chip
    /// label. The lane makes no policy about which annotations count
    /// as findings.
    let rangeFindings: [IntervalTrendRangeFinding]

    /// Add a guide at a user-picked value + label. Non-nil enables the
    /// "+ guide" chip in the caption row.
    let onAddGuide: ((Double, String) -> Void)?

    /// Remove a guide by id. Non-nil enables the guide's tap-to-remove
    /// context menu on the lane.
    let onRemoveGuide: ((UUID) -> Void)?

    /// Author a range finding at the given time range via drag-to-select.
    /// Per project_drag_to_author_range_finding_spec.md: click-drag past
    /// a ~6 pt threshold on the lane body composes a factual coordinate
    /// label + immutable citation caption and creates a range
    /// `Annotation`. Nil disables authoring — the lane's tap/hover
    /// gestures still work.
    let onAuthorRange: ((_ startSeconds: Double,
                         _ endSeconds: Double,
                         _ defaultLabel: String,
                         _ citationCaption: String) -> Void)?

    /// Currently-selected bin-length preset — displayed on the chip.
    let selectedBinPreset: IntervalTrendBinPreset

    private static let laneHeight: CGFloat = 84
    /// Drag threshold to distinguish authoring from a stray tap.
    /// Set from the spec (project_drag_to_author_range_finding_spec.md).
    private static let authoringDragThresholdPt: CGFloat = 6

    @State private var internalHoverTime: Double?
    /// Live time-range for an in-progress authoring drag, already
    /// snapped to bin edges. Nil when no drag is active. Seeded via
    /// `debugAuthoringMarquee` for snapshot tests that need to render
    /// the mid-drag state deterministically (SwiftUI can't
    /// programmatically fire the real DragGesture in a headless
    /// ImageRenderer).
    @State private var authoringMarquee: ClosedRange<Double>?

    /// Test-only seed for `authoringMarquee`. Setting this init
    /// parameter renders the amber marquee in its mid-drag state so
    /// snapshot fixtures can capture it; production callers omit it.
    let debugAuthoringMarquee: ClosedRange<Double>?

    private var hoverTime: Double? { externalHoverTimeSeconds ?? internalHoverTime }

    init(
        timeRangeSeconds: ClosedRange<Double>,
        data: IntervalTrendData,
        metric: IntervalTrendMetric,
        showMode: IntervalTrendShowMode,
        selectedBinPreset: IntervalTrendBinPreset,
        guides: [IntervalTrendGuide] = [],
        events: [IntervalTrendEvent] = [],
        rangeFindings: [IntervalTrendRangeFinding] = [],
        externalHoverTimeSeconds: Double? = nil,
        onLaneHover: ((Double?) -> Void)? = nil,
        onBinClick: ((Double) -> Void)? = nil,
        onPickMetric: ((IntervalTrendMetric) -> Void)? = nil,
        onPickBinPreset: ((IntervalTrendBinPreset) -> Void)? = nil,
        onPickShowMode: ((IntervalTrendShowMode) -> Void)? = nil,
        onAddGuide: ((Double, String) -> Void)? = nil,
        onRemoveGuide: ((UUID) -> Void)? = nil,
        onAuthorRange: ((Double, Double, String, String) -> Void)? = nil,
        debugAuthoringMarquee: ClosedRange<Double>? = nil
    ) {
        self.timeRangeSeconds = timeRangeSeconds
        self.data = data
        self.metric = metric
        self.showMode = showMode
        self.selectedBinPreset = selectedBinPreset
        self.guides = guides
        self.events = events
        self.rangeFindings = rangeFindings
        self.externalHoverTimeSeconds = externalHoverTimeSeconds
        self.onLaneHover = onLaneHover
        self.onBinClick = onBinClick
        self.onPickMetric = onPickMetric
        self.onPickBinPreset = onPickBinPreset
        self.onPickShowMode = onPickShowMode
        self.onAddGuide = onAddGuide
        self.onRemoveGuide = onRemoveGuide
        self.onAuthorRange = onAuthorRange
        self.debugAuthoringMarquee = debugAuthoringMarquee
        self._authoringMarquee = State(initialValue: debugAuthoringMarquee)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            captionRow
            chart
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        // AX1: mark the lane as a container that CONTAINS its children as
        // separate elements. Without this, the container identifier bleeds
        // onto the inner menu buttons and all four (metric/bin/mode/guide)
        // resolve to `interval-trend-lane`, so no test can address one
        // unambiguously (feedback_swiftui_accessibility_contain.md).
        .accessibilityElement(children: .contain)
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
            if IntervalTrendMetric.launchVisible.count <= 1 {
                // AX8: a dropdown that opens to a single option reads as
                // broken. QTc is the only launch-visible metric (PR +
                // QRS-width deferred to Phase 4b per
                // project_measurement_layer_gating.md), so render the metric
                // name as static text; it promotes back to a picker
                // automatically once a second metric becomes launch-visible.
                staticMetricChip
            } else {
                controlChip(label: metric.displayName, identifier: "interval-trend-lane-metric-picker") {
                    Menu {
                        ForEach(IntervalTrendMetric.launchVisible, id: \.self) { option in
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
    }

    /// Static (non-interactive) rendering of the current metric name. Keeps
    /// the `interval-trend-lane-metric-picker` identifier and the chip shape
    /// so layout + tests are stable across the eventual promotion to a
    /// dropdown, but drops the chevron so it never reads as a one-item menu.
    private var staticMetricChip: some View {
        Text(metric.displayName)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("interval-trend-lane-metric-picker")
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
                // Patient-normal baseline band — faint neutral
                // horizontal band at the template QT/QTc baseline
                // (project_qtc_trend_uncertainty_wireup_spec.md): the
                // trend is read as a DEPARTURE from this. Neutral,
                // never caution-hued — a departure past the band is
                // just information at this layer; only the analyst's
                // authored findings carry the amber accent.
                if let band = data.baselineBand {
                    RectangleMark(
                        xStart: .value("t0", timeRangeSeconds.lowerBound),
                        xEnd: .value("t1", timeRangeSeconds.upperBound),
                        yStart: .value("baseline-lo", band.lowerBound),
                        yEnd: .value("baseline-hi", band.upperBound)
                    )
                    .foregroundStyle(Color.primary.opacity(0.08))
                }

                // Live authoring marquee — a semi-transparent amber
                // rectangle over the currently-dragging x-range, full
                // lane height. Same accent as the released range
                // findings so the analyst sees they are authoring the
                // same visual language. Snapped to bin edges by the
                // gesture handler; degenerate drags (< 1 bin) are
                // ignored on release.
                if let marquee = authoringMarquee {
                    RectangleMark(
                        xStart: .value("marq-t0", marquee.lowerBound),
                        xEnd: .value("marq-t1", marquee.upperBound),
                        yStart: .value("marq-y0", yDomain.lowerBound),
                        yEnd: .value("marq-y1", yDomain.upperBound)
                    )
                    .foregroundStyle(Color.orange.opacity(0.22))
                    .annotation(
                        position: .top,
                        alignment: .leading,
                        spacing: 2,
                        overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))
                    ) {
                        Text(marqueeReadout(for: marquee))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .accessibilityIdentifier("interval-trend-lane-authoring-readout")
                    }
                }

                // Analyst-authored range findings — the ONLY amber
                // layer on the lane per ratified B-RUO. Rendered
                // BEHIND events and guides so those still read on top
                // of the finding's tint. `startSeconds`/`endSeconds`
                // clamp to the visible x-range via chart scale.
                ForEach(rangeFindings) { finding in
                    RectangleMark(
                        xStart: .value("find-t0", finding.startSeconds),
                        xEnd: .value("find-t1", finding.endSeconds),
                        yStart: .value("find-y0", yDomain.lowerBound),
                        yEnd: .value("find-y1", yDomain.upperBound)
                    )
                    .foregroundStyle(Color.orange.opacity(0.15))
                    .annotation(
                        position: .top,
                        alignment: .leading,
                        spacing: 2,
                        overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))
                    ) {
                        Text(finding.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .accessibilityIdentifier("interval-trend-lane-finding-\(finding.id.uuidString)")
                    }
                }

                // Analyst-authored events — vertical markers on the
                // axis so drift can be read against WHAT CHANGED.
                // Rendered BEFORE guides so a horizontal guide draws
                // on top of the event's line (guides frame values;
                // events frame time — order chosen so labels don't
                // occlude each other).
                ForEach(events) { event in
                    RuleMark(x: .value("event-t", event.timeSeconds))
                        .foregroundStyle(Color.purple.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                        // `.topLeading` inside the plot + fit-to-plot
                        // overflow keeps the label from being clipped
                        // by the surrounding RoundedRectangle.
                        .annotation(
                            position: .topLeading,
                            alignment: .leading,
                            spacing: 2,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))
                        ) {
                            Text(event.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.purple.opacity(0.85))
                                )
                                .accessibilityIdentifier("interval-trend-lane-event-\(event.id.uuidString)")
                        }
                }

                // Analyst-placed threshold guides — dashed horizontal
                // lines with a right-anchored label. Distinct overlay
                // color (blue) so the guide reads as USER-authored,
                // NEVER a built-in clinical cutoff — the app never
                // ships thresholds per
                // project_interval_trend_lanes_design.md +
                // project_qtc_trend_uncertainty_wireup_spec.md. The
                // "(user-set)" string in the label reinforces the
                // origin at read time.
                ForEach(guides) { guide in
                    RuleMark(y: .value("guide", guide.valueMs))
                        .foregroundStyle(Color.blue.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                        .annotation(
                            position: .topTrailing,
                            alignment: .trailing,
                            spacing: 2,
                            overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))
                        ) {
                            Text(guide.label)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                                )
                                .overlay(
                                    Capsule().stroke(Color.blue.opacity(0.45), lineWidth: 0.5)
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

                // Low-confidence bins — translucent gray fill across the
                // bin's x-range at full plot height. Distinct from the
                // Phase-4 censored open-top treatment: this says
                // "measured but noisy"; open-top says "true value ≥
                // reported (walk hit ceiling)". Rendered as a native
                // RectangleMark (GPU-friendly, negligible per-frame
                // cost during pan) rather than a per-frame Canvas
                // hatch — the fill is subordinate to the median line
                // without triggering the SwiftUI Canvas re-draw cost
                // that the previous crosshatch incurred.
                ForEach(ineligibleBins) { bin in
                    RectangleMark(
                        xStart: .value("ineligible-t0", bin.startSeconds),
                        xEnd: .value("ineligible-t1", bin.endSeconds),
                        yStart: .value("ineligible-y0", yDomain.lowerBound),
                        yEnd: .value("ineligible-y1", yDomain.upperBound)
                    )
                    .foregroundStyle(Color.primary.opacity(0.12))
                }

                // IQR ribbon (wide, ~13% opacity) — how much QT actually
                // varies beat-to-beat = PHYSIOLOGICAL spread. One
                // AreaMark per eligible run so the ribbon never bridges
                // across ineligible / gap bins. Sits OUTSIDE the
                // measurement band per project_qtc_trend_uncertainty_wireup_spec.md.
                if showMode == .medianAndIQR {
                    ForEach(eligibleRuns.indices, id: \.self) { idx in
                        let run = eligibleRuns[idx]
                        ForEach(run) { bin in
                            AreaMark(
                                x: .value("t", bin.centerSeconds),
                                yStart: .value("q1", bin.q1),
                                yEnd: .value("q3", bin.q3),
                                series: .value("iqr-run", idx)
                            )
                            .foregroundStyle(Color.primary.opacity(0.13))
                            .interpolationMethod(.monotone)
                        }
                    }
                }

                // Measurement band (tight, ~30% opacity) — bootstrap CI
                // on the bin median = MEASUREMENT uncertainty (how well
                // we know the trend point). Distinct from IQR: denser
                // + narrower, always drawn regardless of show-mode. This
                // is the visible surface of the calibrated
                // per-beat-uncertainty aggregation.
                //
                // For CENSORED bins (a beat inside hit the T-search-
                // window ceiling → true T-offset ≥ reported), the band
                // is drawn open UPWARD: yStart at bandLower, yEnd at
                // the top of the y-domain — the true measurement is
                // "≥ bandLower". The up-chevron markers + "QT ≥"
                // annotation on the top edge (Canvas overlay below)
                // signal the lower-bound state.
                ForEach(eligibleRuns.indices, id: \.self) { idx in
                    let run = eligibleRuns[idx]
                    ForEach(run) { bin in
                        AreaMark(
                            x: .value("t", bin.centerSeconds),
                            yStart: .value("band-lo", bin.bandLowerMs),
                            yEnd: .value(
                                "band-hi",
                                bin.hasCensoredBeats ? yDomain.upperBound : bin.bandUpperMs
                            ),
                            series: .value("band-run", idx)
                        )
                        .foregroundStyle(Color.primary.opacity(0.30))
                        .interpolationMethod(.monotone)
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
                        .foregroundStyle(Color.primary.opacity(0.35))
                    }
                }

                // Median line — always drawn in NEUTRAL ink per ratified
                // B-RUO color discipline (project_mockup_review_pass.md):
                // app-computed departures never render in caution hues,
                // only analyst-marked findings use amber. Chunked into
                // eligible runs so the line breaks across low-confidence
                // gaps. Censored bins render the median DASHED, marking
                // "at least this prolonged, possibly more" — the point
                // estimate isn't a confident value.
                ForEach(eligibleRuns.indices, id: \.self) { idx in
                    let run = eligibleRuns[idx]
                    ForEach(run) { bin in
                        LineMark(
                            x: .value("t", bin.centerSeconds),
                            y: .value("median", bin.median),
                            series: .value("median-run", idx)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.primary)
                        .lineStyle(
                            bin.hasCensoredBeats
                                ? StrokeStyle(lineWidth: 1.8, lineJoin: .round, dash: [3, 3])
                                : StrokeStyle(lineWidth: 1.8, lineJoin: .round)
                        )
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

                // Censored-bin up-chevron + "QT ≥" annotation — signals
                // that the band top is UN-CAPPED (true value goes
                // upward from the bandLower). One marker per censored
                // bin sits just below the y-domain top edge so the
                // pattern reads as "arrows pointing off-chart," which
                // is the intended visual.
                ForEach(censoredBins) { bin in
                    let markerY = yDomain.upperBound
                        - (yDomain.upperBound - yDomain.lowerBound) * 0.06
                    PointMark(
                        x: .value("censored-t", bin.centerSeconds),
                        y: .value("censored-top", markerY)
                    )
                    .symbol(.triangle)
                    .symbolSize(28)
                    .foregroundStyle(Color.primary.opacity(0.70))
                    .annotation(position: .top, spacing: 0) {
                        Text("QT ≥")
                            .font(.system(size: 8, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("interval-trend-lane-censored-marker")
                    }
                }

                // Hover highlight — rule + emphasized point at the
                // hovered bin's center. Also fires when the ECG is the
                // hover source. Neutral ink for the app-computed hover;
                // no accent hue on a computed magnitude.
                if let hover = hoveredBin {
                    RuleMark(x: .value("hover", hover.centerSeconds))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    if hover.median.isFinite {
                        PointMark(
                            x: .value("hover", hover.centerSeconds),
                            y: .value("hover-y", hover.median)
                        )
                        .symbol(.circle)
                        .symbolSize(60)
                        .foregroundStyle(Color.primary)
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
                        // Drag-to-author. The `minimumDistance` gates the
                        // tap↔drag disambiguation per
                        // project_drag_to_author_range_finding_spec.md:
                        // a stray tap (< 6pt movement) still falls through
                        // to `onTapGesture` above; only a real drag
                        // enters authoring mode. Only active when the
                        // caller opted in with `onAuthorRange`.
                        .gesture(
                            onAuthorRange == nil
                                ? nil
                                : DragGesture(minimumDistance: Self.authoringDragThresholdPt)
                                    .onChanged { drag in
                                        let plotOrigin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                                        let x0 = min(drag.startLocation.x, drag.location.x) - plotOrigin.x
                                        let x1 = max(drag.startLocation.x, drag.location.x) - plotOrigin.x
                                        guard let t0: Double = proxy.value(atX: x0),
                                              let t1: Double = proxy.value(atX: x1),
                                              t1 > t0 else { return }
                                        authoringMarquee = snapAuthoringRange(from: t0, to: t1)
                                    }
                                    .onEnded { _ in
                                        if let range = authoringMarquee, isRangeAuthorable(range) {
                                            let label = composeAuthoringLabel(range: range)
                                            let citation = composeAuthoringCitation(range: range)
                                            onAuthorRange?(range.lowerBound, range.upperBound, label, citation)
                                        }
                                        authoringMarquee = nil
                                    }
                        )
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

    /// Bins containing at least one T-offset-censored beat. Rendered
    /// with the "open-top band + dashed median + QT ≥ marker" treatment.
    /// A bin can be BOTH ineligible AND censored on real data; the
    /// crosshatch (from `chartBackground`) sits behind and the censored
    /// treatment layers on top.
    private var censoredBins: [IntervalTrendBin] {
        data.bins.filter { $0.hasCensoredBeats && $0.isEligible }
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

    // MARK: - Drag-to-author range findings

    /// Snap a raw dragged time range to bin edges. The finding really
    /// covers whole bins (`project_drag_to_author_range_finding_spec.md`)
    /// — honest AND cleaner than a ragged pixel range. Empty-bins
    /// case falls back to the raw range so the caller can decide.
    private func snapAuthoringRange(from t0: Double, to t1: Double) -> ClosedRange<Double> {
        guard !data.bins.isEmpty else { return t0...t1 }
        let low = data.bins
            .min(by: { abs($0.startSeconds - t0) < abs($1.startSeconds - t0) })?
            .startSeconds ?? t0
        let high = data.bins
            .min(by: { abs($0.endSeconds - t1) < abs($1.endSeconds - t1) })?
            .endSeconds ?? t1
        let lo = min(low, high)
        let hi = max(low, high)
        return lo...hi
    }

    /// Degenerate-drag test — a range that spans zero bins produces no
    /// finding (spec: "Degenerate drag (< 1 bin / < 1 beat): ignore").
    private func isRangeAuthorable(_ range: ClosedRange<Double>) -> Bool {
        let bins = binsInRange(range)
        return bins.count >= 1 && range.upperBound > range.lowerBound
    }

    private func binsInRange(_ range: ClosedRange<Double>) -> [IntervalTrendBin] {
        data.bins.filter { bin in
            bin.startSeconds >= range.lowerBound - 0.001 &&
            bin.endSeconds   <= range.upperBound + 0.001
        }
    }

    /// The FACTUAL default label per the spec: coordinates only,
    /// analyst-editable on release. NEVER an interpretation like
    /// "prolongation" — that is the analyst's word to type, not the
    /// app's to assert (RUO ratified color/hedge discipline).
    /// Example: `QTc 432→≥508 ms · 13:30–16:30`.
    private func composeAuthoringLabel(range: ClosedRange<Double>) -> String {
        let bins = binsInRange(range)
        guard let first = bins.first, let last = bins.last else {
            return "\(metric.displayName) · \(formatTime(range.lowerBound))–\(formatTime(range.upperBound))"
        }
        let startVal = String(format: "%.0f", first.median)
        let endPrefix = last.hasCensoredBeats ? "≥" : ""
        let endVal = String(format: "%.0f", last.median)
        return "\(metric.displayName) \(startVal)→\(endPrefix)\(endVal) ms · \(formatTime(range.lowerBound))–\(formatTime(range.upperBound))"
    }

    /// IMMUTABLE citation payload — formula + bin + template + span.
    /// Reused by "Copy citation." Free-text label edits never touch
    /// this. See project_citation_strategy.md.
    private func composeAuthoringCitation(range: ClosedRange<Double>) -> String {
        "\(data.reproCaption) · \(formatTime(range.lowerBound))–\(formatTime(range.upperBound))"
    }

    /// Live readout composed during the drag. Consumes the snapped
    /// marquee so bin count + censored-end preview surface BEFORE
    /// release, not after.
    private func marqueeReadout(for range: ClosedRange<Double>) -> String {
        let bins = binsInRange(range)
        let durationMinutes = Int(((range.upperBound - range.lowerBound) / 60).rounded())
        guard let first = bins.first, let last = bins.last else {
            return "\(formatTime(range.lowerBound))–\(formatTime(range.upperBound))"
        }
        let startVal = String(format: "%.0f", first.median)
        let endPrefix = last.hasCensoredBeats ? "≥" : ""
        let endVal = String(format: "%.0f", last.median)
        var out = "\(formatTime(range.lowerBound))–\(formatTime(range.upperBound))"
        out += " · \(metric.displayName) \(startVal)→\(endPrefix)\(endVal) ms"
        out += " · \(durationMinutes) min · \(bins.count) bins"
        if last.hasCensoredBeats { out += " · end bin censored" }
        return out
    }

    /// Seconds-from-recording-start → "H:MM:SS" or "M:SS" style label.
    /// Chosen for the range-finding chip (spec's `13:30–16:30`).
    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Y-axis math

    private var yDomain: ClosedRange<Double> {
        var values = data.bins
            .filter { $0.isEligible && $0.median.isFinite }
            .flatMap { [$0.q1, $0.q3, $0.median] }
        // Guides must be visible on the lane — otherwise the analyst
        // places a 500 ms guide, the bins sit at 420–465, and the
        // guide silently disappears off-screen.
        values.append(contentsOf: guides.map(\.valueMs))
        guard let lo = values.min(), let hi = values.max() else {
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
