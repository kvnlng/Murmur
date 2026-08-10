//
//  CarriedSessionStoreTests.swift
//  MurmurTests
//
//  X86: unsaved work carried across record switches, and the guards and
//  save that read it.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("Carried session state (X86)")
@MainActor
struct CarriedSessionStoreTests {

    private func note(_ text: String) -> AnchoredNote {
        AnchoredNote(startSample: 100, endSample: 100, leadName: "II",
                     text: text, createdAt: Date(timeIntervalSince1970: 0),
                     modifiedAt: Date(timeIntervalSince1970: 0))
    }

    private func state(notes: [AnchoredNote]?) -> MurSessionState {
        MurSessionState(viewportStartSample: 250, viewportEndSample: 2750,
                        anchoredNotes: notes)
    }

    // MARK: - Park and re-activate

    @Test("A carried record comes back exactly as parked, once")
    func carryConsumeRoundTrip() {
        let store = CarriedSessionStore()
        let parked = state(notes: [note("delta wave?")])
        store.carry(recordID: "100.hea", state: parked, savedNotes: nil)

        let entry = store.consume(recordID: "100.hea")
        #expect(entry?.state == parked)
        #expect(entry?.savedNotes == nil)
        // Consumed means GONE: while the record is on screen its live state
        // is the truth, and a stale entry would double-count its notes or
        // later restore over newer work.
        #expect(store.consume(recordID: "100.hea") == nil)
        #expect(store.entries.isEmpty)
    }

    @Test("Re-parking a record replaces the earlier snapshot")
    func reparkReplaces() {
        let store = CarriedSessionStore()
        let newer = note("v2")
        store.carry(recordID: "100.hea", state: state(notes: [note("v1")]), savedNotes: nil)
        store.carry(recordID: "100.hea", state: state(notes: [newer]), savedNotes: nil)
        #expect(store.consume(recordID: "100.hea")?.state.anchoredNotes == [newer])
    }

    // MARK: - The whole-set dirty check

    @Test("A parked note with no saved baseline is unsaved")
    func neverSavedNotesAreUnsaved() {
        let store = CarriedSessionStore()
        store.carry(recordID: "100.hea", state: state(notes: [note("a")]), savedNotes: nil)
        #expect(store.unsavedRecordIDs == ["100.hea"])
    }

    @Test("A parked record whose notes match its baseline is not unsaved")
    func savedNotesAreNotUnsaved() {
        let store = CarriedSessionStore()
        let notes = [note("a")]
        store.carry(recordID: "100.hea", state: state(notes: notes), savedNotes: notes)
        store.carry(recordID: "101.hea", state: state(notes: nil), savedNotes: nil)
        #expect(store.unsavedRecordIDs.isEmpty)
    }

    /// `nil` notes and `nil` baseline both read as empty — the same rule as
    /// `CurrentRecordingContext.hasUnsavedAnchoredNotes` (X77), so the
    /// whole-set guard can never disagree with the per-record footer.
    @Test("Deleting every saved note reads as unsaved, not as never-had-notes")
    func deletingSavedNotesIsUnsaved() {
        let store = CarriedSessionStore()
        store.carry(recordID: "100.hea", state: state(notes: nil), savedNotes: [note("was saved")])
        #expect(store.unsavedRecordIDs == ["100.hea"])
    }

    // MARK: - What a save makes durable

    @Test("A save marks exactly the written records' baselines")
    func markSavedIsScopedToWrittenRecords() {
        let store = CarriedSessionStore()
        let written = note("flagged")
        store.carry(recordID: "100.hea", state: state(notes: [written]), savedNotes: nil)
        store.carry(recordID: "101.hea", state: state(notes: [note("unflagged")]), savedNotes: nil)

        store.markSaved(recordIDs: ["100.hea", "999.hea"])   // 999 was never parked

        // The unflagged record was NOT written, so the quit guard must keep
        // warning about it — the save panel stated its scope.
        #expect(store.unsavedRecordIDs == ["101.hea"])
        #expect(store.entries["100.hea"]?.savedNotes == [written])
    }

    @Test("A different working set clears the carried state")
    func resetClears() {
        let store = CarriedSessionStore()
        store.carry(recordID: "100.hea", state: state(notes: [note("a")]), savedNotes: nil)
        store.reset()
        #expect(store.entries.isEmpty)
        #expect(store.unsavedRecordIDs.isEmpty)
    }

    // MARK: - The one-time crash-loss disclosure

    @Test("The notice presents once per install, and never under a plain UI-test run")
    func crashLossNoticeGate() {
        #expect(CrashLossNotice.shouldPresent(hasSeen: false, isUITestRun: false, forcedByTest: false))
        #expect(!CrashLossNotice.shouldPresent(hasSeen: true, isUITestRun: false, forcedByTest: false))
        #expect(!CrashLossNotice.shouldPresent(hasSeen: false, isUITestRun: true, forcedByTest: false))
        // Forced presents regardless of stored state — XCUI runs share the
        // app container's defaults, so an acknowledgement from an earlier
        // run must not make the forced test flaky.
        #expect(CrashLossNotice.shouldPresent(hasSeen: true, isUITestRun: true, forcedByTest: true))
    }
}
