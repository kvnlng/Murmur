//
//  MurmurApp.swift
//  Murmur
//
//  Created by Kevin Long on 6/14/26.
//

import AppKit
import MurmurCore
import MurmurMetrics
import SwiftUI
import UniformTypeIdentifiers

/// X77 — the quit-side half of the unsaved-anchored-notes guard (#113).
///
/// Anchored notes are session work product: durable only after File ▸ Save
/// Session (DECISIONS §4 made that deliberate, no autosave). The Context
/// drawer's footer says so while the app is open; this is the last line of
/// defence when it is closing. Uses the same dirty check the footer renders
/// (`CurrentRecordingContext.hasUnsavedAnchoredNotes`), so the alert can
/// never disagree with the indicator.
final class MurmurAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // X86: unsaved work is no longer only the open record's — switching
        // records parks notes in `CarriedSessionStore` instead of forcing a
        // save, so this guard covers the whole in-memory set.
        let hasUnsavedAnywhere = CurrentRecordingContext.shared.hasUnsavedAnchoredNotes
            || !CarriedSessionStore.shared.unsavedRecordIDs.isEmpty
        guard hasUnsavedAnywhere else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit with unsaved anchored notes?"
        alert.informativeText = "Anchored notes save with the session — File ▸ Save Session (⌘S). "
            + "Quitting now discards them, on every record in this session."
        alert.addButton(withTitle: "Save Session…")
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // A cancelled save panel cancels the quit too — the analyst asked
            // to save, and quitting anyway would lose exactly what they were
            // trying to keep.
            return saveSessionPanel() ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

@main
struct MurmurApp: App {

    @NSApplicationDelegateAdaptor(MurmurAppDelegate.self) private var appDelegate

    /// User-facing Help menu destinations. The docs site is the public face
    /// of the app now that the source repo is private; every entry below
    /// links into it (or to a mailto for direct support).
    private enum HelpURL {
        static let home            = URL(string: "https://kvnlng.github.io/Murmur/")!
        static let gettingStarted  = URL(string: "https://kvnlng.github.io/Murmur/getting-started.html")!
        static let annotationSchema = URL(string: "https://kvnlng.github.io/Murmur/annotation-schema.html")!
        static let privacy         = URL(string: "https://kvnlng.github.io/Murmur/privacy.html")!
        static let support         = URL(string: "mailto:long.kevin@gmail.com?subject=Murmur%20Studio%20Support")!
    }

    init() {
        // (Removed by #253) `ToolbarDisplayModeDefault.seedIfNeeded()`, which
        // opened the toolbar on Icon and Text. Icon-only is AppKit's own
        // default, so nothing replaces it — see MurmurToolbar for the measured
        // evidence and for why X60's reasoning reversed rather than being
        // overruled.

        // Reap per-operation scratch (csv-import-*, mur-session-*, ui-test-*)
        // left in the container tmp by earlier launches — nothing deletes it
        // when the operation ends because it backs the viewing session that
        // follows. Launch is the one moment this process provably has no
        // session open; the sweep's age cutoff protects parallel UI-test
        // instances, and makes running it off-main safe (anything the analyst
        // opens after launch is younger than the cutoff). See TempScratchSweeper.
        Task.detached(priority: .utility) {
            TempScratchSweeper.sweepAtLaunch()
            // Same launch-is-the-safe-moment reasoning, aimed at Application
            // Support: recording bundles from before source-fingerprint
            // reuse can never be matched by a future import and had piled
            // up to 16 GB. See RecordingBundleSweeper's header.
            RecordingBundleSweeper.sweepAtLaunch()
        }

        // Publish-side jank measurement (#17): time every main-run-loop turn
        // and persist the ones a person could feel, so "still clunky" can be
        // correlated against the adjacent publish lines in the compute log.
        Task { @MainActor in
            MainThreadStallMonitor.install()
        }

        // Register the baseline producers that ship with the free viewer.
        // The MurmurCore bootstrap encapsulates the DEBUG vs RELEASE
        // policy — in DEBUG it registers the synthetic producer so the
        // pipeline UI is exercisable; in RELEASE it's a no-op and paid
        // frameworks register themselves on framework load.
        Task { @MainActor in
            await bootstrapBaselineProducers()
        }
    }


    /// Production minimum is 1100×720 (Guideline 4 fix), unconditionally.
    /// Under a DEBUG XCUI run the minimum is capped by the runner's visible
    /// screen so the window can fit short CI displays — see WindowSizing for
    /// the failure mode this prevents.
    ///
    /// A property, NOT a `let` + explicit `return` inside `body`: `body` is a
    /// @SceneBuilder, and an explicit `return` silently drops every scene
    /// after the returned one — the Settings scene below became dead code
    /// that way once (no Settings… menu item, no ⌘,), and the only compile
    /// diagnostic is a warning.
    private var minimums: (width: CGFloat, height: CGFloat) {
        WindowSizing.effectiveMinimums()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: minimums.width, minHeight: minimums.height)
                // Invisible orchestrator: watches CurrentRecordingContext +
                // PurchaseStore, computes rolling HRV samples via MurmurMetrics,
                // and publishes to VariabilityLaneContext for BedsideView to
                // render. Lives here because the App target is the only place
                // that imports both MurmurMetrics and MurmurCore.
                .background(VariabilityLaneOrchestrator())
                // Second invisible orchestrator: same pattern, computes P/Q/S/T
                // fiducials + per-patient normal template + interval readouts,
                // publishes to IntervalMarkingsContext.
                .background(IntervalMarkingsOrchestrator())
                // Qualifying-window facts (X42): per-bin rate stability +
                // excluded fraction, published for the trend lane's X43 marker
                // + X46 gate. Depends on the delineated beats above.
                .background(QualifyingWindowOrchestrator())
                // Third invisible orchestrator: owns the VT/VF Core ML model +
                // entitlement gate, presents the scan dialog, and publishes
                // committed candidates to VTVFScanContext for the review queue.
                .background(VTVFScanOrchestrator())
                // Whole-record variability summary (HRV + QTVI), published to
                // VariabilityMetricsContext for the inline strip beneath the
                // variability lane. Formerly the content of a detached
                // "ECG Metrics" window; see VariabilityMetricsStrip.
                .background(VariabilityMetricsOrchestrator())
                // Rolling LF/HF series for the trend stack's LF/HF lane
                // (X76), published to RollingLFHFContext. Off-main compute —
                // thousands of Lomb–Scargle windows on a long record.
                .background(RollingLFHFOrchestrator())
                // Arrhythmia scan (A2): runs ArrhythmiaScanService over the
                // loaded recording (entitled only) and publishes brady/tachy/
                // pause/AFib candidate spans to ArrhythmiaScanContext for the
                // review queue + channel overlays.
                .background(ArrhythmiaScanOrchestrator())
                // X112 — morphology clusters for the Context drawer's
                // Morphology section.
                .background(MorphologyOrchestrator())
        }
        .defaultSize(width: 1320, height: 880)
        .commands {
            // X60: puts View → Customize Toolbar… (and Show/Hide Toolbar) in
            // the menu bar. Without this the bedside toolbar is customisable
            // but the analyst has no way to reach the customisation sheet
            // short of right-clicking the toolbar, which is not discoverable.
            //
            // This is how an analyst turns on Icon and Text. It matters here
            // because `.help()` renders no tooltip anywhere in this app on
            // macOS 26, so labels are the only way an icon-only button can
            // say what it does.
            ToolbarCommands()
            // X63-B: View ▸ Show/Hide Sidebar. The record navigator had no
            // toggle of any kind — no menu item, no toolbar button — so once
            // macOS collapsed the column an analyst could not get the record
            // list back. That also made the Save Session flag, which lives on
            // a navigator row, unreachable.
            SidebarCommands()
            // File menu — native .mur session Save/Open. SAVE is free (per the
            // save-vs-export model): it reads the current recording + its bundle
            // and writes a portable Murmur session package. OPEN routes the
            // picked package to ContentView via the coordinator.
            CommandGroup(after: .newItem) {
                // AX7: the primary open action (a WFDB record folder) existed
                // only as a toolbar button — an empty File menu reads as
                // "prototype". It's the main document type, so it takes ⌘O;
                // Open Session (reopen a .mur) moves to ⌘⇧O.
                Button("Open Record…") { openRecordPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Session…") { openSessionPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                // X22: standard macOS Open Recent — reopens a bookmarked record
                // folder via the coordinator (ContentView's scoped `reopen`).
                Menu("Open Recent") {
                    if RecentFoldersStore.shared.entries.isEmpty {
                        Button("No Recent Records") {}.disabled(true)
                    } else {
                        ForEach(RecentFoldersStore.shared.entries) { entry in
                            Button(entry.displayName) {
                                SessionDocumentCoordinator.shared.requestReopenRecent(entry)
                            }
                        }
                        Divider()
                        Button("Clear Menu") { RecentFoldersStore.shared.clear() }
                    }
                }
                Button("Import CSV…") { importCSVPanel() }
                Divider()
                // X22: plain Save (⌘S) — enabled only when a recording is open.
                // No .mur-in-place path yet, so it prompts a location like an
                // untitled document; Save As keeps ⌘⇧S.
                Button("Save Session") { saveSessionPanel() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(CurrentRecordingContext.shared.recording == nil)
                Button("Save Session As…") { saveSessionPanel() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            // #253 — Attach findings… and the three exports, which existed
            // ONLY as toolbar buttons. Their own `Commands` type at this level
            // rather than more buttons in the group above: a `CommandGroup`
            // builder takes Views, so a `Commands` value cannot nest inside
            // one, and these need `@FocusedValue` to reach the live bedside.
            RecordFileCommands()
            // #253 — the Editing latch, which existed only as a toolbar
            // button. The Edit menu is where a mode that governs whether the
            // document can be modified belongs.
            EditingLatchCommand()
            // #236 — the trend-lane picker, appended to the View menu.
            // #253 added the pane and viewport toggles above it.
            ViewCommandMenu()
            // #253 — record-level analysis. Its own menu rather than a corner
            // of Navigate: the VT/VF scan is not movement, and the handoff's
            // Region 1 cluster treats it as a distinct class of action. The
            // menu is absent entirely for the free viewer (see
            // `AnalyzeCommandMenu`), so this is not an empty menu advertising
            // a locked feature.
            AnalyzeCommandMenu()
            // X22: hoist the bedside navigation / disposition keys into real
            // menu commands so they dispatch through the responder chain
            // (fixing the intermittent J/K defect) and become discoverable.
            BedsideCommandMenu()
            // (Removed 2026-08-04) The Window → "Variability Metrics" item and
            // its ⌘⇧M window. The summary now renders inline in the record's
            // own column beneath the variability lane, so there is no second
            // window to open — and nothing left for a Window-menu entry to do.
            // Replace the system Help menu (which would otherwise point at a
            // non-existent Help Book) with links into the public docs site
            // and a mailto for direct support.
            CommandGroup(replacing: .help) {
                Button("Murmur Studio Help") { URLLauncher.shared.open(HelpURL.home) }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Getting Started")     { URLLauncher.shared.open(HelpURL.gettingStarted) }
                Button("Annotation Schema")   { URLLauncher.shared.open(HelpURL.annotationSchema) }
                Divider()
                // Citation routing: until the paid IAPs ship, both menu
                // items emit the free-viewer entry only. When VT / Metrics
                // land, this picks up tier-aware multi-entry citation per
                // ROADMAP "Citation routing".
                Button("Copy Citation (BibTeX)") {
                    _ = copyViewerCitationToPasteboard(asBibTeX: true)
                }
                Button("Copy Citation (RIS)") {
                    _ = copyViewerCitationToPasteboard(asBibTeX: false)
                }
                Divider()
                Button("Privacy Policy")      { URLLauncher.shared.open(HelpURL.privacy) }
                Button("Contact Support…")    { URLLauncher.shared.open(HelpURL.support) }
            }
        }
        // App-wide preferences. Adds a "Settings…" item under the app menu
        // with the standard ⌘, shortcut.
        Settings {
            SettingsView()
        }
        // (Removed 2026-08-04) The auxiliary "Variability Metrics" window.
        //
        // It occluded the trace it described, carried no record identity —
        // switching recordings recomputed it silently under an unchanged
        // title — and held the same quantity as the variability LANE that
        // already lived in the record column. The summary moved inline
        // (`VariabilityMetricsStrip`); the buy surface it also hosted
        // consolidates into Settings → Purchases, which is where macOS
        // users look for it and the only surface that now needs to be right.
    }

    // MARK: - Native .mur session Save / Open

    fileprivate static let sessionType = UTType("com.kevinlong.murmur.session")

    /// Opens a folder of WFDB records — the primary open action, previously
    /// reachable only from the toolbar (AX7). Routes the picked directory
    /// through the coordinator to ContentView's folder-open path; the panel's
    /// security scope carries the access grant. Same terminus as the toolbar
    /// Open button and the drop delegate.
    @MainActor private func openRecordPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Record"
        panel.message = "Choose a folder containing WFDB records (.hea / .dat)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SessionDocumentCoordinator.shared.requestOpen(url)
    }

    /// Picks a `.mur` package and hands it to ContentView (via the coordinator)
    /// to load + present. The package appears as a single file thanks to
    /// LSTypeIsPackage.
    @MainActor private func openSessionPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Murmur Session"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = Self.sessionType { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SessionDocumentCoordinator.shared.requestOpen(url)
    }

    /// Picks a CSV and hands it to ContentView to convert + present (free
    /// viewer's CSV on-ramp). Header-less CSVs surface an "add metadata" refusal
    /// until the import dialog (X15-C2) lands.
    @MainActor private func importCSVPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import CSV"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SessionDocumentCoordinator.shared.requestOpen(url)
    }

}

// MARK: - Session save flow

// File-scope (X77) so both the File-menu commands and the app delegate's
// quit guard reach one implementation. Previously methods on `MurmurApp`,
// which an `NSApplicationDelegate` cannot call.

/// Writes the analyst's session to a `.mur` package they choose the location
/// of, including the live session snapshot (X59) so a reopen lands them back
/// where they were. Returns whether a package was actually written — the
/// quit guard aborts termination on a cancelled or failed save.
///
/// X63-B: this writes the FLAGGED SET from the record sidebar. With nothing
/// flagged it writes the open record alone, so the single-record gesture is
/// unchanged — an analyst who never touches a flag never notices this.
///
/// The panel states what it is about to write. An analyst must not discover
/// the scope of their own save afterwards.
@MainActor
@discardableResult
func saveSessionPanel() -> Bool {
    let context = CurrentRecordingContext.shared
    let payloads = sessionPayloads()
    guard !payloads.isEmpty else {
        presentSessionAlert(title: "No recording open",
                            message: "Open a recording before saving a Murmur session.")
        return false
    }
    let panel = NSSavePanel()
    panel.title = "Save Murmur Session"
    panel.message = SessionSaveScope.message(recordCount: payloads.count)
    if let type = MurmurApp.sessionType { panel.allowedContentTypes = [type] }
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = SessionSaveScope.defaultFileName(
        recordCount: payloads.count,
        singleSourceFileName: payloads.first?.recording.sourceFileName
    )
    // X63-D: encryption is OPTIONAL PER SAVE — off by default, opted into
    // here. SAVE stays free, encrypted or not; this is never an entitlement
    // check.
    let accessory = SessionPassphrasePrompt.SaveAccessory()
    panel.accessoryView = accessory
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    do {
        try MurSessionPackage.write(
            records: payloads,
            // Land the reopen on whatever the analyst had open, which is
            // rarely whichever record sorted first.
            collectionJSON: try? JSONEncoder().encode(
                MurCollectionState(activeRecordingID: context.recording?.id)
            ),
            passphrase: accessory.passphrase,
            to: url
        )
        // X72: the write succeeded, so what was live is now the saved
        // baseline — the Context drawer's unsaved indicator reads this.
        context.sessionSavedNotes = context.liveSessionState.anchoredNotes ?? []
        // X86: carried records that were actually WRITTEN (the flagged set)
        // are durable now too. A carried record left unflagged was not
        // written, so it stays unsaved and the quit guard keeps warning
        // about it — the panel stated the save's scope, and this must agree.
        CarriedSessionStore.shared.markSaved(
            recordIDs: SessionFlagStore.shared.flaggedRecords.map(\.id)
        )
        return true
    } catch {
        presentSessionAlert(title: "Couldn't save session", message: error.localizedDescription)
        return false
    }
}

/// The records a save would write: the flagged set, or — with nothing
/// flagged — the open record alone.
///
/// Only the OPEN record gets the live session snapshot and provenance:
/// those describe where the analyst is and what the on-screen numbers were
/// made of, and neither is knowable for a record that is merely flagged.
/// Writing the open record's viewport onto every record in the set would be
/// a fabricated coordinate — the X32 error class.
@MainActor
private func sessionPayloads() -> [MurSessionPackage.RecordPayload] {
    let context = CurrentRecordingContext.shared
    // X59: capture the live session snapshot the bedside view publishes.
    // Encoding failure must not cost the analyst their save — fall back to
    // writing without it rather than throwing the whole save away.
    let sessionJSON = try? JSONEncoder().encode(context.liveSessionState)
    // X26: record what the analyst's numbers were MADE OF — the template's
    // population, lead, span and formula — so the saved measurement stays
    // auditable if the delineator or the formula default moves in a later
    // version. Absent when there is no template; never a fabricated
    // zero-beat one.
    let provenanceJSON = MurProvenance.NormalTemplate(
        IntervalMarkingsContext.shared.template
    ).flatMap { try? JSONEncoder().encode(MurProvenance(normalTemplate: $0)) }

    // The RULE lives in MurmurCore so it can be unit-tested. This command
    // is a menu handler wrapped around an NSSavePanel — system-modal, not
    // XCUI-drivable — so anything decided in here is untestable by
    // construction.
    return SessionSaveSet.payloads(
        flagged: SessionFlagStore.shared.flaggedRecords,
        openRecording: context.recording,
        openDirectory: context.directory,
        sessionJSON: sessionJSON,
        provenanceJSON: provenanceJSON,
        // X86: parked state for records the analyst annotated and switched
        // away from — each flagged record saves ITS OWN carried viewport and
        // notes, not a fabricated copy of the open record's.
        carriedSessionJSONByID: CarriedSessionStore.shared.entries
            .compactMapValues { try? JSONEncoder().encode($0.state) }
    )
}

@MainActor
private func presentSessionAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

/// The "Navigate" menu (X22). Reads the bedside actions BedsideView publishes
/// as a focused scene value and exposes them as menu commands with their key
/// equivalents. Dispatching through the menu/responder chain is the fix for
/// the intermittent finding-jump keys (they previously lived on a focusable
/// view that silently lost focus). The bare-key shortcuts are disabled while
/// the notes editor is focused so they don't intercept typing, and the
/// disposition commands additionally require edit mode — mirroring the
/// existing C/D/X gate.
struct BedsideCommandMenu: Commands {
    @FocusedValue(\.bedsideCommands) private var commands

    var body: some Commands {
        CommandMenu("Navigate") {
            Group {
                Button("Next Finding") { commands?.nextFinding() }
                    .keyboardShortcut("j", modifiers: [])
                Button("Previous Finding") { commands?.previousFinding() }
                    .keyboardShortcut("k", modifiers: [])
                Divider()
                Button("Next Departure Beat") { commands?.nextDeviationBeat() }
                    .keyboardShortcut("]", modifiers: [])
                Button("Previous Departure Beat") { commands?.previousDeviationBeat() }
                    .keyboardShortcut("[", modifiers: [])
                Divider()
                Button("Pan Left") { commands?.panLeft() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Pan Right") { commands?.panRight() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Zoom In") { commands?.zoomIn() }
                    .keyboardShortcut("+", modifiers: [])
                Button("Zoom Out") { commands?.zoomOut() }
                    .keyboardShortcut("-", modifiers: [])
            }
            .disabled(navigationDisabled)

            Divider()

            Group {
                Button("Confirm Finding") { commands?.confirm() }
                    .keyboardShortcut("c", modifiers: [])
                Button("Dismiss Finding") { commands?.dismiss() }
                    .keyboardShortcut("d", modifiers: [])
                Button("Reset Finding") { commands?.reset() }
                    .keyboardShortcut("x", modifiers: [])
            }
            .disabled(dispositionDisabled)

            Divider()

            // Standard View (X40): snap both axes back to standard ECG paper.
            // ⌘-modified so it's safe to leave enabled during note entry, and
            // it dispatches through the responder chain (not a focus handler),
            // the X35 lesson.
            Button("Standard View") { commands?.standardView() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(commands == nil)

            // X28: elapsed ↔ time-of-day. DISABLED (not hidden) when the record
            // carries no real start time — the analyst should be able to see
            // that the capability exists and that this record cannot support it,
            // rather than wonder where the option went. ⌘-modified so it stays
            // safe during note entry.
            Button(timeDisplayTitle) { commands?.toggleTimeDisplay() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(commands?.timeDisplayAvailable != true)

            Divider()

            // X72 — the Context drawer. The toggle is ⌘-modified so it stays
            // safe during note entry; the steps share the navigation gate
            // (⌥J while typing must insert "∆", not jump) and additionally
            // show DISABLED when the record carries no anchored notes.
            Button(notesDrawerTitle) { commands?.toggleNotesDrawer() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(commands == nil)
            Button("Next Note") { commands?.nextNote() }
                .keyboardShortcut("j", modifiers: .option)
                .disabled(navigationDisabled || commands?.notesAvailable != true)
            Button("Previous Note") { commands?.previousNote() }
                .keyboardShortcut("k", modifiers: .option)
                .disabled(navigationDisabled || commands?.notesAvailable != true)
        }
    }

    /// Like `timeDisplayTitle`: the title names what the command WILL do.
    private var notesDrawerTitle: String {
        commands?.notesDrawerVisible == true ? "Hide Context Drawer" : "Show Context Drawer"
    }

    /// X28 menu title — a checkmark would be ambiguous on a two-state toggle,
    /// so the title names what the command WILL do.
    private var timeDisplayTitle: String {
        guard let commands, commands.timeDisplayAvailable else {
            return "Show Time of Day"          // disabled: no time base
        }
        return commands.timeDisplayIsWallClock ? "Show Elapsed Time" : "Show Time of Day"
    }

    /// Pan / zoom / jump: available once a recording is loaded, suppressed
    /// while the analyst is typing in the notes editor.
    private var navigationDisabled: Bool {
        guard let commands else { return true }
        return commands.textEntryActive
    }

    /// Disposition additionally requires the recording to be unlocked.
    private var dispositionDisabled: Bool {
        guard let commands else { return true }
        return commands.textEntryActive || !commands.isEditing
    }
}

/// The "View" menu — currently just the trend-lane picker (#236).
///
/// The picker used to be a `Menu` in the trend stack's own header, which is
/// the last thing in a long scrolling column. On a short display it landed at
/// the bottom edge of the screen, and its dropdown had nowhere to open: it
/// rendered under the Variability Metrics strip, and XCUI found no menu items
/// at all. Anywhere inside the window has an edge somewhere; the menu bar does
/// not, which is also why every menu-driven test in this suite has stayed
/// green while in-window clicks have not.
///
/// Lanes are listed only when a record offers them, so the menu never claims a
/// lane this recording cannot draw. Toggles carry no key equivalents on
/// purpose — six bare keys would collide with J/K, the deviation steps and the
/// disposition trio, and lane choice is not a per-beat action.
///
/// #253 — Attach findings… and the three exports, for the File menu.
///
/// These were toolbar-only. That was tolerable while the toolbar seeds Icon
/// AND Text, because the label under the glyph was the whole affordance —
/// `.help()` renders no tooltip anywhere in this app on macOS 26 (X60). The
/// design's icon-only toolbar removes the label and justifies it with "every
/// action keeps its menu-bar equivalent", which was not true of these four.
///
/// Each calls the same closure its toolbar button does, bridged through
/// `BedsideCommands`, so the two paths cannot drift.
struct RecordFileCommands: Commands {
    @FocusedValue(\.bedsideCommands) private var commands

    var body: some Commands {
        // `.importExport` is the native File-menu slot for exactly this, and
        // it sits below this app's Open/Save group — so the order reads
        // Open… / Save… / Attach / Export without hand-placing anything.
        CommandGroup(after: .importExport) {
            Button("Attach Findings…") { commands?.attachFindings() }
                .disabled(commands == nil)
            Divider()
            Button("Export Report…") { commands?.exportReport() }
                .disabled(commands == nil)
            Button("Export Snapshot…") { commands?.exportSnapshot() }
                .disabled(commands == nil)
            // Gated exactly as the toolbar's own menu gates it: with no
            // confirmed finding there is nothing to write. DISABLED rather
            // than hidden, the X32 principle — the analyst sees the capability
            // exists and that this record has not earned it yet.
            Button("Export WFDB Annotations…") { commands?.exportWFDBAnnotations() }
                .disabled(commands?.wfdbExportAvailable != true)
        }
    }
}

/// #253 — the Editing latch, for the Edit menu.
///
/// Titled by what it will DO rather than what it is, because a menu item that
/// reads "Editing" leaves the analyst guessing whether that is a state or an
/// action. The toolbar button can afford "Editing" — it is tinted and sits
/// next to the thing it governs; a menu row has neither.
struct EditingLatchCommand: Commands {
    @FocusedValue(\.bedsideCommands) private var commands

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button(commands?.isEditing == true ? "Lock Editing" : "Unlock for Editing") {
                commands?.toggleEditing()
            }
            .disabled(commands == nil)
        }
    }
}

/// #253 — record-level analysis.
///
/// The whole menu is absent when the VT/VF scan is unavailable, which mirrors
/// the toolbar item's own `scanContext.isScanAvailable` condition. Two reasons
/// not to show it disabled instead: the free viewer would get a top-level menu
/// containing one permanently dead row, which reads as a broken app rather
/// than a locked feature; and an empty `CommandMenu` renders as an empty menu,
/// which is worse than either.
///
/// This is deliberately NOT the X32 "disabled, not hidden" case. X32 is about
/// a capability THIS RECORD cannot support — the analyst should see that the
/// app can do it. Here the app genuinely cannot, until the entitlement is
/// bought, and advertising it in the menu bar is a storefront rather than a
/// status.
struct AnalyzeCommandMenu: Commands {
    @FocusedValue(\.bedsideCommands) private var commands

    var body: some Commands {
        if commands?.scanAvailable == true {
            CommandMenu("Analyze") {
                Button("Scan for VT/VF Candidates…") { commands?.scanForVTVF() }
            }
        }
    }
}

/// `CommandGroup(after: .toolbar)`, NOT `CommandMenu("View")`. SwiftUI already
/// synthesises a View menu for the window's toolbar, so a `CommandMenu` of the
/// same name adds a SECOND one — the menu bar read
/// `… | Edit | View | View | Navigate | …` and XCUI refused the ambiguous
/// subscript ("Multiple matching elements found"). `.toolbar` is the placement
/// that means "the View menu"; this appends to the one already there.
struct ViewCommandMenu: Commands {
    @FocusedValue(\.bedsideCommands) private var commands

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            // No `.accessibilityIdentifier` on any of this, deliberately:
            // identifiers do not reach a menu-bar NSMenuItem. Measured — with
            // one set, `app.menuItems["trend-lane-toggle-hr"]` did not exist
            // and the item's `identifier` came back empty, while its `title`
            // was exactly the label below. Every other menu-bar assertion in
            // the UI suite matches on title for the same reason; the in-window
            // `Menu`s that DO carry identifiers are a different surface.
            // #253 — the review queue and the 10 s window hold, both
            // toolbar-only until now. Titled by what they will do, like the
            // Context drawer item next door in Navigate, rather than rendered
            // as checked Toggles: the trend lanes below are a LIST where a
            // checkmark reads as "this one of many is showing", while these
            // are single panes whose state a Show/Hide title states outright.
            Button(commands?.reviewQueueVisible == true
                   ? "Hide Review Queue" : "Show Review Queue") {
                commands?.toggleReviewQueue()
            }
            .disabled(commands == nil)
            // A MODE, not a pane: held keeps the viewport at 10 s so finding
            // jumps recenter without re-zooming, and a manual zoom releases it.
            Button(commands?.windowHeldTo10s == true
                   ? "Release 10-Second Window" : "Hold to 10-Second Window") {
                commands?.toggleWindowHold()
            }
            .disabled(commands == nil)
            Divider()

            // #248 — the Layers chip, moved out of the window. Same route
            // #240 took for the trend lanes, and for the same reason: an
            // in-window picker near a window edge has nowhere to open, while
            // the menu bar never is.
            //
            // A `Toggle` per layer, so macOS draws the checkmark that spells
            // "this layer is on". The TITLE carries the third state — a layer
            // the analyst enabled that the zoom is holding back reads
            // "P — hidden at this zoom" while staying checked and clickable,
            // because the intent is recorded and takes effect on zoom-in.
            let layers = commands?.fiducialLayers ?? []
            if !layers.isEmpty {
                Section("Fiducial Layers") {
                    ForEach(layers) { layer in
                        Toggle(layer.menuTitle, isOn: Binding(
                            get: { layer.isEnabled },
                            set: { _ in commands?.toggleFiducialLayer(layer.id) }))
                    }
                    // The sentence naming the binding constraint, carried over
                    // from the chip. Only present when something enabled is
                    // being dropped, so it never explains a state nobody is in.
                    if let explanation = commands?.fiducialLayerExplanation {
                        Text(explanation)
                    }
                }
            }

            let lanes = commands?.trendLanes ?? []
            if lanes.isEmpty {
                // Shown DISABLED rather than hidden, the X32 principle: the
                // analyst can see the capability exists and that THIS record
                // has no lanes, instead of wondering where the menu went.
                Button("No Trend Lanes in This Record") {}
                    .disabled(true)
            } else {
                Section("Trend Lanes") {
                    ForEach(lanes) { lane in
                        // A Toggle, not a Button: SwiftUI renders it as a
                        // checked NSMenuItem, which is how macOS spells
                        // "this pane is showing". The binding only ever
                        // reports the toggle action; the truth stays in
                        // BedsideView's `visibleTrendLanes`.
                        Toggle(lane.label, isOn: Binding(
                            get: { lane.isVisible },
                            set: { _ in commands?.toggleTrendLane(lane.id) }))
                    }
                }
            }
        }
    }
}
