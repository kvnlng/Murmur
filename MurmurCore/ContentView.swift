//
//  ContentView.swift
//  Murmur

import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    @State private var state: AppState = .empty
    @State private var importStates: [String: RecordImportState] = [:]
    @State private var selection: String?
    /// X86 — the one-time crash-loss disclosure, raised the first time a
    /// switch actually carries unsaved notes. `hasSeenCrashLossNotice` is the
    /// per-install acknowledgement; the gate itself (with its UI-test
    /// suppress/force split) is `CrashLossNotice.shouldPresent`.
    @AppStorage(CrashLossNotice.shownDefaultsKey)
    private var hasSeenCrashLossNotice = false
    @State private var showCrashLossNotice = false

    /// X78 — an open intercepted by the unsaved-notes guard, parked as the
    /// action itself (the entry paths carry different payloads — a URL, a
    /// RecentFolder — and the dialog doesn't care which).
    @State private var pendingGuardedOpen: PendingOpen?

    private struct PendingOpen {
        let run: () -> Void
    }
    @State private var isImporterPresented = false
    @State private var errorMessage: String?
    @State private var currentImportTask: Task<Void, Never>?
    @State private var recentsStore = RecentFoldersStore.shared
    /// Bridge for the File → Open Session… menu command (Scene-level, can't
    /// reach this view's state directly). Finder double-clicks arrive via
    /// `.onOpenURL` and share the same `openMurPackage` loader.
    @State private var docCoordinator = SessionDocumentCoordinator.shared
    /// A header-less CSV awaiting metadata from the import dialog.
    @State private var pendingCSV: PendingCSVImport?
    /// X63-B: the record navigator's column state. Held by the app rather than
    /// left to the split view so it can be shown deliberately — a folder open
    /// is exactly when an analyst wants the record list, and without a binding
    /// there was no way back once macOS collapsed it.
    ///
    /// X82: the stored value is the analyst's INTENT; what the split view
    /// shows is `panels.resolution`, which additionally applies the
    /// coexistence rule — below `SidePanelCoexistenceContext.coexistenceWidth`
    /// the navigator and the review-queue inspector cannot both be open
    /// without clipping both of them, so the least-recently-requested one
    /// yields entirely.
    @State private var panels = SidePanelCoexistenceContext.shared
    /// X63-C: per-record session state + provenance from an opened `.mur`,
    /// keyed by the same id the navigator and `importStates` use. Staged into
    /// `CurrentRecordingContext` as each record is activated, so every record
    /// restores ITS OWN paper rather than the active one's.
    @State private var sessionStates: [String: MurSessionState] = [:]
    @State private var sessionProvenances: [String: MurProvenance] = [:]
    /// X4b: the once-only first-launch RUO disclosure. Set on acknowledge,
    /// never re-prompted (see RUOFirstRunNotice for the rule framing).
    @AppStorage(RUOFirstRunNotice.acknowledgedDefaultsKey)
    private var hasAcknowledgedRUONotice = false
    @State private var showRUONotice = false

    struct PendingCSVImport: Identifiable {
        let id = UUID()
        let url: URL
        let columnCount: Int
        var refusalMessage: String?
    }

    public init() {}

    /// X4b: present the first-run RUO notice when the gate says so. The
    /// force/suppress split lives in `RUOFirstRunNotice.shouldPresent`;
    /// outside DEBUG there is no force path and no UI-test suppression.
    private func presentRUONoticeIfNeeded() {
        #if DEBUG
        showRUONotice = RUOFirstRunNotice.shouldPresent(
            hasAcknowledged: hasAcknowledgedRUONotice,
            isUITestRun: UITestSupport.isRunningUITest,
            forcedByTest: UITestSupport.forceFirstRunRUO
        )
        #else
        showRUONotice = RUOFirstRunNotice.shouldPresent(
            hasAcknowledged: hasAcknowledgedRUONotice,
            isUITestRun: false,
            forcedByTest: false
        )
        #endif
    }

    enum AppState {
        case empty
        // X63-C: `browsing` is no longer folder-only. An opened multi-record
        // `.mur` lands here too, so the navigator, the flag and the detail
        // pane all stay one code path — the spec's "populate the EXISTING
        // record sidebar, do not build a second record list".
        case browsing(source: RecordListSource, records: [RecordListEntry])
        case directView(directory: URL, recording: Recording)
    }

    enum RecordImportState {
        case importing(progress: ImportProgress?)
        case imported(directory: URL, recording: Recording)
        case failed(message: String)
    }

    public var body: some View {
        Group {
            switch state {
            case .empty:
                emptyShell
            case .browsing(let source, let records):
                browseShell(source: source, records: records)
            case .directView(let directory, let recording):
                directShell(directory: directory, recording: recording)
            }
        }
        .overlay(alignment: .topLeading) {
            #if DEBUG
            urlLauncherProbe
            #endif
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder]
        ) { result in
            handleFolderPick(result)
        }
        .alert(
            "Couldn't open record folder",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            #if DEBUG
            await WindowSizing.applyTestWindowPolicy()
            loadUITestSampleIfRequested()
            openUITestPathIfRequested()
            openUITestSessionIfRequested()
            openUITestCSVIfRequested()
            openUITestHeaderlessCSVIfRequested()
            #endif
            presentRUONoticeIfNeeded()
        }
        // The acknowledge button is the only way out — an Esc-dismissal
        // would silently re-queue the notice for next launch.
        .sheet(isPresented: $showRUONotice) {
            RUOFirstRunView {
                hasAcknowledgedRUONotice = true
                showRUONotice = false
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $pendingCSV) { pending in
            CSVImportDialog(
                fileName: pending.url.lastPathComponent,
                columnCount: pending.columnCount,
                refusalMessage: pending.refusalMessage,
                onImport: { draft in importCSV(pending, draft: draft) },
                onCancel: { pendingCSV = nil }
            )
        }
        // Finder double-click / `open` routes here (both .mur and .csv).
        //
        // Each open is deferred to the next main-runloop turn with a
        // `@MainActor` Task. These handlers fire during SwiftUI's view update,
        // which runs inside a CoreAnimation transaction commit; opening a
        // sealed `.mur` presents an `NSAlert` passphrase prompt, and AppKit
        // SUPPRESSES `runModal()` inside a commit — the prompt never shows and
        // the open silently no-ops. Hopping off the commit lets the modal run.
        .onOpenURL { url in Task { @MainActor in runGuardingUnsavedNotes { open(url) } } }
        // File → Open Session… / Import CSV… bridge through the coordinator.
        .onChange(of: docCoordinator.openRequestURL) { _, url in
            guard let url else { return }
            docCoordinator.openRequestURL = nil
            Task { @MainActor in runGuardingUnsavedNotes { open(url) } }
        }
        // File → Open Recent (X22): reuse `reopen` so the bookmark is resolved
        // and read in one scoped call.
        .onChange(of: docCoordinator.reopenRecentRequest) { _, entry in
            guard let entry else { return }
            docCoordinator.reopenRecentRequest = nil
            Task { @MainActor in runGuardingUnsavedNotes { reopen(entry) } }
        }
        // X78 — the open-side half of the unsaved-anchored-notes guard
        // (#117). Same check and copy family as the X77 quit and
        // record-switch guards, so the three warnings read as one behaviour.
        .confirmationDialog(
            "Open with unsaved anchored notes?",
            isPresented: Binding(
                get: { pendingGuardedOpen != nil },
                set: { if !$0 { pendingGuardedOpen = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard and Open", role: .destructive) {
                guard let pending = pendingGuardedOpen else { return }
                pendingGuardedOpen = nil
                // Explicit discard, same reasoning as X77: the quit guard
                // must not later warn about notes that are already gone.
                // X86: that now includes the carried set — an open tears
                // down every record's in-memory work, not just the open one.
                CurrentRecordingContext.shared.liveSessionState.anchoredNotes = nil
                CarriedSessionStore.shared.reset()
                pending.run()
            }
            Button("Cancel", role: .cancel) { pendingGuardedOpen = nil }
        } message: {
            Text("Anchored notes save with the session — File ▸ Save Session (⌘S). Opening something else discards them, on every record in this session.")
        }
    }

    /// X78 — run `action` now, or park it behind the confirmation when the
    /// open would tear down unsaved anchored notes. One guard at the choke
    /// point rather than one per entry path: Finder opens, Open Record… /
    /// Open Session… / Import CSV…, Open Recent, and the toolbar Open
    /// button's folder pick all pass through here.
    ///
    /// X86: "unsaved" now means the whole working set — the open record OR
    /// any record parked in `CarriedSessionStore` with unsaved notes.
    private func runGuardingUnsavedNotes(_ action: @escaping () -> Void) {
        if CurrentRecordingContext.shared.hasUnsavedAnchoredNotes
            || !CarriedSessionStore.shared.unsavedRecordIDs.isEmpty {
            pendingGuardedOpen = PendingOpen(run: action)
        } else {
            action()
        }
    }

    /// Dispatches an opened URL: `.csv` converts through the CSV importer, a
    /// `.mur` package reopens as a session, and a plain directory is treated
    /// as a WFDB record folder (the File → Open Record… path). Anything else
    /// falls back to the `.mur` reader, unchanged.
    private func open(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "csv" {
            openCSV(url)
        } else if ext == "mur" {
            openMurPackage(url)
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            // A `.mur` package is also a directory on disk, but it carries the
            // `mur` extension and is handled above; a bare directory here is a
            // folder of WFDB records.
            openFolder(url)
        } else {
            openMurPackage(url)
        }
    }

    /// The free viewer's CSV on-ramp. A CSV that carries a complete `#` header
    /// block converts + presents directly; a header-less one opens the import
    /// dialog to collect the metadata (the RUO surface). Any other refusal
    /// surfaces its single reason.
    private func openCSV(_ url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't read \(url.lastPathComponent)."
            return
        }
        do {
            let parsed = try CSVImport.parse(data: data, dialogMetadata: nil)
            try presentParsedCSV(parsed, url: url)
        } catch let refusal as CSVImport.Refusal where refusal.reason == .incompleteMetadata {
            pendingCSV = PendingCSVImport(
                url: url,
                columnCount: CSVImport.detectColumnCount(data: data) ?? 0,
                refusalMessage: nil
            )
        } catch let refusal as CSVImport.Refusal {
            errorMessage = refusal.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-parses the pending CSV with the dialog-supplied metadata and presents
    /// it. A refusal keeps the dialog open with the reason (same sheet identity
    /// so the analyst's edits survive) rather than starting over.
    private func importCSV(_ pending: PendingCSVImport, draft: CSVImport.Draft) {
        let url = pending.url
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            pendingCSV = nil
            errorMessage = "Couldn't read \(url.lastPathComponent)."
            return
        }
        do {
            let metadata = try draft.metadata(columnCount: pending.columnCount)
            let parsed = try CSVImport.parse(data: data, dialogMetadata: metadata)
            pendingCSV = nil
            try presentParsedCSV(parsed, url: url)
        } catch let refusal as CSVImport.Refusal {
            pendingCSV?.refusalMessage = refusal.message
        } catch {
            pendingCSV = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Converts a parsed CSV to a WFDB record in a scratch dir, imports it, and
    /// presents it — the same `directView` path everything else uses.
    private func presentParsedCSV(_ parsed: CSVImport.Parsed, url: URL) throws {
        let recordName = sanitizedRecordName(url.deletingPathExtension().lastPathComponent)
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let heaURL = try CSVImport.writeWFDBRecord(parsed, recordName: recordName, in: workingDirectory)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: workingDirectory)
        setAppState(.directView(directory: summary.directory, recording: summary.recording))
    }

    /// WFDB record names are bare tokens; map anything else to `_`.
    private func sanitizedRecordName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? "csv" : mapped
    }

    // MARK: - Native .mur session open

    /// Reads a `.mur` document package into a scratch working directory, loads
    /// its recording, and presents it — the same `directView` path the folder
    /// import and sample fixture use. The working directory must outlive the
    /// viewing session (channel binaries are read lazily from it), so it lives
    /// under a unique temp subdirectory rather than being cleaned up here.
    private func openMurPackage(_ url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            let workingDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mur-session-\(UUID().uuidString)", isDirectory: true)
            // Cancelling the passphrase prompt yields nil — "not now", not a
            // failure, so nothing is surfaced.
            guard let result = try SessionPackageOpener.read(
                packageURL: url, into: workingDirectory,
                prompt: { retry in
                    SessionPassphrasePrompt.askToOpen(
                        fileName: url.lastPathComponent, retryAfterFailure: retry
                    ).map { .passphrase($0) } ?? .cancelled
                }
            ) else { return }
            // X63-C: surface EVERY record through the same navigator a folder
            // open uses — the spec's "populate the EXISTING record sidebar, do
            // not build a second record list". Each record was reconstituted to
            // its own directory by `read`, so all of them are already
            // "imported": pre-populating `importStates` is what lets selection,
            // the flag and the detail pane stay one code path.
            let plan = try SessionOpenPlan.make(from: result) {
                try RecordingStore.shared.loadManifest(at: $0)
            }

            currentImportTask?.cancel()
            importStates = plan.records.reduce(into: [:]) { states, record in
                states[record.id] = .imported(directory: record.directory, recording: record.recording)
            }
            sessionStates = plan.records.reduce(into: [:]) { states, record in
                states[record.id] = record.sessionState
            }
            sessionProvenances = plan.records.reduce(into: [:]) { store, record in
                store[record.id] = record.provenance
            }
            // A session is its own working set; flags from a previously-open
            // folder do not belong to it. Neither does carried unsaved work —
            // the X78 guard already adjudicated it before this open ran.
            SessionFlagStore.shared.reset()
            CarriedSessionStore.shared.reset()
            for record in plan.records {
                SessionFlagStore.shared.register(
                    FlaggedRecord(id: record.id, recording: record.recording, directory: record.directory)
                )
                // FLAGGED, not merely registered. The records in a session ARE
                // the analyst's set — that is what saving them together meant.
                // Leaving them unflagged makes File → Save Session write only
                // the open record, so opening a 4-record session and saving it
                // again would silently drop three. A round-trip must not lose
                // records.
                SessionFlagStore.shared.flag(record.id)
            }
            setAppState(.browsing(source: .session(url), records: plan.records.map(\.entry)))

            // Land on the record the analyst had open when they saved.
            selection = plan.activeID
            // X96: publish + stage EXPLICITLY. The comment that used to sit
            // here claimed setting `selection` drives `handleSelectionChanged`
            // — it does not on THIS path: the browsing view mounts with the
            // selection already set, so its `.onChange(of: selection)` sees
            // no change and never fires for the record the package opens on.
            // Every restore of the active record's saved state (viewport,
            // paper, lead, notes) silently depended on that never-firing
            // handler; clicking any other row and coming back was the only
            // thing that made it work. Found while giving the lead overlay a
            // round-trip test — the first end-to-end coverage this seam had.
            handleSelectionChanged(plan.activeID, source: .session(url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Assign `AppState` and mirror the transition into
    /// `CurrentRecordingContext.shared` in one atomic step. Every
    /// call site that used to write to `state` directly goes through
    /// this instead so auxiliary windows (ECG Metrics, etc.) reliably
    /// see the recording change — the previous `.onChange` approach
    /// depended on SwiftUI observation that didn't fire on all
    /// state transitions in practice.
    private func setAppState(_ newState: AppState) {
        state = newState
        switch newState {
        case .directView(let dir, let recording):
            CurrentRecordingContext.shared.set(recording: recording, directory: dir)
        case .empty, .browsing:
            CurrentRecordingContext.shared.clear()
        }
    }

    // MARK: - Shells

    // #242 / 12a: the launch shell. The welcome card that used to render
    // here is gone — see LaunchShellView's header for the product call and
    // what happened to each of the card's entry points. Recents live in
    // File ▸ Open Recent; drag-a-folder and the sample recording were
    // removed deliberately.
    private var emptyShell: some View {
        NavigationStack {
            LaunchShellView(onOpenFolder: { isImporterPresented = true })
                .navigationTitle("Murmur")
                .toolbar(id: MurmurToolbar.identifier) {
                    overflowToolbarItems
                    // #285 / 12a: the frame never moves — the bedside's
                    // whole item set exists at launch, idle. See
                    // `IdleToolbarItems` for why this is a mirror and how
                    // it is kept from drifting.
                    IdleToolbarItems()
                }
        }
    }

    /// #285 — true when a `BedsideView` is on screen and therefore
    /// registering the live toolbar items. The idle set mounts exactly when
    /// this is false; both at once would register duplicate ids.
    private var isBedsideMounted: Bool {
        switch state {
        case .empty:
            return false
        case .directView:
            return true
        case .browsing:
            guard let key = selection, case .imported = importStates[key] else { return false }
            return true
        }
    }

    #if DEBUG
    /// DEBUG-only since #242: the welcome card's "Try a sample recording"
    /// button was the last user-reachable caller. The whole UI suite still
    /// launches through this via `--ui-test-sample`, so the function must
    /// survive — but a Release ARCHIVE must not compile an uncalled path
    /// whose only remaining caller sits inside `#if DEBUG` (the exact
    /// archive-time trap documented on `richVariantParameters` below).
    private func loadSampleFixture() {
        do {
            let directory = try SyntheticRecording.makeFixture()
            let recording = try RecordingStore.shared.loadManifest(at: directory)
            setAppState(.directView(directory: directory, recording: recording))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    #if DEBUG
    // Test-fixture plumbing only — `UITestSupport` (and these two helpers'
    // sole callers in `applyUITestHooks`) exist only in DEBUG, so a Release
    // ARCHIVE must not compile them. The PR test suites build Debug, which
    // is why an unguarded reference here survives every green Cloud test
    // run and fails only at archive time.
    /// X105 (#176): the canned edge-state fixtures behind
    /// `--ui-test-sample-rich=<variant>`. Constructed states, not inject
    /// flags — each is an ordinary record the app opens through the real
    /// import path.
    private static func richVariantParameters(
        _ variant: UITestSupport.RichSampleVariant
    ) -> (parameters: SyntheticECG.Parameters, leadRenames: [String: String]) {
        switch variant {
        case .flatline:
            // A 15 s full disconnect mid-record: every lead flat, artifact
            // lane at 0.9 in agreement — the flat-line lane-plot state.
            return (SyntheticECG.Parameters(flatlineSpans: [.init(range: 60...75)]), [:])
        case .dropout:
            // The DEFAULT PRIMARY lead is the dead one, deliberately — this
            // is the primary-lead-fallback / flat-panel surface, not just a
            // quiet overlay entry.
            return (SyntheticECG.Parameters(droppedLeads: ["I"]), [:])
        case .noConventional:
            // X109 (§2.4): lead II renamed to a telemetry-style MCL1 — the
            // generated record carries NO conventional QT lead, so automated
            // QT abstains and the manual-caliper override is the only path
            // to a QT number.
            return (SyntheticECG.Parameters(), ["II": "MCL1"])
        case .twoMorphology:
            // X112c: two wide-complex runs (X104 machinery, beats coded "V")
            // long enough that the second shape clears the panel's fold rule
            // (≥ 30 beats and ≥ 1% burden) — a genuine second conduction the
            // analyst can endorse as a second baseline mode.
            return (SyntheticECG.Parameters(
                wideComplexRuns: [.init(range: 40...55), .init(range: 100...115)]), [:])
        }
    }

    /// X99 — same shape as `loadSampleFixture`, but generation + import of a
    /// minutes-long record is real work, so it runs off-main behind a brief
    /// empty state rather than blocking the first frame.
    private func loadRichSampleFixture(
        parameters: SyntheticECG.Parameters,
        leadRenames: [String: String] = [:]
    ) {
        Task { @MainActor in
            do {
                let directory = try await Task.detached(priority: .userInitiated) {
                    try SyntheticRecording.makeRichFixture(
                        parameters: parameters, leadRenames: leadRenames)
                }.value
                let recording = try RecordingStore.shared.loadManifest(at: directory)
                setAppState(.directView(directory: directory, recording: recording))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    #endif

    private func browseShell(source: RecordListSource, records: [RecordListEntry]) -> some View {
        // X63-B: the record navigator was not appearing when a folder opened —
        // no rows in the accessibility tree and no splitter in the window, on a
        // real 48-record MIT-BIH directory opened through File → Open Record….
        // Verified longstanding, not a regression: the same probe returns
        // nothing on the commit before the X60 toolbar work.
        //
        // The split view had no `columnVisibility` binding, so once macOS
        // collapsed the column nothing could bring it back — the app ships no
        // `SidebarCommands()` either, so there was no menu item and no toolbar
        // toggle. Holding the binding here makes the navigator's visibility
        // state the app's to control; `SidebarCommands()` in MurmurApp gives
        // the analyst the View ▸ Show/Hide Sidebar item to drive it.
        //
        // This matters beyond navigation: the Save Session flag lives on a
        // sidebar row, so a navigator that cannot be shown is a feature that
        // cannot be reached.
        NavigationSplitView(columnVisibility: navigatorVisibilityBinding) {
            RecordSidebar(records: records, importStates: importStates, selection: $selection)
                .navigationTitle(source.displayName)
                .navigationSplitViewColumnWidth(min: 160, ideal: 240, max: 320)
                // X81: suppress the split view's own sidebar toggle. With the
                // persistent toggle below, the toolbar carried TWO adjacent
                // sidebar buttons while the navigator was open. The system one
                // is the wrong one to keep: it lives in the sidebar's toolbar
                // region and vanishes with the collapsed column (verified on
                // macOS 26 — the X63-B trap is still real), so it can hide
                // the navigator but never bring it back.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailPane
                .navigationTitle(detailTitle)
                .toolbar(id: MurmurToolbar.identifier) {
                    overflowToolbarItems
                    // #285: the frame holds through browse-with-no-selection
                    // too — the idle set stands in until the selected record
                    // finishes importing and BedsideView takes over the ids.
                    if !isBedsideMounted {
                        IdleToolbarItems()
                    }
                }
                // Persistent record-list toggle. The sidebar-toggle button
                // NavigationSplitView injects lives in the sidebar's own
                // toolbar region, so it collapses together with the column —
                // once hidden there is no icon left to bring the record list
                // back. This one lives on the detail side, which stays on
                // screen, and records the analyst's intent with the
                // coexistence context so it toggles both ways regardless of
                // responder-chain state.
                .toolbar { sidebarToggleToolbarItem }
        }
        .onChange(of: selection) { oldValue, newValue in
            // X86 (#135) — switching records no longer interrupts. The X77
            // record-switch confirmation used to stand here, because the
            // switch tears down BedsideView's @State, where unsaved notes
            // live. Now the outgoing record's live state is PARKED instead
            // (viewport, paper, and notes ride together), re-applied when
            // the analyst comes back, and written by File ▸ Save Session.
            // The quit and open guards still warn — over the whole
            // in-memory set, not just the record on screen.
            if let oldValue, oldValue != newValue {
                carrySessionState(forRecordID: oldValue)
            }
            handleSelectionChanged(newValue, source: source)
        }
        // X86 — the one-time crash-loss disclosure, raised by the first
        // switch that actually carries unsaved notes. One acknowledgement,
        // per install: unsaved work living in memory is the app's standing
        // behaviour now, not a per-switch decision.
        .alert(CrashLossNotice.title, isPresented: $showCrashLossNotice) {
            Button("OK") { showCrashLossNotice = false }
        } message: {
            Text(CrashLossNotice.message)
        }
        // X82: the coexistence rule needs the real window content width —
        // and needs to know a navigator exists (the direct shell has none,
        // and a stale narrow width must not arbitrate against it there).
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            panels.windowContentWidth = width
        }
        .onAppear { panels.navigatorPresent = true }
        .onDisappear { panels.navigatorPresent = false }
    }

    /// X82: what the split view SHOWS. Reads the coexistence resolution;
    /// writes back as analyst intent (View ▸ Show/Hide Sidebar and the split
    /// view's own drag-collapse both land here).
    private var navigatorVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { panels.resolution.navigatorVisible ? .all : .detailOnly },
            // Same echo guard as the inspector binding: only a write that
            // disagrees with the resolution is analyst intent.
            set: { newValue in
                let open = newValue != .detailOnly
                guard open != panels.resolution.navigatorVisible else { return }
                panels.request(.navigator, open: open)
            }
        )
    }

    /// A leading toolbar button that shows or hides the record navigator by
    /// recording the analyst's intent with the coexistence context. Placed on
    /// the detail pane so it survives the sidebar collapsing.
    @ToolbarContentBuilder
    private var sidebarToggleToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation {
                    panels.request(.navigator, open: !panels.resolution.navigatorVisible)
                }
            } label: {
                Label("Toggle Record List", systemImage: "sidebar.leading")
            }
            .help("Show or hide the record list")
            .accessibilityIdentifier("toolbar-sidebar-toggle")
        }
    }

    private func directShell(directory: URL, recording: Recording) -> some View {
        NavigationStack {
            BedsideView(
                recording: recording,
                recordingDirectory: directory,
                // X16: a gain reinterpretation mutates the manifest; the
                // view's own `recording` is this state's copy, so the state
                // must adopt the mutation for the panels to re-render.
                onRecordingMutated: { setAppState(.directView(directory: directory, recording: $0)) }
            )
                .navigationTitle(recording.device)
                .toolbar(id: MurmurToolbar.identifier) { overflowToolbarItems }
        }
    }

    private static let openFolderHelp =
        "Open a folder of WFDB records (.hea / .dat)"

    /// The overflow menu and the open-folder button it now contains.
    ///
    /// X68 moved Open Record Folder off the toolbar's top level: it is a
    /// once-per-session action sitting among per-record ones. The standalone
    /// item stays REGISTERED but hidden by default, for the same reason the
    /// two collapsed exports do — the id is persisted in saved toolbar
    /// layouts, and an analyst who wants it back as a labelled button can drag
    /// it out of Customize Toolbar…
    ///
    /// Contributed by `ContentView`, not `BedsideView`, because it must be
    /// reachable with no recording open — which is exactly when opening a
    /// folder is the only thing left to do.
    @ToolbarContentBuilder
    private var overflowToolbarItems: some CustomizableToolbarContent {
        ToolbarItem(id: "toolbar-more", placement: .automatic, showsByDefault: true) {
            Menu {
                Button("Open Record Folder…") { isImporterPresented = true }
                    .accessibilityIdentifier("toolbar-open-button-item")
                Divider()
                Button("Customize Toolbar…") { runToolbarCustomization() }
                    .accessibilityIdentifier("toolbar-customize-item")
            } label: {
                Label("More", systemImage: ToolbarGlyph.moreActions)
            }
            .help("Open a record folder, customise this toolbar")
            .accessibilityIdentifier("toolbar-more")
        }
        ToolbarItem(id: "toolbar-open-button", placement: .automatic, showsByDefault: false) {
            Button {
                isImporterPresented = true
            } label: {
                Label("Open Record Folder", systemImage: ToolbarGlyph.openRecordFolder)
            }
            // X60: this button had NO hover text at all — not the `.help()`
            // rendering bug, simply never written. It also carried
            // `doc.badge.plus`, pixel-identical to the bedside "Attach
            // findings…" button two positions away, which is why two
            // unrelated actions were indistinguishable.
            .help(Self.openFolderHelp)
            .accessibilityIdentifier("toolbar-open-button")
        }
    }

    /// Opens AppKit's own customisation palette.
    ///
    /// macOS already puts this in the View menu, but the design asks for it
    /// here too: the toolbar is where an analyst is looking when they decide
    /// they want it different, and with `.help()` broken the customisation
    /// sheet is also the only route to visible labels.
    private func runToolbarCustomization() {
        NSApp.keyWindow?.toolbar?.runCustomizationPalette(nil)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let key = selection {
            switch importStates[key] {
            case .importing(let progress):
                importingPane(progress: progress)
            case .imported(let directory, let recording):
                BedsideView(
                    recording: recording,
                    recordingDirectory: directory,
                    // X16: same adoption as the direct view, into this
                    // folder-entry's import cache.
                    onRecordingMutated: { updated in
                        importStates[key] = .imported(directory: directory, recording: updated)
                        CurrentRecordingContext.shared.set(recording: updated, directory: directory)
                    }
                )
                    .id(recording.id)
            case .failed(let message):
                failedPane(message: message, filename: key)
            case .none:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                "Select a record",
                systemImage: "list.bullet.rectangle",
                description: Text("Pick a record from the sidebar to view its signals.")
            )
        }
    }

    private func importingPane(progress: ImportProgress?) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress?.fractionComplete ?? 0)
                .frame(maxWidth: 240)
            Text(progress.map { "Importing… \(Int(($0.fractionComplete * 100).rounded()))%" } ?? "Importing…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedPane(message: String, filename: String) -> some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Button("Retry") {
                // Only a folder record can be re-imported; a session record's
                // bytes came out of the package and there is nothing to retry.
                if case .browsing(.folder(let folder), _) = state {
                    startImport(filename: filename, source: folder)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailTitle: String {
        guard let key = selection else { return "Murmur" }
        if case .imported(_, let recording) = importStates[key] {
            return recording.device
        }
        // X56 §6: the selection tag is the `.hea` FILENAME; the window
        // represents a record, not a header file, so title by the record name.
        // (The imported path above already uses `recordName`, which carries no
        // extension — this makes the pre-import title agree with it.)
        return (key as NSString).deletingPathExtension
    }

    // MARK: - Folder + selection handling

    private func handleFolderPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let folderURL):
            // X78: the toolbar Open button reaches here with a recording
            // (and possibly unsaved notes) still open.
            runGuardingUnsavedNotes { openFolder(folderURL) }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Common open-folder path used by both the file picker and the
    /// recents list. Records the folder in `recentsStore` on success so
    /// every successful open gets a one-click re-entry next launch.
    private func openFolder(_ folderURL: URL) {
        do {
            let records = try scanFolder(folderURL)
            guard !records.isEmpty else {
                errorMessage = "No WFDB records (.hea files) found in \(folderURL.lastPathComponent)."
                return
            }
            currentImportTask?.cancel()
            importStates = [:]
            // X63-B: a flag says "this record belongs in my session", and a
            // session is scoped to the folder being worked. A different folder
            // is a different working set.
            SessionFlagStore.shared.reset()
            CarriedSessionStore.shared.reset()
            sessionStates = [:]
            sessionProvenances = [:]
            setAppState(.browsing(source: .folder(folderURL), records: records.map(RecordListEntry.init)))
            recentsStore.record(folder: folderURL)
            let firstFilename = records.first?.filename
            selection = firstFilename
            if let firstFilename {
                startImport(filename: firstFilename, source: folderURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resolves a recents-row bookmark and routes it through the same
    /// open-folder path as a fresh pick. Drops the entry if the bookmark
    /// is unrecoverable.
    private func reopen(_ entry: RecentFolder) {
        guard let url = recentsStore.resolve(entry) else {
            recentsStore.remove(entry)
            errorMessage = "Couldn't reopen \(entry.displayName) — the folder may have moved or its access was revoked."
            return
        }
        openFolder(url)
    }

    private func scanFolder(_ folderURL: URL) throws -> [WFDBRecordEntry] {
        let needsScope = folderURL.startAccessingSecurityScopedResource()
        defer { if needsScope { folderURL.stopAccessingSecurityScopedResource() } }
        let files = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let heaURLs = files
            .filter { $0.pathExtension.lowercased() == "hea" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return heaURLs.compactMap { url -> WFDBRecordEntry? in
            guard let header = try? WFDBHeaderParser.parse(url: url) else { return nil }
            return WFDBRecordEntry(filename: url.lastPathComponent, header: header)
        }
    }

    /// Called when the sidebar selection changes.
    private func handleSelectionChanged(_ filename: String?, source: RecordListSource) {
        // The browsing view keeps `state` at `.browsing` and shows the
        // picked record inline in its detail pane — the whole
        // browse-then-select flow never transitions state to
        // `.directView`. Push the currently-visible recording into
        // `CurrentRecordingContext` here so auxiliary windows
        // (ECG Metrics, etc.) can react.
        guard let filename else {
            CurrentRecordingContext.shared.clear()
            return
        }
        switch importStates[filename] {
        case .imported(let dir, let recording):
            CurrentRecordingContext.shared.set(recording: recording, directory: dir)
            // X63-C: hand this record's OWN saved viewport + paper to the
            // bedside view. `project_standard_view_is_the_open_state.md` says a
            // `.mur` restores the analyst's paper rather than snapping to
            // Standard View; with many records in a package that rule applies
            // per record, on each activation — not once at open.
            stageSessionRestore(for: filename)
        case .importing:
            return     // waiting for startImport's completion to fire the set
        default:
            // Only a folder record needs importing. A session record was
            // reconstituted when the package opened, so reaching here for one
            // means its subtree is missing — surface that rather than kicking
            // off a WFDB import that has no `.hea` to read.
            switch source {
            case .folder(let folder):
                startImport(filename: filename, source: folder)
            case .session:
                errorMessage = "That recording is missing from this session file."
            }
        }
    }

    /// X86 — park the outgoing record's live state as the analyst switches
    /// away, so the switch loses nothing. The snapshot in
    /// `liveSessionState` is still the OLD record's at this moment: the
    /// incoming bedside view hasn't mounted, and only it republishes.
    ///
    /// Guarded on the context actually showing the record being left —
    /// clicking past a still-importing record must not park another
    /// record's state under its id.
    private func carrySessionState(forRecordID id: String) {
        let context = CurrentRecordingContext.shared
        guard case .imported(_, let recording) = importStates[id],
              context.recording?.id == recording.id else { return }
        CarriedSessionStore.shared.carry(
            recordID: id,
            state: context.liveSessionState,
            savedNotes: context.sessionSavedNotes
        )
        guard context.hasUnsavedAnchoredNotes else { return }
        // Carried unsaved notes ARE analyst work, so the record joins the
        // save set by default (a default, not a lock — an explicit unflag
        // stays unflagged). Under X87 this is a backstop: selection already
        // applied the default when the record imported, so this only
        // matters for a path where notes exist without that having fired.
        SessionFlagStore.shared.applyDefaultFlag(for: id)
        presentCrashLossNoticeIfNeeded()
    }

    /// X86 — one disclosure, the first time a switch carries unsaved work.
    private func presentCrashLossNoticeIfNeeded() {
        #if DEBUG
        let present = CrashLossNotice.shouldPresent(
            hasSeen: hasSeenCrashLossNotice,
            isUITestRun: UITestSupport.isRunningUITest,
            forcedByTest: UITestSupport.forceCrashLossNotice
        )
        #else
        let present = CrashLossNotice.shouldPresent(
            hasSeen: hasSeenCrashLossNotice,
            isUITestRun: false,
            forcedByTest: false
        )
        #endif
        guard present else { return }
        hasSeenCrashLossNotice = true
        showCrashLossNotice = true
    }

    /// Stage the per-record session state an opened `.mur` carried, if any.
    /// Consumed by the bedside view on appear (X59), so a later re-render can
    /// not re-apply a stale restore over the analyst's own navigation.
    ///
    /// X86: state parked by a record switch outranks the `.mur`'s — it is
    /// the same record, later. Consuming the parked entry (rather than
    /// reading it) is what keeps `CarriedSessionStore` from double-counting
    /// the on-screen record's notes or restoring stale state over newer
    /// work; the carried saved-notes baseline rides along so the restore
    /// doesn't mark unsaved notes as durable.
    private func stageSessionRestore(for id: String) {
        let context = CurrentRecordingContext.shared
        if let carried = CarriedSessionStore.shared.consume(recordID: id) {
            context.pendingSessionRestore = carried.state
            context.pendingCarriedNotesBaseline = .init(notes: carried.savedNotes)
        } else if let state = sessionStates[id] {
            context.pendingSessionRestore = state
        }
        if let provenance = sessionProvenances[id] {
            context.restoredProvenance = provenance
        }
    }

    /// #263 — the info bar's global import strip. Counts the folder plan
    /// around the in-flight record: completed = records already imported,
    /// total = every record the sidebar lists.
    private func publishImportProgress(filename: String, fraction: Double) {
        let completed = importStates.values.filter {
            if case .imported = $0 { return true }
            return false
        }.count
        let total: Int
        if case .browsing(_, let records) = state {
            total = records.count
        } else {
            total = max(completed + 1, 1)
        }
        ImportProgressContext.shared.update(
            recordName: (filename as NSString).deletingPathExtension,
            fractionComplete: fraction,
            completedRecords: completed,
            totalRecords: total
        )
    }

    private func startImport(filename: String, source folder: URL) {
        importStates[filename] = .importing(progress: nil)
        publishImportProgress(filename: filename, fraction: 0)
        currentImportTask?.cancel()
        currentImportTask = Task {
            do {
                let summary = try await RecordingStore.shared.importWFDB(
                    folderURL: folder,
                    heaFilename: filename,
                    progress: { snapshot in
                        Task { @MainActor in
                            if case .importing = importStates[filename] {
                                importStates[filename] = .importing(progress: snapshot)
                                publishImportProgress(
                                    filename: filename,
                                    fraction: snapshot.fractionComplete
                                )
                            }
                        }
                    }
                )
                await MainActor.run {
                    importStates[filename] = .imported(directory: summary.directory, recording: summary.recording)
                    // #263 — the strip unmounts when nothing is in flight.
                    ImportProgressContext.shared.clear()
                    // X63-B: only an imported record can be saved, so this is
                    // where it becomes flaggable.
                    SessionFlagStore.shared.register(
                        FlaggedRecord(
                            id: filename,
                            recording: summary.recording,
                            directory: summary.directory
                        )
                    )
                    // X87: SELECTING a record for review includes it in the
                    // save set by default — the analyst unflags to exclude.
                    // Folder imports are lazy, driven by sidebar clicks, so
                    // every record reaching this completion was selected;
                    // applying the default here (rather than on the click)
                    // also covers the record that finished importing after
                    // the analyst moved on. Once-only, analyst-wins: an
                    // explicit unflag survives revisits. This supersedes the
                    // X63-B disk probe, which pre-flagged only records whose
                    // bundle carried prior analyst work — a subset of
                    // "selected", since import is what makes a bundle.
                    SessionFlagStore.shared.applyDefaultFlag(for: filename)
                    // If this import corresponds to the record currently
                    // selected in the browsing sidebar, publish it as the
                    // current recording so ECG Metrics + friends light up.
                    if selection == filename {
                        CurrentRecordingContext.shared.set(
                            recording: summary.recording,
                            directory: summary.directory
                        )
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        importStates[filename] = .failed(message: error.localizedDescription)
                        // #263 — a failed import is no longer in flight.
                        ImportProgressContext.shared.clear()
                    }
                }
            }
        }
    }

    #if DEBUG
    /// Hidden 1pt overlay that echoes `URLLauncher.shared.lastLaunchedURL`
    /// onto an accessibility element. Lets XCUI assert "the Privacy Policy
    /// command targets the right URL" without launching a browser. The view
    /// is always mounted in DEBUG so reading the property establishes
    /// observation regardless of which launch args are set; the launcher
    /// itself no-ops on actual `open` calls when `--ui-test-record-urls` is
    /// present.
    private var urlLauncherProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("ui-test-last-launched-url")
            .accessibilityLabel(URLLauncher.shared.lastLaunchedURL?.absoluteString ?? "")
            .accessibilityHidden(false)
    }

    private func loadUITestSampleIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        // X99: the rich fixture outranks the plain one when both are passed —
        // a test asking for realism means it.
        if let variant = UITestSupport.richSampleVariant {
            let variantSpec = Self.richVariantParameters(variant)
            loadRichSampleFixture(parameters: variantSpec.parameters,
                                  leadRenames: variantSpec.leadRenames)
            return
        }
        if let seconds = UITestSupport.richSampleDurationSeconds {
            loadRichSampleFixture(parameters: SyntheticECG.Parameters(durationSeconds: seconds))
            return
        }
        if args.contains("--ui-test-sample") {
            loadSampleFixture()
            attachFindingsIfRequested()
            return
        }
        if args.contains("--ui-test-seed-recent") {
            seedRecentForTesting()
            return
        }
        if args.contains(where: { $0.hasPrefix("--ui-test-open-folder") }) {
            openSyntheticFolderForTesting()
            return
        }
        if args.contains("--ui-test-prep-large-fixture") {
            prepLargeFixtureForTesting()
            return
        }
        if args.contains("--ui-test-load-prepped-bundle") {
            loadPreppedLargeBundleForTesting()
        }
    }

    /// `--ui-test-open-sample-session`: package a synthetic fixture into a
    /// `.mur` and open it through the real loader, so an XCUI test can assert
    /// the full read → loadManifest → present chain (the NSOpenPanel itself is
    /// XCUI-hostile, like the folder picker).
    /// `--ui-test-open-path=<relative>`: open a record folder staged inside the
    /// app container, resolved against `NSHomeDirectory()`.
    ///
    /// Kept rather than scaffolded-and-deleted. The redesign's remaining
    /// visual work — the stage bands (X70) and the shared-axis trend stack
    /// (X74) — cannot be verified through the accessibility tree, because a
    /// Metal canvas, a `Path` and a Swift Charts lane all expose nothing about
    /// what they PAINTED. Checking those against pixels needs a real
    /// multi-hour record, which is far too large to live in the repo, so it
    /// has to be staged locally and opened by path. X64 removed this hook and
    /// X70 had to write it again; the second time is the signal.
    ///
    /// The path is RELATIVE deliberately: the app sandbox denies an absolute
    /// path even into its own container, which cost a debugging cycle in X64.
    private func openUITestPathIfRequested() {
        guard let arg = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--ui-test-open-path=") }) else { return }
        let relative = String(arg.dropFirst("--ui-test-open-path=".count))
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative)
        openFolder(url)
    }

    private func openUITestSessionIfRequested() {
        // Bare flag: a package with no session state, as always. X96:
        // `--ui-test-open-sample-session=overlay` writes one whose session
        // state stages V1 (primary) + I overlaid — the NSSavePanel side is
        // XCUI-hostile, so the restore half is what the UI test drives.
        let overlayVariant = UITestSupport.value(forFlag: "ui-test-open-sample-session") == "overlay"
        guard overlayVariant
            || ProcessInfo.processInfo.arguments.contains("--ui-test-open-sample-session") else { return }
        do {
            let fixtureDir = try SyntheticRecording.makeFixture()
            let recording = try RecordingStore.shared.loadManifest(at: fixtureDir)
            let packageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ui-test-\(UUID().uuidString).mur")
            var sessionJSON: Data?
            if overlayVariant {
                sessionJSON = try JSONEncoder().encode(MurSessionState(
                    focusedChannelName: "V1",
                    focusedChannelNames: ["V1", "I"]
                ))
            }
            try MurSessionPackage.write(
                recording: recording, recordingDirectory: fixtureDir,
                sessionJSON: sessionJSON, to: packageURL
            )
            openMurPackage(packageURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `--ui-test-open-sample-csv`: write a header-block CSV to a temp file and
    /// drive the real CSV open → convert → import → present chain (the
    /// NSOpenPanel is XCUI-hostile), so a test can assert a CSV lands in the
    /// viewer.
    private func openUITestCSVIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-open-sample-csv") else { return }
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: adc_counts
        0,10
        1,11
        2,12
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-test-\(UUID().uuidString).csv")
        do {
            try Data(csv.utf8).write(to: url)
            openCSV(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `--ui-test-open-headerless-csv`: open a CSV with NO header block so the
    /// import dialog presents — asserts the header-less → dialog routing.
    private func openUITestHeaderlessCSVIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-open-headerless-csv") else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-test-\(UUID().uuidString).csv")
        do {
            try Data("0,10\n1,11\n2,12".utf8).write(to: url)
            openCSV(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Materialises a synthetic WFDB source folder and calls the same
    /// `openFolder(_:)` path the picker, the toolbar button, and the
    /// drag-and-drop delegate all go through. Bypasses the system
    /// `NSOpenPanel` modal (XCUI-hostile) while still exercising the full
    /// scanFolder → import → bedside pipeline.
    private func openSyntheticFolderForTesting() {
        // `--ui-test-open-folder` materialises one record; `=N` materialises
        // N (named synth, synth2, …). Two is what the X77 record-switch guard
        // test needs — a folder with a second row to click.
        let count = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--ui-test-open-folder=") }
            .flatMap { Int($0.dropFirst("--ui-test-open-folder=".count)) } ?? 1
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-ui-test-open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )) != nil,
              (try? SyntheticRecording.makeMultiFrequencyRecord(into: workDir)) != nil else {
            return
        }
        if count >= 2 {
            for extra in 2...count {
                _ = try? SyntheticRecording.makeMultiFrequencyRecord(
                    into: workDir, recordName: "synth\(extra)"
                )
            }
        }
        openFolder(workDir)
    }

    /// When `--ui-test-attach-findings` is set, writes a synthetic
    /// attach-sidecar JSON to a temp file. BedsideView picks the path up
    /// from `UITestSupport.attachFindingsURL` and routes it through its
    /// existing `handleAttachFindings` path on appear. Done up here so the
    /// fixture is on disk before BedsideView's `.task` fires.
    private func attachFindingsIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-attach-findings"),
              let url = UITestSupport.makeAttachFindingsFixture() else { return }
        UITestSupport.attachFindingsURL = url
    }

    /// Fixed location for the large pre-imported bundle used by
    /// MurmurUILargeDatasetTests. The prep step generates a 1-hour
    /// synthetic WFDB record here, runs the importer, and leaves the
    /// resulting bundle ready to load. Subsequent tests in the same class
    /// run skip prep and load directly from this path.
    private static var largeFixtureBundleParent: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-perf-large-bundle", isDirectory: true)
    }

    /// Generates a 1-hour synthetic record into a fixed location and runs
    /// the importer. The resulting bundle stays on disk for the next test
    /// iteration to load via `--ui-test-load-prepped-bundle`. Sets state
    /// to `.directView` so the test runner can detect "prep finished" by
    /// waiting for `bedside-view`.
    private func prepLargeFixtureForTesting() {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-perf-large-work", isDirectory: true)
        let bundleParent = Self.largeFixtureBundleParent
        // Reuse a previously-prepped bundle if present — the prep is
        // idempotent and slow, so a re-launch with the same flag should
        // be cheap.
        if let existing = preppedLargeBundlePath() {
            do {
                let recording = try RecordingStore.shared.loadManifest(at: existing)
                setAppState(.directView(directory: existing, recording: recording))
                return
            } catch {
                // Fall through and regenerate.
            }
        }
        try? FileManager.default.removeItem(at: workDir)
        try? FileManager.default.removeItem(at: bundleParent)
        guard (try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.createDirectory(at: bundleParent, withIntermediateDirectories: true)) != nil else {
            return
        }
        do {
            let heaURL = try SyntheticRecording.makeMultiFrequencyRecord(
                into: workDir,
                durationSeconds: 3600
            )
            let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: bundleParent)
            let recording = try RecordingStore.shared.loadManifest(at: summary.directory)
            setAppState(.directView(directory: summary.directory, recording: recording))
        } catch {
            errorMessage = "Large-fixture prep failed: \(error.localizedDescription)"
        }
    }

    /// Loads the pre-prepped bundle without re-running the importer.
    /// Used by every iteration of every large-dataset test *after* the
    /// one-time prep.
    private func loadPreppedLargeBundleForTesting() {
        guard let bundle = preppedLargeBundlePath() else {
            errorMessage = "No prepped large bundle found — did the prep test run first?"
            return
        }
        do {
            let recording = try RecordingStore.shared.loadManifest(at: bundle)
            setAppState(.directView(directory: bundle, recording: recording))
        } catch {
            errorMessage = "Failed to load prepped large bundle: \(error.localizedDescription)"
        }
    }

    /// Walks `largeFixtureBundleParent` for a single child directory
    /// containing a `recording.json` — that's the imported bundle. Returns
    /// nil if prep hasn't run.
    private func preppedLargeBundlePath() -> URL? {
        let parent = Self.largeFixtureBundleParent
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        return children.first { url in
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("recording.json").path
            )
        }
    }

    /// Materialises the synthetic fixture's source WFDB folder on disk and
    /// seeds it as a recents-store entry, without auto-loading. Lets a UI
    /// test land on the welcome screen with one clickable recents row that
    /// will go through the full `scanFolder` → import → bedside flow when
    /// clicked.
    private func seedRecentForTesting() {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-ui-test-recents", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )) != nil,
              (try? SyntheticRecording.makeMultiFrequencyRecord(into: workDir)) != nil else {
            return
        }
        // Wipe any persisted entries first so each test run starts from a
        // known-empty list — UserDefaults survives across runs otherwise.
        recentsStore.clear()
        recentsStore.recordForTesting(folder: workDir)
    }
    #endif

}

// MARK: - Sidebar

private struct RecordSidebar: View {
    let records: [RecordListEntry]
    let importStates: [String: ContentView.RecordImportState]
    @Binding var selection: String?
    @State private var flags = SessionFlagStore.shared

    /// Search text (X68). Matches the record name and its metadata line, so
    /// typing `72` finds the 72-hour records and `F` finds the female
    /// subjects — the `.hea` comment is in the subtitle and is the field that
    /// actually distinguishes one row from another.
    @State private var searchText: String = ""
    @State private var recordsExpanded: Bool = true

    private var filtered: [RecordListEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: $selection) {
                Section(isExpanded: $recordsExpanded) {
                    ForEach(filtered) { record in
                        RecordRow(
                            record: record,
                            importState: importStates[record.id],
                            isFlagged: flags.isFlagged(record.id),
                            canFlag: isImported(record.id),
                            onToggleFlag: { flags.toggle(record.id) }
                        )
                        .tag(record.id)
                        // `.contain` keeps the row's own controls addressable. An
                        // identifier on a container otherwise collapses its subtree to
                        // one element, which is how the Save Session flag ended up
                        // clickable by hand but invisible to VoiceOver and XCUI —
                        // the same defect X51 §1 chased, and the rule
                        // feedback_swiftui_accessibility_contain exists to prevent.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("record-row-\(record.id)")
                    }
                } header: {
                    sectionHeader
                }
            }
            .overlay {
                // A filtered-to-nothing list is otherwise indistinguishable
                // from a folder that produced no records, and the analyst has
                // no way to tell which without clearing the field.
                if filtered.isEmpty && !records.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityIdentifier("record-search-field")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("record-search-clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sectionHeader: some View {
        HStack {
            Text("RECORDS")
            Spacer()
            // The count follows the FILTER, not the folder — a header reading
            // 20 above 3 visible rows would be describing something the
            // analyst cannot see.
            Text("\(filtered.count)")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("records-section-header")
    }

    /// Only an IMPORTED record can be saved — it is the import that produces
    /// the `Recording` and the bundle a `.mur` embeds. Flagging one that has
    /// never been opened would promise a save that could not include it.
    private func isImported(_ filename: String) -> Bool {
        if case .imported = importStates[filename] { return true }
        return false
    }
}

private struct RecordRow: View {
    let record: RecordListEntry
    let importState: ContentView.RecordImportState?
    let isFlagged: Bool
    let canFlag: Bool
    let onToggleFlag: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            flagButton
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.body.monospaced())
                Text(record.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            statusIcon
        }
        .padding(.vertical, 2)
    }

    /// X63-B: the analyst's "this one matters". File → Save Session writes
    /// exactly the flagged set, so this is the only selection concept — there
    /// is no separate basket or multi-select.
    @ViewBuilder
    private var flagButton: some View {
        if canFlag {
            Button(action: onToggleFlag) {
                Image(systemName: isFlagged ? "flag.fill" : "flag")
                    .foregroundStyle(isFlagged ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(isFlagged
                  ? "Flagged for Save Session. Click to remove."
                  : "Flag this record to include it in Save Session.")
            .accessibilityLabel(isFlagged ? "Flagged" : "Not flagged")
            .accessibilityIdentifier("record-flag-\(record.id)")
        } else {
            // Keeps the rows' text aligned whether or not a record is
            // flaggable, so the list doesn't jitter as imports land.
            Color.clear.frame(width: 13, height: 13)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch importState {
        case .importing:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Importing")
        case .imported:
            // AX6: without an explicit label this checkmark speaks as
            // "Selected", so every imported row reads "Selected" and gets
            // confused with the list's actual single-selection state. Label
            // it as the import status it actually is.
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Imported")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Import failed")
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Data model

/// One WFDB record found in a picked folder.
struct WFDBRecordEntry: Identifiable, Equatable {
    var id: String { filename }
    let filename: String     // e.g. "100.hea"
    let header: WFDBHeader

    var durationSeconds: Double {
        guard header.samplingFrequency > 0 else { return 0 }
        return Double(header.sampleCount) / header.samplingFrequency
    }
}
