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

    @State private var viewport: RecordingViewport
    /// Shared amplitude/timebase calibration (X40). Gain is shared across
    /// leads by clinical convention, so it lives once here and threads into
    /// every ChannelPanel, exactly like `viewport`.
    @State private var calibration = Calibration()
    @State private var filter = FindingFilter()
    @State private var showFindings = true
    /// When on, the viewport is held at a 10-second window and finding /
    /// candidate jumps recenter without changing zoom — for analysts who
    /// read in fixed time windows. A manual zoom breaks the lock.
    @State private var windowLockedTo10s = false
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
    /// Findings the analyst attached after import (via the "Attach
    /// findings…" toolbar action). Merged with `recording.annotations`
    /// for display. In-memory only for now; a future pass persists them
    /// to the bundle's `annotations.json` so they survive across launches.
    @State private var attachedAnnotations: [Annotation] = []
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

    static let initialDurationSeconds: Double = 10

    init(recording: Recording, recordingDirectory: URL) {
        self.recording = recording
        self.recordingDirectory = recordingDirectory
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
        _layoutMode = State(initialValue: firstECG.map { .focus($0.id) } ?? .strips)
        _dispositionStore = State(initialValue: DispositionStore(bundleDirectory: recordingDirectory))
        _candidateDispositionStore = State(initialValue: VTVFCandidateDispositionStore(bundleDirectory: recordingDirectory))
        _trendGuideStore = State(initialValue: IntervalTrendGuideStore(bundleDirectory: recordingDirectory))
    }

    /// ECG / pressure channels — rendered on the Metal canvas.
    private var ecgChannels: [Channel] {
        recording.channels.filter { !$0.isTrendChannel }
    }

    /// Low-rate channels split by intent. Alarms and state probabilities
    /// get their own dedicated strips; everything else (continuous-valued
    /// vital trends) goes through the sparkline strip.
    private var lowRatePartition: LowRatePartition {
        LowRatePartition(channels: recording.channels.filter(\.isTrendChannel))
    }

    /// Pure-numeric vital trends (HR, SpO₂, etCO₂, BPM, tidal volume…)
    /// rendered as sparklines in `ChannelTrendStrip`.
    private var vitalTrendChannels: [Channel] { lowRatePartition.trends }

    /// Boolean-valued alarm / status channels rendered in `AlarmStrip`.
    private var alarmChannels: [Channel] { lowRatePartition.alarms }

    /// Continuous quality / artifact-ratio channels rendered in `QualityStrip`.
    private var qualityChannels: [Channel] { lowRatePartition.quality }

    /// The matched `prob_state_*` channel pair for `StateBackdropStrip`.
    /// Either side may be nil — the strip still renders with whatever's
    /// present and falls silent only if both are missing.
    private var stateChannels: (spontaneous: Channel?, assist: Channel?) {
        (lowRatePartition.spontaneous, lowRatePartition.assistControl)
    }

    /// Union of the producer's findings and anything the analyst has
    /// attached via the "Attach findings…" toolbar action. Every downstream
    /// surface — canvas overlays, findings panel, density timeline, summary
    /// chips — reads from this so attached findings are first-class.
    private var allAnnotations: [Annotation] {
        recording.annotations + attachedAnnotations
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
        scanContext.candidates.filter { $0.matchesChannel(channel.name) }
    }

    private var focusedChannel: Channel? {
        guard case .focus(let id) = layoutMode else { return nil }
        return ecgChannels.first { $0.id == id }
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
            textEntryActive: notesEditorFocused,
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
    @ToolbarContentBuilder
    private var windowLockToolbarItem: some ToolbarContent {
        ToolbarItem {
            Button {
                toggleWindowLock()
            } label: {
                Label("10 s window", systemImage: windowLockedTo10s ? "lock.fill" : "lock.open")
            }
            .help(windowLockedTo10s
                  ? "Locked to a 10-second window. Jumps recenter without changing zoom. Click (or zoom) to unlock."
                  : "Lock the trace to a 10-second window so jumps keep your time frame.")
            .tint(windowLockedTo10s ? Color.accentColor : nil)
            .accessibilityIdentifier("window-lock-toggle")
        }
    }

    @ToolbarContentBuilder
    private var scanToolbarItem: some ToolbarContent {
        if scanContext.isScanAvailable {
            ToolbarItem {
                Button {
                    scanContext.requestScanDialog(
                        viewStartSample: viewport.startSample,
                        viewEndSample: viewport.endSample
                    )
                } label: {
                    Label("Scan for VT/VF candidates", systemImage: "waveform.badge.magnifyingglass")
                }
                .help("Scan this recording for candidate VT/VF episodes (research use only)")
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
            candidateProvenance: scanContext.candidateProvenance
        )
        .inspectorColumnWidth(min: 260, ideal: 340, max: 500)
    }

    var body: some View {
        VStack(spacing: 0) {
            LeadChipBar(
                channels: ecgChannels,
                layoutMode: $layoutMode
            )
            Divider()
            bedsideContent
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
        .inspector(isPresented: $showFindings) {
            findingsInspector
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isEditing.toggle()
                } label: {
                    Label(
                        isEditing ? "Editing" : "Locked",
                        systemImage: isEditing ? "lock.open.fill" : "lock.fill"
                    )
                }
                .help(isEditing
                      ? "Editing on — notes and annotations are editable. Click to lock."
                      : "Read-only. Click to unlock and edit notes and annotations.")
                .tint(isEditing ? Color.accentColor : nil)
                .accessibilityIdentifier("edit-mode-toggle")
            }
            ToolbarItem {
                Button {
                    showAttachFindings = true
                } label: {
                    Label("Attach findings…", systemImage: "doc.badge.plus")
                }
                .help("Merge a producer's annotations JSON into this recording")
                .accessibilityIdentifier("attach-findings")
            }
            scanToolbarItem
            ToolbarItem {
                Button { exportMarkdownReport() } label: {
                    Label("Export report…", systemImage: "square.and.arrow.up")
                }
                .help("Save a markdown report of this recording's findings and dispositions")
                .accessibilityIdentifier("export-report")
            }
            ToolbarItem {
                Button { exportSnapshotPNG() } label: {
                    Label("Export snapshot…", systemImage: "camera")
                }
                .help("Save a PNG snapshot of the current bedside view")
                .accessibilityIdentifier("export-snapshot")
            }
            ToolbarItem {
                Button { exportWFDBAnnotations() } label: {
                    Label("Export WFDB annotations…", systemImage: "doc.badge.arrow.up")
                }
                .help("Write your confirmed findings as a WFDB annotation file (\(wfdbRecordBase).\(WFDBAnnotationWriter.defaultAnnotator)) beside the recording, to hand to a peer")
                .disabled(amberFindingCount == 0)
                .accessibilityIdentifier("export-wfdb")
            }
            #if DEBUG
            ToolbarItem {
                Button {
                    showProducersPanel = true
                } label: {
                    Label("Producers", systemImage: "wand.and.stars")
                }
                .help("Run a registered FindingProducer over this recording")
                .accessibilityIdentifier("producers-toggle")
            }
            #endif
            windowLockToolbarItem
            ToolbarItem {
                Button {
                    showFindings.toggle()
                } label: {
                    Label("Findings", systemImage: "stethoscope.circle")
                }
                .help("Show or hide the findings panel")
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
            applyOpenCalibrationIfNeeded()
        }
        #if DEBUG
        .task { applyUITestHooks() }
        #endif
    }

    /// X50: snap a freshly opened raw record onto standard ECG paper the first
    /// time the focused panel reports a real canvas size. `applyStandardView()`
    /// needs `calibration.canvasSize` (published post-layout), so this can't
    /// run in `init`. Runs exactly once, and only while gain is still unset, so
    /// a restored `.mur` session (X14) keeps its own paper and the analyst's
    /// subsequent manual changes are never clobbered.
    private func applyOpenCalibrationIfNeeded() {
        guard !hasAppliedOpenCalibration,
              calibration.canvasSize.width > 0,
              calibration.gainMillimetersPerMillivolt == nil else { return }
        #if DEBUG
        // Under XCUI the snapped width is display-size dependent, which would
        // make every bare `--ui-test-sample` test's open geometry vary by
        // machine. Keep the legacy open width in tests unless a test explicitly
        // opts in (the dedicated X50 wire-up guard does). Non-test launches
        // always snap.
        if UITestSupport.isRunningUITest && !UITestSupport.standardOpenEnabled {
            hasAppliedOpenCalibration = true
            return
        }
        #endif
        hasAppliedOpenCalibration = true
        applyStandardView(anchorFraction: 0)   // open at t = 0, not centred
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
        let template = MarkingsTemplate(
            sampleCount: 30,
            medianPRMs: 150, iqrPRMs: 8,
            medianQRSMs: 90, iqrQRSMs: 6,
            medianQTMs: qtcMs * 0.9, iqrQTMs: 10,
            qtcFormulaName: markingsContext.qtcFormula.displayName,
            medianQTcMs: qtcMs, iqrQTcMs: 10
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
                    attachError = "Findings were attached for this session but could not be saved to the bundle: \(error.localizedDescription)"
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

    private func jumpViewport(toBeat sample: Int64) {
        let total = max(1, viewport.totalSamples)
        viewport.animateJump(toFraction: Double(sample) / Double(total), duration: 0.18)
        markingsContext.focus(beatSampleIndex: sample)
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
                    summaryHeader
                    ForEach(ecgChannels) { channel in
                        ChannelPanel(
                            channel: channel,
                            directory: recordingDirectory,
                            viewport: viewport,
                            calibration: calibration,
                            annotations: annotationsForChannel(channel),
                            candidates: candidatesForChannel(channel),
                            sizing: .strip
                        )
                    }
                    variabilityLaneStrip
                    intervalTrendLaneStrip
                    trendStrip
                    alarmStrip
                    stateStrip
                    qualityStrip
                }
                .padding(16)
            }
        }
    }

    /// Persistent-stage focus-mode layout — the ECG trace + docked
    /// beat inspector pin at the top of the center column; the
    /// review-queue context (findings overview, variability/trend/
    /// alarm/quality lanes) scrolls beneath. The clinician's visual
    /// clues stay on screen while the surrounding context moves.
    /// See `project_layout_persistent_stage.md`.
    private func focusModeLayout(channel: Channel) -> some View {
        VStack(spacing: 0) {
            pinnedStage(channel: channel)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryHeader
                    variabilityLaneStrip
                    intervalTrendLaneStrip
                    trendStrip
                    alarmStrip
                    stateStrip
                    qualityStrip
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The pinned stage. Contains the ECG canvas, the docked caliper
    /// readout sitting beside it, and the one-map overview beneath.
    /// Never scrolls; the analyst's primary reading surface stays put
    /// while the scrolling context under it moves.
    private func pinnedStage(channel: Channel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ChannelPanel(
                    channel: channel,
                    directory: recordingDirectory,
                    viewport: viewport,
                    calibration: calibration,
                    annotations: annotationsForChannel(channel),
                    candidates: candidatesForChannel(channel),
                    sizing: .focus
                )
                // Tear down + rebuild when the focused lead changes —
                // WaveformCanvas's MTKView caches the previous channel's
                // sample buffer and the off-scale scanner is per-channel,
                // so reusing the same SwiftUI identity would leave the
                // viewer showing stale data after the chip-bar tap.
                .id(channel.id)

                dockedBeatInspector
            }

            OverviewMap(
                annotations: filteredAnnotations,
                totalSamples: channel.sampleCount,
                sampleRate: channel.sampleRate,
                viewport: viewport,
                channelName: channel.name,
                dispositionsByID: dispositionStore.records,
                candidates: candidatesForChannel(channel)
            )
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

    /// The focus-beat caliper docked beside the trace. Renders when
    /// a beat is focused; otherwise a placeholder holds the layout
    /// width so the trace doesn't reflow when focus changes.
    /// Underneath both variants: a compact "Layers" menu chip when
    /// the fiducial store has beats — lets the analyst show/hide
    /// P / QRS / T fiducials for QT vs. conduction studies.
    private var dockedBeatInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            viewportIndicator
            CalibrationReadout(reading: calibrationReading)
            calibrationControls
            dockedBeatCard
            if !markingsContext.beats.isEmpty {
                fiducialLayersChip
            }
        }
        .frame(width: 220, alignment: .topLeading)
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
            millimetersPerPoint: DisplayMetrics.millimetersPerPoint()
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

    private var viewportIndicator: some View {
        let sr = viewport.sampleRate > 0 ? viewport.sampleRate : 250
        // X49: one shared m:ss.d formatter across all three viewport renderers.
        let start = ViewportTimeFormat.elapsed(Double(viewport.startSample) / sr)
        let end = ViewportTimeFormat.elapsed(Double(viewport.endSample) / sr)
        let total = ViewportTimeFormat.elapsed(Double(viewport.totalSamples) / sr, tenths: false)
        return HStack(spacing: 4) {
            Image(systemName: "scope")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("\(start)–\(end)")
                .font(.caption.monospacedDigit().weight(.semibold))
            Text("of \(total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("viewport-indicator")
    }

    @ViewBuilder
    private var dockedBeatCard: some View {
        if let focusIdx = markingsContext.focusedBeatSampleIndex,
           let beat = markingsContext.beats.first(where: { $0.rPeakSampleIndex == focusIdx }) {
            BeatCalipers(
                beat: beat,
                sampleRate: markingsContext.sampleRate,
                template: markingsContext.template,
                qtcFormula: markingsContext.qtcFormula,
                kind: caliperKind(for: beat)
            )
            .accessibilityIdentifier("docked-beat-inspector")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Focus beat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Hover the trace to focus a beat")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            // X51 §4: combine the two texts into ONE element so the identifier
            // isn't shared across both static texts (which made `.firstMatch`
            // bind arbitrarily).
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("docked-beat-inspector-empty")
        }
    }

    /// Menu chip that toggles P / QRS / T fiducial overlays. R marks
    /// are non-toggleable (they anchor every beat's identity).
    private var fiducialLayersChip: some View {
        Menu {
            ForEach(MarkingsFiducialLayer.allCases, id: \.self) { layer in
                Button {
                    toggleFiducialLayer(layer)
                } label: {
                    Label(
                        layer.displayName,
                        systemImage: markingsContext.enabledLayers.contains(layer) ? "checkmark" : ""
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up.badge.a")
                    .font(.caption2)
                Text("Layers · \(enabledLayersSummary)")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show or hide P / QRS / T fiducial overlays")
        .accessibilityIdentifier("fiducial-layers-picker")
    }

    private var enabledLayersSummary: String {
        // Preserve canonical P·QRS·T order for the readout so a
        // conduction-study analyst can visually confirm the set at a
        // glance (e.g. "P·QRS" means T is hidden).
        let ordered: [MarkingsFiducialLayer] = [.p, .qrs, .t]
        let active = ordered.filter { markingsContext.enabledLayers.contains($0) }
        if active.isEmpty { return "R only" }
        if active.count == ordered.count { return "all" }
        return active.map(\.displayName).joined(separator: "·")
    }

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
                timeRangeSeconds: viewportTimeRange,
                metricLabel: laneContext.metricLabel,
                unit: laneContext.unit,
                windowCaption: laneContext.windowCaption,
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
                viewportTimeRange: viewportTimeRange,
                band: IntervalTrendRepresentation.band(
                    viewportWindowSeconds: viewport.durationSeconds
                ),
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
        isEditing && PurchaseStore.shared.owns(.annotationAuthoring)
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

    /// Click-through from the trend lane back to a specific beat.
    /// Finds the beat closest to the clicked bin center and asks
    /// `IntervalMarkingsContext` to jump the viewport + focus that
    /// beat — same drilldown mechanism the deviation-navigation
    /// shortcuts use.
    private func handleIntervalTrendBinClick(atTimeSeconds seconds: Double) {
        guard markingsContext.sampleRate > 0 else { return }
        let sampleIndex = Int64(seconds * markingsContext.sampleRate)
        if let beat = markingsContext.nearestBeat(toSampleIndex: sampleIndex) {
            markingsContext.requestJump(toSampleIndex: beat.rPeakSampleIndex)
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

    /// Sparkline panel for the continuous-valued vital trend channels.
    /// Hidden when no such channels exist (the legacy single-rate case
    /// stays unchanged).
    @ViewBuilder
    private var trendStrip: some View {
        if !vitalTrendChannels.isEmpty {
            ChannelTrendStrip(
                channels: vitalTrendChannels,
                recordingDirectory: recordingDirectory,
                viewport: viewport
            )
        }
    }

    /// Per-channel alarm / status lanes. Hidden when the recording carries
    /// no alarm channels.
    @ViewBuilder
    private var alarmStrip: some View {
        if !alarmChannels.isEmpty, let primary = ecgChannels.first {
            AlarmStrip(
                channels: alarmChannels,
                recordingDirectory: recordingDirectory,
                totalSamplesPrimary: primary.sampleCount,
                primarySampleRate: primary.sampleRate,
                viewport: viewport
            )
        }
    }

    /// One-row colored strip showing ventilation state (spontaneous vs
    /// assist-control). Hidden when neither probability channel is present.
    @ViewBuilder
    private var stateStrip: some View {
        let (spontaneous, assist) = stateChannels
        if (spontaneous != nil || assist != nil), let primary = ecgChannels.first {
            StateBackdropStrip(
                spontaneousChannel: spontaneous,
                assistControlChannel: assist,
                recordingDirectory: recordingDirectory,
                totalSamplesPrimary: primary.sampleCount,
                primarySampleRate: primary.sampleRate,
                viewport: viewport
            )
        }
    }

    /// Heat-band strip for `ecg_artifact_ratio` and other 0-to-1 quality
    /// metrics. Hidden when the recording carries none.
    @ViewBuilder
    private var qualityStrip: some View {
        if !qualityChannels.isEmpty, let primary = ecgChannels.first {
            QualityStrip(
                channels: qualityChannels,
                recordingDirectory: recordingDirectory,
                totalSamplesPrimary: primary.sampleCount,
                primarySampleRate: primary.sampleRate,
                viewport: viewport
            )
        }
    }

    // findingsOverview retired 2026-07-05: category-filter + tally
    // functionality is now consolidated in the review-queue rail's
    // triage tally + category menu (project_findings_review_queue_design).
    // Removing the redundant chip row from the scrolling context also
    // eliminates the CI-window-height flake where the chip landed
    // below the visible fold and XCUI reported "not hittable".

    private var summaryHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.device)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("bedside-summary")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(summaryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(navigationHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 320, alignment: .leading)

            if !recording.headerComments.isEmpty || recording.notesFileName != nil {
                RecordContextPanel(
                    headerComments: recording.headerComments,
                    notesURL: recording.notesFileName.map {
                        recordingDirectory.appendingPathComponent($0)
                    },
                    isEditing: isEditing,
                    editorFocus: $notesEditorFocused
                )
                // AX2: contain the panel's children so it stops collapsing to
                // a single element that speaks the decorative doc.text symbol
                // name ("Plain Text Document"); this also surfaces the `.hea`
                // demographics + notes to VoiceOver as readable content.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("context-panel")
            }
        }
    }

    private var summaryDetail: String {
        let channelCount = recording.channels.count
        let duration = Self.formatDuration(seconds: totalDurationSeconds)
        var detail = "\(channelCount) channels  •  \(duration)"
        // X32: only show a start time when the source genuinely carried one.
        // WFDB records without a base date/time (MIT-BIH) must not display a
        // fabricated start — the origin is elapsed-time-only.
        if recording.hasAbsoluteStartTime, let start = recording.channels.first?.startDate {
            detail += "  •  starts \(start.formatted(date: .numeric, time: .standard))"
        } else {
            detail += "  •  no absolute start time"
        }
        if !recording.annotations.isEmpty {
            detail += "  •  \(recording.annotations.count) annotations"
        }
        return detail
    }

    private var navigationHint: String {
        "Drag or ←/→ to pan  •  Pinch or +/− to zoom  •  J/K to jump between findings  •  Unlock + C/D/X to confirm / dismiss / reset"
    }

    private var totalDurationSeconds: Double {
        recording.channels.first?.durationSeconds ?? 0
    }

    private static func formatDuration(seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }
}

// MARK: - ECG grid spec (used by both Metal renderer and SwiftUI axis overlays)

/// Picks the minor / major / landmark grid spacings (in seconds / mV) for a
/// viewport of the given duration. Three tiers mirror standard ECG paper:
///   • Minor    — thin lines, finest tick (e.g. 0.04 s × 0.1 mV)
///   • Major    — every 5th minor — the calibration grid (0.2 s × 0.5 mV)
///   • Landmark — every 5th major — the second/2.5-mV beat landmark
///                used to find "1 second from here" at a glance.
/// Adaptive density keeps the active gridline count bounded across every zoom
/// level so the chart never devolves into a pink wash.
struct ECGGridSpec: Equatable {
    let xMinor: Double          // seconds
    let xMajor: Double
    let xLandmark: Double
    let yMinor: Double          // mV (or matching unit)
    let yMajor: Double
    let yLandmark: Double

    static func forDuration(seconds: Double) -> ECGGridSpec {
        // Landmark is always 5× the major — the standard clinical "every 5th"
        // landmark on printed ECG paper. The y-landmark mirrors that across
        // every tier so the chart stays clinically calibrated end-to-end.
        switch seconds {
        case ..<30:
            return ECGGridSpec(
                xMinor: 0.04, xMajor: 0.2,  xLandmark: 1.0,
                yMinor: 0.1,  yMajor: 0.5,  yLandmark: 2.5
            )
        case ..<300:        // up to 5 min
            return ECGGridSpec(
                xMinor: 0.2,  xMajor: 1.0,  xLandmark: 5.0,
                yMinor: 0.1,  yMajor: 0.5,  yLandmark: 2.5
            )
        case ..<1800:       // up to 30 min
            return ECGGridSpec(
                xMinor: 1.0,  xMajor: 5.0,  xLandmark: 25.0,
                yMinor: 0.5,  yMajor: 1.0,  yLandmark: 5.0
            )
        case ..<7200:       // up to 2 hr
            return ECGGridSpec(
                xMinor: 5.0,  xMajor: 30.0, xLandmark: 150.0,
                yMinor: 0.5,  yMajor: 2.5,  yLandmark: 12.5
            )
        default:
            return ECGGridSpec(
                xMinor: 30.0, xMajor: 300.0, xLandmark: 1500.0,
                yMinor: 1.0,  yMajor: 5.0,   yLandmark: 25.0
            )
        }
    }
}

// MARK: - Layout mode

enum BedsideLayoutMode: Equatable {
    /// Single lead, full available height — the analyst's default.
    case focus(Channel.ID)
    /// All leads stacked in compact strips — opt-in cross-lead comparison.
    case strips
}

/// Horizontal lead-chip bar with a Focus/Strips mode toggle. Single-tap a lead
/// to focus it; toggle to strips to see them all stacked.
private struct LeadChipBar: View {
    let channels: [Channel]
    @Binding var layoutMode: BedsideLayoutMode

    var body: some View {
        HStack(spacing: 10) {
            modeToggle
            Divider().frame(maxHeight: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(channels) { channel in
                        chip(for: channel)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lead-chip-bar")
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeButton(
                systemImage: "rectangle.fill",
                label: "Focus",
                isOn: isFocusMode,
                action: switchToFocus
            )
            modeButton(
                systemImage: "rectangle.split.1x2.fill",
                label: "Strips",
                isOn: layoutMode == .strips,
                action: { layoutMode = .strips }
            )
        }
    }

    private func modeButton(systemImage: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isOn ? Color.accentColor : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityIdentifier("layout-mode-\(label.lowercased())")
    }

    private func chip(for channel: Channel) -> some View {
        let isFocused = (layoutMode == .focus(channel.id))
        return Button {
            layoutMode = .focus(channel.id)
        } label: {
            Text(channel.name)
                .font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isFocused ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                )
                .overlay(
                    Capsule()
                        .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lead-chip-\(channel.name)")
    }

    private var isFocusMode: Bool {
        if case .focus = layoutMode { return true }
        return false
    }

    private func switchToFocus() {
        if case .focus = layoutMode { return }
        if let first = channels.first { layoutMode = .focus(first.id) }
    }
}

// MARK: - Channel panel

private struct ChannelPanel: View {
    enum Sizing {
        /// Strips mode — compact stacked layout. Floor is small enough that a
        /// short window can still show a couple of leads at once.
        case strip
        /// Focus mode — chart fills the available vertical space. Floor is the
        /// smallest window-height the analyst is likely to ever want.
        case focus

        var canvasMinHeight: CGFloat {
            switch self {
            case .strip: return 130
            case .focus: return 360
            }
        }

        var expands: Bool {
            self == .focus
        }
    }

    let channel: Channel
    let directory: URL
    let viewport: RecordingViewport
    /// Shared calibration (X40). The focus-sized panel publishes its measured
    /// canvas size + visible mV span here so the readout can convert to
    /// clinical units; strip panels don't (the readout is a focus-mode surface).
    let calibration: Calibration
    let annotations: [Annotation]
    /// VT/VF model candidate episodes (range annotations) to draw as
    /// translucent bands on the trace so a queue jump lands on a visible
    /// region. Kept separate from `annotations` because candidates route
    /// through the region-keyed disposition store, not the annotation one.
    var candidates: [Annotation] = []
    var sizing: Sizing = .strip

    @State private var clippedRanges: [ClippedRange] = []
    /// Recording-wide min/max for this channel, populated by the same
    /// background scan that builds `clippedRanges`. nil until the scan
    /// finishes (or empty for zero-sample channels). Drives both the
    /// header range badge and the per-channel Y-axis autoscale.
    @State private var sampleRange: MinMaxScanner.Range?
    /// This panel's measured canvas height in points, feeding the gain-derived
    /// amplitude window (X40). 0 until first layout → displayRange falls back
    /// to ±5 mV meanwhile.
    @State private var canvasHeightPoints: CGFloat = 0

    // Per-gesture starting state so each gesture is computed against the
    // viewport as it was when the gesture began, not the most recent update.
    @State private var dragStartRange: Range<Int64>?
    @State private var zoomStartWidth: Int64?

    /// Signature of the visible annotation set on the previous drag tick.
    /// What goes into the set depends on `hapticMode` — IDs for the
    /// "every new annotation" mode, categories for the "new category
    /// only" mode. A non-empty delta vs. this set triggers a haptic
    /// tick. Reset on drag start.
    @State private var lastHapticSignature: Set<String> = []

    /// Visual translation in points applied to the chart content while a
    /// drag is pulling past a viewport boundary. Stays at zero when the
    /// drag is within the recording's bounds. When the user pulls past
    /// `startSample == 0` or `endSample == totalSamples`, the excess
    /// drag distance is fed through a rubber-band damping curve and the
    /// chart shifts to follow the cursor partially — the classic
    /// iOS-style elastic edge. Springs back to 0 on drag release.
    @State private var overscrollPx: CGFloat = 0

    /// User preference for haptic feedback during pan. Stored in
    /// UserDefaults via `@AppStorage`; defaults to `.off` so first-launch
    /// is silent. Live-read every onChanged so toggling the Settings
    /// picker takes effect on the next drag without restart.
    @AppStorage(HapticPreferences.modeKey)
    private var hapticMode: HapticMode = HapticPreferences.defaultMode

    // Hover-driven tooltip: which finding is under the cursor, and where
    // (in canvas-local coordinates) the cursor currently sits.
    @State private var hoveredAnnotation: Annotation?
    @State private var hoverLocation: CGPoint = .zero
    /// True while the pointer is anywhere over the canvas. Drives the
    /// vertical crosshair + time readout — present even when there's no
    /// finding under the cursor.
    @State private var hoverIsActive: Bool = false

    /// Bidirectional hover coordination with the variability lane. The
    /// canvas publishes its own hover time (source .ecg) so the lane
    /// highlights the corresponding sample, and reads back the lane's
    /// hover (source .lane) so it can draw a translucent band over
    /// the beats that produced the hovered metric — the "window-on-
    /// signal" signature interaction from the variability-lane spec.
    @State private var laneContext = VariabilityLaneContext.shared

    /// Read of the per-beat fiducial store — powers the FiducialOverlay
    /// drawn above the Metal canvas. Written by the App target's
    /// IntervalMarkingsOrchestrator.
    @State private var markingsContext = IntervalMarkingsContext.shared

    /// Semantic-zoom tier for the waveform per
    /// project_waveform_zoom_lod_spec.md. Persists across body evals so
    /// `WaveformZoomTierSelector.select(current:)`'s hysteresis is
    /// honoured — otherwise the tier would strobe on slow zooms across
    /// a threshold. Written asynchronously via `.task(id:)` when the
    /// resolved tier for the current viewport differs from the stored
    /// value.
    @State private var waveformZoomTier: WaveformZoomTier = .inspect

    private static let yMin: Double = -5
    private static let yMax: Double =  5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            HStack(alignment: .top, spacing: 0) {
                WaveformVoltageAxis(yMin: displayRange.lowerBound, yMax: displayRange.upperBound, durationSeconds: durationSeconds)
                    .frame(minHeight: sizing.canvasMinHeight)
                canvasArea
            }
            .frame(maxHeight: sizing.expands ? .infinity : nil)
            // At Context zoom the density lane below the trace used to
            // render bulk-category intensity here, but the ratified
            // design (Kevin, 2026-07-07) hands the far-out density job
            // off to the pinned Overview strip below — a heatmap-style
            // strip beneath the trace was competing visually with the
            // Overview and duplicating the density surface. The trace
            // area at Context now shows envelope silhouette + rare
            // landmarks + focus locator ONLY; the Overview carries
            // the "where in the recording" density read.
            WaveformTimeAxis(startTime: startTime, endTime: endTime)
                .padding(.leading, 56)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channel-panel-\(channel.name)")
        .task { await scanForOffScale() }
    }

    /// Effective display range for the canvas + voltage axis.
    ///   • A canonical gain is set (Standard View / a preset / Fit to window)
    ///     → the mV window is DERIVED from that gain + this panel's height +
    ///     the display's physical size, centred on the baseline (X40).
    ///   • Otherwise → the legacy fixed ±5 mV reference (also the fallback
    ///     until the canvas is measured or when the display size is untrusted).
    /// There is no live Auto-Y mode any more — a scale that rescaled per window
    /// was the amplitude-ruler incoherence X40 closes; fitting is now one-shot.
    private var displayRange: ClosedRange<Double> {
        if let gain = calibration.gainMillimetersPerMillivolt,
           canvasHeightPoints > 0,
           let mmPerPoint = DisplayMetrics.millimetersPerPoint(),
           let halfSpan = CalibrationMath.millivoltHalfSpan(
               gainMillimetersPerMillivolt: gain,
               canvasHeightPoints: Double(canvasHeightPoints),
               millimetersPerPoint: mmPerPoint
           ) {
            return -halfSpan...halfSpan
        }
        return Self.yMin...Self.yMax
    }

    /// One-shot "Fit amplitude to window" (X40) — replaces the deleted live
    /// Auto Y. Computes a single gain so the observed excursion fits the
    /// baseline-centred window (10% headroom), sets the shared gain, and the
    /// view is then in a plain non-standard gain state the readout reports.
    /// Per-channel observed range but SHARED gain, matching the focused lead.
    private func fitAmplitudeToWindow() {
        guard let range = sampleRange, !range.isEmpty,
              canvasHeightPoints > 0,
              let mmPerPoint = DisplayMetrics.millimetersPerPoint() else { return }
        let extent = Double(max(abs(range.min), abs(range.max))) * 1.1
        guard let gain = CalibrationMath.fitGain(
            extentMillivolts: extent,
            canvasHeightPoints: Double(canvasHeightPoints),
            millimetersPerPoint: mmPerPoint
        ) else { return }
        calibration.gainMillimetersPerMillivolt = gain
    }

    /// Publish this panel's trace geometry to the shared calibration so the
    /// readout can report clinical units. Only the focus-sized panel writes —
    /// the readout is a focus-mode surface and strip panels would clobber it.
    private func publishCalibrationGeometry(canvasSize: CGSize) {
        guard sizing == .focus else { return }
        calibration.canvasSize = canvasSize
        calibration.visibleMillivoltSpan = displayRange.upperBound - displayRange.lowerBound
    }

    private var canvasArea: some View {
        // Read the canvas size directly via GeometryReader instead of the
        // preference-key + onPreferenceChange dance. In Swift 6 strict
        // concurrency, `onPreferenceChange`'s `@Sendable` perform closure
        // silently swallows `@State` mutations on the host view, leaving
        // canvasSize permanently at .zero — which then trips the
        // `canvasSize.width > 0` guards in panGesture and the crosshair.
        // Capturing `geo.size` synchronously below avoids the indirection
        // entirely.
        GeometryReader { geo in
            let liveSize = geo.size
            // Points-per-beat for THIS viewport, at THIS panel's width.
            // Feeds the semantic zoom tier — the annotation-rail
            // treatment, the fiducial detail level, and (in follow-up
            // commits) the density lane all key off the same value so
            // every layer stays in lockstep with what the trace itself
            // is showing.
            //
            // BEAT SOURCE: prefer the delineator's fiducial store when
            // it's populated (paid ECG Metrics active), otherwise fall
            // back to counting the wfdb.atr POINT annotations in the
            // viewport. Without this fallback, the tier stays at
            // .inspect forever for free-viewer users looking at a
            // MIT-BIH recording — the whole zoom-out simplification
            // never fires because the compute-side beat count is empty.
            let delineatorBeats = markingsContext.beats.count(where: {
                $0.rPeakSampleIndex >= viewport.startSample
                && $0.rPeakSampleIndex <= viewport.endSample
            })
            let beatsInWindow: Int = {
                if delineatorBeats > 0 { return delineatorBeats }
                return visibleAnnotations.reduce(0) { partial, ann in
                    ann.kind == .point ? partial + 1 : partial
                }
            }()
            let pointsPerBeat = WaveformZoomTierSelector.pointsPerBeat(
                plotWidthPoints: Double(liveSize.width),
                beatsInWindow: beatsInWindow
            )
            let resolvedTier = WaveformZoomTierSelector.select(
                pointsPerBeat: pointsPerBeat,
                current: waveformZoomTier
            )
            ZStack(alignment: .topLeading) {
                // Chart content — translated by the rubber-band offset so
                // the trace, off-scale markers, and annotation labels all
                // move together when the user pulls past a viewport
                // boundary. Cursor-anchored overlays below the Group are
                // intentionally NOT offset so the crosshair / tooltip
                // stay locked to the cursor while the chart bands away.
                Group {
                    WaveformCanvas(
                        channel: channel,
                        directory: directory,
                        startSample: viewport.startSample,
                        endSample: viewport.endSample,
                        annotations: visibleAnnotations,
                        focusedBeatSampleIndex: markingsContext.focusedBeatSampleIndex,
                        displayMin: displayRange.lowerBound,
                        displayMax: displayRange.upperBound,
                        onScroll: { handleWheelScroll($0, canvasWidth: liveSize.width) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    WaveformClippingOverlay(
                        clippedRanges: clippedRanges,
                        startSample: viewport.startSample,
                        endSample: viewport.endSample
                    )

                    WaveformAnnotationOverlay(
                        annotations: visibleAnnotations,
                        startSample: viewport.startSample,
                        endSample: viewport.endSample,
                        tier: resolvedTier
                    )

                    // VT/VF candidate regions as translucent bands. Range
                    // annotations aren't drawn by the chip rail (point-only),
                    // so without this a queue jump to a candidate lands on a
                    // trace with no marker for the episode.
                    VTVFCandidateBandOverlay(
                        candidates: visibleCandidates,
                        startSample: viewport.startSample,
                        endSample: viewport.endSample
                    )
                }
                .offset(x: overscrollPx)

                HoverTrackingView { location in
                    applyHover(location, in: liveSize)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: liveSize) {
                    #if DEBUG
                    // If `--ui-test-hover-at=X,Y` was passed, fire the same
                    // hover-update path that HoverTrackingView would.
                    // `id: liveSize` re-runs the task once GeometryReader
                    // measures, so the injection happens against a real
                    // canvas size (not .zero on first body evaluation).
                    if liveSize.width > 0, let pt = UITestSupport.hoverPoint {
                        applyHover(pt, in: liveSize)
                    }
                    #endif
                }

                if hoverIsActive, liveSize.width > 0 {
                    hoverCrosshair(in: liveSize)
                }

                // Lane-hover → ECG band overlay. The "highlight the beats
                // in THAT window" half of the window-on-signal linkage:
                // when the analyst hovers the variability lane below,
                // draw a translucent band over the beats whose RRs
                // populate the hovered window. Only renders when the
                // hover source is the lane — the ECG's own hover uses
                // the crosshair above instead.
                laneWindowBand(in: liveSize)
                    .allowsHitTesting(false)

                // Fiducial overlay — P/QRS/T marks per beat, LOD-
                // driven by viewport duration. Hidden when the
                // context is empty (no entitlement / no beats).
                FiducialOverlay(
                    beats: markingsContext.beats(inSampleRange: viewport.startSample...viewport.endSample),
                    viewportSampleRange: viewport.startSample..<viewport.endSample,
                    sampleRate: markingsContext.sampleRate,
                    detailLevel: MarkingsDetailLevel.level(forViewportSeconds: viewport.durationSeconds),
                    focusedRPeakSampleIndex: markingsContext.focusedBeatSampleIndex,
                    enabledLayers: markingsContext.enabledLayers,
                    canvasSize: liveSize,
                    tier: resolvedTier
                )

                if let hovered = hoveredAnnotation {
                    AnnotationTooltip(annotation: hovered, sampleRate: channel.sampleRate)
                        .frame(maxWidth: 260, alignment: .leading)
                        .offset(tooltipOffset(in: liveSize))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                // Invisible accessibility element exposing the resolved
                // tier + the beats-in-window count that fed the selector.
                // Lets XCUI tests assert "did zooming out actually cross
                // a tier?" without inspecting Metal render state. Same
                // pattern as the ui-test-viewport-state overlay at the
                // BedsideView level. Format uses letter separators so
                // macOS's accessibility comma-injection doesn't rewrite
                // 4+ digit numbers.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("ui-test-waveform-tier")
                    .accessibilityLabel("tier=\(resolvedTier.rawValue) beats=\(beatsInWindow)")
                    .allowsHitTesting(false)
            }
            // Persist the resolved tier back to @State so the next
            // body pass has the correct `current` input for the
            // hysteresis rule. Async by construction (Task-scheduled);
            // acceptable because the visible tier this frame is already
            // `resolvedTier` — the state write is only to inform the
            // NEXT frame's selector call.
            .task(id: resolvedTier) {
                if resolvedTier != waveformZoomTier {
                    waveformZoomTier = resolvedTier
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture(in: liveSize))
            .gesture(zoomGesture(in: liveSize))
            // Publish the focused trace's geometry so the calibration readout
            // (a level up, beside the viewport indicator) can convert points →
            // mm. Height + mV span both feed pointsPerMillivolt; width feeds
            // pointsPerSecond. Only the focus-sized panel writes.
            .onChange(of: liveSize, initial: true) { _, size in
                canvasHeightPoints = size.height
                publishCalibrationGeometry(canvasSize: size)
            }
            .onChange(of: displayRange) { _, _ in
                publishCalibrationGeometry(canvasSize: liveSize)
            }
        }
        .frame(minHeight: sizing.canvasMinHeight, maxHeight: sizing.expands ? .infinity : nil)
    }

    // MARK: Hover hit-testing
    // Mouse tracking is delivered by `HoverTrackingView` (an
    // NSTrackingArea-backed overlay). It calls back with the cursor
    // location on enter/move and `nil` on exit; canvasArea routes
    // through applyHover so the UI-test injection takes the same path.

    private func applyHover(_ location: CGPoint?, in canvasSize: CGSize) {
        if let location {
            hoverLocation = location
            hoverIsActive = true
            hoveredAnnotation = hitTest(at: location, in: canvasSize)
            // Publish the hovered time to the shared variability-lane
            // context so the lane can highlight the sample whose
            // window contains this instant. `setHover` guards against
            // stale hover-exits from other surfaces clobbering us.
            laneContext.setHover(
                time: cursorTimeSeconds(at: location, in: canvasSize),
                from: .ecg
            )
            // Also focus the nearest fiducial beat so the FiducialOverlay
            // highlights the R-tick + the BeatCalipers readout tracks
            // the analyst's cursor.
            let cursorSample = cursorSampleIndex(at: location, in: canvasSize)
            markingsContext.focus(beatSampleIndex: markingsContext.nearestBeat(toSampleIndex: cursorSample)?.rPeakSampleIndex)
        } else {
            hoverIsActive = false
            hoveredAnnotation = nil
            laneContext.setHover(time: nil, from: .ecg)
            markingsContext.focus(beatSampleIndex: nil)
        }
    }

    /// Absolute sample index at the given canvas-local point.
    private func cursorSampleIndex(at location: CGPoint, in canvasSize: CGSize) -> Int64 {
        let cursorX = max(0, min(canvasSize.width, location.x))
        let span = max(1, viewport.endSample - viewport.startSample)
        return viewport.startSample + Int64(Double(span) * Double(cursorX / canvasSize.width))
    }

    /// Absolute time (seconds from recording start) at the given
    /// canvas-local point, using the same viewport math the
    /// `hoverCrosshair` overlay uses.
    private func cursorTimeSeconds(at location: CGPoint, in canvasSize: CGSize) -> Double {
        let cursorX = max(0, min(canvasSize.width, location.x))
        let span = max(1, viewport.endSample - viewport.startSample)
        let sample = viewport.startSample + Int64(Double(span) * Double(cursorX / canvasSize.width))
        return Double(sample) / channel.sampleRate
    }

    /// 1-px vertical line at the cursor with a floating time label at the
    /// top edge. Receives the canvas size from the enclosing GeometryReader
    /// so the Rectangle can be sized explicitly to the canvas height
    /// (without an explicit height it collapses to ~12 pt and vanishes).
    /// Translucent band over the ECG covering the RR-window of the
    /// variability lane's hovered sample. Renders only when the hover
    /// source is the lane and the window intersects the current
    /// viewport — otherwise emits an `EmptyView`.
    @ViewBuilder
    private func laneWindowBand(in canvasSize: CGSize) -> some View {
        if laneContext.hoveredSource == .lane,
           let t = laneContext.hoveredTimeSeconds,
           let sample = laneContext.sample(atTimeSeconds: t),
           canvasSize.width > 0,
           channel.sampleRate > 0 {
            let sr = channel.sampleRate
            let startSec = Double(viewport.startSample) / sr
            let endSec = Double(viewport.endSample) / sr
            let spanSec = max(0.0001, endSec - startSec)
            // Clip the band to the visible viewport before computing
            // pixel coords — a window that starts before the visible
            // range must still render its visible half.
            let bandStart = max(startSec, sample.windowStartSeconds)
            let bandEnd = min(endSec, sample.windowEndSeconds)
            if bandEnd > bandStart {
                let x1 = CGFloat((bandStart - startSec) / spanSec) * canvasSize.width
                let x2 = CGFloat((bandEnd - startSec) / spanSec) * canvasSize.width
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: max(1, x2 - x1), height: canvasSize.height)
                    .offset(x: x1)
                    .accessibilityIdentifier("lane-window-band")
            }
        }
    }

    @ViewBuilder
    private func hoverCrosshair(in canvasSize: CGSize) -> some View {
        let cursorX = max(0, min(canvasSize.width, hoverLocation.x))
        let span = max(1, viewport.endSample - viewport.startSample)
        let cursorSample = viewport.startSample + Int64(Double(span) * Double(cursorX / canvasSize.width))
        let cursorTime = Double(cursorSample) / channel.sampleRate

        // `.topLeading` alignment + `.offset` keeps each subview's layout
        // area tight (1 pt wide for the rule, intrinsic for the label).
        // We avoided `.position(x:y:)` here because that modifier expands
        // the view's reported area to fill the parent — even with
        // `.allowsHitTesting(false)` on the ZStack, the expanded area
        // appeared to confuse SwiftUI's drag-gesture recognizer and
        // intermittently cancel pans mid-drag once the cursor crossed
        // the crosshair's frozen position.
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 1, height: canvasSize.height)
                .offset(x: cursorX - 0.5)
            Text(String(format: "%.3f s", cursorTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.thinMaterial)
                )
                .fixedSize()
                .offset(
                    x: max(0, min(canvasSize.width - 56, cursorX - 28)),
                    y: 4
                )
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        // Forced leaf — SwiftUI drops non-hit-testable views from the
        // macOS XCUI accessibility tree without this.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("hover-crosshair")
    }

    /// Returns the finding under `point`, preferring ranges that strictly
    /// contain the hover sample. Otherwise picks the nearest point finding
    /// within a small pixel tolerance so the analyst doesn't have to land
    /// exactly on a one-pixel-wide tick.
    private func hitTest(at point: CGPoint, in canvasSize: CGSize) -> Annotation? {
        guard canvasSize.width > 0 else { return nil }
        let span = max(1, viewport.endSample - viewport.startSample)
        let fraction = max(0, min(1, Double(point.x / canvasSize.width)))
        let hoverSample = viewport.startSample + Int64(Double(span) * fraction)

        if let inside = visibleAnnotations.first(where: { ann in
            guard ann.kind == .range else { return false }
            let end = ann.endSampleIndex ?? ann.sampleIndex
            return hoverSample >= ann.sampleIndex && hoverSample <= end
        }) {
            return inside
        }

        let tolerancePx: CGFloat = 6
        let toleranceSamples = Int64(Double(span) * Double(tolerancePx / canvasSize.width))
        return visibleAnnotations
            .filter { $0.kind == .point && abs($0.sampleIndex - hoverSample) <= toleranceSamples }
            .min(by: { abs($0.sampleIndex - hoverSample) < abs($1.sampleIndex - hoverSample) })
    }

    /// Offset the tooltip away from the cursor so the cursor itself doesn't
    /// land inside the tooltip rectangle (which would obscure what the user
    /// is pointing at). Flip the tooltip to the cursor's left when there
    /// isn't enough room on the right.
    private func tooltipOffset(in canvasSize: CGSize) -> CGSize {
        let nudgeX: CGFloat = 14
        let tooltipWidth: CGFloat = 240
        let tooltipHeightApprox: CGFloat = 92
        var x = hoverLocation.x + nudgeX
        if x + tooltipWidth > canvasSize.width {
            x = max(0, hoverLocation.x - nudgeX - tooltipWidth)
        }
        var y = hoverLocation.y + nudgeX
        if y + tooltipHeightApprox > canvasSize.height {
            y = max(0, hoverLocation.y - tooltipHeightApprox - nudgeX)
        }
        return CGSize(width: x, height: y)
    }

    /// Annotations that overlap the current viewport. Point findings are visible
    /// when their sample falls inside the range; range findings are visible when
    /// their [start, end] interval intersects it. The list is sorted by sample
    /// index, so we can scan from a small lookahead window.
    private var visibleAnnotations: [Annotation] {
        guard !annotations.isEmpty else { return [] }
        let range = viewport.rangeSamples
        return annotations.filter { ann in
            switch ann.kind {
            case .point:
                return range.contains(ann.sampleIndex)
            case .range:
                let start = ann.sampleIndex
                let end   = ann.endSampleIndex ?? ann.sampleIndex
                return end >= range.lowerBound && start < range.upperBound
            }
        }
    }

    /// Candidate episodes whose [start, end] interval intersects the
    /// viewport — the subset the band overlay needs to draw.
    private var visibleCandidates: [Annotation] {
        guard !candidates.isEmpty else { return [] }
        let range = viewport.rangeSamples
        return candidates.filter { c in
            let start = c.sampleIndex
            let end = c.endSampleIndex ?? c.sampleIndex
            return end >= range.lowerBound && start < range.upperBound
        }
    }

    private var startTime: Double {
        Double(viewport.startSample) / channel.sampleRate
    }
    private var endTime: Double {
        Double(viewport.endSample) / channel.sampleRate
    }
    private var durationSeconds: Double { endTime - startTime }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(channel.name).font(.headline)
            Text(channel.unit.isEmpty ? "" : "(\(channel.unit))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !clippedRanges.isEmpty {
                Label("\(clippedRanges.count) off-scale", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("\(clippedRanges.count) segment\(clippedRanges.count == 1 ? "" : "s") exceed ±5 mV and aren't drawn")
            }
            if let range = sampleRange, !range.isEmpty {
                Text(String(format: "%.2f – %.2f", range.min, range.max))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Recording-wide voltage range observed on this channel")
                    .accessibilityIdentifier("channel-range-\(channel.name)")
                Button {
                    fitAmplitudeToWindow()
                } label: {
                    Label("Fit amplitude", systemImage: "arrow.up.and.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Set the gain once so this channel's observed amplitude fills the window (10% headroom). A one-shot fit, not a live rescale — the calibration readout then reports the resulting gain.")
                .accessibilityIdentifier("fit-amplitude-\(channel.name)")
            }
            Spacer()
            Text(timeWindowLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("time-window-label")
            Text("\(Int(channel.sampleRate)) Hz")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timeWindowLabel: String {
        // X49: the shared m:ss.d formatter (raw seconds moved to the inspector).
        ViewportTimeFormat.window(startSeconds: startTime, endSeconds: endTime)
    }

    /// One-time scan over the full channel at panel mount. Runs the
    /// clipping detector AND the min/max scanner in the same detached
    /// task so each panel reads the channel file off the main thread
    /// exactly once. Feeds the chevron overlay, the off-scale header
    /// badge, and the informational range badge.
    private func scanForOffScale() async {
        let url = directory.appendingPathComponent(channel.storageFileName)
        let total = channel.sampleCount
        guard total > 0 else { return }
        struct ScanResult: Sendable {
            let clipped: [ClippedRange]
            let range: MinMaxScanner.Range?
        }
        let result: ScanResult = await Task.detached(priority: .utility) {
            guard let access = try? BinaryRecordingFile.mappedAccess(url: url) else {
                return ScanResult(clipped: [], range: nil)
            }
            let samples = access.samples(range: 0..<total)
            let clipped = ClippedRangeScanner.scan(
                samples: samples,
                clipMin: Float(Self.yMin),
                clipMax: Float(Self.yMax)
            )
            let range = MinMaxScanner.scan(samples: samples)
            return ScanResult(clipped: clipped, range: range)
        }.value
        await MainActor.run {
            clippedRanges = result.clipped
            sampleRange = result.range
        }
    }

    // MARK: Gestures

    private func panGesture(in canvasSize: CGSize) -> some Gesture {
        // minimumDistance: 1 keeps a one-pixel dead zone so a click that
        // jitters by a hair doesn't read as a drag, but eliminates the
        // 2-pt accumulation delay that read as start-of-pan hesitation.
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRange == nil {
                    dragStartRange = viewport.rangeSamples
                    lastHapticSignature = hapticSignature(for: visibleAnnotations)
                }
                guard let start = dragStartRange, canvasSize.width > 0 else { return }
                let width = start.upperBound - start.lowerBound
                let samplesPerPixel = Double(width) / Double(canvasSize.width)
                let desiredDeltaSamples = Int64(-value.translation.width * samplesPerPixel)
                let proposedStart = start.lowerBound + desiredDeltaSamples
                // Clamp to recording bounds — the viewport itself never
                // exceeds [0, totalSamples - width].
                let maxStart = max(0, viewport.totalSamples - width)
                let clampedStart = max(0, min(maxStart, proposedStart))
                viewport.setStart(clampedStart)
                // The pixel distance the cursor pulled past the boundary
                // (positive when pulling past the left edge, negative when
                // pulling past the right). Feed through rubber-band damping
                // so the chart shifts visibly to follow the cursor but with
                // diminishing return — the classic iOS elastic edge.
                let overshootSamples = Double(clampedStart - proposedStart)
                let overshootPx = CGFloat(overshootSamples / samplesPerPixel)
                overscrollPx = RubberBand.damp(
                    overshoot: overshootPx,
                    canvasWidth: canvasSize.width
                )
                // Keep the crosshair tracking the cursor during the drag.
                // NSTrackingArea suppresses mouseMoved while a button is
                // down, so the hover path can't update hoverLocation;
                // without this the crosshair freezes at the drag-start
                // position and analysts can't tell whether the chart is
                // unresponsive or rubber-banding against a boundary.
                hoverLocation = value.location
                hoverIsActive = true
                emitHapticIfAnnotationsEntered()
            }
            .onEnded { value in
                defer {
                    dragStartRange = nil
                    lastHapticSignature = []
                }
                guard canvasSize.width > 0 else { return }
                // Spring the rubber-band back to neutral. Snappy enough
                // that it feels like a release, not a glide.
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    overscrollPx = 0
                }
                // DragGesture estimates a momentum trajectory in
                // `predictedEndLocation`. The difference between the
                // release point and the predicted rest position is the
                // post-release displacement under the system's default
                // deceleration, divided by ~0.5s to get a per-second
                // velocity (which startPanMomentum then re-eases).
                let dragVelocityPx = Double(value.predictedEndLocation.x - value.location.x)
                let span = Double(viewport.endSample - viewport.startSample)
                let samplesPerPixel = span / Double(canvasSize.width)
                // Drag-right means the viewport pans left → negate.
                let velocitySamplesPerSec = -dragVelocityPx * samplesPerPixel / 0.5
                viewport.startPanMomentum(velocitySamplesPerSec: velocitySamplesPerSec)
            }
    }

    /// Apply one coalesced mouse-wheel gesture (X38). Mirrors the pinch
    /// `zoomGesture` and drag `panGesture` by mutating the shared viewport
    /// directly: zoom is exponential at 1.35× per detent, anchored at the
    /// pointer's fraction so retreat is as cheap as descent for a mouse user;
    /// pan shifts the window by the scrolled distance. `canvasWidth` is the
    /// live trace width in points.
    private func handleWheelScroll(_ scroll: WheelScroll, canvasWidth: CGFloat) {
        // The recording span bounds every viewport figure; clamping the Double
        // to it BEFORE the Int64 conversion is essential — a big zoom-out burst
        // sends `factor` (and the raw product) past Int64.max, and converting
        // that traps at runtime. setWidth / pan re-clamp anyway, so bounded
        // input is behaviour-preserving.
        let total = Double(max(viewport.minSamples, viewport.totalSamples))

        // Calibration lock (X40 §4): pan stays free, zoom is held.
        if scroll.zoomDetents != 0, !calibration.locked {
            let factor = pow(1.35, -scroll.zoomDetents)   // detents > 0 → zoom in
            if let width = RecordingViewport.zoomedWidthSamples(
                currentWidth: viewport.endSample - viewport.startSample,
                factor: factor,
                totalSamples: viewport.totalSamples
            ) {
                viewport.setWidth(width, anchorFraction: scroll.anchorFractionX)
            }
        }
        if scroll.panPoints != 0, canvasWidth > 0 {
            let span = Double(viewport.endSample - viewport.startSample)
            let samplesPerPoint = span / Double(canvasWidth)
            let delta = (scroll.panPoints * samplesPerPoint).rounded()
            if delta.isFinite {
                viewport.pan(bySamples: Int64(min(max(delta, -total), total)))
            }
        }
    }

    private func zoomGesture(in canvasSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Calibration lock (X40 §4): a pinch can't change the timebase
                // calibration while locked.
                guard !calibration.locked else { return }
                if zoomStartWidth == nil {
                    zoomStartWidth = viewport.endSample - viewport.startSample
                }
                guard let startWidth = zoomStartWidth else { return }
                let factor = 1.0 / max(0.01, value.magnification)
                let newWidth = Int64(Double(startWidth) * factor)
                viewport.setWidth(newWidth, anchorFraction: 0.5)
            }
            .onEnded { _ in zoomStartWidth = nil }
    }

    /// Fires a single `.alignment` haptic tick when the signature of the
    /// visible annotation set has grown since the previous drag tick.
    /// What "grown" means depends on `hapticMode`:
    ///   • `.off` — no-op
    ///   • `.allAnnotations` — any new annotation (by ID) entering the
    ///     viewport triggers a tick
    ///   • `.categoryTransitions` — only a new *category* (not seen on
    ///     the previous tick) triggers a tick, so clustered findings of
    ///     the same kind don't produce a buzz
    /// Force Touch trackpad only; a no-op on Magic Mouse and external
    /// pointing devices.
    private func emitHapticIfAnnotationsEntered() {
        guard hapticMode != .off else { return }
        let current = hapticSignature(for: visibleAnnotations)
        if !current.subtracting(lastHapticSignature).isEmpty {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }
        lastHapticSignature = current
    }

    /// Projects a visible-annotation list into the comparison set that
    /// `emitHapticIfAnnotationsEntered` diffs against. The projection
    /// depends on the active `hapticMode` so the same diff-on-grow logic
    /// services both per-annotation and per-category modes.
    private func hapticSignature(for visible: [Annotation]) -> Set<String> {
        switch hapticMode {
        case .off:
            return []
        case .allAnnotations:
            return Set(visible.map { String(describing: $0.id) })
        case .categoryTransitions:
            return Set(visible.map(\.category))
        }
    }
}

// MARK: - Layout plumbing

private struct CanvasSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - Interval trend lane memoization

/// Wraps `IntervalTrendComputer.compute` + `IntervalTrendLane` so
/// SwiftUI can `.equatable()`-skip the whole subtree when the parent
/// body re-runs for reasons unrelated to the trend (the dominant
/// case being pan/zoom of the ECG viewport). Compute is O(N_beats)
/// with bootstrap CI on every bin — on a 1600-beat recording it
/// dominates the per-tick cost of a pan burst.
///
/// The equality fingerprint is intentionally lightweight: `beats`
/// count + endpoint R-peak samples. The delineator writes the entire
/// beats array atomically per recording; middle mutations don't
/// happen at runtime, so this fingerprint catches every real change
/// (new recording / delineator re-run with different config both
/// change endpoints or count) without paying an O(N) hash per pass.
/// Closures are excluded — they're rebuilt on every parent body
/// pass but capture the same latest bindings, so skipping body when
/// only the closure identity changed is safe.
private struct IntervalTrendLaneMemoizedStrip: View, Equatable {
    let beats: [MarkingsBeat]
    let template: MarkingsTemplate?
    let sampleRate: Double
    let metric: IntervalTrendMetric
    let binSeconds: Double
    let templateBeatCount: Int?
    let qtcFormulaName: String
    /// The QTc formula in effect, for the X44 picker (distinct from the echoed
    /// `qtcFormulaName` string used in the repro caption).
    let qtcFormula: MarkingsQTcFormula
    /// Paid per-bin qualifying facts (X42) joined into the bins for the X43
    /// marker + X46 gate. Empty in the free viewer.
    let qualifiers: [IntervalBinQualifier]
    let recordingTimeRange: ClosedRange<Double>
    /// The ECG viewport's visible window (seconds). At `.window` band it
    /// becomes the lane's x-domain so per-beat scatter is legible (X41).
    let viewportTimeRange: ClosedRange<Double>
    /// Zoom band derived from the viewport window — drives representation.
    let band: IntervalTrendLaneBand
    let showMode: IntervalTrendShowMode
    let selectedBinPreset: IntervalTrendBinPreset
    let guides: [IntervalTrendGuide]
    let events: [IntervalTrendEvent]
    let externalHoverTimeSeconds: Double?
    /// Analyst-authored range findings rendered as amber overlays. In the
    /// fingerprint so authoring a new finding rebuilds the lane.
    let rangeFindings: [IntervalTrendRangeFinding]
    /// Whether drag-to-author is active (edit latch + Annotation IAP). In the
    /// fingerprint so toggling edit mode / entitlement re-arms the gesture.
    let authoringEnabled: Bool
    let onLaneHover: (Double?) -> Void
    let onBinClick: (Double) -> Void
    let onPickMetric: (IntervalTrendMetric) -> Void
    let onPickBinPreset: (IntervalTrendBinPreset) -> Void
    let onPickShowMode: (IntervalTrendShowMode) -> Void
    let onPickFormula: (MarkingsQTcFormula) -> Void
    let onAddGuide: (Double, String) -> Void
    let onRemoveGuide: (UUID) -> Void
    /// Excluded from `==` (a closure rebuilt every pass); gated by
    /// `authoringEnabled`, which IS in the fingerprint.
    let onAuthorRange: (Double, Double, String, String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.beats.count == rhs.beats.count,
              lhs.beats.first?.rPeakSampleIndex == rhs.beats.first?.rPeakSampleIndex,
              lhs.beats.last?.rPeakSampleIndex == rhs.beats.last?.rPeakSampleIndex else {
            return false
        }
        return lhs.templateBeatCount == rhs.templateBeatCount
            && lhs.sampleRate == rhs.sampleRate
            && lhs.metric == rhs.metric
            && lhs.binSeconds == rhs.binSeconds
            && lhs.qtcFormulaName == rhs.qtcFormulaName
            && lhs.qtcFormula == rhs.qtcFormula
            && lhs.qualifiers == rhs.qualifiers
            && lhs.recordingTimeRange == rhs.recordingTimeRange
            && lhs.viewportTimeRange == rhs.viewportTimeRange
            && lhs.band == rhs.band
            && lhs.showMode == rhs.showMode
            && lhs.selectedBinPreset == rhs.selectedBinPreset
            && lhs.guides == rhs.guides
            && lhs.events == rhs.events
            && lhs.externalHoverTimeSeconds == rhs.externalHoverTimeSeconds
            && lhs.rangeFindings == rhs.rangeFindings
            && lhs.authoringEnabled == rhs.authoringEnabled
    }

    var body: some View {
        let data = IntervalTrendComputer.compute(
            beats: beats,
            template: template,
            sampleRate: sampleRate,
            metric: metric,
            binSeconds: binSeconds,
            templateBeatCount: templateBeatCount,
            qtcFormulaName: qtcFormulaName,
            // X48 §4(b): the template's beats are the annotator's normal-beat
            // code (Recording.normalBeatSampleIndices), NOT an app-computed
            // morphology cluster — state that selection basis in the caption.
            templateSelectionBasis: template != nil ? "annotator-coded normal (N)" : nil,
            qualifiers: qualifiers
        )
        IntervalTrendLane(
            // Map band → whole recording ribbon; window band → the viewport
            // window becomes the x-domain so per-beat scatter fills the lane.
            timeRangeSeconds: band == .window ? viewportTimeRange : recordingTimeRange,
            data: data,
            metric: metric,
            showMode: showMode,
            band: band,
            qtcFormula: qtcFormula,
            selectedBinPreset: selectedBinPreset,
            guides: guides,
            events: events,
            rangeFindings: rangeFindings,
            externalHoverTimeSeconds: externalHoverTimeSeconds,
            onLaneHover: onLaneHover,
            onBinClick: onBinClick,
            onPickMetric: onPickMetric,
            onPickBinPreset: onPickBinPreset,
            onPickShowMode: onPickShowMode,
            onPickFormula: onPickFormula,
            onAddGuide: onAddGuide,
            onRemoveGuide: onRemoveGuide,
            // Gate the gesture here so a locked / unentitled lane still taps +
            // hovers but never authors.
            onAuthorRange: authoringEnabled ? onAuthorRange : nil
        )
    }
}


