//
//  MurmurToolbarItems.swift
//  MurmurCore
//
//  The window's whole customisable item set — idle AND live — registered
//  from ONE site per hierarchy (#298; was IdleToolbar.swift).
//
//  #285 shipped the idle set as a MIRROR of BedsideView's registrations:
//  same ids from a second `.toolbar(id:)` contributor, "never mounted at
//  once". That claim held at the SwiftUI state level and failed at the
//  AppKit one — the toolbar bridge's update is not atomic across two
//  contributors in the same window, so a bedside↔idle swap (switching to
//  an unimported record, opening a folder over an open record) could
//  insert one set's item while the other's identical id was still
//  registered. `NSToolbar` throws on the duplicate, and the app died in
//  `+[NSApplication _crashOnException:]` — 12 of 12 attempts on Xcode
//  Cloud's slower VM (Build 146), never once on fast local hardware.
//
//  So: one registration, whose items RENDER differently by state. `live`
//  carries the bedside's closures and state bits — the same
//  `BedsideCommands` the menu bar already reads via the focused-scene
//  bridge (#253), so a toolbar button and its menu equivalent literally
//  share a closure and cannot drift. Nil means no bedside is on screen and
//  every item renders inert at the standard ~32% disabled treatment, which
//  is the 12a launch look. Opening a record changes each control's STATE,
//  never the frame — and now that sentence is true at the AppKit level,
//  because the ids exist exactly once for the hierarchy's life.
//
//  The ids are the accessibility identifiers, deliberately: one name per
//  button, stable, and what the XCUI suite binds to. They are persisted in
//  analysts' saved toolbar layouts — DO NOT rename one without accepting
//  that a saved layout loses that item.
//
//  X60's record, still binding: an ID'd toolbar is a CUSTOMISABLE one —
//  macOS offers View ▸ Customize Toolbar…, the analyst's one route to
//  visible labels while `.help()` renders no tooltip on macOS 26. The
//  default went icon-only in #253 only after #287 gave every action a
//  menu-bar row. See MurmurToolbar for the full record.
//
//  `showsByDefault` is part of the frame: a hidden-by-default item that
//  appeared at launch would itself be the frame moving.
//

import SwiftUI

/// The bedside toolbar's item set, in both states. Registered by
/// `ContentView` in EVERY app state — the one contributor per hierarchy —
/// with `live` read from the bedside's focused-scene commands (nil when no
/// bedside is mounted).
struct MurmurToolbarItems: CustomizableToolbarContent {
    /// The mounted bedside's actions and state, or nil at idle.
    var live: BedsideCommands?

    /// #303 — the launch shell's empty review-queue pane. With no bedside
    /// mounted, the queue toggle alone stays live: it acts on chrome, not on
    /// record data, and 12a wants the panes closed-but-openable at launch.
    /// Nil (the loaded shells) keeps the toggle wired to `live` exactly as
    /// before.
    var idleQueueVisible: Bool = false
    var idleQueueToggle: (() -> Void)?

    // MARK: - Hover text (X60)
    //
    // Named once each so the string a button claims is greppable. NOTE:
    // these do not currently reach the user — `.help()` renders no tooltip
    // anywhere in this app on macOS 26 (X60) — but they are kept accurate
    // so that whenever hover text works again the copy is already right.
    private static let scanHelp =
        "Scan this recording for candidate VT/VF episodes (research use only)"
    private static let attachHelp =
        "Merge a producer's annotations JSON into this recording"
    private static let exportReportHelp =
        "Save a markdown report of this recording's findings and dispositions"
    private static let exportSnapshotHelp =
        "Save a PNG snapshot of the current bedside view"
    private static let findingsHelp = "Show or hide the review queue"

    private static func editModeHelp(isEditing: Bool) -> String {
        isEditing
            ? "Editing on — notes and annotations are editable. Click to lock."
            : "Read-only. Click to unlock and edit notes and annotations."
    }

    private static func windowLockHelp(held: Bool) -> String {
        held
            ? "Held to a 10-second window. Jumps recenter without changing zoom. Click (or zoom) to release."
            : "Hold the trace to a 10-second window so jumps keep your time frame."
    }

    var body: some CustomizableToolbarContent {
        // X72 — the Context drawer toggle, leading the trailing cluster per
        // the wireframe's ordering. Same action as ⌘⇧N (shared closure).
        ToolbarItem(id: "notes-toggle", placement: .automatic, showsByDefault: true) {
            Button {
                live?.toggleNotesDrawer()
            } label: {
                Label("Notes", systemImage: ToolbarGlyph.notes)
            }
            .help("Show or hide the Context drawer (⌘⇧N)")
            .tint(live?.notesDrawerVisible == true ? Color.accentColor : nil)
            .disabled(live == nil)
            .accessibilityIdentifier("notes-toggle")
        }
        ToolbarItem(id: "edit-mode-toggle", placement: .automatic, showsByDefault: true) {
            Button {
                live?.toggleEditing()
            } label: {
                Label(
                    live?.isEditing == true ? "Editing" : "Locked",
                    systemImage: live?.isEditing == true
                        ? ToolbarGlyph.editModeUnlocked : ToolbarGlyph.editModeLocked
                )
            }
            .help(Self.editModeHelp(isEditing: live?.isEditing == true))
            .tint(live?.isEditing == true ? Color.accentColor : nil)
            .disabled(live == nil)
            .accessibilityIdentifier("edit-mode-toggle")
        }
        // 10-second window hold: finding + candidate jumps recenter without
        // re-zooming; a manual zoom releases it.
        ToolbarItem(id: "window-lock-toggle", placement: .automatic, showsByDefault: true) {
            Button {
                live?.toggleWindowHold()
            } label: {
                Label("10 s window", systemImage: live?.windowHeldTo10s == true
                    ? ToolbarGlyph.windowHeld : ToolbarGlyph.windowFree)
            }
            .help(Self.windowLockHelp(held: live?.windowHeldTo10s == true))
            .tint(live?.windowHeldTo10s == true ? Color.accentColor : nil)
            .disabled(live == nil)
            .accessibilityIdentifier("window-lock-toggle")
        }
        // Present at idle (12a: the frame shows every capability), and with
        // a record open only while the App-target orchestrator reports the
        // VT/VF IAP owned — the free viewer never sees it, so the model is
        // never implied to be present. Conditional registration within the
        // ONE contributor, which is the pattern the bedside always used.
        if live == nil || live?.scanAvailable == true {
            ToolbarItem(id: "vtvf-scan-action", placement: .automatic, showsByDefault: true) {
                Button {
                    live?.scanForVTVF()
                } label: {
                    Label("Scan for VT/VF candidates", systemImage: ToolbarGlyph.scanVTVF)
                }
                .help(Self.scanHelp)
                .disabled(live == nil)
                .accessibilityIdentifier("vtvf-scan-action")
            }
        }
        ToolbarItem(id: "attach-findings", placement: .automatic, showsByDefault: true) {
            Button {
                live?.attachFindings()
            } label: {
                Label("Attach findings…", systemImage: ToolbarGlyph.attachFindings)
            }
            .help(Self.attachHelp)
            .disabled(live == nil)
            .accessibilityIdentifier("attach-findings")
        }
        // The three exports as one menu (X68). The other two ids stay
        // REGISTERED but hidden by default rather than retired: they are
        // persisted in analysts' saved layouts, and X60 made the toolbar
        // customisable precisely so labels could be turned back on.
        ToolbarItem(id: "export-report", placement: .automatic, showsByDefault: true) {
            Menu {
                Button("Export report…") { live?.exportReport() }
                    .accessibilityIdentifier("export-report-item")
                Button("Export snapshot…") { live?.exportSnapshot() }
                    .accessibilityIdentifier("export-snapshot-item")
                Button("Export WFDB annotations…") { live?.exportWFDBAnnotations() }
                    .disabled(live?.wfdbExportAvailable != true)
                    .accessibilityIdentifier("export-wfdb-item")
            } label: {
                Label("Export", systemImage: ToolbarGlyph.exportReport)
            }
            .help(Self.exportReportHelp)
            .disabled(live == nil)
            .accessibilityIdentifier("export-report")
        }
        ToolbarItem(id: "export-snapshot", placement: .automatic, showsByDefault: false) {
            Button {
                live?.exportSnapshot()
            } label: {
                Label("Export snapshot…", systemImage: ToolbarGlyph.exportSnapshot)
            }
            .help(Self.exportSnapshotHelp)
            .disabled(live == nil)
            .accessibilityIdentifier("export-snapshot")
        }
        ToolbarItem(id: "export-wfdb", placement: .automatic, showsByDefault: false) {
            Button {
                live?.exportWFDBAnnotations()
            } label: {
                Label("Export WFDB annotations…", systemImage: ToolbarGlyph.exportWFDB)
            }
            .help(live?.exportWFDBHelp ?? "Write your confirmed findings as a WFDB annotation file beside the recording, to hand to a peer")
            .disabled(live == nil || live?.wfdbExportAvailable != true)
            .accessibilityIdentifier("export-wfdb")
        }
        #if DEBUG
        ToolbarItem(id: "producers-toggle", placement: .automatic, showsByDefault: true) {
            Button {
                live?.showProducers()
            } label: {
                Label("Producers", systemImage: ToolbarGlyph.producers)
            }
            .help("Run a registered FindingProducer over this recording")
            .disabled(live == nil)
            .accessibilityIdentifier("producers-toggle")
        }
        #endif
        ToolbarItem(id: "findings-toggle", placement: .automatic, showsByDefault: true) {
            Button {
                if let live {
                    live.toggleReviewQueue()
                } else {
                    idleQueueToggle?()
                }
            } label: {
                Label("Review queue", systemImage: ToolbarGlyph.reviewQueue)
            }
            .help(Self.findingsHelp)
            .tint(live?.reviewQueueVisible == true || idleQueueVisible
                  ? Color.accentColor : nil)
            .disabled(live == nil && idleQueueToggle == nil)
            .accessibilityIdentifier("findings-toggle")
        }
    }
}
