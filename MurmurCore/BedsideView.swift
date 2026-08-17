//
//  BedsideView.swift
//  Murmur
//
//  Stacked channel panels driven by a shared `RecordingViewport`. The main
//  waveform is GPU-rendered (Metal) via `WaveformCanvas`; SwiftUI overlays
//  draw the axis labels and annotation symbols on top.
//
//  Drag on a chart pans all channels in lock-step; pinch zooms. Click/drag
//  on the overview ribbon scrubs.
//

import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct BedsideView: View {
    let recording: Recording
    let recordingDirectory: URL
    /// X16: called after a gain reinterpretation is persisted to the bundle
    /// manifest, with the updated recording — the owner of the `recording`
    /// value adopts it so every panel re-renders against the new factor.
    /// nil (previews/tests) means mutations render only after a reload.
    var onRecordingMutated: ((Recording) -> Void)?

    @State private var viewport: RecordingViewport
    /// Shared amplitude/timebase calibration (X40). Gain is shared across
    /// leads by clinical convention, so it lives once here and threads into
    /// every ChannelPanel, exactly like `viewport`.
    @State private var calibration = Calibration()
    @State private var filter = FindingFilter()
    /// X82: the review-queue inspector's open state lives in the coexistence
    /// context — the analyst's intent, arbitrated against the navigator and
    /// the window width so neither panel ever renders partially clipped.
    @State private var panels = SidePanelCoexistenceContext.shared
    /// When on, the viewport is held at a 10-second window and finding /
    /// candidate jumps recenter without changing zoom — for analysts who
    /// read in fixed time windows. A manual zoom breaks the lock.
    @State private var windowLockedTo10s = false
    /// X28 — elapsed vs wall-clock. App preference, shared across records.
    private var timeDisplay: TimeDisplayContext { TimeDisplayContext.shared }
    /// The record's real start instant, or nil when it carried none. nil is the
    /// honest answer for MIT-BIH-style records and keeps wall-clock unavailable.
    private var recordingStartUnixMillis: Int64? {
        guard recording.hasAbsoluteStartTime else { return nil }
        return recording.channels.first?.startTimeUnixMS
    }
    /// X50: a raw record opens ON standard ECG paper (25 mm/s · 10 mm/mV)
    /// rather than at whatever calibration falls out of the initial time
    /// window. Applied once, on the first valid layout — canvasSize is `.zero`
    /// until the focused panel lays out, so `applyStandardView()` can't run in
    /// `init`. This latch fires it exactly once and never fights the analyst's
    /// later manual gain/speed changes. (A restored `.mur` sets gain before
    /// layout; the `gain == nil` guard below leaves that saved paper alone —
    /// the open state is the default for a record the app has never seen, not
    /// an override. `.mur` restore is gated on X14.)
    @State private var hasAppliedOpenCalibration = false
    @State private var layoutMode: BedsideLayoutMode
    /// App-wide read/write latch. Governs the context-notes editor and the
    /// per-finding disposition trio; new annotation create/edit/delete will
    /// hang off the same latch.
    @State private var isEditing: Bool = false
    /// Analyst review state for this recording's findings — confirm /
    /// dismiss / reset. Persisted to `<bundle>/dispositions.json`.
    @State private var dispositionStore: DispositionStore
    /// Analyst review state for VT/VF model CANDIDATES — keyed on time
    /// region (not annotation id) so it survives a rescan. Persisted to
    /// `<bundle>/candidate-dispositions.json`.
    @State private var candidateDispositionStore: VTVFCandidateDispositionStore
    /// Bridge to the App-target VT/VF scan orchestrator: exposes the
    /// committed candidates + drives the "Scan for VT/VF candidates"
    /// toolbar affordance. The model + entitlement live on the App side.
    @State private var scanContext = VTVFScanContext.shared
    /// Bridge to the App-target arrhythmia scan orchestrator (A2): exposes
    /// the detector's brady/tachy/pause/AFib candidate spans. The compute +
    /// entitlement gate live on the App side.
    @State private var arrhythmiaContext = ArrhythmiaScanContext.shared
    /// Region-keyed review state for the arrhythmia candidates — own
    /// sidecar, never shared with the VT/VF store (overlapping spans must
    /// not inherit each other's calls).
    @State private var arrhythmiaDispositionStore: VTVFCandidateDispositionStore
    /// Findings the analyst attached after import (via the "Attach
    /// findings…" toolbar action). Merged with `recording.annotations`
    /// for display. In-memory only for now; a future pass persists them
    /// to the bundle's `annotations.json` so they survive across launches.
    @State private var attachedAnnotations: [Annotation] = []
    /// #250 — in-session display-label overrides for analyst-authored
    /// findings, keyed by annotation id. Applied in `allAnnotations` and
    /// persisted through the bundle sidecar on every rename.
    @State private var renamedLabels: [UUID: String] = [:]
    /// #250 — true while the queue's rename field is on screen, so the
    /// bedside's plain-key shortcuts stay out of the analyst's typing.
    @State private var findingRenameActive = false
    /// Drives the file-importer sheet for "Attach findings…".
    @State private var showAttachFindings: Bool = false
    /// Error message shown when an attach attempt fails (unreadable file,
    /// unsupported schema, malformed JSON, etc).
    @State private var attachError: String?
    /// Result of the most recent WFDB export — surfaced to XCUI via a hidden
    /// accessibility leaf (exported count + annotator suffix).
    @State private var lastWFDBExport: WFDBAnnotationExport.Result?
    /// Drives the producer-run sheet. Visible in DEBUG via the toolbar;
    /// once IAP frameworks land in RELEASE, the toolbar item gates on
    /// "any producer registered" instead of the DEBUG flag.
    @State private var showProducersPanel: Bool = false
    /// Rolling HRV samples for the variability lane. Written by the
    /// App target's orchestrator (which owns MurmurMetrics + the
    /// entitlement gate); we render the lane only when non-empty.
    /// Empty covers all "no lane" cases — no recording, no entitlement,
    /// too few beats — so BedsideView has no policy of its own.
    @State private var laneContext = VariabilityLaneContext.shared
    /// Per-beat fiducials + normal template — powers the fiducial
    /// overlay drawn in ChannelPanel and the deviation-ranked
    /// navigation shortcuts (`[` / `]`) on BedsideView itself.
    @State private var markingsContext = IntervalMarkingsContext.shared
    /// Analyst-facing config for the interval trend lane (which
    /// interval, bin length, show mode). The lane hides itself when
    /// `markingsContext` has no beats.
    @State private var trendLaneContext = IntervalTrendLaneContext.shared
    /// Paid per-bin qualifying facts (X42), published by the App orchestrator.
    @State private var qualifyingContext = QualifyingWindowContext.shared
    /// True while the notes editor is the first responder. Published into
    /// `BedsideCommands.textEntryActive` so the App disables the bedside key
    /// commands during note typing and the editor keeps its keystrokes (X22).
    @FocusState private var notesEditorFocused: Bool
    /// Analyst-placed threshold guides on the interval trend lane —
    /// user-set only, never built-in clinical cutoffs. Persists to
    /// `<bundle>/interval_guides.json`.
    @State private var trendGuideStore: IntervalTrendGuideStore
    /// Which trend lanes are switched on (X74). Every lane the record can
    /// produce starts visible — the menu is for turning things OFF, and a
    /// stack that opened empty would make the analyst discover the menu
    /// before seeing anything.
    @State private var visibleTrendLanes: Set<String> = [
        BedsideTrendStack.hrLaneID, BedsideTrendStack.beatHRLaneID,
        "rmssd", "interval-trend",
        BedsideTrendStack.lfhfLaneID, BedsideTrendStack.qualityLaneID,
    ]
    /// Rolling LF/HF series (X76) — computed by the App-target orchestrator
    /// behind the entitlement gate, rendered here. Empty means no lane.
    @State private var lfhfContext = RollingLFHFContext.shared
    /// What the trace is actually drawing — zoom tier, points-per-beat, and
    /// the resolved LOD — published outward by the canvas so the info bar can
    /// report it (X69).
    @State private var renderState = WaveformRenderStateContext.shared
    /// Whether the Context region is open. Per APP, not per record: an analyst
    /// who works with notes open wants them open on the next record too, and
    /// the design says as much.
    @AppStorage("murmur.notesDrawerExpanded")
    private var notesDrawerExpanded: Bool = false

    /// What the drawer actually RENDERS as. Identical to
    /// `notesDrawerExpanded` in production and in any UI test that doesn't ask
    /// otherwise; pinned closed for suites launched with
    /// `--ui-test-context-drawer-collapsed`, which need the drawer out of the
    /// way and inherit its persisted state from whatever ran before them.
    /// Reads go through here; the stored value is still what toggling writes.
    private var contextDrawerIsOpen: Bool {
        #if DEBUG
        if UITestSupport.shouldCollapseContextDrawer { return false }
        #endif
        return notesDrawerExpanded
    }
    /// X85 — the trend stack folds like the Context drawer. Defaults
    /// EXPANDED (unlike the drawer): the stack is a primary reading surface
    /// that has always been visible; folding is an option the analyst takes,
    /// not a demotion the app applies.
    @AppStorage("murmur.trendStackExpanded")
    private var trendStackExpanded: Bool = true
    /// X72 — the analyst's time-anchored notes. Session work product: they
    /// travel in `sessionSnapshot` → `MurSessionState` and are written by
    /// File ▸ Save Session, never autosaved (DECISIONS §4).
    @State private var anchoredNotes: [AnchoredNote] = []
    // X112 — morphology-cluster endorsements: session work product with the
    // same lifecycle as anchored notes (reset with the view on record swap,
    // saved via the session snapshot, restored from the .mur).
    @State private var morphologyEndorsements: [MorphologyEndorsement] = []
    @State private var morphologyContext = MorphologyContext.shared
    /// Which drawer row is open. Defaults to the notes.md document — the
    /// record-level surface that predates anchored notes.
    @State private var drawerSelection: ContextDrawerSelection? = .document

    static let initialDurationSeconds: Double = 10

    init(
        recording: Recording,
        recordingDirectory: URL,
        onRecordingMutated: ((Recording) -> Void)? = nil
    ) {
        self.recording = recording
        self.recordingDirectory = recordingDirectory
        self.onRecordingMutated = onRecordingMutated
        // Viewport + focus mode key off the first *ECG* channel — trend
        // channels (1/60 Hz vitals, GMM states) live in their own strip and
        // shouldn't drive viewport math.
        let firstECG = recording.channels.first(where: { !$0.isTrendChannel })
            ?? recording.channels.first
        // UI tests can override the initial viewport width via
        // `--ui-test-initial-duration=<seconds>` so drag-pan tests have
        // somewhere to move to (the 10 s default encompasses the whole
        // synthetic fixture).
        let initialDuration: Double = {
            #if DEBUG
            return UITestSupport.initialDurationSeconds ?? Self.initialDurationSeconds
            #else
            return Self.initialDurationSeconds
            #endif
        }()
        _viewport = State(initialValue: RecordingViewport(
            totalSamples: firstECG?.sampleCount ?? 0,
            sampleRate: firstECG?.sampleRate ?? 250,
            initialDurationSeconds: initialDuration
        ))
        // Default: focus the first lead. Single-lead is the typical analyst
        // workflow; strips mode is opt-in for cross-lead comparison.
        let defaultMode: BedsideLayoutMode = firstECG.map { .focus(only: $0.id) } ?? .strips
        #if DEBUG
        // `--ui-test-overlay-leads=I,V1` seeds the overlay a ⌘-click would
        // build — XCUI on macOS can't hold a modifier while clicking.
        let ecg = recording.channels.filter { !$0.isTrendChannel }
        let requested = UITestSupport.overlayLeadNames.compactMap { name in
            ecg.first { $0.name == name }?.id
        }
        _layoutMode = State(initialValue: LeadSelection(ordered: requested).map { .focus($0) } ?? defaultMode)
        #else
        _layoutMode = State(initialValue: defaultMode)
        #endif
        _dispositionStore = State(initialValue: DispositionStore(bundleDirectory: recordingDirectory))
        _candidateDispositionStore = State(initialValue: VTVFCandidateDispositionStore(bundleDirectory: recordingDirectory))
        _arrhythmiaDispositionStore = State(initialValue: VTVFCandidateDispositionStore(
            bundleDirectory: recordingDirectory,
            fileName: ArrhythmiaCandidateSource.dispositionFileName
        ))
        _trendGuideStore = State(initialValue: IntervalTrendGuideStore(bundleDirectory: recordingDirectory))
    }

    /// ECG / pressure channels — rendered on the Metal canvas.
    private var ecgChannels: [Channel] {
        recording.channels.filter { !$0.isTrendChannel }
    }

    /// The low-rate channels this view renders: the HR trend and the
    /// quality ratios. X66 retired the alarm and ventilation-state lanes —
    /// see `LowRatePartition`.
    private var lowRatePartition: LowRatePartition {
        LowRatePartition(channels: recording.channels.filter(\.isTrendChannel))
    }

    /// Continuous quality / artifact-ratio channels, rendered as the trend
    /// stack's quality lane (X74).
    private var qualityChannels: [Channel] { lowRatePartition.quality }

    /// Union of the producer's findings and anything the analyst has
    /// attached via the "Attach findings…" toolbar action. Every downstream
    /// surface — canvas overlays, findings panel, density timeline, summary
    /// chips — reads from this so attached findings are first-class.
    private var allAnnotations: [Annotation] {
        // #250 — rename overlay. `recording` is immutable and a reopened
        // bundle's findings live in `recording.annotations` (the sidecar
        // overrides the manifest at load), so an in-session rename cannot
        // land in either store directly. The overlay maps by id over the
        // union, which covers a finding authored this session and one
        // loaded from the sidecar identically — and `BundleAnnotationsFile
        // .write(allAnnotations…)` therefore persists renames on the same
        // write every other authoring act uses.
        (recording.annotations + attachedAnnotations).map { annotation in
            guard let newLabel = renamedLabels[annotation.id] else { return annotation }
            return annotation.withLabel(newLabel)
        }
    }

    /// Annotations that survive the current filter. Drives the canvas, the
    /// findings panel, and the density timeline so all three stay in sync.
    private var filteredAnnotations: [Annotation] {
        allAnnotations.filter(filter.matches)
    }

    /// Annotations that should render on `channel`'s waveform panel.
    /// Lead-tagged findings only show on the channel whose name matches;
    /// lead-less findings (the common case — whole-recording
    /// observations like AFib) show on every channel.
    private func annotationsForChannel(_ channel: Channel) -> [Annotation] {
        filteredAnnotations.filter { $0.matchesChannel(channel.name) }
    }

    /// VT/VF candidate episodes to draw on `channel`'s trace. Same
    /// lead-matching rule as annotations; lead-less candidates show on
    /// every channel.
    private func candidatesForChannel(_ channel: Channel) -> [Annotation] {
        (scanContext.candidates + arrhythmiaContext.candidates)
            .filter { $0.matchesChannel(channel.name) }
    }

    /// The lead everything per-channel follows: the trace on the stage, the
    /// fiducial and annotation marks, the docked inspector, the calibration
    /// readout, the off-scale scanner and the deviation-nav. With an overlay
    /// selected this is the designated PRIMARY, because marks drawn over a
    /// trace they were not measured from would imply a measurement nobody
    /// made (`project_lead_overlay_focus_spec.md` §4).
    private var focusedChannel: Channel? {
        guard let selection = layoutMode.leadSelection else { return nil }
        return ecgChannels.first { $0.id == selection.primary }
    }

    /// Leads overlaid on the focus stage above the primary, in selection
    /// order. Empty in the ordinary single-lead case.
    private var overlayChannels: [Channel] {
        guard let selection = layoutMode.leadSelection else { return [] }
        return selection.secondaries.compactMap { id in ecgChannels.first { $0.id == id } }
    }

    /// Extracted out of `body` to keep the view's type-check tractable —
    /// the interpolation was tipping the whole body over the inference
    /// budget once the VT/VF surfaces were added.
    private var viewportStateLabel: String {
        "start=\(viewport.startSample) end=\(viewport.endSample)"
    }

    /// Human-readable position readout for VoiceOver (AX4). A tool whose job
    /// is locating positions in a long signal must let a non-sighted analyst
    /// learn where they are; the machine-format `ui-test-viewport-state`
    /// element is for XCUI equality assertions and reads poorly aloud, so
    /// this is a separate, spoken surface. Reports the window in clock time
    /// and the focused beat when one is selected.
    private var viewportPositionLabel: String {
        let sr = viewport.sampleRate > 0 ? viewport.sampleRate : 250
        let t0 = clockString(Double(viewport.startSample) / sr)
        let t1 = clockString(Double(viewport.endSample) / sr)
        var label = "Viewing \(t0) to \(t1)"
        if let beat = markingsContext.focusedBeatSampleIndex {
            label += ", beat selected at \(clockString(Double(beat) / sr))"
        }
        return label
    }

    private func clockString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The menu-command bridge (X22). Closures mirror the onKeyPress handlers
    /// exactly — same actions, all operating on reference-type state
    /// (viewport / markings / disposition store), so they're safe to invoke
    /// from the menu. `textEntryActive`/`isEditing` are read each body pass so
    /// the App can disable the shortcuts during note entry / outside editing.
    private var bedsideCommands: BedsideCommands {
        BedsideCommands(
            panLeft: { panByOneViewport(direction: .left) },
            panRight: { panByOneViewport(direction: .right) },
            zoomIn: { zoom(factor: 0.8) },
            zoomOut: { zoom(factor: 1.25) },
            nextFinding: { jumpToNextFinding() },
            previousFinding: { jumpToPreviousFinding() },
            nextDeviationBeat: { jumpToNextDeviationBeat() },
            previousDeviationBeat: { jumpToPreviousDeviationBeat() },
            confirm: { _ = dispositionFocused(.confirm) },
            dismiss: { _ = dispositionFocused(.dismiss) },
            reset: { _ = dispositionFocused(.reset) },
            standardView: { applyStandardView() },
            toggleTimeDisplay: {
                let ctx = TimeDisplayContext.shared
                ctx.mode = (ctx.mode == .wallClock) ? .elapsed : .wallClock
            },
            timeDisplayAvailable: recording.hasAbsoluteStartTime,
            timeDisplayIsWallClock: TimeDisplayContext.shared.mode == .wallClock,
            toggleNotesDrawer: {
                withAnimation(.snappy(duration: 0.18)) { notesDrawerExpanded.toggle() }
            },
            nextNote: { stepNote(by: 1) },
            previousNote: { stepNote(by: -1) },
            notesAvailable: !anchoredNotes.isEmpty,
            notesDrawerVisible: contextDrawerIsOpen,
            trendLanes: availableTrendLanes.map {
                BedsideCommands.TrendLaneMenuItem(
                    id: $0.id,
                    label: $0.label,
                    isVisible: visibleTrendLanes.contains($0.id))
            },
            toggleTrendLane: { toggleTrendLane($0) },
            // #248 — the Layers chip's contents, moved to View ▸ Fiducial
            // Layers. Resolved from the SAME `renderPolicy` the overlay draws
            // from, which is X61's rule: a control that claims a state the
            // canvas is not honouring reads as a control that does nothing.
            fiducialLayers: MarkingsFiducialLayer.allCases.map { layer in
                let policy = markingsContext.renderPolicy
                return BedsideCommands.FiducialLayerMenuItem(
                    id: layer.rawValue,
                    label: layer.displayName,
                    isEnabled: markingsContext.enabledLayers.contains(layer),
                    isRendering: policy.drawsMarks
                        && policy.renderableLayers.contains(layer))
            }
            // #227 — the roadmap's "intervals" layer joins the same menu.
            // Not a `MarkingsFiducialLayer` case (its raw values persist,
            // and the letter palette has no letter for it), so it rides
            // along as one more row with its own id; `isRendering` reads
            // the SAME policy the overlay draws from, per X61.
            + [BedsideCommands.FiducialLayerMenuItem(
                id: "interval-spans",
                label: "Intervals",
                isEnabled: markingsContext.showIntervalSpans,
                isRendering: markingsContext.renderPolicy.drawsIntervalSpans)],
            toggleFiducialLayer: { raw in
                if raw == "interval-spans" {
                    markingsContext.showIntervalSpans.toggle()
                    return
                }
                guard let layer = MarkingsFiducialLayer(rawValue: raw) else { return }
                toggleFiducialLayer(layer)
            },
            fiducialLayerExplanation: markingsContext.renderPolicy
                .explanation(enabled: markingsContext.enabledLayers),
            // #253 — the toolbar's own actions, each invoking the SAME closure
            // its button does rather than a parallel implementation. A menu
            // item that drifts from the button it mirrors is worse than no
            // menu item: it teaches the analyst a path that behaves subtly
            // differently from the one they can see.
            toggleEditing: { isEditing.toggle() },
            toggleWindowHold: { toggleWindowLock() },
            windowHeldTo10s: windowLockedTo10s,
            scanForVTVF: {
                scanContext.requestScanDialog(
                    viewStartSample: viewport.startSample,
                    viewEndSample: viewport.endSample
                )
            },
            scanAvailable: scanContext.isScanAvailable,
            attachFindings: { showAttachFindings = true },
            exportReport: { exportMarkdownReport() },
            exportSnapshot: { exportSnapshotPNG() },
            exportWFDBAnnotations: { exportWFDBAnnotations() },
            wfdbExportAvailable: amberFindingCount > 0,
            toggleReviewQueue: {
                panels.request(.inspector, open: !panels.resolution.inspectorVisible)
            },
            reviewQueueVisible: panels.resolution.inspectorVisible,
            // #250: the rename field raises the same gate as the notes
            // editor — typing a finding's name must not pan the viewport.
            textEntryActive: notesEditorFocused || findingRenameActive,
            isEditing: isEditing
        )
    }

    /// VT/VF candidate scan toolbar item — only surfaces when the VT/VF
    /// IAP is owned AND a recording is loaded (the App-target orchestrator
    /// sets `isScanAvailable`). The free viewer never sees it, so the model
    /// is never implied to be present. Extracted as its own toolbar-content
    /// property to keep the `.toolbar` builder's type-check tractable.
    /// 10-second window lock. Snaps the viewport to a 10 s window and holds
    /// it there — finding + candidate jumps recenter without re-zooming, so
    /// an analyst reading in fixed windows keeps their frame. A manual zoom
    /// (see `zoom(factor:)`) releases the lock.
    // MARK: - Toolbar hover text (X60)
    //
    // Named once each rather than written inline, so the string a button
    // claims is greppable and reviewable rather than buried in a modifier.
    //
    // NOTE: these do not currently reach the user. `.help()` renders no
    // tooltip anywhere in this app on macOS 26 — see the X60 PR for the
    // evidence. They are kept accurate so that whenever hover text works
    // again (an OS fix, or a decision to show toolbar labels), the copy is
    // already right rather than needing an audit first.

    private static let scanHelp =
        "Scan this recording for candidate VT/VF episodes (research use only)"
    private static let attachHelp =
        "Merge a producer's annotations JSON into this recording"
    private static let exportReportHelp =
        "Save a markdown report of this recording's findings and dispositions"
    private static let exportSnapshotHelp =
        "Save a PNG snapshot of the current bedside view"
    private static let findingsHelp = "Show or hide the review queue"

    private var editModeHelp: String {
        isEditing
            ? "Editing on — notes and annotations are editable. Click to lock."
            : "Read-only. Click to unlock and edit notes and annotations."
    }

    private var windowLockHelp: String {
        windowLockedTo10s
            ? "Held to a 10-second window. Jumps recenter without changing zoom. Click (or zoom) to release."
            : "Hold the trace to a 10-second window so jumps keep your time frame."
    }

    private var exportWFDBHelp: String {
        "Write your confirmed findings as a WFDB annotation file "
        + "(\(wfdbRecordBase).\(WFDBAnnotationWriter.defaultAnnotator)) "
        + "beside the recording, to hand to a peer"
    }

    @ToolbarContentBuilder
    private var windowLockToolbarItem: some CustomizableToolbarContent {
        ToolbarItem(id: "window-lock-toggle", placement: .automatic, showsByDefault: true) {
            Button {
                toggleWindowLock()
            } label: {
                Label("10 s window", systemImage: windowLockedTo10s ? ToolbarGlyph.windowHeld : ToolbarGlyph.windowFree)
            }
            .help(windowLockHelp)
            .tint(windowLockedTo10s ? Color.accentColor : nil)
            .accessibilityIdentifier("window-lock-toggle")
        }
    }

    @ToolbarContentBuilder
    private var scanToolbarItem: some CustomizableToolbarContent {
        if scanContext.isScanAvailable {
            ToolbarItem(id: "vtvf-scan-action", placement: .automatic, showsByDefault: true) {
                Button {
                    scanContext.requestScanDialog(
                        viewStartSample: viewport.startSample,
                        viewEndSample: viewport.endSample
                    )
                } label: {
                    Label("Scan for VT/VF candidates", systemImage: ToolbarGlyph.scanVTVF)
                }
                .help(Self.scanHelp)
                .accessibilityIdentifier("vtvf-scan-action")
            }
        }
    }

    /// The review-queue inspector — extracted from `body` for the same
    /// type-check reason. Carries both the annotation findings and the
    /// VT/VF model candidates + their region-keyed disposition store.
    private var findingsInspector: some View {
        FindingsPanel(
            annotations: allAnnotations,
            viewport: viewport,
            sampleRate: recording.channels.first?.sampleRate ?? 250,
            headerComments: recording.headerComments,
            filter: $filter,
            dispositionStore: dispositionStore,
            isEditing: isEditing,
            lockZoom: windowLockedTo10s,
            candidates: scanContext.candidates,
            candidateDispositionStore: candidateDispositionStore,
            regulatoryNotice: scanContext.regulatoryNotice,
            parametersCaption: scanContext.parametersCaption,
            candidateProvenance: scanContext.candidateProvenance,
            arrhythmiaCandidates: arrhythmiaContext.candidates,
            arrhythmiaDispositionStore: arrhythmiaDispositionStore,
            arrhythmiaParametersCaption: arrhythmiaContext.parametersCaption,
            arrhythmiaRegulatoryNotice: arrhythmiaContext.regulatoryNotice,
            arrhythmiaPreflightWindows: arrhythmiaContext.preflightWindows,
            onRenameFinding: { annotation, newLabel in
                renameFinding(annotation, to: newLabel)
            },
            onRenameFieldActive: { findingRenameActive = $0 }
        )
        .inspectorColumnWidth(min: 260, ideal: 340, max: 500)
        // The Review Queue owns its own scrolling, so its content height is
        // its business and not the window's. Without this floor the queue
        // publishes that height upward and the whole window inherits a
        // minimum it never needed — measured at 850 pt against a 720 pt
        // window minimum. Same contract as the centre column above.
        .frame(minHeight: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            LeadChipBar(
                channels: ecgChannels,
                layoutMode: $layoutMode,
                recordDurationSeconds: totalDurationSeconds,
                viewportDurationSeconds: viewport.durationSeconds,
                onSelectZoom: applyZoomLadderStep
            )
            Divider()
            bedsideContent
            Divider()
            // Outside `bedsideContent` deliberately: it is the WINDOW's rail,
            // not the stage's, so it stays put in both layout modes — strips
            // mode scrolls wholesale and would otherwise carry it off-screen.
            infoBar
        }
        // X73: publish the viewport so the metrics block can scope to it.
        // Published on every change and DEBOUNCED on the orchestrator side —
        // it owns the recompute, so it should own the cost of deciding when
        // to pay it. Publishing a value is cheap; recomputing over millions of
        // beats is not.
        .onChange(of: viewport.rangeSamples, initial: true) { _, range in
            MetricsScopeContext.shared.set(viewportRange: range, sampleRate: viewport.sampleRate)
        }
        .focusable()
        .focusEffectDisabled()
        // Keyboard navigation. Arrow keys pan by one viewport width,
        // +/- zoom around the viewport centre, J/K jump to the next /
        // previous filtered finding. Text fields (notes editor, attach
        // sheet, etc.) become first-responder when active, so these
        // handlers don't fire while typing.
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in
            panByOneViewport(direction: .left)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in
            panByOneViewport(direction: .right)
            return .handled
        }
        // Two bindings for zoom-in so the analyst doesn't have to hold
        // shift on US layouts: "+" only types via shift+=, but "=" is
        // the unshifted key in the same position.
        .onKeyPress("=", phases: [.down, .repeat]) { _ in
            zoom(factor: 0.8)
            return .handled
        }
        .onKeyPress("+", phases: [.down, .repeat]) { _ in
            zoom(factor: 0.8)
            return .handled
        }
        .onKeyPress("-", phases: [.down, .repeat]) { _ in
            zoom(factor: 1.25)
            return .handled
        }
        .onKeyPress("j", phases: [.down, .repeat]) { _ in
            jumpToNextFinding()
            return .handled
        }
        .onKeyPress("k", phases: [.down, .repeat]) { _ in
            jumpToPreviousFinding()
            return .handled
        }
        // Deviation-ranked navigation through fiducial beats — steps
        // from the most-deviant beat toward more-typical ones on `]`,
        // and back on `[`. Hidden when no template exists.
        .onKeyPress("]", phases: [.down, .repeat]) { _ in
            jumpToNextDeviationBeat()
            return .handled
        }
        .onKeyPress("[", phases: [.down, .repeat]) { _ in
            jumpToPreviousDeviationBeat()
            return .handled
        }
        // Disposition shortcuts. Gated on the same Editing latch the
        // toolbar uses for notes / annotation create-edit-delete —
        // analysts have to unlock the recording before keystrokes
        // mutate state. All three shortcuts target the annotation
        // closest to the viewport centre (the one J/K most recently
        // jumped to). No `.repeat` phase since each disposition is a
        // single-shot action.
        .onKeyPress("c") {
            return dispositionFocused(.confirm) ? .handled : .ignored
        }
        .onKeyPress("d") {
            return dispositionFocused(.dismiss) ? .handled : .ignored
        }
        .onKeyPress("x") {
            return dispositionFocused(.reset) ? .handled : .ignored
        }
        // #225: release the pinned beat. `.ignored` when nothing is pinned,
        // so Escape keeps whatever meaning the rest of the app gives it —
        // swallowing it unconditionally would make this the handler for a
        // key the analyst presses to dismiss things generally.
        .onKeyPress(.escape) {
            guard markingsContext.pinnedBeatSampleIndex != nil else { return .ignored }
            markingsContext.clearPin()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bedside-view")
        // X22: publish the bedside actions as a focused SCENE value so the
        // "Navigate" menu can drive them through the responder chain (fixes
        // the intermittent J/K defect) and expose them + their shortcuts in
        // the menu bar. The onKeyPress handlers above stay as a trace-focused
        // fallback; the menu is the reliable path.
        .focusedSceneValue(\.bedsideCommands, bedsideCommands)
        // Invisible accessibility-only element exposing the current
        // viewport range as a label. Lets XCUI tests assert "did a
        // drag/click change the viewport?" without trying to read
        // nested SwiftUI Text elements (which the accessibility tree
        // hides behind their container's identifier).
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("ui-test-viewport-state")
                // Format avoids `dddd-dddd` patterns that the macOS
                // accessibility post-processor reformats with thousands
                // separators (e.g. `1750` → `1,750`). Letter separators
                // keep tests' equality comparisons stable.
                .accessibilityLabel(viewportStateLabel)
                .allowsHitTesting(false)
        }
        // AX4: VoiceOver-facing position readout (clock time + focused beat),
        // separate from the machine-format element above so it can speak
        // naturally without disturbing XCUI's equality assertions.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("viewport-position")
                .accessibilityLabel(viewportPositionLabel)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            // Hidden leaf exposing the last WFDB export's result to XCUI —
            // the count travels through the amber filter + writer, so only an
            // end-to-end assertion proves the plumbing. Suffix uses letters,
            // count stays under 1000, so the accessibility post-processor
            // doesn't reformat the label.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("ui-test-wfdb-export")
                .accessibilityLabel(lastWFDBExport.map { "annotator=\($0.annotator) count=\($0.findingCount)" } ?? "none")
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            // Count of analyst-authored range findings — proves drag-to-author
            // created + persisted a finding (the gesture itself isn't XCUI-
            // drivable, so the bypass invokes the handler and this leaf reports).
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("ui-test-authored-count")
                .accessibilityLabel("\(authoredRangeFindings.count)")
                .allowsHitTesting(false)
        }
        .inspector(isPresented: Binding(
            get: { panels.resolution.inspectorVisible },
            // Intent only when the write DISAGREES with the resolution: when
            // the coexistence rule hides the inspector, SwiftUI echoes the
            // dismissal back through this binding, and recording that echo as
            // analyst intent would keep the queue hidden after the window
            // widens again.
            set: { newValue in
                guard newValue != panels.resolution.inspectorVisible else { return }
                panels.request(.inspector, open: newValue)
            }
        )) {
            findingsInspector
        }
        // X60: an ID'd toolbar is a CUSTOMISABLE one — macOS then offers
        // View → Customize Toolbar…, where the analyst can switch the display
        // mode to Icon and Text and drop the buttons they don't use.
        //
        // That matters more here than it normally would: `.help()` renders no
        // tooltip anywhere in this app on macOS 26 (see X60), so an icon-only
        // button has no way at all to say what it is. Customisation gives the
        // analyst a route to visible labels that does not depend on a broken
        // API.
        //
        // The default is icon-only again as of #253 — AppKit's own default,
        // with X60's seed deleted rather than reversed. That was declined
        // twice before, both times for the reason above: with tooltips broken,
        // removing the labels leaves nothing saying what a button is. It went
        // ahead now because #287 finally supplied the replacement affordance
        // the redesign always assumed — every action here has a menu-bar row.
        // See MurmurToolbar for the full record.
        //
        // The ids are the accessibility identifiers, deliberately: one name
        // per button, already stable, and already what the XCUI suite binds
        // to. They are persisted in the customisation, so DO NOT rename one
        // without accepting that an analyst's saved layout loses that item.
        .toolbar(id: MurmurToolbar.identifier) {
            // X72 — the Context drawer toggle, leading the trailing cluster
            // per the wireframe's ordering. Same action as ⌘⇧N.
            ToolbarItem(id: "notes-toggle", placement: .automatic, showsByDefault: true) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { notesDrawerExpanded.toggle() }
                } label: {
                    Label("Notes", systemImage: ToolbarGlyph.notes)
                }
                .help("Show or hide the Context drawer (⌘⇧N)")
                .tint(contextDrawerIsOpen ? Color.accentColor : nil)
                .accessibilityIdentifier("notes-toggle")
            }
            ToolbarItem(id: "edit-mode-toggle", placement: .automatic, showsByDefault: true) {
                Button {
                    isEditing.toggle()
                } label: {
                    Label(
                        isEditing ? "Editing" : "Locked",
                        systemImage: isEditing ? ToolbarGlyph.editModeUnlocked : ToolbarGlyph.editModeLocked
                    )
                }
                .help(editModeHelp)
                .tint(isEditing ? Color.accentColor : nil)
                .accessibilityIdentifier("edit-mode-toggle")
            }
            windowLockToolbarItem
            scanToolbarItem
            ToolbarItem(id: "attach-findings", placement: .automatic, showsByDefault: true) {
                Button {
                    showAttachFindings = true
                } label: {
                    Label("Attach findings…", systemImage: ToolbarGlyph.attachFindings)
                }
                .help(Self.attachHelp)
                .accessibilityIdentifier("attach-findings")
            }
            // The three exports become one menu (X68). The other two ids stay
            // REGISTERED but hidden by default rather than being retired: they
            // are persisted in every analyst's saved toolbar layout, and X60
            // made the toolbar customisable precisely so labels could be turned
            // back on. A menu-backed action cannot be dragged out as a labelled
            // button; a hidden-by-default item can.
            ToolbarItem(id: "export-report", placement: .automatic, showsByDefault: true) {
                Menu {
                    Button("Export report…") { exportMarkdownReport() }
                        .accessibilityIdentifier("export-report-item")
                    Button("Export snapshot…") { exportSnapshotPNG() }
                        .accessibilityIdentifier("export-snapshot-item")
                    Button("Export WFDB annotations…") { exportWFDBAnnotations() }
                        .disabled(amberFindingCount == 0)
                        .accessibilityIdentifier("export-wfdb-item")
                } label: {
                    Label("Export", systemImage: ToolbarGlyph.exportReport)
                }
                .help(Self.exportReportHelp)
                .accessibilityIdentifier("export-report")
            }
            ToolbarItem(id: "export-snapshot", placement: .automatic, showsByDefault: false) {
                Button { exportSnapshotPNG() } label: {
                    Label("Export snapshot…", systemImage: ToolbarGlyph.exportSnapshot)
                }
                .help(Self.exportSnapshotHelp)
                .accessibilityIdentifier("export-snapshot")
            }
            ToolbarItem(id: "export-wfdb", placement: .automatic, showsByDefault: false) {
                Button { exportWFDBAnnotations() } label: {
                    Label("Export WFDB annotations…", systemImage: ToolbarGlyph.exportWFDB)
                }
                .help(exportWFDBHelp)
                .disabled(amberFindingCount == 0)
                .accessibilityIdentifier("export-wfdb")
            }
            #if DEBUG
            ToolbarItem(id: "producers-toggle", placement: .automatic, showsByDefault: true) {
                Button {
                    showProducersPanel = true
                } label: {
                    Label("Producers", systemImage: ToolbarGlyph.producers)
                }
                .help("Run a registered FindingProducer over this recording")
                .accessibilityIdentifier("producers-toggle")
            }
            #endif
            ToolbarItem(id: "findings-toggle", placement: .automatic, showsByDefault: true) {
                Button {
                    panels.request(.inspector, open: !panels.resolution.inspectorVisible)
                } label: {
                    Label("Review queue", systemImage: ToolbarGlyph.reviewQueue)
                }
                .help(Self.findingsHelp)
                .tint(panels.resolution.inspectorVisible ? Color.accentColor : nil)
                .accessibilityIdentifier("findings-toggle")
            }
        }
        .fileImporter(
            isPresented: $showAttachFindings,
            allowedContentTypes: [.json]
        ) { result in
            handleAttachFindings(result)
        }
        .sheet(isPresented: $showProducersPanel) {
            ProducersPanel { findings in
                handleProducerOutput(findings)
            }
            .environment(\.activeRecording, recording)
        }
        // X16: the gain-reinterpretation sheet. `item:` so each channel's
        // sheet opens pre-filled with THAT channel's standing factor.
        .sheet(item: $gainSheetChannel) { channel in
            GainInterpretationSheet(
                channel: channel,
                onApply: { factor in applyGainInterpretation(channel: channel, factor: factor) },
                onCancel: { gainSheetChannel = nil }
            )
        }
        .alert(
            "Couldn't attach findings",
            isPresented: Binding(
                get: { attachError != nil },
                set: { if !$0 { attachError = nil } }
            )
        ) {
            Button("OK") { attachError = nil }
        } message: {
            Text(attachError ?? "")
        }
        .onChange(of: calibration.canvasSize, initial: true) { _, _ in
            // Order is load-bearing (X50(b)): the saved PAPER goes on first, so
            // the snap guard sees a non-nil gain and declines; then the snap
            // runs for anything that has no saved paper; then the rest of the
            // restore (viewport, lead, lock) lands last, so a snap can't
            // clobber a restored viewport width.
            applyPendingCalibrationRestoreIfNeeded()
            applyOpenCalibrationIfNeeded()
            applyPendingSessionRestoreIfNeeded()
        }
        // X59: republish the live snapshot on every change, so ⌘S can capture
        // state that lives in this view's @State. MERGES rather than replaces —
        // `MurSessionState` also carries fields owned by other surfaces (the
        // scan dials, X11), and assigning a fresh value built only from this
        // view's state would silently wipe them.
        .onChange(of: sessionSnapshot, initial: true) { _, snapshot in
            let context = CurrentRecordingContext.shared
            context.liveSessionState = context.liveSessionState
                .replacingViewState(with: snapshot)
        }
        // X112c: mirror the endorsements to the shared context so the
        // markings orchestrator (App target — can't reach this @State) can
        // rebuild the baseline from the endorsed clusters. The view stays
        // the owner; this is transport, like the live snapshot above.
        .onChange(of: morphologyEndorsements, initial: true) { _, endorsements in
            MorphologyContext.shared.setEndorsements(endorsements)
        }
        #if DEBUG
        .task { applyUITestHooks() }
        #endif
    }

    /// X50: snap a freshly opened raw record onto standard ECG paper the first
    /// time the focused panel reports a real canvas size. `applyStandardView()`
    /// needs `calibration.canvasSize` (published post-layout), so this can't
    /// run in `init`. Runs exactly once, and only while gain is still unset, so
    /// the analyst's subsequent manual changes are never clobbered.
    ///
    /// NOTE (verified 2026-08-02): this guard is currently the ONLY gate, and a
    /// `.mur` open takes the SAME path as a raw import — `openMurPackage`
    /// discards `sessionJSON`, and `MurSessionState` carries no calibration
    /// field at all. So a restored session does NOT yet keep its own paper; it
    /// snaps to Standard View like everything else. An earlier version of this
    /// comment claimed otherwise. Restoring saved calibration is X59 (session
    /// capture) plus X50's second half — until both land, do not read this
    /// guard as if `.mur` were already exempt.
    private func applyOpenCalibrationIfNeeded() {
        #if DEBUG
        // Under XCUI the X100 window policy (`applyTestWindowPolicy`) sizes
        // the window ASYNCHRONOUSLY after launch, so the first-layout canvas
        // a one-shot snap would use is transient: once the resize lands, the
        // viewport's samples are frozen but the canvas is wider, and the
        // readout reports 25 × (settled ÷ snap-time width) mm/s —
        // "non-standard" on open, the exact X50 own-goal, manufactured by the
        // harness. Under the X50 opt-in the snap therefore RE-APPLIES on
        // every canvas change: the same `applyStandardView` wiring production
        // runs once, held through the harness's late resize. (This flag is
        // exclusively the X50 wire-up guard's; nothing restored or manually
        // set exists under it for the re-snap to clobber.)
        if UITestSupport.standardOpenEnabled {
            guard calibration.canvasSize.width > 0 else { return }
            hasAppliedOpenCalibration = true
            applyStandardView(anchorFraction: 0)
            return
        }
        #endif
        guard !hasAppliedOpenCalibration,
              calibration.canvasSize.width > 0,
              calibration.gainMillimetersPerMillivolt == nil else { return }
        #if DEBUG
        // Under XCUI the snapped width is display-size dependent, which would
        // make every bare `--ui-test-sample` test's open geometry vary by
        // machine. Keep the legacy open width in tests unless a test explicitly
        // opts in (the dedicated X50 wire-up guard does). Non-test launches
        // always snap.
        if UITestSupport.isRunningUITest {
            hasAppliedOpenCalibration = true
            return
        }
        #endif
        hasAppliedOpenCalibration = true
        applyStandardView(anchorFraction: 0)   // open at t = 0, not centred
    }

    // MARK: - Session capture (X59)

    /// The live session snapshot published for `.mur` save. Deliberately small:
    /// only state an analyst would notice losing on reopen. Read by
    /// `saveSessionPanel()` via `CurrentRecordingContext.liveSessionState`,
    /// because this state is `@State` on this view and the App target's menu
    /// commands cannot reach in.
    private var sessionSnapshot: MurSessionState {
        MurSessionState(
            viewportStartSample: viewport.startSample,
            viewportEndSample: viewport.endSample,
            focusedChannelName: focusedChannel?.name,
            // X96: the full overlay, in selection order — nil for a
            // single-lead stage, so a package saved without an overlay is
            // byte-identical to a pre-X96 one. The singular above always
            // carries the primary for older readers.
            focusedChannelNames: overlaySessionLeadNames,
            windowLockedTo10s: windowLockedTo10s,
            // X50(b): the analyst's paper. Still `nil` before the open snap
            // resolves a gain, which is exactly right — a package saved in that
            // state carries no paper and reopens at Standard View.
            gainMillimetersPerMillivolt: calibration.gainMillimetersPerMillivolt,
            // X72: nil-when-empty so a session with no notes is byte-identical
            // to one saved before notes existed. Carried through
            // `replacingViewState` — omitting it there is the X11 wipe.
            anchoredNotes: anchoredNotes.isEmpty ? nil : anchoredNotes,
            // X112: same nil-when-empty discipline; carried through
            // `replacingViewState` like the notes.
            morphologyEndorsements: morphologyEndorsements.isEmpty ? nil : morphologyEndorsements
        )
    }

    /// X96: the overlay as session state — every staged lead's NAME in
    /// selection order (names, not IDs: channel IDs are per-import). nil
    /// unless the stage actually carries an overlay. A staged lead whose
    /// name can't be resolved is dropped rather than guessed.
    private var overlaySessionLeadNames: [String]? {
        guard let selection = layoutMode.leadSelection, !selection.isSingle else { return nil }
        let namesByID = Dictionary(
            ecgChannels.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let names = selection.ordered.compactMap { namesByID[$0] }
        return names.count > 1 ? names : nil
    }

    /// X50(b) — restore the saved paper, and ONLY the paper, before
    /// `applyOpenCalibrationIfNeeded()` gets a chance to snap.
    ///
    /// Ordering is the whole mechanism: that guard fires only while
    /// `gainMillimetersPerMillivolt == nil`, so setting the saved gain first
    /// makes it correctly decline, and a `.mur` keeps its own paper. A raw
    /// import (no pending restore) and a `.mur` saved without a resolved gain
    /// both leave it nil, so X50(a)'s standard-paper open is untouched.
    ///
    /// Deliberately does NOT consume `pendingSessionRestore` — the rest of the
    /// restore has to land *after* the snap, or a standard-view snap would
    /// clobber the restored viewport width.
    private func applyPendingCalibrationRestoreIfNeeded() {
        guard let restore = CurrentRecordingContext.shared.pendingSessionRestore,
              let gain = restore.gainMillimetersPerMillivolt,
              calibration.gainMillimetersPerMillivolt == nil else { return }
        calibration.gainMillimetersPerMillivolt = gain
    }

    /// Applies session state restored from a `.mur`, exactly once.
    ///
    /// Runs AFTER `applyOpenCalibrationIfNeeded()` so a viewport the analyst
    /// deliberately saved wins over the standard-paper default. A raw
    /// WFDB/CSV import never has a pending restore, so X50's standard open
    /// state is untouched — as is a `.mur` written before session capture
    /// existed (absent stays absent; nothing is fabricated).
    ///
    /// CONSUMES the pending value, so a later re-render cannot re-apply a
    /// stale restore over navigation the analyst has done since.
    private func applyPendingSessionRestoreIfNeeded() {
        let context = CurrentRecordingContext.shared
        guard let restore = context.pendingSessionRestore else { return }
        context.pendingSessionRestore = nil

        // Adopt the restored state wholesale as the live baseline FIRST, so
        // fields this view doesn't own (the scan dials, X11) survive the round
        // trip. The view then applies the subset it does own, below.
        context.liveSessionState = restore

        if let start = restore.viewportStartSample,
           let end = restore.viewportEndSample,
           end > start {
            // Width first, then origin: `setWidth` re-anchors, and both clamp
            // to recording bounds, so a corrupt or out-of-range pair can't
            // push the viewport outside the record.
            viewport.setWidth(end - start, anchorFraction: 0)
            viewport.setStart(start)
        }
        if let locked = restore.windowLockedTo10s {
            windowLockedTo10s = locked
        }
        // X96: restore the whole staged overlay, in the saved selection
        // order — order is what X64-C assigns trace inks by, so preserving
        // it is what keeps a reopened session's traces the same colours.
        // Names missing from the record (renamed/absent channel) drop out;
        // if nothing resolves, the default focus stands rather than a
        // fabricated one. Old packages carry only the singular field and
        // restore single-lead exactly as before (`restoredLeadNames`).
        let restoredNames = restore.restoredLeadNames
        if !restoredNames.isEmpty {
            let idsByName = Dictionary(
                ecgChannels.map { ($0.name, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            if let selection = LeadSelection(ordered: restoredNames.compactMap { idsByName[$0] }) {
                layoutMode = .focus(selection)
            }
        }
        // X72: anchored notes ride the same restore. Absent stays absent —
        // a package saved before notes existed restores none, never a
        // fabricated empty list overwriting notes taken since open.
        if let notes = restore.anchoredNotes {
            anchoredNotes = notes
        }
        // X112: endorsements ride the same restore, same absent-stays-absent
        // rule. Re-attachment to the recomputed clusters happens at render
        // time by representative match — nothing to resolve here.
        if let endorsements = restore.morphologyEndorsements {
            morphologyEndorsements = endorsements
        }
        if let carried = context.pendingCarriedNotesBaseline {
            // X86: this restore came from CarriedSessionStore, not from a
            // `.mur` — its notes are only as saved as they were when the
            // analyst switched away. Keeping the parked baseline is what
            // lets the drawer footer and the quit guard stay truthful.
            context.pendingCarriedNotesBaseline = nil
            context.sessionSavedNotes = carried.notes
        } else {
            // What was just restored IS the saved state — seed the drawer's
            // unsaved-indicator baseline with it.
            context.sessionSavedNotes = restore.anchoredNotes ?? []
        }
    }

    #if DEBUG
    /// Grants the VT/VF IAP and publishes a fixed set of synthetic
    /// candidates — the same state a committed scan produces — so XCUI can
    /// exercise the candidate group + disposition wire-up without running
    /// Core ML. Coordinates sit inside the 10 s synthetic fixture.
    @MainActor
    private func injectSyntheticVTVFCandidates() {
        // Deliberately does NOT grant PurchaseStore entitlement — that
        // races against the store's async currentEntitlements refresh. The
        // orchestrator makes the scan affordance available under the same
        // launch flag instead (without loading Core ML).
        let sr = ecgChannels.first?.sampleRate ?? 250
        let candidates = [
            VTVFCandidateSource.makeAnnotation(
                startSample: Int64(1 * sr), endSample: Int64(4 * sr), score: 0.93
            ),
            VTVFCandidateSource.makeAnnotation(
                startSample: Int64(6 * sr), endSample: Int64(9 * sr), score: 0.81
            ),
        ]
        scanContext.setCandidates(
            candidates,
            parametersCaption: "τ 0.87 · min 4s · gap 5s · vtvf_seres_lstm",
            provenance: .init(modelIdentifier: "vtvf_seres_lstm", tau: 0.87)
        )
        scanContext.isScanAvailable = true
    }

    /// Publishes a fixed set of arrhythmia candidates (A2) — the same state
    /// a completed scan produces — so XCUI can exercise the queue group +
    /// region-keyed disposition wire-up without running the detectors.
    /// Coordinates sit inside the 10 s synthetic fixture; kinds cover a
    /// span detector (brady) and the two point-like ones (pause, AFib).
    @MainActor
    private func injectSyntheticArrhythmiaCandidates() {
        let sr = ecgChannels.first?.sampleRate ?? 250
        let candidates = [
            ArrhythmiaCandidateSource.makeAnnotation(
                kind: .bradycardia,
                startSample: Int64(1 * sr), endSample: Int64(3 * sr),
                detail: "median 48 bpm", confidence: 0.97
            ),
            ArrhythmiaCandidateSource.makeAnnotation(
                kind: .pause,
                startSample: Int64(5 * sr), endSample: Int64(7 * sr),
                detail: "2.40 s gap", confidence: 1.0
            ),
            ArrhythmiaCandidateSource.makeAnnotation(
                kind: .atrialFibrillation,
                startSample: Int64(7 * sr), endSample: Int64(9 * sr),
                detail: "irregularly irregular RR", confidence: 0.92
            ),
        ]
        arrhythmiaContext.setCandidates(
            candidates,
            parametersCaption: "lead II · 12 beats detected · RR artifact 0.0% · signal quality 0 of 1 windows flagged"
        )
    }

    /// X52 §5: publish a deterministic fiducial store whose every beat carries
    /// the SAME known QTc, so the paid trend lane's computed bin median is a
    /// value the wire-up test knows in advance and can assert the RENDERED
    /// number against. Entitlement is granted in `PurchaseStore.init` under the
    /// same flag; the orchestrator skips its recompute so this store survives.
    @MainActor
    private func injectSyntheticQTcLane(qtcMs: Double) {
        let sr = ecgChannels.first?.sampleRate ?? 250
        // 30 high-confidence beats across the fixture — enough to clear the
        // per-bin confidence floor and land a stable median.
        let beats: [MarkingsBeat] = (0..<30).map { i in
            let r = Int64(100 + i * 80)
            return MarkingsBeat(
                rPeakSampleIndex: r,
                rPeakConfidence: 1.0,
                qrsOnset: MarkingsFiducial(kind: .qrsOnset, sampleIndex: r - 15, confidence: 0.95),
                tOffset:  MarkingsFiducial(kind: .tOffset,  sampleIndex: r + 90, confidence: 0.95),
                prMs: 150, qrsMs: 90, qtMs: qtcMs * 0.9, qtcMs: qtcMs, precedingRRMs: 800
            )
        }
        // X58: carries a fixed per-reason exclusion split so XCUI can assert
        // the exclude-and-count surfaces (lane caption + provenance footer)
        // render the counts without running the delineator.
        let template = MarkingsTemplate(
            sampleCount: 30,
            medianPRMs: 150, iqrPRMs: 8,
            medianQRSMs: 90, iqrQRSMs: 6,
            medianQTMs: qtcMs * 0.9, iqrQTMs: 10,
            qtcFormulaName: markingsContext.qtcFormula.displayName,
            medianQTcMs: qtcMs, iqrQTcMs: 10,
            excludedBeatCount: 5,
            excludedImplausibleCount: 2,
            excludedUnreliableCount: 3
        )
        markingsContext.set(beats: beats, sampleRate: sr, template: template)
    }

    /// Confirms a fixed synthetic candidate region — shared by the export
    /// bypass and the seed-only flag so both exercise the same amber input.
    @MainActor
    private func seedConfirmedRegionForTests() {
        let sr = ecgChannels.first?.sampleRate ?? 250
        candidateDispositionStore.confirm(
            start: Int64(1 * sr), end: Int64(4 * sr), kind: .vt,
            modelIdentifier: "vtvf_seres_lstm", tauAtConfirmation: 0.87
        )
    }

    /// Applies launch-arg-driven viewport mutations once the view appears.
    /// Mirrors the gestures' code paths so the wiring from launch arg →
    /// viewport state matches the wiring from gesture → viewport state.
    /// Runs after a tick so the viewport has its initial range in place.
    private func applyUITestHooks() {
        Task { @MainActor in
            // 1 ms is long enough for the viewport's initial range to settle
            // but short enough that the test's waitForExistence still catches
            // the post-hook state.
            try? await Task.sleep(nanoseconds: 1_000_000)
            if UITestSupport.injectVTVFCandidates {
                injectSyntheticVTVFCandidates()
            }
            if UITestSupport.injectArrhythmiaCandidates {
                injectSyntheticArrhythmiaCandidates()
            }
            if let qtc = UITestSupport.injectQTcLaneValue {
                injectSyntheticQTcLane(qtcMs: qtc)
            }
            if UITestSupport.exportWFDBFindings {
                // Confirm a synthetic candidate region so the amber filter has
                // something to export, then export to a fixed container path
                // (no save panel — XCUI can't drive one) and publish the result
                // on the a11y leaf.
                seedConfirmedRegionForTests()
                let url = recordingDirectory
                    .appendingPathComponent("\(wfdbRecordBase).\(WFDBAnnotationWriter.defaultAnnotator)")
                performWFDBExport(to: url)
            }
            if UITestSupport.seedConfirmedRegion {
                // Confirm a region but do NOT export — lets an XCUI test drive
                // the real export button + confirm alert.
                seedConfirmedRegionForTests()
            }
            if UITestSupport.authorRange {
                // Drive the drag-to-author handler directly (the DragGesture
                // itself isn't XCUI-drivable) so the author→persist→render path
                // is assertable via the authored-count leaf.
                authorRangeFinding(
                    startSeconds: 1, endSeconds: 4,
                    label: "QTc 432→508 ms · 0:01–0:04",
                    citation: "QTc · Fridericia · test"
                )
            }
            if let delta = UITestSupport.panBySamples {
                viewport.setStart(viewport.startSample + delta)
            }
            if let seconds = UITestSupport.zoomToSeconds,
               let firstECG = ecgChannels.first {
                let width = Int64(seconds * firstECG.sampleRate)
                viewport.setWidth(width, anchorFraction: 0.5)
            }
            if let url = UITestSupport.attachFindingsURL {
                handleAttachFindings(.success(url))
                UITestSupport.attachFindingsURL = nil
            }
            if UITestSupport.injectLFHFLane {
                // X76 wire-up: a deterministic series whose every window reads
                // exactly 1.50, so the UI test can assert the RENDERED value.
                // Windows tile the whole record at the shipping 5-min/1-min
                // geometry scaled down to the 10 s fixture (2 s window, 1 s
                // step) — the lane's geometry doesn't care, only the values do.
                let total = Double(viewport.totalSamples) / max(1, viewport.sampleRate)
                let injected = stride(from: 0.0, through: max(0, total - 2), by: 1.0).map {
                    VariabilityLaneSample(
                        windowStartSeconds: $0,
                        windowEndSeconds: $0 + 2,
                        value: 1.50,
                        isEligible: true
                    )
                }
                RollingLFHFContext.shared.set(
                    samples: injected,
                    caption: RollingLFHFContext.provenanceCaption
                )
            }
            if let count = UITestSupport.seedNotesCount {
                // X72: seed N anchored notes, evenly spaced, each one second
                // long — deterministic positions so the record band's note
                // ticks land where a pixel check expects them.
                let total = viewport.totalSamples
                let sr = Int64(max(1, viewport.sampleRate))
                let now = Date(timeIntervalSince1970: 1_750_000_000)
                anchoredNotes = (0..<count).map { i in
                    let start = total * Int64(i * 2 + 1) / Int64(count * 2 + 1)
                    return AnchoredNote(
                        startSample: start,
                        endSample: min(total, start + sr),
                        leadName: focusedChannel?.name,
                        text: "seeded note \(i + 1)",
                        createdAt: now,
                        modifiedAt: now
                    )
                }
            }
            if let count = UITestSupport.panBurstTickCount {
                // Idle long enough that MTKView's display link auto-suspends,
                // then drip N viewport mutations at drag-tick cadence. The
                // first signpost interval captures cold-start cost; the rest
                // capture warm steady-state. See testWarmPanBurstSignpostLatency.
                try? await Task.sleep(nanoseconds: UITestSupport.panBurstIdleNanoseconds)
                for _ in 0..<count {
                    viewport.setStart(viewport.startSample + UITestSupport.panBurstTickDeltaSamples)
                    try? await Task.sleep(nanoseconds: UITestSupport.panBurstTickIntervalNanoseconds)
                }
            }
        }
    }
    #endif

    /// Reads the analyst-picked JSON, parses it through `AnnotationLoader`
    /// (which validates schema version and resolves both sample-index and
    /// unix-millis timestamps), and merges the findings into
    /// `attachedAnnotations`. Failures surface in an alert; nothing in the
    /// existing finding set is mutated on error.
    private func handleAttachFindings(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            attachError = error.localizedDescription
        case .success(let url):
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let firstChannel = recording.channels.first
                let startMS = Int64(
                    (firstChannel?.startDate.timeIntervalSince1970 ?? 0) * 1000
                )
                let sampleRate = firstChannel?.sampleRate ?? 250
                let parsed = try AnnotationLoader.parse(
                    data: data,
                    recordingStartUnixMS: startMS,
                    sampleRate: sampleRate,
                    fallbackSource: "attached.\(url.deletingPathExtension().lastPathComponent)"
                )
                attachedAnnotations.append(contentsOf: parsed)
                // Persist the union so reopening the bundle (or quitting and
                // relaunching) keeps the attached findings without forcing
                // the analyst to re-attach. Write failures are surfaced in
                // the same alert path; nothing in the in-memory list is
                // rolled back since attachment itself succeeded.
                do {
                    try BundleAnnotationsFile.write(allAnnotations, to: recordingDirectory)
                } catch {
                    attachError = "Review-queue items were attached for this session but could not be saved to the bundle: \(error.localizedDescription)"
                }
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    /// Called by the producer-run sheet when a producer finishes
    /// successfully. Appends the producer's findings to the in-memory
    /// `attachedAnnotations` and re-persists the union to the bundle
    /// sidecar so re-opening the recording later still sees them.
    /// Mirrors the persistence semantics of `handleAttachFindings` — a
    /// write failure surfaces in the same alert path but doesn't roll
    /// back the in-memory state.
    /// #250 — rename an analyst-authored finding. Guarded on source here as
    /// well as at the affordance: renaming someone else's annotation would
    /// falsify provenance, and a UI bug must not be enough to do it. Same
    /// persistence semantics as attach/producer: the in-memory rename holds
    /// even if the sidecar write fails, and the failure is surfaced.
    private func renameFinding(_ annotation: Annotation, to newLabel: String) {
        guard annotation.source == Annotation.analystAuthoredSource else { return }
        renamedLabels[annotation.id] = newLabel
        do {
            try BundleAnnotationsFile.write(allAnnotations, to: recordingDirectory)
        } catch {
            attachError = "The finding was renamed for this session but could not be "
                + "saved to the bundle: \(error.localizedDescription)"
        }
    }

    private func handleProducerOutput(_ findings: [Annotation]) {
        guard !findings.isEmpty else { return }
        attachedAnnotations.append(contentsOf: findings)
        do {
            try BundleAnnotationsFile.write(allAnnotations, to: recordingDirectory)
        } catch {
            attachError = "Producer findings were added for this session but could not be saved to the bundle: \(error.localizedDescription)"
        }
    }

    // MARK: - Markdown report export

    /// Opens an NSSavePanel suggesting a filename derived from the
    /// recording, renders the markdown report via `MarkdownReport`,
    /// and writes UTF-8 to the chosen path. Failures route to the
    /// existing `attachError` alert path so we don't have to bring
    /// up new error UI.
    private func exportMarkdownReport() {
        let panel = NSSavePanel()
        panel.title = "Export findings report"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.suggestedReportFilename(
            for: recording,
            at: Date()
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let body = MarkdownReport.generate(
            recording: recording,
            annotations: allAnnotations,
            dispositions: dispositionStore.records,
            tally: dispositionStore.tally(for: allAnnotations),
            // X72: inclusion is the analyst's per-note checkbox, decided here
            // at the call site — the report renders what it is given.
            notes: anchoredNotes.filter { $0.includeInReport == true },
            now: Date()
        )
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            attachError = "Could not write the report: \(error.localizedDescription)"
        }
    }

    /// Builds the suggested save-panel filename from the recording's
    /// source name and a `yyyy-MM-dd-HHmm` timestamp. Pure helper so
    /// tests can pin it deterministically; the in-app path passes
    /// `Date()` at click time.
    static func suggestedReportFilename(for recording: Recording, at date: Date) -> String {
        let base = (recording.sourceFileName as NSString).deletingPathExtension
        let stem = base.isEmpty ? "recording" : base
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(stem)-report-\(formatter.string(from: date)).md"
    }

    // MARK: - PNG snapshot export

    /// Opens an NSSavePanel, captures the key window's content view
    /// via `SnapshotExporter.renderKeyWindowPNG()`, and writes the PNG
    /// to the chosen path. Failures route through `attachError` for
    /// consistent alert handling.
    private func exportSnapshotPNG() {
        let panel = NSSavePanel()
        panel.title = "Export bedside snapshot"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SnapshotExporter.suggestedFilename(
            for: recording,
            at: Date()
        )

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = SnapshotExporter.renderKeyWindowPNG() else {
            attachError = "Couldn't capture the current window — try resizing slightly and retrying."
            return
        }
        do {
            try data.write(to: url)
        } catch {
            attachError = "Couldn't write the snapshot: \(error.localizedDescription)"
        }
    }

    // MARK: - WFDB annotation export

    /// Record basename WFDB annotators must share (so `rdann` finds them
    /// beside the `.hea`/`.dat`). Falls back to a stable stem when the source
    /// name is empty.
    private var wfdbRecordBase: String {
        let base = (recording.sourceFileName as NSString).deletingPathExtension
        return base.isEmpty ? "recording" : base
    }

    /// Count of amber (analyst-authored / confirmed) findings eligible for
    /// export — drives the toolbar button's enabled state.
    private var amberFindingCount: Int {
        WFDBAnnotationExport.amberFindings(
            annotations: allAnnotations,
            annotationDispositions: dispositionStore.records,
            confirmedRegions: candidateDispositionStore.records
        ).count
    }

    /// Presents a save panel (suggesting `<base>.mur`) so the analyst chooses
    /// where the annotations land — the file is meant to be handed to a peer,
    /// so it must be reachable, not buried in the app container. The panel's
    /// message surfaces the lossy span→onset-comment reduction (consent at the
    /// moment of export); the panel itself handles any replace-existing prompt.
    /// Mirrors the imperative NSSavePanel idiom of the report/PNG exports.
    private func exportWFDBAnnotations() {
        let panel = NSSavePanel()
        panel.title = "Export WFDB annotations"
        panel.message = "Each finding is written as a WFDB comment at its onset carrying your label text. A span's extent is described in that text, not written as rhythm boundaries — drop this file beside a copy of the record to read it back."
        panel.allowedContentTypes = [UTType(filenameExtension: WFDBAnnotationWriter.defaultAnnotator) ?? .data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(wfdbRecordBase).\(WFDBAnnotationWriter.defaultAnnotator)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        performWFDBExport(to: url)
    }

    /// Writes the amber findings to `url`. Failures route through the shared
    /// `attachError` alert. The result feeds the hidden XCUI leaf.
    private func performWFDBExport(to url: URL) {
        do {
            lastWFDBExport = try WFDBAnnotationExport.export(
                annotations: allAnnotations,
                annotationDispositions: dispositionStore.records,
                confirmedRegions: candidateDispositionStore.records,
                to: url
            )
        } catch {
            attachError = "Couldn't export findings: \(error.localizedDescription)"
        }
    }

    // MARK: - Keyboard navigation actions

    private enum PanDirection {
        case left, right
    }

    /// Shifts the viewport by exactly one viewport width — the keyboard
    /// equivalent of a full-page scroll. Direct mutation (not animated)
    /// so rapid arrow-key presses don't queue up overlapping animations.
    /// `RecordingViewport.setStart` clamps to recording bounds.
    private func panByOneViewport(direction: PanDirection) {
        let width = viewport.endSample - viewport.startSample
        let delta = direction == .left ? -width : width
        viewport.setStart(viewport.startSample + delta)
    }

    /// Scales the viewport width by `factor` around its centre. `< 1`
    /// zooms in; `> 1` zooms out. Centering on `anchorFraction: 0.5`
    /// keeps whatever the analyst was looking at in the same on-screen
    /// position.
    private func zoom(factor: Double) {
        // Calibration lock (X40 §4): while locked, zoom no-ops so the timebase
        // calibration can't be silently changed out from under the readout.
        // Contract (a) — the lock is a genuine hold, not a soft preference.
        guard !calibration.locked else { return }
        // A deliberate zoom breaks the 10 s window lock — the analyst has
        // chosen a different frame.
        if windowLockedTo10s { windowLockedTo10s = false }
        let currentWidth = viewport.endSample - viewport.startSample
        let newWidth = Int64(Double(currentWidth) * factor)
        viewport.setWidth(newWidth, anchorFraction: 0.5)
    }

    /// Standard View (X40): snap BOTH axes back to standard ECG paper —
    /// 10 mm/mV and 25 mm/s — the "put me back on known paper" home position.
    /// Sets the canonical gain (which the panels' displayRange derives from)
    /// and the viewport width for 25 mm/s, preserving the centre time so the
    /// analyst isn't teleported. A no-op on the time axis when the display's
    /// physical size can't be trusted (we won't assert a mm scale we can't
    /// verify — the X32 honesty rule); the gain is still set to the nominal
    /// standard so the amplitude returns home.
    private func applyStandardView(anchorFraction: Double = 0.5) {
        calibration.gainMillimetersPerMillivolt = CalibrationReading.standardMillimetersPerMillivolt
        guard let mmPerPoint = DisplayMetrics.millimetersPerPoint(),
              let samples = CalibrationMath.windowSamples(
                  millimetersPerSecond: CalibrationReading.standardMillimetersPerSecond,
                  canvasWidthPoints: Double(calibration.canvasSize.width),
                  millimetersPerPoint: mmPerPoint,
                  sampleRate: viewport.sampleRate
              ) else { return }
        if windowLockedTo10s { windowLockedTo10s = false }
        // The command preserves centre time (anchor 0.5) so the analyst isn't
        // teleported; the open path (X50) passes 0 to keep the viewport at
        // t = 0 — a known coordinate, not a first-interesting-region guess.
        viewport.setWidth(samples, anchorFraction: anchorFraction)
    }

    /// Set the shared amplitude gain to a preset (X40 §5: 5 / 10 / 20 mm/mV).
    /// Shared across leads by clinical convention; the panels' displayRange
    /// derives from it reactively.
    private func setGain(millimetersPerMillivolt gain: Double) {
        calibration.gainMillimetersPerMillivolt = gain
    }

    /// Set the timebase to a preset (X40 §5: 25 / 50 mm/s) by snapping the
    /// viewport width, preserving centre time. No-op when the display's
    /// physical size can't be trusted (the X32 honesty rule).
    private func setSpeed(millimetersPerSecond speed: Double) {
        guard let mmPerPoint = DisplayMetrics.millimetersPerPoint(),
              let samples = CalibrationMath.windowSamples(
                  millimetersPerSecond: speed,
                  canvasWidthPoints: Double(calibration.canvasSize.width),
                  millimetersPerPoint: mmPerPoint,
                  sampleRate: viewport.sampleRate
              ) else { return }
        if windowLockedTo10s { windowLockedTo10s = false }
        viewport.setWidth(samples, anchorFraction: 0.5)
    }

    /// Toggle the 10-second window lock. Engaging it snaps the viewport to a
    /// 10 s window centered on the current position; the lock then holds the
    /// zoom steady through finding / candidate jumps (see FindingsPanel's
    /// `lockZoom`). Candidate jumps preserve zoom regardless of this lock.
    private func toggleWindowLock() {
        windowLockedTo10s.toggle()
        if windowLockedTo10s {
            let tenSeconds = Int64(viewport.sampleRate * 10)
            viewport.setWidth(tenSeconds, anchorFraction: 0.5)
        }
    }

    /// Set the viewport to a ladder rung, anchored on the window centre so the
    /// analyst keeps the thing they were looking at.
    ///
    /// Releases the window hold (DECISIONS §5). A ladder click IS a manual
    /// zoom — the pin's meaning is "hold 10 s across finding jumps until I
    /// zoom", and honouring the pin here would make the ladder silently do
    /// nothing, which is the worst of the three options. `windowLockedTo10s`
    /// stays a Bool, so its name, its `.mur` field and its tooltip all stay
    /// true.
    private func applyZoomLadderStep(seconds: Double) {
        windowLockedTo10s = false
        let width = Int64((seconds * max(1, viewport.sampleRate)).rounded())
        viewport.setWidth(max(2, width), anchorFraction: 0.5)
    }

    /// Animated jump to the first filtered finding strictly after the
    /// viewport centre. No-op when there are no findings ahead.
    private func jumpToNextFinding() {
        let centre = (viewport.startSample + viewport.endSample) / 2
        guard let next = Annotation.nextFinding(after: centre, in: filteredAnnotations) else { return }
        let total = max(1, viewport.totalSamples)
        viewport.animateJump(toFraction: Double(next.sampleIndex) / Double(total), duration: 0.18)
    }

    /// Animated jump to the last filtered finding strictly before the
    /// viewport centre.
    private func jumpToPreviousFinding() {
        let centre = (viewport.startSample + viewport.endSample) / 2
        guard let prev = Annotation.previousFinding(before: centre, in: filteredAnnotations) else { return }
        let total = max(1, viewport.totalSamples)
        viewport.animateJump(toFraction: Double(prev.sampleIndex) / Double(total), duration: 0.18)
    }

    /// Jump to the next beat by deviation-from-template ranking. Steps
    /// from most-deviant toward more-typical. No-op when the fiducial
    /// store is empty or no template is available.
    private func jumpToNextDeviationBeat() {
        guard let next = markingsContext.nextDeviationBeat(after: markingsContext.focusedBeatSampleIndex) else { return }
        jumpViewport(toBeat: next.rPeakSampleIndex)
    }

    /// Jump to the previous beat by deviation-from-template ranking.
    private func jumpToPreviousDeviationBeat() {
        guard let prev = markingsContext.previousDeviationBeat(before: markingsContext.focusedBeatSampleIndex) else { return }
        jumpViewport(toBeat: prev.rPeakSampleIndex)
    }

    /// Move the viewport to a beat the analyst named, and PIN it there.
    ///
    /// The single path for every "take me to this beat" gesture — `]` / `[`
    /// and the interval-trend bin click. They used to be separate and each
    /// had half the behaviour: this one moved the viewport but only
    /// hover-focused, so the next mouse-exit erased the card (#279), while
    /// the trend click pinned but never moved the viewport, because it
    /// posted a jump request nothing consumed.
    private func jumpViewport(toBeat sample: Int64) {
        let total = max(1, viewport.totalSamples)
        viewport.animateJump(toFraction: Double(sample) / Double(total), duration: 0.18)
        markingsContext.pin(beatSampleIndex: sample)
    }

    /// Determine the caliper kind for the focused beat by cross-
    /// referencing the recording's annotations near the R-peak. An
    /// annotation whose category is a WFDB ectopic class (V, PVC,
    /// paced-broad-QRS variants) within a QRS-width tolerance of the
    /// R-peak classifies the beat as ectopic — the docked inspector
    /// then renders PR / QT / QTc as undefined per the ratified
    /// mockup-review Correction A. Reads imported annotations only
    /// (no arithmetic on measurements — free-viewer scope).
    private func caliperKind(for beat: MarkingsBeat) -> BeatCaliperKind {
        // ~100 ms window — wide enough to catch an annotation placed
        // at either the R-peak or a QRS-onset offset, narrow enough
        // to not sweep in a neighbouring beat's tag.
        let toleranceSamples = Int64(markingsContext.sampleRate * 0.1)
        let center = beat.rPeakSampleIndex
        let ectopicCategories: Set<String> = ["V", "PVC", "F", "E", "J", "S", "e", "j", "P", "r"]
        for ann in allAnnotations where ann.kind == .point {
            guard abs(ann.sampleIndex - center) <= toleranceSamples else { continue }
            let normalized = ann.category.trimmingCharacters(in: .whitespaces).uppercased()
            if ectopicCategories.contains(normalized) || normalized == "PVC" {
                return .ectopic
            }
        }
        return .unknown
    }

    /// Action menu for the C / D / X disposition keyboard shortcuts.
    private enum DispositionAction { case confirm, dismiss, reset }

    /// Applies a disposition action to the annotation closest to the
    /// viewport centre. Returns `true` when the action ran (and the
    /// gesture handler should consume the key event), `false` when the
    /// editing latch is locked or there's nothing to target.
    ///
    /// `.confirm` records the finding as confirmed with
    /// `confirmedKind = .unclassified` — the analyst's keyboard
    /// shortcut commits the binary "yes this is real" call without
    /// pre-committing a VT/VF sub-classification. Specific sub-kinds
    /// stay reachable via the panel's row buttons.
    private func dispositionFocused(_ action: DispositionAction) -> Bool {
        guard isEditing else { return false }
        let centre = (viewport.startSample + viewport.endSample) / 2
        guard let target = Annotation.closest(to: centre, in: filteredAnnotations) else {
            return false
        }
        switch action {
        case .confirm:
            dispositionStore.confirm(target.id, kind: .unclassified)
        case .dismiss:
            dispositionStore.dismiss(target.id)
        case .reset:
            dispositionStore.reset(target.id)
        }
        return true
    }

    @ViewBuilder
    private var bedsideContent: some View {
        switch layoutMode {
        case .focus:
            if let channel = focusedChannel {
                focusModeLayout(channel: channel)
            } else {
                ContentUnavailableView(
                    "No lead selected",
                    systemImage: "waveform",
                    description: Text("Pick a lead from the bar above.")
                )
            }
        case .strips:
            // Strips mode is the ratified exception to the persistent-
            // stage rule (project_layout_persistent_stage.md,
            // 2026-07-05). The pin is a focus-mode ergonomic; strips
            // mode's ergonomic is multi-lead visual alignment across
            // the whole stack, which pinning would actively fight.
            // Fully-scrolling is the correct UX here. Don't retrofit
            // the pinned stage onto this branch.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // X83: the whole-record summary reads ABOVE the monitor
                    // in both layouts — first in the scroll here, above the
                    // pinned stage in focus mode.
                    VariabilityMetricsStrip()
                    contextBar
                    ForEach(ecgChannels) { channel in
                        ChannelPanel(
                            channel: channel,
                            directory: recordingDirectory,
                            viewport: viewport,
                            calibration: calibration,
                            annotations: annotationsForChannel(channel),
                            candidates: candidatesForChannel(channel),
                            sizing: .strip,
                            noteAuthoring: noteAuthoringHooks
                        )
                    }
                    contextLanes
                }
                .padding(16)
            }
        }
    }

    /// The scrolling context beneath the trace — the same lanes, in the same
    /// order, in BOTH layouts. Focus mode and strips mode have drifted apart
    /// before (X62 was filed because the order had to be corrected in two
    /// places); sharing one property makes divergence impossible rather than
    /// merely detectable.
    ///
    /// X62 ordered the whole-record summary BEFORE the rolling lanes; X83
    /// moves it further, ABOVE the monitor itself (each layout branch places
    /// it), so this property now starts at the trend stack. The reading
    /// order is unchanged — record's numbers first, then how they move.
    @ViewBuilder
    private var contextLanes: some View {
        beatSourceDisclosure
        trendStackHeader
        // X85: folded, the header bar is all that renders — same
        // whole-region collapse as the Context drawer.
        if trendStackExpanded {
            BedsideTrendStack(
                heartRateChannel: lowRatePartition.heartRate,
                qualityChannels: qualityChannels,
                directory: recordingDirectory,
                recordingRange: recordingTimeRange,
                viewportRange: viewportTimeRange,
                visibleLanes: visibleTrendLanes,
                // X89 — the delineator's beats; empty (no lane) in the free
                // viewer, same gate the interval lane inherits.
                beats: markingsContext.beats,
                beatSampleRate: markingsContext.sampleRate,
                onSeek: { seconds in
                    viewport.center(onSample: Int64(seconds * max(1, viewport.sampleRate)))
                },
                onZoomRange: { range in
                    // ⌥drag zoom (13a / #261): width first, then start —
                    // `setWidth` clamps to the viewport's own floor, and
                    // `setStart` re-clamps against the clamped width, so a
                    // sliver-sized sweep lands on the minimum window centered
                    // where the analyst swept rather than trapping or
                    // over-zooming. Same `setWidth` path as pinch and the
                    // zoom ladder, so it inherits their hold semantics.
                    let rate = max(1, viewport.sampleRate)
                    let width = (range.upperBound - range.lowerBound) * rate
                    guard width.isFinite, width < Double(Int64.max) else { return }
                    viewport.setWidth(Int64(width), anchorFraction: 0)
                    viewport.setStart(Int64(range.lowerBound * rate))
                },
                rmssdLane: rmssdLane,
                intervalLane: intervalLane,
                lfhfLane: lfhfLane
            )
        }
    }

    /// Stated once, where the beat-derived surfaces would have been (#206).
    ///
    /// One line rather than three: Variability Metrics, the Trend stack and
    /// Morphology are absent for a single reason, and repeating it at each
    /// hole would read as three faults instead of one property of the record.
    @ViewBuilder
    private var beatSourceDisclosure: some View {
        if let absence = recording.beatSourceAbsence() {
            BeatSourceDisclosure(
                absence: absence,
                siblingBeatFileName: BeatSourceDisclosure.siblingBeatFileName(
                    // `sourceFileName` is the `.hea` this record was imported
                    // from, so its stem is the WFDB record name every sibling
                    // shares — `418.hea` → `418` → `418.qrs`.
                    forRecordNamed: (recording.sourceFileName as NSString).deletingPathExtension,
                    in: recordingDirectory
                )
            )
        }
    }

    /// The rolling LF/HF lane (X76). Nil — no row at all — when the series is
    /// empty: not entitled, no recording, or a record shorter than one window.
    /// The free viewer never sees the surface of a measurement it doesn't own.
    private var lfhfLane: TrendStackLane? {
        guard !lfhfContext.samples.isEmpty else { return nil }
        return TrendStackLane(
            id: BedsideTrendStack.lfhfLaneID,
            title: "LF / HF",
            // Provenance travels with the number — estimator, window, step.
            subtitle: lfhfContext.caption ?? "rolling 5 min",
            value: lfhfValueAtViewportStart,
            unit: "ratio",
            height: 86,
            seekable: true,
            accent: TrendStackLane.lfhfAccent
        ) {
            LFHFLanePlot(
                samples: lfhfContext.samples,
                recordingRange: recordingTimeRange,
                stepSeconds: 60
            )
        }
    }

    /// The reading at the viewport's start — same "what is it HERE" contract
    /// as the HR and quality value columns.
    private var lfhfValueAtViewportStart: String? {
        guard viewport.sampleRate > 0 else { return nil }
        let t = Double(viewport.startSample) / viewport.sampleRate
        let sample = lfhfContext.samples.first {
            t >= $0.windowStartSeconds && t <= $0.windowEndSeconds
        }
        return sample.map { String(format: "%.2f", $0.value) }
    }

    /// The RMSSD lane as a stack row. The lane view keeps its own control
    /// chips and live-value caption — those belong to the lane, not to the
    /// container — so it supplies the whole plot cell rather than a bare plot.
    private var rmssdLane: TrendStackLane? {
        guard !laneContext.samples.isEmpty else { return nil }
        return TrendStackLane(
            id: "rmssd",
            title: laneContext.metricLabel,
            // The caption is the lane's own provenance (window length, step);
            // absent, name the unit rather than leaving the row unlabelled.
            subtitle: laneContext.windowCaption ?? laneContext.unit,
            value: laneContext.samples.last.map { String(format: "%.1f", $0.value) },
            unit: laneContext.unit,
            // Natural height: the cell carries the lane's own header, chips
            // and captions — a fixed row overflowed through the lanes beneath
            // the moment an entitled record populated it (X76 finding). The
            // 13a plot heights (86/104) are the RENDERERS' target (#261
            // phase 2), not this row's.
            height: nil,
            accent: TrendStackLane.variabilityAccent
        ) {
            variabilityLaneStrip
        }
    }

    private var intervalLane: TrendStackLane? {
        guard !markingsContext.beats.isEmpty else { return nil }
        return TrendStackLane(
            id: "interval-trend",
            title: "Interval trend",
            subtitle: "\(trendLaneContext.metric.displayName) · \(Int(trendLaneContext.binSeconds / 60)) min bins",
            value: nil,
            height: nil,   // natural — the cell carries chips, chart, captions
            accent: TrendStackLane.intervalAccent
        ) {
            intervalTrendLaneStrip
        }
    }

    /// The `Lanes` menu (X74). Sits above the stack rather than inside it,
    /// because it governs which rows exist and a control that can remove the
    /// container it lives in is a control that can hide itself.
    ///
    /// X85: the header row is also the stack's fold toggle, mirroring the
    /// Context bar — chevron, click-to-fold, whole-region collapse. Folded,
    /// the bar reports what's inside (the shown-lane count) and the Lanes
    /// menu hides: configuring rows that aren't rendered is a control that
    /// appears to do nothing.
    /// The lanes THIS record can offer. Shared by the header (which reports
    /// the shown count) and by `bedsideCommands`, which publishes them to the
    /// View ▸ Trend Lanes menu — one source, so the menu can never disagree
    /// with the stack about what exists.
    var availableTrendLanes: [(id: String, label: String)] {
        BedsideTrendStack.availableLanes(
            heartRate: lowRatePartition.heartRate,
            quality: qualityChannels,
            beatHR: !markingsContext.beats.isEmpty,
            rmssd: !laneContext.samples.isEmpty,
            interval: !markingsContext.beats.isEmpty,
            lfhf: !lfhfContext.samples.isEmpty
        )
    }

    /// Show or hide one lane. The View menu's action; also the single place
    /// the visibility set is mutated.
    func toggleTrendLane(_ id: String) {
        guard availableTrendLanes.contains(where: { $0.id == id }) else { return }
        if visibleTrendLanes.contains(id) {
            visibleTrendLanes.remove(id)
        } else {
            visibleTrendLanes.insert(id)
        }
    }

    @ViewBuilder
    private var trendStackHeader: some View {
        let available = availableTrendLanes
        if !available.isEmpty {
            let shown = available.count(where: { visibleTrendLanes.contains($0.id) })
            // #236: the lane picker used to live HERE, as a `Menu` beside the
            // fold chevron — which is why this was an HStack. That header is
            // the last thing in a long scrolling column, so on a short display
            // it lands at the bottom edge of the screen and the dropdown has
            // nowhere to open: observed rendering under the Variability
            // Metrics strip, with XCUI finding no menu items at all. Moving it
            // elsewhere in the window only relocates the edge.
            //
            // It now lives in the menu bar: View ▸ Trend Lanes, published
            // through `BedsideCommands`. The menu bar is the one surface that
            // is never near a screen edge, it is discoverable, and it keeps the
            // original principle intact — a control that governs which rows
            // exist should not sit among the rows.
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    trendStackExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: trendStackExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Trend stack")
                        .font(.subheadline.weight(.semibold))
                    Text(trendStackExpanded
                         ? "one axis · click the HR or quality lane to move the trace"
                         : "\(shown) lane\(shown == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Trend stack. \(shown) lane\(shown == 1 ? "" : "s")")
            .accessibilityIdentifier("trend-stack-bar")
        }
    }

    /// Persistent-stage focus-mode layout — the ECG trace + docked
    /// beat inspector pin at the top of the center column; the
    /// review-queue context (findings overview, variability/trend/
    /// alarm/quality lanes) scrolls beneath. The clinician's visual
    /// clues stay on screen while the surrounding context moves.
    /// See `project_layout_persistent_stage.md`.
    private func focusModeLayout(channel: Channel) -> some View {
        // ONE scroll for the centre column, stage included.
        //
        // The stage used to sit outside the scroll view, so its ~732 pt floor
        // was published straight up into the split view's minimum. Nothing
        // below could yield enough to cover that — the stage alone exceeded the
        // 720 pt window minimum — which is what made #202/#207 look like a
        // choice between compressing the trace and abandoning the persistent
        // stage. It was neither: a column that scrolls does not need its
        // content to fit, only to stop declaring a floor. Measured, the stage
        // reports 523 pt here instead of 732, and the trace is untouched.
        //
        // `minHeight: 0` is the load-bearing half, and it is the same lesson as
        // X97's `minWidth: 0` on the trend lane's plot cell, rotated: without
        // it a scroll view's minimum follows its content, and a ScrollView
        // whose minimum is its content height does not scroll — it relocates
        // the overflow to its parent.
        ScrollView {
            VStack(spacing: 0) {
                pinnedStage(channel: channel)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    contextBar
                    contextLanes
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 0)
        // X83: the whole-record summary reads ABOVE the monitor. As a top
        // safe-area inset, so it reads as chrome (like the chip bar) rather
        // than as the first row of the stage.
        //
        // Unconditionally now. X83 made this conditional on a 800 pt height,
        // because below that the column could not hold stage + strip and the
        // strip would have pushed the stage off-window — X82's whole-or-
        // nothing rule, applied vertically. That premise is gone: the column
        // scrolls, so nothing is pushed anywhere and a short window costs the
        // analyst a scroll rather than a surface.
        //
        // Worth recording that the rule was never observed working. It
        // compared `bedsideContentHeight` — which came from the layout it was
        // handed, i.e. the OVERSIZED 1104 — against 800, so it read "plenty of
        // room" at every window size including 720 and kept the strip up top
        // regardless. Fixing the overflow made it start firing, and the first
        // thing it did was move the strip below the trace, which is not where
        // this summary belongs.
        .safeAreaInset(edge: .top, spacing: 0) {
            VariabilityMetricsStrip()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.background)
                // As tall as the strip, never taller than the cap. Both
                // halves matter and both live in the modifier, where a
                // test measures the same construction the app renders —
                // see `MetricsStripInsetHeight` for why (#208).
                .modifier(MetricsStripInsetHeight())
        }
    }

    /// The pinned stage. Contains the ECG canvas, the docked caliper
    /// readout sitting beside it, and the one-map overview beneath.
    ///
    /// "Pinned" names its position in the column — first, above the context
    /// lanes — not an exemption from scrolling. It sits INSIDE
    /// `focusModeLayout`'s scroll view and scrolls with everything else; the
    /// claim that it never does has been wrong since 2dfdd5c (#202 / #207)
    /// put one scroll around the whole centre column. On a window too short
    /// to hold the stage whole, its lower band is below the viewport — by
    /// design, so the canvas can keep the height its mV graticule needs
    /// instead of squashing to fit.
    private func pinnedStage(channel: Channel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // X70: the two coarser bands read ABOVE the trace, so the stage
            // goes whole-record → hour → window top to bottom. The overview
            // used to sit beneath the canvas, which made the analyst read the
            // scales in the opposite order from the one they navigate in.
            bandLadder(channel: channel)

            HStack(alignment: .top, spacing: 12) {
                ChannelPanel(
                    channel: channel,
                    directory: recordingDirectory,
                    viewport: viewport,
                    calibration: calibration,
                    annotations: annotationsForChannel(channel),
                    candidates: candidatesForChannel(channel),
                    sizing: .focus,
                    overlayChannels: overlayChannels,
                    noteAuthoring: noteAuthoringHooks
                )
                // Tear down + rebuild when the focused lead changes —
                // WaveformCanvas's MTKView caches the previous channel's
                // sample buffer and the off-scale scanner is per-channel,
                // so reusing the same SwiftUI identity would leave the
                // viewer showing stale data after the chip-bar tap.
                //
                // Keyed on the PRIMARY only. Adding or removing an overlaid
                // lead must not rebuild the whole panel — the overlay canvases
                // carry their own identities, and rebuilding here would flash
                // the paper and re-run the off-scale scan on every ⌘-click.
                .id(channel.id)

                dockedBeatInspector
            }

        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.background)
        // `.contain` keeps child accessibility elements (channel-panel-<lead>,
        // docked-beat-inspector, overview-map) reachable — without it, the
        // parent's accessibilityIdentifier collapses the subtree to one leaf
        // and XCUI's `channel-panel-I` waits time out.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pinned-stage")
    }

    /// The two coarser bands of the stage's three-tier ladder: the whole
    /// record, then the enclosing hour. The trace beneath them is the third.
    ///
    /// Each band maps ITS OWN span across the same pixel width — they do not
    /// share a time domain, they share a geometry. That is what lets the window
    /// box mean the same thing in all three: *this slice of what you are
    /// looking at*. A shared domain would make the hour band a near-invisible
    /// sliver of the record band and answer nothing.
    ///
    /// The hour band renders only when the record is longer than an hour.
    /// Below that the record band already IS the hour, and two bands showing
    /// the same span with different boxes is a puzzle, not a ladder.
    @ViewBuilder
    private func bandLadder(channel: Channel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                bandLabel("Record", detail: RecordListEntry.duration(totalDurationSeconds))
                OverviewMap(
                    annotations: filteredAnnotations,
                    totalSamples: channel.sampleCount,
                    sampleRate: channel.sampleRate,
                    viewport: viewport,
                    channelName: channel.name,
                    dispositionsByID: dispositionStore.records,
                    candidates: candidatesForChannel(channel),
                    // X84: record-level notes have no anchor — drawing one
                    // at sample 0 would invent a location the note refuses
                    // to have.
                    noteAnchors: anchoredNotes.filter { !$0.isLocationless }.map {
                        $0.startSample...max($0.startSample, $0.endSample)
                    }
                )
            }
            if totalDurationSeconds > HourBand.defaultSpanSeconds {
                HStack(alignment: .center, spacing: 10) {
                    bandLabel("Hour", detail: "60 min")
                    HourBand(
                        channel: channel,
                        directory: recordingDirectory,
                        viewport: viewport
                    )
                }
            }
        }
    }

    private func bandLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 76, alignment: .leading)
    }

    /// Names the lead every number in this column was measured from.
    ///
    /// Shown ONLY while leads are overlaid. With one lead on the stage there
    /// is nothing to disambiguate and the note would be noise — but with two,
    /// a QT interval or a calibration reading sitting beside two traces says
    /// nothing about which trace produced it. The marks are drawn on the
    /// primary; so are these numbers; the analyst is told so.
    @ViewBuilder
    private var primaryLeadNote: some View {
        if !overlayChannels.isEmpty, let primary = focusedChannel {
            Text("Measured on \(primary.name)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Measured on \(primary.name)")
                .accessibilityIdentifier("primary-lead-note")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The focus-beat caliper docked beside the trace. Renders when
    /// a beat is focused; otherwise a placeholder holds the layout
    /// width so the trace doesn't reflow when focus changes.
    /// Underneath both variants: a compact "Layers" menu chip when
    /// the fiducial store has beats — lets the analyst show/hide
    /// P / QRS / T fiducials for QT vs. conduction studies.
    private var dockedBeatInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            primaryLeadNote
            calibrationControls
            CalibrationReadout(reading: calibrationReading)
            if !markingsContext.beats.isEmpty {
                fiducialSuppressionNote
            }
            // #246: the beat readout is ALWAYS mounted — focused, empty, or
            // beat-less record — one card, one size, values withheld as "—"
            // when there is nothing to measure. (X71 briefly made it
            // focus-only; the history of that reversal is on dockedBeatCard.)
            dockedBeatCard
            keyboardHint
        }
        .frame(width: BedsideGeometry.dockedColumnWidth, alignment: .topLeading)
    }

    /// The one-line keyboard hint, relocated from the retired `summaryHeader`
    /// (X69 moved everything else in that block to the info bar).
    ///
    /// Deliberately shorter than the original. That version listed six
    /// shortcuts across a full-width line; at 186 pt it would wrap to four
    /// lines of tertiary text sitting under the thing an analyst actually
    /// reads. The menu bar carries the full set with their key equivalents.
    private var keyboardHint: some View {
        Text("J / K next finding · ← → pan one window")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("stage-keyboard-hint")
    }

    /// X33: a VISIBLE, always-present readout of the current window against
    /// the whole recording ("6:52–7:02 of 30:05"). The beat card below is
    /// hover-driven and empty once the pointer leaves the trace; in a long
    /// record the analyst otherwise has no on-screen sense of where they are.
    /// The machine-format `ui-test-viewport-state` element stays the XCUI
    /// endpoint; this is the human-facing one.
    /// Current calibration in clinical units, derived from the focused
    /// panel's published geometry (X40 phase 1). Reports the ACTUAL on-screen
    /// scale — it does not yet impose one — so until Standard View lands it
    /// typically reads non-standard, which is the honest present state.
    private var calibrationReading: CalibrationReading {
        CalibrationReading.make(
            windowSeconds: viewport.durationSeconds,
            canvasWidthPoints: calibration.canvasSize.width,
            canvasHeightPoints: calibration.canvasSize.height,
            visibleMillivoltSpan: calibration.visibleMillivoltSpan,
            millimetersPerPoint: DisplayMetrics.millimetersPerPoint(),
            // X16: the readout's mm/mV maps TRUE millivolts — when the
            // focused lead is reinterpreted, the correction travels with
            // the claim.
            gainAnnotation: (focusedChannel?.appliedGainFactor).flatMap { factor in
                factor == 1 ? nil : String(format: "gain ×%g — analyst", factor)
            }
        )
    }

    /// The clinical preset ladder (X40 §5) + the inline Standard View
    /// affordance (§2's toolbar path). Gain and speed are the standard ECG
    /// idiom, not arbitrary numbers; gain buttons highlight the active preset.
    private var calibrationControls: some View {
        let activeGain = calibration.gainMillimetersPerMillivolt
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Gain").font(.caption2).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                ForEach([5.0, 10.0, 20.0], id: \.self) { value in
                    Button("\(Int(value))") { setGain(millimetersPerMillivolt: value) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(activeGain == value ? Color.accentColor : nil)
                        .accessibilityIdentifier("gain-\(Int(value))")
                }
                Text("mm/mV").font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                Text("Speed").font(.caption2).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                ForEach([25.0, 50.0], id: \.self) { value in
                    Button("\(Int(value))") { setSpeed(millimetersPerSecond: value) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .accessibilityIdentifier("speed-\(Int(value))")
                }
                Text("mm/s").font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Button {
                    applyStandardView()
                } label: {
                    Label("Standard View", systemImage: "ruler")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("standard-view-button")

                // Lock to standard (X40 §4): holds calibration across zoom
                // gestures — paging a long record on fixed paper. Pan stays
                // free; a pinch / ⌘-wheel / ± no-ops while engaged.
                Button {
                    calibration.locked.toggle()
                } label: {
                    Image(systemName: calibration.locked ? "lock.fill" : "lock.open")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(calibration.locked ? Color.accentColor : nil)
                .help(calibration.locked
                      ? "Calibration locked — zoom is held so the paper scale can't change while you page. Click to unlock."
                      : "Lock the calibration so zoom gestures don't change the paper scale while panning. Pan stays free.")
                .accessibilityIdentifier("calibration-lock-button")
                .accessibilityLabel(calibration.locked ? "Calibration locked" : "Calibration unlocked")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calibration-controls")
    }

    private var dockedBeatCard: some View {
        // #246: the card renders in EVERY state — focused, unfocused, even a
        // record with no beats — always the same slots, so it never pops in
        // or out and never changes height under the analyst's eye.
        //
        // This reverses X71's "no empty state". X71 was answering a layout
        // question (the placeholder's job was to hold the column's width, and
        // the fixed 186 pt frame made that moot) and concluded the card could
        // simply be absent. TestFlight said otherwise: to an analyst mid-read,
        // a card that vanishes when the pointer strays reads as breakage, and
        // one that holds still is scannable. The empty card is no longer
        // instructions-as-furniture; it is the same instrument showing "—".
        let focused = markingsContext.focusedBeatSampleIndex.flatMap { idx in
            markingsContext.beats.first(where: { $0.rPeakSampleIndex == idx })
        }
        return VStack(alignment: .leading, spacing: 4) {
            BeatCalipers(
                beat: focused,
                sampleRate: markingsContext.sampleRate,
                template: markingsContext.template,
                modes: markingsContext.modes,
                qtcFormula: markingsContext.qtcFormula,
                kind: focused.map { caliperKind(for: $0) } ?? .unknown,
                qtWithheldReason: markingsContext.qtWithheldReason,
                placeholderNote: markingsContext.beats.isEmpty
                    ? "No beats in this record"
                    : "Hover the trace to focus a beat"
            )
            pinFooter(showing: focused?.rPeakSampleIndex)
        }
        // `children: .contain` is load-bearing: without it the wrapper
        // collapses into one element and the footer's own identifier is
        // swallowed, so no test can ask whether the card says it's
        // pinned (X51 §4, same fault as the Layers chip's).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("docked-beat-inspector")
    }

    /// One line under the card saying whether what you are reading will still
    /// be there when you move the mouse (#225).
    ///
    /// The pin is otherwise invisible state: the card looks identical pinned
    /// and hovered, and the difference — does this survive the pointer
    /// leaving the trace — is the entire reason the pin exists. Naming it
    /// also carries the gesture, which nothing else on screen does.
    @ViewBuilder
    private func pinFooter(showing sample: Int64?) -> some View {
        // #246: both variants are ONE line so pinning and releasing cannot
        // change the card's height — the hint used to wrap freely.
        if let sample, markingsContext.pinnedBeatSampleIndex == sample {
            Button {
                markingsContext.clearPin()
            } label: {
                Label("Pinned — click to release", systemImage: "pin.fill")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("This beat stays on screen when the pointer leaves the trace. Escape also releases it.")
            .accessibilityIdentifier("beat-card-unpin")
        } else {
            Text("Click the beat to pin this open")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("A pinned beat stays on screen when the pointer leaves the trace.")
                .accessibilityIdentifier("beat-card-pin-hint")
        }
    }

    /// Menu chip that toggles P / QRS / T fiducial overlays. R marks
    /// are non-toggleable (they anchor every beat's identity).
    ///
    /// X61: the chip reports the CURRENT ZOOM'S render policy, not just the
    /// analyst's toggles. The overlay is gated twice — by the semantic zoom
    /// tier and by the viewport-keyed detail level — and until this landed
    /// the chip read `Layers · all` at the 4.5 s window Standard View opens
    /// on, while the renderer was dropping P and T. A control that claims a
    /// state the canvas is not honouring reads, correctly, as a control that
    /// does nothing. Both this and `FiducialOverlay` resolve the SAME
    /// `FiducialRenderPolicy`; the gates are unchanged, only their visibility.
    /// What is left in the window after #248 moved the chip's CONTROLS to
    /// View ▸ Fiducial Layers: one line, only when the zoom is actually
    /// holding a layer back.
    ///
    /// The feedback was "get rid of the Layers button", and the button is
    /// gone — this is not interactive and never appears when the canvas and
    /// the analyst's toggles agree. Keeping it is deliberate, and it is the
    /// half of X61 worth preserving.
    ///
    /// X61's finding was that a control claiming `Layers · all` while the
    /// renderer dropped P and T reads as a control that does nothing. But the
    /// deeper problem it fixed is the analyst's: at a 5 s window the marks
    /// simply are not there, and without something saying why, "this zoom is
    /// holding them back" is indistinguishable from "this record has no P
    /// waves". One is a display setting, the other is a finding. A tool that
    /// lets those two look identical is not safe to read from.
    ///
    /// Moving the whole chip into the menu bar would have lost that, because
    /// a menu only discloses when opened, and nobody opens a menu to explain
    /// an absence they have not noticed. So the CONTROL moves and the
    /// DISCLOSURE stays — and it stays quieter than the chip was, since it is
    /// absent entirely in the common case rather than dimmed.
    @ViewBuilder
    private var fiducialSuppressionNote: some View {
        let policy = markingsContext.renderPolicy
        let suppressed = policy.suppressedLayers(enabled: markingsContext.enabledLayers)
        if !suppressed.isEmpty {
            // Built as a String first: `Label`'s literal initialiser takes a
            // LocalizedStringKey, and concatenating one is a type error
            // rather than a formatting choice.
            let names = FiducialRenderPolicy.readoutOrdered(suppressed)
                .map(\.displayName)
                .joined(separator: "·")
            Label("\(names) hidden at this zoom", systemImage: "square.stack.3d.up.slash")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .help(policy.explanation(enabled: markingsContext.enabledLayers)
                  ?? "Zoom in to show these marks.")
            // `children: .ignore` BEFORE the label, and both are load-bearing
            // (X51 §4, the same class of fault the chip hit). A `Label` is a
            // group of icon + text, so the identified element is a CONTAINER:
            // its own label stays empty and `.accessibilityLabel` alone does
            // not reach it. Measured — with the identifier and label set but
            // no `.ignore`, the element exists and reads ''. Collapsing it to
            // one element makes the sentence the element's own.
            //
            // It is also what VoiceOver speaks, and "P·T hidden at this zoom"
            // is what an analyst needs to hear, not the glyph's name.
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("fiducial-suppression-note")
            .accessibilityLabel("\(names) hidden at this zoom")
        }
    }

    // (Removed by #248) `layersSummary` and `chipHelp`, the chip's own copy.
    // `FiducialRenderPolicy.summary(enabled:)` still exists and is still
    // unit-tested — it is the sentence X61 moved into the policy so it could
    // be tested at all, and it is the natural readout if a compact layers
    // status ever returns to the window. The chip's `.help()` string is gone
    // outright: `.help()` renders no tooltip on macOS 26 anyway, and the menu
    // carries the explanation as a real row now.

    private func toggleFiducialLayer(_ layer: MarkingsFiducialLayer) {
        if markingsContext.enabledLayers.contains(layer) {
            markingsContext.enabledLayers.remove(layer)
        } else {
            markingsContext.enabledLayers.insert(layer)
        }
    }

    /// Rolling HRV lane rendered directly beneath the ECG panels,
    /// sharing the exact same time axis via `viewport`. Hidden when
    /// no samples are available — the App-target orchestrator publishes
    /// the empty set when there's no entitlement, no recording, or too
    /// few beats. Feature scope + build order come from
    /// `project_variability_lane_design.md`.
    @ViewBuilder
    private var variabilityLaneStrip: some View {
        if !laneContext.samples.isEmpty {
            VariabilityLane(
                samples: laneContext.samples,
                // X74: the shared RECORD axis, not the viewport. This lane was
                // viewport-scoped, so it and the interval trend below it were
                // two different x-axes stacked vertically — alignment that
                // looked real and was not.
                timeRangeSeconds: recordingTimeRange,
                metricLabel: laneContext.metricLabel,
                unit: laneContext.unit,
                windowCaption: laneContext.windowCaption,
                // #209: the Trend stack's rail already prints both of these
                // (`title:` / `subtitle:` on the lane below) — the lane must
                // not say its own name a second time inside the plot.
                showsMetricLabel: false,
                // Read hover state so the lane highlights coordinate
                // with ECG-side hovers when that direction lands.
                externalHoverTimeSeconds: laneContext.hoveredSource == .ecg
                    ? laneContext.hoveredTimeSeconds
                    : nil,
                selectedPreset: laneContext.windowPreset,
                onLaneHover: { time in
                    laneContext.setHover(time: time, from: .lane)
                },
                onPickWindowPreset: { preset in
                    laneContext.windowPreset = preset
                }
            )
        }
    }

    /// Interval trend lane — third view of the fiducial store,
    /// trending an interval (default QTc/Fridericia, 2-min bins) over
    /// the whole recording. Design spec:
    /// `project_interval_trend_lanes_design.md`. Hidden when there are
    /// no beats in the fiducial store (no template + no data to bin).
    ///
    /// Wrapped in `IntervalTrendLaneMemoizedStrip` + `.equatable()` so
    /// SwiftUI skips the O(N_beats) `IntervalTrendComputer.compute`
    /// on every pan tick — the compute inputs don't depend on viewport
    /// (the lane spans the whole recording), so a viewport change is
    /// not a reason to rebuild the trend.
    @ViewBuilder
    private var intervalTrendLaneStrip: some View {
        if !markingsContext.beats.isEmpty {
            IntervalTrendLaneMemoizedStrip(
                beats: markingsContext.beats,
                template: markingsContext.template,
                sampleRate: markingsContext.sampleRate,
                metric: trendLaneContext.metric,
                binSeconds: trendLaneContext.binSeconds,
                templateBeatCount: markingsContext.template?.sampleCount,
                qtcFormulaName: markingsContext.qtcFormula.displayName,
                qtcFormula: markingsContext.qtcFormula,
                qualifiers: qualifyingContext.qualifiers(forBinSeconds: trendLaneContext.binSeconds),
                recordingTimeRange: recordingTimeRange,
                showMode: trendLaneContext.showMode,
                selectedBinPreset: trendLaneContext.binPreset,
                guides: trendGuideStore.guides(for: trendLaneContext.metric),
                events: trendLaneEvents,
                externalHoverTimeSeconds: laneContext.hoveredSource == .ecg
                    ? laneContext.hoveredTimeSeconds
                    : nil,
                rangeFindings: authoredRangeFindings,
                authoringEnabled: canAuthorFindings,
                onLaneHover: { time in
                    laneContext.setHover(time: time, from: .lane)
                },
                onBinClick: { time in
                    handleIntervalTrendBinClick(atTimeSeconds: time)
                },
                onPickMetric: { metric in
                    trendLaneContext.metric = metric
                },
                onPickBinPreset: { preset in
                    trendLaneContext.binPreset = preset
                },
                onPickShowMode: { mode in
                    trendLaneContext.showMode = mode
                },
                onPickFormula: { formula in
                    markingsContext.qtcFormula = formula
                },
                qtWithheldReason: markingsContext.qtWithheldReason,
                rrCVFlagPercent: trendLaneContext.rrCVFlagPercent,
                onPickRRCVFlag: { bound in
                    trendLaneContext.rrCVFlagPercent = bound
                },
                tOffsetGateEnabled: markingsContext.tOffsetExclusionEnabled,
                tOffsetGateScore: markingsContext.tOffsetExclusionScore,
                onSetTOffsetGate: { enabled, score in
                    markingsContext.tOffsetExclusionEnabled = enabled
                    markingsContext.tOffsetExclusionScore = score
                },
                onAddGuide: { valueMs, label in
                    trendGuideStore.add(
                        metric: trendLaneContext.metric,
                        valueMs: valueMs,
                        label: label
                    )
                },
                onRemoveGuide: { guideID in
                    trendGuideStore.remove(guideID)
                },
                onAuthorRange: { startSeconds, endSeconds, label, citation in
                    authorRangeFinding(
                        startSeconds: startSeconds,
                        endSeconds: endSeconds,
                        label: label,
                        citation: citation
                    )
                }
            )
            .equatable()
        }
    }

    /// Analyst-authored range findings, projected onto the trend lane's time
    /// axis. Sourced from the same `Annotation` store everything else reads, so
    /// they persist and also flow to the review queue + WFDB export.
    private var authoredRangeFindings: [IntervalTrendRangeFinding] {
        let sr = viewport.sampleRate
        guard sr > 0 else { return [] }
        return allAnnotations
            .filter { $0.kind == .range && $0.source == Annotation.analystAuthoredSource }
            .map { ann in
                IntervalTrendRangeFinding(
                    id: ann.id,
                    startSeconds: Double(ann.sampleIndex) / sr,
                    endSeconds: Double(ann.renderEndSample) / sr,
                    label: ann.displayLabel
                )
            }
    }

    /// Drag-to-author is live only when the analyst is editing AND owns the
    /// Annotation IAP — authoring is a paid mutation; viewing findings is free.
    private var canAuthorFindings: Bool {
        isEditing && PurchaseStore.shared.hasStudio
    }

    /// Creates + persists a range `Annotation` from a drag-to-author gesture.
    /// The lane composes the factual `label` (analyst-editable) and the
    /// immutable `citation`; this stamps the analyst-authored source so it's
    /// amber everywhere and exports to WFDB. Persistence mirrors
    /// `handleProducerOutput`. Not entitlement-gated itself — the gesture that
    /// calls it is (`canAuthorFindings`); a DEBUG test hook also drives it.
    @MainActor
    private func authorRangeFinding(startSeconds: Double, endSeconds: Double, label: String, citation: String) {
        let sr = viewport.sampleRate
        guard sr > 0, endSeconds > startSeconds else { return }
        let finding = Annotation(
            kind: .range,
            sampleIndex: Int64((startSeconds * sr).rounded()),
            endSampleIndex: Int64((endSeconds * sr).rounded()),
            category: "ANALYST_FINDING",
            label: label,
            source: Annotation.analystAuthoredSource,
            citationCaption: citation
        )
        attachedAnnotations.append(finding)
        do {
            try BundleAnnotationsFile.write(allAnnotations, to: recordingDirectory)
        } catch {
            attachError = "Finding was added for this session but could not be saved to the bundle: \(error.localizedDescription)"
        }
    }

    /// Whole-recording time range (seconds from recording start).
    /// The interval trend lane's default zoom is the whole recording,
    /// per the design spec ("the story is a slow drift, not a single
    /// beat"). The x-axis clips to this rather than the viewport so a
    /// zoomed-in analyst sees the full trend and where they are on it.
    private var recordingTimeRange: ClosedRange<Double> {
        let sr = viewport.sampleRate
        guard sr > 0, viewport.totalSamples > 0 else { return 0...1 }
        let end = Double(viewport.totalSamples) / sr
        return 0...max(0.001, end)
    }

    /// Derives interval-trend events from the recording's annotations.
    /// Any point annotation whose category matches an "event-worthy"
    /// token (WFDB comment `"`, or `comment` / `event` / `note` /
    /// `drug` / `dose` category) surfaces as a vertical marker on the
    /// trend axis. No app-asserted classification — this is a pure
    /// rendering rule over what the analyst / producer already wrote.
    private var trendLaneEvents: [IntervalTrendEvent] {
        guard let firstChannel = recording.channels.first,
              firstChannel.sampleRate > 0 else { return [] }
        let sr = firstChannel.sampleRate
        return allAnnotations.compactMap { ann in
            guard ann.kind == .point else { return nil }
            guard isEventCategory(ann.category) else { return nil }
            let trimmedNote = ann.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (trimmedNote?.isEmpty == false ? trimmedNote : nil)
                ?? ann.displayLabel
            return IntervalTrendEvent(
                id: ann.id,
                timeSeconds: Double(ann.sampleIndex) / sr,
                label: label
            )
        }
    }

    private func isEventCategory(_ category: String) -> Bool {
        let key = category.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "\"", "comment", "event", "note", "drug", "dose", "drug_admin":
            return true
        default:
            return false
        }
    }

    /// Click-through from the trend lane back to a specific beat. Finds the
    /// beat closest to the clicked bin centre and jumps to it — literally the
    /// same call the deviation shortcuts make, which is what the old comment
    /// here claimed ("same drilldown mechanism") without it being true.
    ///
    /// It used to post a jump request that nothing consumed, so the beat was
    /// pinned and the viewport never moved: a click on a bin quietly did half
    /// its job.
    private func handleIntervalTrendBinClick(atTimeSeconds seconds: Double) {
        guard markingsContext.sampleRate > 0 else { return }
        let sampleIndex = Int64(seconds * markingsContext.sampleRate)
        if let beat = markingsContext.nearestBeat(toSampleIndex: sampleIndex) {
            jumpViewport(toBeat: beat.rPeakSampleIndex)
        }
    }

    /// Viewport time range in absolute seconds — passed to the
    /// variability lane so its x-axis stays locked to the ECG canvas.
    private var viewportTimeRange: ClosedRange<Double> {
        let sr = viewport.sampleRate
        guard sr > 0 else { return 0...1 }
        let start = Double(viewport.startSample) / sr
        let end = Double(viewport.endSample) / sr
        return start...max(start + 0.001, end)
    }

    // trendStrip / qualityStrip retired with X74: both viewport-scoped
    // strips were replaced by the shared-axis whole-record lanes in
    // `BedsideTrendStack` (see `contextLanes`).

    // findingsOverview retired 2026-07-05: category-filter + tally
    // functionality is now consolidated in the review-queue rail's
    // triage tally + category menu (project_findings_review_queue_design).
    // Removing the redundant chip row from the scrolling context also
    // eliminates the CI-window-height flake where the chip landed
    // below the visible fold and XCUI reported "not hittable".

    // MARK: - Context bar (X69)

    /// The collapsible Context region, replacing `summaryHeader`.
    ///
    /// `summaryHeader` carried three things and X69 rehomed all of them: the
    /// record name and its metadata line moved to the info bar (which is what
    /// the design's Region 5 exists for), the keyboard hint goes to the stage's
    /// right column in X71, and the `RecordContextPanel` — which had no home
    /// of its own and merely sat beside the summary — becomes this.
    ///
    /// Collapsed by default, matching the canonical `11a`. Expanded, it
    /// mounts the two-column `ContextDrawer` (X72) — which absorbed the old
    /// `RecordContextPanel`'s notes.md editing wholesale.
    @ViewBuilder
    private var contextBar: some View {
        if !recording.headerComments.isEmpty || recording.notesFileName != nil
            || morphologyContext.summary != nil {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        notesDrawerExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: contextDrawerIsOpen ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Context")
                            .font(.caption.weight(.semibold))
                        Text(contextBarDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Context. \(contextBarDetail)")
                .accessibilityIdentifier("context-bar")

                if contextDrawerIsOpen {
                    ContextDrawer(
                        headerComments: recording.headerComments,
                        notesURL: recording.notesFileName.map {
                            recordingDirectory.appendingPathComponent($0)
                        },
                        notes: $anchoredNotes,
                        selection: $drawerSelection,
                        isEditing: isEditing,
                        editorFocus: $notesEditorFocused,
                        sampleRate: viewport.sampleRate,
                        hasAbsoluteStartTime: recording.hasAbsoluteStartTime,
                        startUnixMillis: recordingStartUnixMillis,
                        currentWindow: viewport.startSample...max(viewport.startSample, viewport.endSample),
                        currentLeadName: focusedChannel?.name,
                        savedNotes: CurrentRecordingContext.shared.sessionSavedNotes,
                        morphologySummary: morphologyContext.summary,
                        morphologyEndorsements: $morphologyEndorsements,
                        onJump: { note in jumpToNoteAnchor(note) }
                    )
                    // AX2: contain the drawer's children so it stops collapsing
                    // to a single element; this also surfaces the `.hea`
                    // demographics + notes to VoiceOver as readable content.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("context-panel")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the collapsed bar says is inside.
    ///
    /// Deliberately NOT the design's `last edited 2 min ago`: an edit
    /// timestamp for notes.md would mean reading the file here purely to
    /// describe it, duplicating the drawer's own I/O. The bar reports what
    /// this view actually knows: the document's existence, the anchored-note
    /// count, and the `.hea` lines.
    private var contextBarDetail: String {
        var parts: [String] = []
        if recording.notesFileName != nil { parts.append("notes.md") }
        if !anchoredNotes.isEmpty {
            parts.append("\(anchoredNotes.count) entr\(anchoredNotes.count == 1 ? "y" : "ies")")
        }
        let comments = recording.headerComments.count
        if comments > 0 {
            parts.append("\(comments) line\(comments == 1 ? "" : "s") from .hea")
        }
        if let morphology = morphologyContext.summary {
            let clusters = morphology.cards.count
            parts.append("\(clusters) morphology cluster\(clusters == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Anchored notes (X72)

    /// Move the trace to a note's anchor. Honours the 10 s pin the same way
    /// finding jumps do: pinned, the window stays 10 s and centres on the
    /// anchor; unpinned, the viewport becomes the anchor range itself.
    // MARK: - Right-click authoring (X84)

    /// The hooks the trace's context menu calls back through. Notes append to
    /// the same collection the drawer edits; findings go through the same
    /// store + persistence as drag-to-author. The menu is the second way in;
    /// the drawer's own buttons stay.
    /// X109: the in-flight manual QT caliper — Q onset placed, T offset
    /// pending. Cleared on completion, cancellation, or recording swap.
    @State private var pendingQTCaliperStart: (sample: Int64, leadName: String?)?

    // X16: the channel whose gain-reinterpretation sheet is open.
    @State private var gainSheetChannel: Channel?

    /// X16: persist the analyst's factor to the bundle manifest and hand the
    /// updated recording to the owner. `nil` clears the correction. Failures
    /// surface in the attach-error alert path — same class of bundle-write
    /// failure, same disclosure.
    private func applyGainInterpretation(channel: Channel, factor: Double?) {
        gainSheetChannel = nil
        var updated = channel
        updated.analystGainFactor = factor
        let mutated = recording.replacingChannel(updated)
        do {
            try RecordingStore.shared.writeManifest(mutated, at: recordingDirectory)
            onRecordingMutated?(mutated)
        } catch {
            attachError = "The gain interpretation could not be saved to the bundle: \(error.localizedDescription)"
        }
    }

    private var noteAuthoringHooks: NoteAuthoringHooks {
        NoteAuthoringHooks(
            isEditing: isEditing,
            canAuthorFindings: canAuthorFindings,
            addNote: { sample in addAnchoredNote(atSample: sample) },
            addRecordNote: { addRecordNote() },
            addFinding: { sample in markFinding(atSample: sample) },
            timeLabel: { sample in noteTimeLabel(sample) },
            qtCaliperPendingLabel: pendingQTCaliperStart.map { noteTimeLabel($0.sample) },
            beginQTCaliper: { sample in
                pendingQTCaliperStart = (sample, focusedChannel?.name)
            },
            completeQTCaliper: { sample in completeQTCalipers(atSample: sample) },
            cancelQTCaliper: { pendingQTCaliperStart = nil },
            interpretGain: { channel in gainSheetChannel = channel }
        )
    }

    /// X109 (§2.4): complete the two-click manual QT measurement. The result
    /// is an analyst-authored RANGE annotation with the span's milliseconds
    /// in its label — provenance is structurally distinct from every
    /// automated measurement (source, category, citation all say
    /// analyst-placed), so downstream layers can never confuse the two. It
    /// deliberately does NOT feed the QTc trend, the template, or any
    /// automated surface.
    private func completeQTCalipers(atSample sample: Int64) {
        guard let pending = pendingQTCaliperStart else { return }
        defer { pendingQTCaliperStart = nil }
        let sr = viewport.sampleRate
        guard sr > 0, sample != pending.sample else { return }
        let start = min(pending.sample, sample)
        let end = max(pending.sample, sample)
        let ms = Double(end - start) / sr * 1000.0
        let lead = pending.leadName ?? focusedChannel?.name
        let caliper = Annotation(
            kind: .range,
            sampleIndex: start,
            endSampleIndex: end,
            category: "QT-MANUAL",
            label: String(format: "QT %.0f ms — analyst-placed", ms),
            source: Annotation.analystAuthoredSource,
            lead: lead,
            citationCaption: String(
                format: "Manual QT calipers: Q onset to T offset placed by the analyst on %@ — %.0f ms. Not an automated measurement.",
                lead ?? "the ECG", ms)
        )
        attachedAnnotations.append(caliper)
        do {
            try BundleAnnotationsFile.write(allAnnotations, to: recordingDirectory)
        } catch {
            attachError = "The caliper measurement was added for this session "
                + "but could not be saved to the bundle: \(error.localizedDescription)"
        }
    }

    private func noteTimeLabel(_ sample: Int64) -> String {
        let sr = viewport.sampleRate
        guard sr > 0 else { return "—" }
        let mode = timeDisplay.effectiveMode(hasAbsoluteStart: recording.hasAbsoluteStartTime)
        return ViewportTimeFormat.coordinate(
            Double(sample) / sr, mode: mode, startUnixMillis: recordingStartUnixMillis
        )
    }

    /// A location-marked note anchored to the clicked INSTANT (start ==
    /// end). The drawer's own button still anchors to the current window —
    /// the two entries answer different questions ("this beat" vs "this
    /// stretch I'm looking at").
    private func addAnchoredNote(atSample sample: Int64) {
        let now = Date()
        let note = AnchoredNote(
            startSample: sample,
            endSample: sample,
            leadName: focusedChannel?.name,
            createdAt: now,
            modifiedAt: now
        )
        anchoredNotes.append(note)
        openDrawer(selecting: note)
    }

    /// The location-less kind (X84): record-level, no anchor, no marker.
    private func addRecordNote() {
        let now = Date()
        let note = AnchoredNote(
            startSample: 0,
            endSample: 0,
            createdAt: now,
            modifiedAt: now,
            isRecordLevel: true
        )
        anchoredNotes.append(note)
        openDrawer(selecting: note)
    }

    /// Creation without a visible editor is a note the analyst can't type
    /// into — every entry point opens the drawer on the fresh note.
    private func openDrawer(selecting note: AnchoredNote) {
        drawerSelection = .note(note.id)
        withAnimation(.snappy(duration: 0.18)) { notesDrawerExpanded = true }
    }

    /// A point finding at the clicked sample — the point-kind sibling of
    /// `authorRangeFinding`, with the same source stamp, persistence, and
    /// review-queue/WFDB behaviour.
    private func markFinding(atSample sample: Int64) {
        let finding = Annotation(
            kind: .point,
            sampleIndex: sample,
            category: "ANALYST_FINDING",
            label: "Analyst mark",
            source: Annotation.analystAuthoredSource,
            lead: focusedChannel?.name,
            citationCaption: "Marked by the analyst on the \(focusedChannel?.name ?? "ECG") trace"
        )
        attachedAnnotations.append(finding)
        do {
            try BundleAnnotationsFile.write(allAnnotations, to: recordingDirectory)
        } catch {
            attachError = "Finding was added for this session but could not be saved to the bundle: \(error.localizedDescription)"
        }
    }

    private func jumpToNoteAnchor(_ note: AnchoredNote) {
        // X84: a record-level note has no anchor; there is nothing to jump to.
        guard !note.isLocationless else { return }
        if windowLockedTo10s {
            viewport.center(onSample: (note.startSample + note.endSample) / 2)
        } else {
            let width = max(note.endSample - note.startSample, Int64(viewport.sampleRate))
            viewport.setWidth(width, anchorFraction: 0)
            viewport.setStart(note.startSample)
        }
    }

    /// ⌥J/⌥K — step through the notes in anchor order, opening the drawer so
    /// the analyst can see which note they landed on. Record-level notes are
    /// not part of the walk: the walk IS a tour of anchors (X84), and
    /// `jumpToNoteAnchor` would silently no-op on them anyway.
    private func stepNote(by delta: Int) {
        let ordered = anchoredNotes.filter { !$0.isLocationless }
            .sorted { $0.startSample < $1.startSample }
        guard let next = ContextDrawer.stepped(notes: ordered, selection: drawerSelection, by: delta) else { return }
        drawerSelection = .note(next.id)
        notesDrawerExpanded = true
        jumpToNoteAnchor(next)
    }

    // MARK: - Info bar (X69)

    /// The window's bottom rail: what this record IS on the left, what the
    /// trace is DOING on the right.
    ///
    /// Region 5 describes this as replacing "the metadata that used to sit in
    /// the title". It did not sit in the title — `navigationTitle` has been the
    /// bare record name since X56, and the metadata was `summaryDetail`, inside
    /// the scrolling context column where it left the screen the moment an
    /// analyst scrolled to a lane. That is the actual defect this fixes.
    private var infoBar: some View {
        HStack(spacing: 10) {
            Text(recording.device)
                .fontWeight(.medium)
            Text(recordFacts)
            if let start = absoluteStartLabel {
                Text(start)
            }
            Spacer(minLength: 12)
            Text(windowRangeLabel)
            // The tier stands alone when there is no points-per-beat reading.
            // With no beats in the window the selector reports NaN — which is
            // an absence, not a number — and the tier is still meaningful,
            // because it is what the renderer is acting on either way.
            if let tier = renderState.zoomTier {
                Text(Self.zoomTierLabel(tier, pointsPerBeat: renderState.pointsPerBeat))
            }
            if let lod = renderState.lod {
                Text("LOD \(lod.label)")
            }
            if !anchoredNotes.isEmpty {
                Text("\(anchoredNotes.count) note\(anchoredNotes.count == 1 ? "" : "s")")
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("info-bar")
    }

    /// `12 leads · 250 Hz · 72.4 h · 65.1 M samples/lead`.
    ///
    /// Counts ECG leads, not channels: a record carrying an HR trend and a
    /// quality ratio would otherwise claim two more leads than it has, and
    /// "leads" is the word the analyst reads it as.
    private var recordFacts: String {
        let leads = ecgChannels.count
        var parts = ["\(leads) lead\(leads == 1 ? "" : "s")"]
        if let primary = ecgChannels.first ?? recording.channels.first {
            if primary.sampleRate > 0 {
                parts.append("\(Int(primary.sampleRate.rounded())) Hz")
            }
            parts.append(RecordListEntry.duration(totalDurationSeconds))
            parts.append("\(Self.compactCount(primary.sampleCount)) samples/lead")
        }
        return parts.joined(separator: " · ")
    }

    /// The record's real start instant, or nothing.
    ///
    /// X32: a WFDB record without a base date/time has no start instant, and
    /// the honest rendering is silence. The retired `summaryDetail` said "no
    /// absolute start time" out loud, which spent a field on an absence.
    private var absoluteStartLabel: String? {
        guard recording.hasAbsoluteStartTime,
              let start = recording.channels.first?.startDate else { return nil }
        return "starts \(start.formatted(date: .numeric, time: .standard))"
    }

    /// `zoom tier inspect · 78 pt/beat`, or just `zoom tier inspect` when the
    /// window holds no beats to measure against.
    static func zoomTierLabel(_ tier: WaveformZoomTier, pointsPerBeat: Double?) -> String {
        guard let ppb = pointsPerBeat, ppb.isFinite else {
            return "zoom tier \(tier.rawValue)"
        }
        return "zoom tier \(tier.rawValue) · \(Int(ppb.rounded())) pt/beat"
    }

    /// The current window, in whichever time base the analyst has chosen.
    ///
    /// X71 routed this through `ViewportTimeFormat.coordinate` rather than
    /// formatting elapsed seconds directly. The retired `viewportIndicator`
    /// was the only surface honouring X28's elapsed / wall-clock switch, and
    /// folding it into the info bar without carrying that through would have
    /// quietly removed wall-clock from the app. `coordinate` falls back to
    /// elapsed when the record has no real time base, so no synthesised clock
    /// can reach the screen (X32).
    private var windowRangeLabel: String {
        let sr = viewport.sampleRate > 0 ? viewport.sampleRate : 250
        let mode = timeDisplay.effectiveMode(hasAbsoluteStart: recording.hasAbsoluteStartTime)
        let base = recordingStartUnixMillis
        let start = ViewportTimeFormat.coordinate(
            Double(viewport.startSample) / sr, mode: mode, startUnixMillis: base
        )
        let end = ViewportTimeFormat.coordinate(
            Double(viewport.endSample) / sr, mode: mode, startUnixMillis: base
        )
        // The TOTAL stays elapsed in both modes: it is a DURATION, not an
        // instant. A time of day there would be a category error.
        let total = ViewportTimeFormat.elapsed(Double(viewport.totalSamples) / sr, tenths: false)
        return "window \(start)–\(end) of \(total)"
    }

    private var totalDurationSeconds: Double {
        recording.channels.first?.durationSeconds ?? 0
    }

    /// `65.1 M`, `32 k`, `840`. The info bar has one line for the whole
    /// record's facts; a raw 65,100,000 spends a third of it on digits.
    static func compactCount(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1_000_000 { return String(format: "%.1f M", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1f k", v / 1_000) }
        return "\(value)"
    }

    /// `21:40:19.0` — tenths, because at the 2 s zoom step a whole-second
    /// readout would not change as the analyst pans.
    static func preciseClock(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let secs = clamped - Double(hours * 3600 + minutes * 60)
        if hours > 0 {
            return String(format: "%d:%02d:%04.1f", hours, minutes, secs)
        }
        return String(format: "%d:%04.1f", minutes, secs)
    }
}
