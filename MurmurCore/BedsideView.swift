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
    @State private var filter = FindingFilter()
    @State private var showFindings = true
    @State private var layoutMode: BedsideLayoutMode
    /// App-wide read/write latch. Governs the context-notes editor and the
    /// per-finding disposition trio; new annotation create/edit/delete will
    /// hang off the same latch.
    @State private var isEditing: Bool = false
    /// Analyst review state for this recording's findings — confirm /
    /// dismiss / reset. Persisted to `<bundle>/dispositions.json`.
    @State private var dispositionStore: DispositionStore
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
    /// Drives the producer-run sheet. Visible in DEBUG via the toolbar;
    /// once IAP frameworks land in RELEASE, the toolbar item gates on
    /// "any producer registered" instead of the DEBUG flag.
    @State private var showProducersPanel: Bool = false

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

    /// Unfiltered rollup for the summary chip row — chips show total counts
    /// across the recording regardless of the active filter, so the user
    /// always sees "47 PVCs" instead of "8 of 47 shown."
    private var unfilteredSummary: AnnotationSummary {
        AnnotationSummary.build(
            from: allAnnotations,
            recordingDurationSamples: recording.channels.first?.sampleCount,
            sampleRate: recording.channels.first?.sampleRate ?? 250
        )
    }

    private var focusedChannel: Channel? {
        guard case .focus(let id) = layoutMode else { return nil }
        return ecgChannels.first { $0.id == id }
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
                .accessibilityLabel("start=\(viewport.startSample) end=\(viewport.endSample)")
                .allowsHitTesting(false)
        }
        .inspector(isPresented: $showFindings) {
            FindingsPanel(
                annotations: allAnnotations,
                viewport: viewport,
                sampleRate: recording.channels.first?.sampleRate ?? 250,
                filter: $filter,
                dispositionStore: dispositionStore,
                isEditing: isEditing
            )
            .inspectorColumnWidth(min: 220, ideal: 320, max: 480)
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
        #if DEBUG
        .task { applyUITestHooks() }
        #endif
    }

    #if DEBUG
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
        let currentWidth = viewport.endSample - viewport.startSample
        let newWidth = Int64(Double(currentWidth) * factor)
        viewport.setWidth(newWidth, anchorFraction: 0.5)
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryHeader
                        findingsOverview
                        ChannelPanel(
                            channel: channel,
                            directory: recordingDirectory,
                            viewport: viewport,
                            annotations: annotationsForChannel(channel),
                            sizing: .focus
                        )
                        // Tear down + rebuild when the focused lead changes —
                        // WaveformCanvas's MTKView caches the previous channel's
                        // sample buffer and the off-scale scanner is per-channel,
                        // so reusing the same SwiftUI identity would leave the
                        // viewer showing stale data after the chip-bar tap.
                        .id(channel.id)
                        trendStrip
                        alarmStrip
                        stateStrip
                        qualityStrip
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "No lead selected",
                    systemImage: "waveform",
                    description: Text("Pick a lead from the bar above.")
                )
            }
        case .strips:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryHeader
                    findingsOverview
                    ForEach(ecgChannels) { channel in
                        ChannelPanel(
                            channel: channel,
                            directory: recordingDirectory,
                            viewport: viewport,
                            annotations: annotationsForChannel(channel),
                            sizing: .strip
                        )
                    }
                    trendStrip
                    alarmStrip
                    stateStrip
                    qualityStrip
                }
                .padding(16)
            }
        }
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

    /// Summary chip row + recording-level finding-density timeline. Both
    /// reuse `recording.annotations` so there's no new derived state to
    /// keep in sync beyond `filter` — toggling a chip narrows the timeline
    /// and the canvas in lockstep.
    @ViewBuilder
    private var findingsOverview: some View {
        if !recording.annotations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FindingsSummaryHeader(
                    summary: unfilteredSummary,
                    filter: $filter,
                    dispositionTally: dispositionStore.tally(for: recording.annotations)
                )
                if let firstChannel = recording.channels.first {
                    FindingDensityTimeline(
                        annotations: filteredAnnotations,
                        totalSamples: firstChannel.sampleCount,
                        sampleRate: firstChannel.sampleRate,
                        viewport: viewport,
                        dispositionsByID: dispositionStore.records
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.thinMaterial)
            )
        }
    }

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
                    isEditing: isEditing
                )
                .accessibilityIdentifier("context-panel")
            }
        }
    }

    private var summaryDetail: String {
        let channelCount = recording.channels.count
        let duration = Self.formatDuration(seconds: totalDurationSeconds)
        let start = recording.channels.first?.startDate
            .formatted(date: .numeric, time: .standard) ?? "—"
        var detail = "\(channelCount) channels  •  \(duration)  •  starts \(start)"
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
    let annotations: [Annotation]
    var sizing: Sizing = .strip

    @State private var clippedRanges: [ClippedRange] = []
    /// Recording-wide min/max for this channel, populated by the same
    /// background scan that builds `clippedRanges`. nil until the scan
    /// finishes (or empty for zero-sample channels). Drives both the
    /// header range badge and the per-channel Y-axis autoscale.
    @State private var sampleRange: MinMaxScanner.Range?
    /// When true, the canvas's display range fits the scanned signal
    /// (plus padding) instead of the fixed ±5 mV clinical reference.
    /// Per-channel state because different leads in a record can have
    /// very different amplitudes (e.g., precordial vs. limb leads).
    @State private var autoscaleY: Bool = false

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
            WaveformTimeAxis(startTime: startTime, endTime: endTime)
                .padding(.leading, 56)
            OverviewRibbon(
                channel: channel,
                directory: directory,
                viewport: viewport,
                annotations: annotations
            )
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channel-panel-\(channel.name)")
        .task { await scanForOffScale() }
    }

    /// Effective display range for the canvas + voltage axis. When
    /// autoscale is off (the default), uses the fixed ±5 mV clinical
    /// reference. When on, derives from the scanned `sampleRange` with
    /// 10% headroom on each side; falls back to the fixed range until
    /// the scan completes.
    private var displayRange: ClosedRange<Double> {
        guard autoscaleY, let range = sampleRange, !range.isEmpty else {
            return Self.yMin...Self.yMax
        }
        return range.displayRange()
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
                        displayMin: displayRange.lowerBound,
                        displayMax: displayRange.upperBound
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

                if let hovered = hoveredAnnotation {
                    AnnotationTooltip(annotation: hovered, sampleRate: channel.sampleRate)
                        .frame(maxWidth: 260, alignment: .leading)
                        .offset(tooltipOffset(in: liveSize))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(panGesture(in: liveSize))
            .gesture(zoomGesture(in: liveSize))
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
        } else {
            hoverIsActive = false
            hoveredAnnotation = nil
        }
    }

    /// 1-px vertical line at the cursor with a floating time label at the
    /// top edge. Receives the canvas size from the enclosing GeometryReader
    /// so the Rectangle can be sized explicitly to the canvas height
    /// (without an explicit height it collapses to ~12 pt and vanishes).
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
                Toggle(isOn: $autoscaleY) {
                    Label("Auto Y", systemImage: "arrow.up.and.down")
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .help(autoscaleY
                      ? "Display range fits this channel's observed amplitude (with 10% headroom). Click to fix at ±5 mV."
                      : "Display range fixed at ±5 mV. Click to fit this channel's observed amplitude.")
                .accessibilityIdentifier("autoscale-y-\(channel.name)")
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
        String(format: "%.2f – %.2f s", startTime, endTime)
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

    private func zoomGesture(in canvasSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
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


