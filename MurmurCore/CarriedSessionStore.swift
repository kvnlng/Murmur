//
//  CarriedSessionStore.swift
//  MurmurCore
//
//  Unsaved work carried across record switches (X86).
//
//  Before this, switching records tore down BedsideView's @State — which is
//  where anchored notes live — so the X77 guard interrupted every switch that
//  would lose something. The issue (#135) asks for the opposite trade:
//  switching never interrupts, the work rides along in memory, and the analyst
//  is told once that a crash loses whatever hasn't been saved.
//
//  ## What is carried
//
//  The whole `MurSessionState` snapshot (viewport, paper, focused lead, notes),
//  not just the notes: an analyst who parks record A mid-measurement and comes
//  back expects THEIR view of A, and the restore machinery (X59/X63-C) already
//  round-trips exactly this shape. Alongside it rides the saved-notes baseline
//  (X72) so the drawer's unsaved indicator — and the quit guard — keep telling
//  the truth for a record that was carried rather than saved.
//
//  ## Why a shared store
//
//  Same reason as `SessionFlagStore`: File ▸ Save Session and the quit guard
//  live in the App target, which cannot reach ContentView's `@State`. The view
//  publishes at each switch, the menu and the delegate read.
//
//  Keys are the record sidebar's ids (the `.hea` filename), the same id space
//  as `SessionFlagStore` and ContentView's `sessionStates`, so a save can line
//  carried state up against the flagged set without translation.
//

import Foundation
import Observation

@MainActor
@Observable
public final class CarriedSessionStore {

    /// Shared instance the app uses. Tests construct their own so parallel
    /// runs stay isolated.
    public static let shared = CarriedSessionStore()

    public init() {}

    /// One parked record: its live snapshot at the moment the analyst
    /// switched away, and the saved-notes baseline it had then. `savedNotes`
    /// is `nil` for "never saved this session" — the same reading as
    /// `CurrentRecordingContext.sessionSavedNotes`.
    public struct Entry: Equatable, Sendable {
        public var state: MurSessionState
        public var savedNotes: [AnchoredNote]?

        public init(state: MurSessionState, savedNotes: [AnchoredNote]?) {
            self.state = state
            self.savedNotes = savedNotes
        }

        /// The X72 dirty check, per carried record: notes differ from the
        /// baseline they were last saved under.
        public var hasUnsavedAnchoredNotes: Bool {
            (state.anchoredNotes ?? []) != (savedNotes ?? [])
        }
    }

    public private(set) var entries: [String: Entry] = [:]

    /// Park a record's live state as the analyst switches away. Replaces any
    /// earlier entry — the newest snapshot is the only truthful one.
    public func carry(recordID: String, state: MurSessionState, savedNotes: [AnchoredNote]?) {
        entries[recordID] = Entry(state: state, savedNotes: savedNotes)
    }

    /// Take a parked record's state back OUT of the store, for re-activation.
    /// Removing it is deliberate: while a record is on screen, BedsideView's
    /// live state is the truth, and a stale entry left here would double-count
    /// its notes in `unsavedRecordIDs` and could later restore over newer work.
    public func consume(recordID: String) -> Entry? {
        entries.removeValue(forKey: recordID)
    }

    /// Records parked with notes that no save has made durable yet. The quit
    /// and open guards union this with the OPEN record's own dirty check.
    public var unsavedRecordIDs: [String] {
        entries.filter { $0.value.hasUnsavedAnchoredNotes }.keys.sorted()
    }

    /// A successful File ▸ Save Session wrote these records, so what was
    /// carried is now the saved baseline for each of them. Records NOT in
    /// `recordIDs` (carried but unflagged, so not written) stay unsaved.
    public func markSaved(recordIDs: some Sequence<String>) {
        for id in recordIDs {
            guard var entry = entries[id] else { continue }
            entry.savedNotes = entry.state.anchoredNotes ?? []
            entries[id] = entry
        }
    }

    /// Clear everything — a different folder or session is a different
    /// working set, and an explicit discard means the work is gone.
    public func reset() {
        entries.removeAll()
    }
}

/// The one-time crash-loss disclosure (X86): unsaved annotations now travel
/// across record switches in memory, so the analyst is told — once per
/// install — that a crash loses whatever hasn't been saved.
///
/// Same gate shape as `RUOFirstRunNotice`, and pure for the same reason:
/// suppressed under UI tests (every existing test would otherwise meet an
/// alert it never asked for) except when a test forces it, and a forced run
/// always presents regardless of stored state because XCUI runs share the
/// app container's defaults.
public enum CrashLossNotice {
    /// UserDefaults key. Per-install, per the issue's "one time warning" —
    /// a plain bool, not versioned.
    public static let shownDefaultsKey = "hasSeenCarryCrashLossNotice"

    public static let title = "Unsaved notes stay in memory"

    public static let message =
        "You can switch records without saving — unsaved annotations travel "
        + "with the session in memory. If Murmur crashes, they are lost. "
        + "File ▸ Save Session (⌘S) makes them durable."

    public static func shouldPresent(
        hasSeen: Bool,
        isUITestRun: Bool,
        forcedByTest: Bool
    ) -> Bool {
        if forcedByTest { return true }
        if isUITestRun { return false }
        return !hasSeen
    }
}
