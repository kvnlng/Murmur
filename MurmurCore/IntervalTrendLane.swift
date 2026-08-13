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

    /// Show-mode ("median + IQR", etc.) — the analyst's PREFERENCE from the
    /// picker. The EFFECTIVE representation is this capped by `band` (X41):
    /// per-beat scatter is coerced to median + IQR at map scale.
    let showMode: IntervalTrendShowMode

    /// The representation actually drawn — the preference with per-beat
    /// scatter coerced away (X88: the x-domain is always the whole record,
    /// where scatter is the illegible wall).
    private var effectiveShowMode: IntervalTrendShowMode {
        IntervalTrendRepresentation.effectiveMode(preferred: showMode)
    }

    /// The QTc rate-correction formula in effect (X44). Shown as a picker on
    /// the QTc lane so an analyst reproducing published work can match its
    /// formula. Ignored for non-QTc metrics.
    let qtcFormula: MarkingsQTcFormula

    /// Callbacks for the control-chip menus. Nil hides the picker.
    let onPickMetric: ((IntervalTrendMetric) -> Void)?
    let onPickBinPreset: ((IntervalTrendBinPreset) -> Void)?
    let onPickShowMode: ((IntervalTrendShowMode) -> Void)?
    /// Set the QTc formula (X44). Nil hides the formula picker.
    let onPickFormula: ((MarkingsQTcFormula) -> Void)?

    /// X58: the T-offset reliability gate in effect — whether unreliable
    /// T-offsets are excluded from the QT aggregates, and at what risk-score
    /// threshold. Display state for the gate chip; ignored off the QTc lane.
    /// X109 (§2.4): non-nil ⇒ automated QT was withheld (no conventional
    /// lead). The QTc lane renders THIS string as its null state instead of
    /// the generic no-fiducials message; PR/QRS lanes ignore it.
    let qtWithheldReason: String?
    /// X111 (§2.1): the exposed R–R CV bound (percent) above which a QTc
    /// bin carries the rate-instability marker. 0 = off. Never withholds
    /// the value; the marker + note cite the mechanism, not a verdict.
    let rrCVFlagPercent: Double
    /// Set the CV bound. Nil hides the chip (non-QTc lanes, previews).
    let onPickRRCVFlag: ((Double) -> Void)?
    let tOffsetGateEnabled: Bool
    let tOffsetGateScore: Int
    /// Change the gate (enabled, score). Nil hides the gate chip.
    let onSetTOffsetGate: ((Bool, Int) -> Void)?

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
        qtcFormula: MarkingsQTcFormula = .fridericia,
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
        onPickFormula: ((MarkingsQTcFormula) -> Void)? = nil,
        qtWithheldReason: String? = nil,
        rrCVFlagPercent: Double = 0,
        onPickRRCVFlag: ((Double) -> Void)? = nil,
        tOffsetGateEnabled: Bool = true,
        tOffsetGateScore: Int = IntervalMarkingsContext.defaultTOffsetExclusionScore,
        onSetTOffsetGate: ((Bool, Int) -> Void)? = nil,
        onAddGuide: ((Double, String) -> Void)? = nil,
        onRemoveGuide: ((UUID) -> Void)? = nil,
        onAuthorRange: ((Double, Double, String, String) -> Void)? = nil,
        debugAuthoringMarquee: ClosedRange<Double>? = nil
    ) {
        self.timeRangeSeconds = timeRangeSeconds
        self.data = data
        self.metric = metric
        self.showMode = showMode
        self.qtcFormula = qtcFormula
        self.onPickFormula = onPickFormula
        self.qtWithheldReason = qtWithheldReason
        self.rrCVFlagPercent = rrCVFlagPercent
        self.onPickRRCVFlag = onPickRRCVFlag
        self.tOffsetGateEnabled = tOffsetGateEnabled
        self.tOffsetGateScore = tOffsetGateScore
        self.onSetTOffsetGate = onSetTOffsetGate
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
            // Chrome inset, chart full-bleed — the lane's data has to span its
            // cell edge to edge or it is not on the stack's axis (#210).
            captionRow
                .padding(.horizontal, 12)
            chart
            rrAssumptionNote
                .padding(.horizontal, 12)
        }
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

    /// Provenance on the leading edge, controls on the trailing edge.
    ///
    /// #223: the controls wrap. Seven `.fixedSize()` chips in a plain `HStack`
    /// composed into a 633 pt floor — wider than this lane's cell in any window
    /// under ~1180 pt — and the cell's `.clipped()` then removed the trailing
    /// chips from view while leaving them in the layout. `WrappingChipRow`
    /// makes the cluster's minimum its widest chip instead of the sum of all
    /// of them; on a wide lane it lays out identically to the `HStack`.
    private var captionRow: some View {
        HStack(alignment: .top, spacing: 6) {
            provenanceText
            // `minLength: 0` so the chips may take the whole row before the
            // provenance text is asked to give up its last few points: the
            // text truncates gracefully and a clipped chip does not.
            Spacer(minLength: 0)
            WrappingChipRow(spacing: 6) {
                metricPicker
                formulaPicker
                tOffsetGateChip
                cvFlagMenu
                binPicker
                showModePicker
                addGuideChip
            }
        }
    }

    private var provenanceText: some View {
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
            } else if let clock = qtClockText {
                // QT clock (X46) — percent of beats above the analyst's guide
                // over qualifying windows. Shown when not hovering a specific
                // bin, so it doesn't fight the per-bin readout. Neutral.
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(clock)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("interval-trend-lane-qt-clock")
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var addGuideChip: some View {
        if let onAdd = onAddGuide {
            Menu {
                // C5: the word "guide" alone doesn't say whose norm this is.
                // These are the ANALYST'S OWN reference lines, never a
                // built-in population/clinical cutoff (QTc ranges are
                // sex-specific, and the app asserts none) — say so in the
                // header and tag each value "user-set"
                // (project_interval_trend_lanes_design.md).
                Section("Add your own reference line (\(metric.displayName), ms)") {
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
                    Text("your guide")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                // X51 §3: name the Menu via its CONTENT, not the Menu itself —
                // on macOS an `.accessibilityLabel` on the Menu blanks the name
                // (the audit found it missing), whereas the content name is what
                // the working pickers surface. This label is RUO-load-bearing:
                // it marks the line as the analyst's, not an app-supplied cutoff.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Add your own reference line")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add your own reference line — a user-set threshold, not a population or clinical norm")
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

    /// X111: the CV-bound chip — QTc only. A preset menu, not a free field:
    /// the review supplies exactly two cited bounds (10% conservative, 15%
    /// universal) and Off; 20% is headroom, not a citation.
    @ViewBuilder
    private var cvFlagMenu: some View {
        if metric == .qtc, let onPick = onPickRRCVFlag {
            let label = rrCVFlagPercent > 0
                ? String(format: "CV flag %.0f%%", rrCVFlagPercent)
                : "CV flag off"
            controlChip(label: label, identifier: "interval-trend-lane-cv-flag-picker") {
                Menu {
                    Button("Off") { onPick(0) }
                    ForEach([10.0, 15.0, 20.0], id: \.self) { bound in
                        Button(String(format: "%.0f%%", bound)) { onPick(bound) }
                    }
                } label: {
                    chipContent(text: label)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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

    /// QTc formula picker (X44). Reproducing published work means matching its
    /// correction, so the analyst chooses; the app presents the options and the
    /// caveats but never arbitrates. Only on the QTc lane.
    @ViewBuilder
    private var formulaPicker: some View {
        if metric == .qtc, let onPick = onPickFormula {
            controlChip(label: qtcFormula.displayName, identifier: "interval-trend-lane-formula-picker") {
                Menu {
                    ForEach(MarkingsQTcFormula.allCases, id: \.self) { option in
                        Button(option.displayName) { onPick(option) }
                    }
                } label: {
                    chipContent(text: qtcFormula.displayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                // Regulatory divergence + the non-comparability rule, per the
                // 2026-07-03 spec: the app states the choice, never arbitrates.
                .help("QTc rate-correction formula. FDA/EMA favour Fridericia for drug studies; the 2009 AHA/ACCF/HRS statement preferred linear methods (Framingham, Hodges) over Bazett and Fridericia for routine monitoring. Values under different formulas are NOT comparable — don't read one against another.")
            }
        }
    }

    /// X58: the analyst's T-offset reliability dial — exclude-and-count,
    /// exclude by default. The app ships the DERIVED operating point
    /// (score ≥ 1, QTDB+LUDB sweep) and never arbitrates the dial; this chip
    /// is where the analyst owns it. Governs the bin medians, the
    /// patient-normal template, and the departure baseline — not just the
    /// visible aggregate. QTc-only: the gate touches no other metric.
    @ViewBuilder
    private var tOffsetGateChip: some View {
        if metric == .qtc, let onSet = onSetTOffsetGate {
            controlChip(
                label: gateChipLabel,
                identifier: "interval-trend-lane-toffset-gate"
            ) {
                Menu {
                    Toggle(isOn: Binding(
                        get: { !tOffsetGateEnabled },
                        set: { include in onSet(!include, tOffsetGateScore) }
                    )) {
                        Text("Include low-confidence beats")
                    }
                    Section("Exclude at T-offset risk score ≥") {
                        ForEach(1...5, id: \.self) { score in
                            Toggle(isOn: Binding(
                                get: { tOffsetGateEnabled && tOffsetGateScore == score },
                                set: { _ in onSet(true, score) }
                            )) {
                                Text(score == IntervalMarkingsContext.defaultTOffsetExclusionScore
                                     ? "\(score) — derived default (QTDB+LUDB)"
                                     : "\(score)")
                            }
                        }
                    }
                } label: {
                    chipContent(text: gateChipLabel)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("T-offset reliability gate. Beats the delineator flags at or above the score are withheld from the QTc bin medians, the patient-normal template, and the departure baseline — withheld and counted, never hidden. The default (score ≥ 1) is the QTDB+LUDB-derived operating point: T-offset SD 59.3 ms at 12.6% excluded. Including low-confidence beats lets biased-long false T-terminations into those aggregates. Measurement reliability only — never a statement about the patient.")
            }
        }
    }

    private var gateChipLabel: String {
        tOffsetGateEnabled ? "T-gate ≥\(tOffsetGateScore)" : "T-gate off"
    }

    @ViewBuilder
    private var showModePicker: some View {
        if let onPick = onPickShowMode {
            controlChip(label: showMode.displayName, identifier: "interval-trend-lane-show-picker") {
                Menu {
                    // X88: per-beat scatter is permanently coerced (whole-
                    // record x-domain), so offering it would be a dead option.
                    ForEach(
                        IntervalTrendShowMode.allCases.filter { $0 != .perBeatScatter },
                        id: \.self
                    ) { option in
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

    /// C8: persistent neutral note stating the rate-correction assumption,
    /// paired with the per-bin R–R CV surfaced on hover. States what the
    /// formula assumes about its INPUT; it is NOT a verdict about the QTc or
    /// the patient, applies no threshold, and reserves no amber. QTc-only.
    @ViewBuilder
    private var rrAssumptionNote: some View {
        if metric == .qtc, !data.bins.isEmpty {
            Text("Rate-corrected QTc assumes a steady R–R interval — per-bin R–R variability (CV) shown on hover.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("interval-trend-lane-rr-assumption-note")
            // X111 (§2.1): when bins exceed the exposed bound, say so and
            // cite the mechanism — the formula's failure, never the
            // patient's. The QTc values stay rendered.
            if let note = Self.rrInstabilityNote(
                flaggedBins: flaggedCVBins.count, thresholdPercent: rrCVFlagPercent) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("interval-trend-lane-cv-instability-note")
            }
        }
    }

    /// X111: bins over the exposed CV bound (QTc lane only; empty when off).
    private var flaggedCVBins: [IntervalTrendBin] {
        guard metric == .qtc, rrCVFlagPercent > 0 else { return [] }
        return data.bins.filter { ($0.rrCVPercent ?? 0) > rrCVFlagPercent }
    }

    /// Static so the wording is unit-testable. Nil when the flag is off or
    /// nothing exceeded it — no note is better than a vacuous one.
    static func rrInstabilityNote(flaggedBins: Int, thresholdPercent: Double) -> String? {
        guard thresholdPercent > 0, flaggedBins > 0 else { return nil }
        let plural = flaggedBins == 1 ? "bin exceeds" : "bins exceed"
        return String(
            format: "%d %@ R–R CV %.0f%% — steady-state rate correction is "
                + "unreliable above that bound (exposed threshold; values still shown).",
            flaggedBins, plural, thresholdPercent)
    }

    private func hoverValueString(_ bin: IntervalTrendBin) -> String {
        if !bin.isEligible {
            return "low conf."
        }
        var text = String(format: "%.0f", bin.median)
        // C8: on the QTc lane, surface the bin's R–R variability (the
        // steadiness the rate correction assumes) next to the value — a
        // factual measurement, no verdict, no threshold.
        if metric == .qtc, let cv = bin.rrCVPercent {
            text += String(format: " · RR CV %.0f%%", cv)
            if rrCVFlagPercent > 0, cv > rrCVFlagPercent {
                text += String(format: " (> %.0f%% bound)", rrCVFlagPercent)
            }
        }
        // X43: flag that the preceding-2-min rate wasn't stable — the rate
        // correction's own input assumption. A property of the input, not a
        // verdict on the QTc.
        // Quotes the DRIFT, which is the quantity the verdict rests on. It used
        // to quote the max instantaneous deviation — a figure that ran ~17 bpm
        // on ordinary sinus rhythm and had nothing to do with why the bin was
        // marked.
        if metric == .qtc, bin.showsRateUnstableMarker, let drift = bin.rateUnstableMarkerBpm {
            text += String(format: " · rate unstable (drift %.1f bpm / 2 min)", drift)
        }
        // X45: the working metric in practice is the CHANGE, not the absolute —
        // the numeric departure from the patient's own normal, alongside the
        // absolute. Neutral, shown only for eligible bins with a baseline;
        // absent (blank) when there's no template, which stays visually
        // distinct from a zero departure ("Δ+0 ms").
        if bin.isEligible, let departure = Self.baselineDepartureText(median: bin.median, baseline: data.baselineMedian) {
            text += " · \(departure)"
        }
        // X46: per-bin percent above the analyst's guide, for qualifying bins.
        if bin.isQualifying, let guide = qtClockGuide,
           let pct = Self.percentAbove(perBeatValues: bin.perBeatValues, guideMs: guide.valueMs) {
            text += String(format: " · %.0f%% > %.0f", pct, guide.valueMs)
        }
        return text
    }

    /// Signed departure of a bin from the patient-normal baseline, e.g.
    /// "Δ+20 ms" / "Δ−15 ms" / "Δ+0 ms". `nil` when there is no baseline —
    /// the caller shows nothing, keeping "no reference" distinct from "zero
    /// change" (K9's blank-vs-zero rule). Pure, so it's unit-testable.
    static func baselineDepartureText(median: Double, baseline: Double?) -> String? {
        guard let baseline else { return nil }
        // Use a minus glyph (not hyphen) so negatives read cleanly in the mono row.
        let d = median - baseline
        let rounded = d.rounded()
        let sign = rounded < 0 ? "−" : "+"
        return "Δ\(sign)\(String(format: "%.0f", abs(rounded))) ms"
    }

    /// Percent (0…100) of `perBeatValues` strictly above `guideMs`, or nil for
    /// an empty bin. Pure — the "QT clock" read (X46) is just a count, and the
    /// analyst supplies the line (X27), so the app never picks a threshold.
    static func percentAbove(perBeatValues: [Double], guideMs: Double) -> Double? {
        guard !perBeatValues.isEmpty else { return nil }
        let above = perBeatValues.reduce(0) { $0 + ($1 > guideMs ? 1 : 0) }
        return 100 * Double(above) / Double(perBeatValues.count)
    }

    /// The guide the QT-clock read is computed against — the analyst's lowest
    /// line for this metric (deterministic; guides are value-sorted).
    private var qtClockGuide: IntervalTrendGuide? { guides.first }

    /// Renders a percentage so a quantity that EXISTS never reads as one that
    /// does not (K9 / X56 §2): "2 of 1,861 excluded" must not print `0%`. A
    /// non-zero fraction under 1% shows `<1%`, and a value just shy of totality
    /// shows `>99%`, so neither end fabricates an absolute. A true zero still
    /// prints `0%`. Pure so the boundaries are unit-testable without a view.
    static func percentText(_ pct: Double) -> String {
        if pct <= 0 { return "0%" }
        if pct >= 100 { return "100%" }
        // Where whole-number rounding would fabricate an absolute, keep one
        // decimal — the same convention `qtImplausibleSummaryText` (X53) already
        // uses, rather than inventing a second voice for the same idea.
        if pct < 1 || pct > 99 { return String(format: "%.1f%%", pct) }
        return String(format: "%.0f%%", pct)
    }

    /// "QT clock" aggregate (X46): the percentage of beats above the analyst's
    /// guide, over QUALIFYING windows only (eligible + rate-stable), with the
    /// excluded fraction stated when the paid layer computed it. nil when there
    /// is no guide or no qualifying beats — the app never supplies the line.
    private var qtClockText: String? {
        guard let guide = qtClockGuide else { return nil }
        var above = 0
        var total = 0
        // BEAT-WEIGHTED, not a mean of per-bin fractions: `excludedBeatFraction`
        // is a fraction *of the bin's beats*, so a 3-beat bin and a 300-beat bin
        // must not carry equal weight. Mirrors the X53 sibling
        // (`qtImplausibleSummaryText`), which established this convention.
        var excludedBeats = 0.0
        var excludedTotal = 0
        for bin in data.bins where bin.isQualifying {
            for v in bin.perBeatValues where v > guide.valueMs { above += 1 }
            total += bin.perBeatValues.count
            if let ex = bin.excludedBeatFraction {
                excludedBeats += ex * Double(bin.beatCount)
                excludedTotal += bin.beatCount
            }
        }
        guard total > 0 else { return nil }
        let pct = 100 * Double(above) / Double(total)
        var text = "\(Self.percentText(pct)) > \(String(format: "%.0f", guide.valueMs)) (qualifying)"
        if excludedTotal > 0 {
            let excludedPct = 100 * excludedBeats / Double(excludedTotal)
            text += " · \(Self.percentText(excludedPct)) excl"
        }
        return text
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
                // X111: rate-instability markers — a dashed neutral rule
                // across each bin whose R–R CV exceeds the exposed bound.
                // Marks the INPUT assumption failing; the median below
                // stays plotted (§2.1: flag, never withhold).
                ForEach(flaggedCVBins, id: \.startSeconds) { bin in
                    RuleMark(
                        xStart: .value("cv-t0", bin.startSeconds),
                        xEnd: .value("cv-t1", bin.endSeconds),
                        y: .value("cv-y", yDomain.upperBound)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [3, 2]))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                }

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

                // Rate-stability validity marker (X43) — a thin NEUTRAL band
                // along the BOTTOM edge under bins whose preceding-2-min rate
                // wasn't stable, i.e. the rate correction's own input assumption
                // (a steady R–R) didn't hold. Deliberately distinct from the two
                // existing states: it sits at the bottom (not full height like
                // the low-confidence fill) and uses secondary ink (not the
                // primary open-top censored treatment). A statement about the
                // formula's INPUT — never "invalid QTc", never "AF", no amber.
                ForEach(rateUnstableBins) { bin in
                    RectangleMark(
                        xStart: .value("rate-unstable-t0", bin.startSeconds),
                        xEnd: .value("rate-unstable-t1", bin.endSeconds),
                        yStart: .value("rate-unstable-y0", yDomain.lowerBound),
                        yEnd: .value("rate-unstable-y1",
                                     yDomain.lowerBound + (yDomain.upperBound - yDomain.lowerBound) * 0.05)
                    )
                    .foregroundStyle(Color.secondary.opacity(0.55))
                }

                // IQR ribbon (wide, ~13% opacity) — how much QT actually
                // varies beat-to-beat = PHYSIOLOGICAL spread. One
                // AreaMark per eligible run so the ribbon never bridges
                // across ineligible / gap bins. Sits OUTSIDE the
                // measurement band per project_qtc_trend_uncertainty_wireup_spec.md.
                if effectiveShowMode == .medianAndIQR {
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
                // we know the trend point). Distinct from IQR: denser +
                // narrower. X88 gates it behind the "median + IQR" show
                // mode so the default read is a plain line matching the
                // other location-finder lanes; the censored-bin dashed
                // median + chevrons below stay in EVERY mode — they are
                // a correctness disclosure, not decoration.
                //
                // For CENSORED bins (a beat inside hit the T-search-
                // window ceiling → true T-offset ≥ reported), the band
                // is drawn open UPWARD: yStart at bandLower, yEnd at
                // the top of the y-domain — the true measurement is
                // "≥ bandLower". The up-chevron markers + "QT ≥"
                // annotation on the top edge (Canvas overlay below)
                // signal the lower-bound state.
                if effectiveShowMode == .medianAndIQR {
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
            .trendLaneYAxis()
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
            // X51 §2: the chart emitted ~183 unnamed per-bin marks — noise for
            // VoiceOver, unaddressable for XCUI. Collapse them into ONE element
            // carrying the footer facts (metric · formula · bins · template ·
            // lead). Gestures on the overlay are unaffected (not AX children).
            .accessibilityElement(children: .ignore)
            // X52 §5: fold the value the chart actually plots (median of the
            // eligible bin medians) INTO the label — macOS surfaces a composed
            // element's label reliably, its value less so — so a wire-up test
            // can assert screen == what the validated computer produced.
            .accessibilityLabel(summaryAXLabel)
            .accessibilityIdentifier("interval-trend-lane-summary")
            // Repro caption emitted verbatim to the citation menu.
            Text(data.reproCaption)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .accessibilityIdentifier("interval-trend-lane-repro-caption")
            // X53: state the QT-implausible excluded fraction when the paid
            // layer computed one and any beat was withheld. Neutral ink, a
            // factual input condition — never a verdict, never amber.
            if let excluded = qtImplausibleSummaryText {
                Text(excluded)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("interval-trend-lane-excluded-fraction")
            }
        }
    }

    /// The single value the chart plots as "the reading": the median of the
    /// eligible bin medians (finite only). `nil` when nothing is eligible. This
    /// is derived straight from the `IntervalTrendData` the validated computer
    /// produced, so asserting the rendered value against a known input catches a
    /// units/binding slip between compute and screen (X52 §5).
    private var laneReadingText: String? {
        let medians = data.bins.filter { $0.isEligible && $0.median.isFinite }.map(\.median).sorted()
        guard !medians.isEmpty else { return nil }
        return String(format: "%.0f", medians[medians.count / 2])
    }

    /// The collapsed-chart element's spoken label: the repro caption plus the
    /// plotted reading (X52 §5). Extracted so the view builder isn't asked to
    /// type-check a string expression with an optional map inline.
    private var summaryAXLabel: String {
        guard let reading = laneReadingText else { return data.reproCaption }
        return "\(data.reproCaption) · reading \(reading) ms"
    }

    /// Whole-lane statement of the beats withheld from the medians —
    /// physically impossible QT (X53) and unreliable T-offset (X79), each
    /// bucket named. Beat-weighted across bins that carry a fraction (paid
    /// delineation only); `nil` in the free viewer or when nothing was
    /// excluded, so a zero never reads as a computed "0% excluded" where no
    /// filter ran.
    private var qtImplausibleSummaryText: String? {
        var implausible = 0.0
        var unreliable = 0.0
        var total = 0
        for bin in data.bins {
            guard bin.qtImplausibleFraction != nil || bin.qtUnreliableFraction != nil else { continue }
            implausible += (bin.qtImplausibleFraction ?? 0) * Double(bin.beatCount)
            unreliable += (bin.qtUnreliableFraction ?? 0) * Double(bin.beatCount)
            total += bin.beatCount
        }
        return Self.qtExclusionSummary(implausible: implausible, unreliable: unreliable, total: total)
    }

    /// Static so the wording is unit-testable. `implausible`/`unreliable` are
    /// beat-weighted counts (possibly fractional), `total` the measured-beat
    /// population they were withheld from.
    static func qtExclusionSummary(implausible: Double, unreliable: Double, total: Int) -> String? {
        let excluded = implausible + unreliable
        guard total > 0, excluded >= 0.5 else { return nil }
        let count = Int(excluded.rounded())
        // X56 §4: name the population — these are the beats the delineator
        // produced a QT for, distinct from the annotated-beat and template
        // counts elsewhere on screen. X79: name each REASON with its own
        // count — on rec 212 the unreliable bucket is 30× the implausible
        // one, and a single undifferentiated number would hide the record's
        // real story.
        var reasons: [String] = []
        if implausible >= 0.5 {
            reasons.append("QT physically impossible (\(Int(implausible.rounded())))")
        }
        if unreliable >= 0.5 {
            reasons.append("unreliable T-offset (\(Int(unreliable.rounded())))")
        }
        var base = "\(count) of \(total) measured beats excluded — " + reasons.joined(separator: " · ")
        // Collapse the redundant per-reason count when there is only one
        // reason — "12 excluded — QT physically impossible (12)" says 12
        // twice.
        if reasons.count == 1 {
            base = "\(count) of \(total) measured beats excluded — "
                + (implausible >= 0.5 ? "QT physically impossible" : "unreliable T-offset")
        }
        // X56 §2 / K9: a count that exists must not render as "(0%)". One
        // decimal, and drop the parenthetical entirely when it would still round
        // to 0.0 — the count already carries the information.
        let pct = 100 * excluded / Double(total)
        guard (pct * 10).rounded() >= 1 else { return base }
        return base + String(format: " (%.1f%%)", pct)
    }

    private var emptyState: some View {
        // X109: on the QTc lane a withheld QT is a deliberate, non-error
        // status (§2.4) — state it plainly where the metric normally sits,
        // never the generic "unavailable".
        let withheldReason = metric == .qtc ? qtWithheldReason : nil
        let message = withheldReason
            ?? "Interval trend unavailable — no fiducials in this recording"
        return ZStack(alignment: .center) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
            Text(message)
                .font(.caption2)
                .foregroundStyle(withheldReason != nil ? AnyShapeStyle(.secondary)
                                                       : AnyShapeStyle(.tertiary))
        }
        .frame(height: Self.laneHeight)
        // One AX element carrying the message as its label — the ZStack
        // otherwise swallows the inner text and tests (and VoiceOver) read
        // an empty container.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityIdentifier(withheldReason != nil
            ? "interval-trend-lane-qt-withheld"
            : "interval-trend-lane-empty")
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

    /// Bins whose preceding-2-min rate was evaluated and found unstable — the
    /// rate-stability validity marker (X43). Only meaningful for QTc, whose
    /// correction assumes a steady rate.
    private var rateUnstableBins: [IntervalTrendBin] {
        guard metric == .qtc else { return [] }
        return data.bins.filter { $0.showsRateUnstableMarker }
    }

    /// Bins containing at least one T-offset-censored beat. Rendered
    /// with the "open-top band + dashed median + QT ≥ marker" treatment.
    /// A bin can be BOTH ineligible AND censored on real data; the
    /// crosshatch (from `chartBackground`) sits behind and the censored
    /// treatment layers on top.
    private var censoredBins: [IntervalTrendBin] {
        data.bins.filter { $0.hasCensoredBeats && $0.isEligible }
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
