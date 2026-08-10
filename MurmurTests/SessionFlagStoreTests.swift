//
//  SessionFlagStoreTests.swift
//  MurmurTests
//
//  X63-B: flagging records out of a directory, and what Save Session then
//  writes.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("Session flagging (X63-B)")
@MainActor
struct SessionFlagStoreTests {

    private func tempDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flag-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ id: String, directory: URL) -> FlaggedRecord {
        let channel = Channel(name: "II", unit: "mV", sampleRate: 250,
                              startTimeUnixMS: 0, sampleCount: 4, storageFileName: "ch0.bin")
        return FlaggedRecord(
            id: id,
            recording: Recording(version: 1, id: UUID(), device: id,
                                 createdAt: Date(timeIntervalSince1970: 0),
                                 sourceFileName: id, channels: [channel]),
            directory: directory
        )
    }

    // MARK: - Flag semantics

    @Test("Nothing is flagged until the analyst says so")
    func startsEmpty() throws {
        let store = SessionFlagStore()
        store.register(record("100.hea", directory: try tempDir("a")))
        #expect(store.flaggedRecords.isEmpty)
    }

    @Test("Flagged records come back in sidebar order, not registration-set order")
    func preservesOrder() throws {
        let store = SessionFlagStore()
        for name in ["100.hea", "101.hea", "102.hea"] {
            store.register(record(name, directory: try tempDir(name)))
        }
        // Flag out of order; the save must still write the analyst's order.
        store.toggle("102.hea")
        store.toggle("100.hea")
        #expect(store.flaggedRecords.map(\.id) == ["100.hea", "102.hea"])
    }

    @Test("Re-importing a record replaces its entry without disturbing its flag")
    func reregisterKeepsFlag() throws {
        let store = SessionFlagStore()
        let first = try tempDir("first")
        store.register(record("100.hea", directory: first))
        store.toggle("100.hea")

        let second = try tempDir("second")
        store.register(record("100.hea", directory: second))
        #expect(store.available.count == 1, "re-import should replace, not duplicate")
        #expect(store.isFlagged("100.hea"))
        #expect(store.flaggedRecords.first?.directory == second)
    }

    @Test("A different folder is a different working set")
    func resetClearsEverything() throws {
        let store = SessionFlagStore()
        store.register(record("100.hea", directory: try tempDir("a")))
        store.toggle("100.hea")
        store.reset()
        #expect(store.flaggedIDs.isEmpty)
        #expect(store.available.isEmpty)
    }

    // MARK: - The pre-flag default (X87: selection is the trigger)

    @Test("Selecting a record for review flags it by default")
    func selectionPreflags() {
        let store = SessionFlagStore()
        store.applyDefaultFlag(for: "100.hea")
        #expect(store.isFlagged("100.hea"))
    }

    /// The default is a convenience, not a decision the app keeps re-making.
    @Test("Unflagging a pre-flagged record stays unflagged on a later visit")
    func defaultDoesNotOverrideTheAnalyst() {
        let store = SessionFlagStore()
        store.applyDefaultFlag(for: "100.hea")
        #expect(store.isFlagged("100.hea"))

        store.toggle("100.hea")                  // analyst says no
        store.applyDefaultFlag(for: "100.hea")   // navigate away and back
        #expect(!store.isFlagged("100.hea"), "a default must not overrule the analyst")
    }

    /// X63-C: opening a session flags its records, because those records ARE
    /// the analyst's set. Without this, opening a 4-record session and hitting
    /// Save Session would write only the open record and drop three.
    @Test("Flagging outright also settles the pre-flag default")
    func flagIsExplicitAndSticks() {
        let store = SessionFlagStore()
        store.flag("100.hea")
        #expect(store.isFlagged("100.hea"))
        // A later default pass must not un-flag it, and must not re-flag it
        // after the analyst clears it.
        store.applyDefaultFlag(for: "100.hea")
        #expect(store.isFlagged("100.hea"))
        store.toggle("100.hea")
        store.applyDefaultFlag(for: "100.hea")
        #expect(!store.isFlagged("100.hea"))
    }

    // MARK: - What a save actually writes

    private let sessionJSON = Data(#"{"viewportStartSample":7}"#.utf8)
    private let provenanceJSON = Data(#"{"normalTemplate":{"beatCount":9}}"#.utf8)

    @Test("With nothing flagged, a save writes the open record alone")
    func nothingFlaggedSavesOpenRecord() throws {
        let dir = try tempDir("open")
        let open = record("100.hea", directory: dir)
        let payloads = SessionSaveSet.payloads(
            flagged: [], openRecording: open.recording, openDirectory: dir,
            sessionJSON: sessionJSON, provenanceJSON: provenanceJSON
        )
        #expect(payloads.count == 1)
        #expect(payloads[0].recording.id == open.recording.id)
        // The gesture analysts already use must be unchanged, session state
        // and provenance included.
        #expect(payloads[0].sessionJSON == sessionJSON)
        #expect(payloads[0].provenanceJSON == provenanceJSON)
    }

    @Test("With nothing flagged and nothing open, a save has nothing to write")
    func nothingFlaggedNothingOpen() {
        #expect(SessionSaveSet.payloads(
            flagged: [], openRecording: nil, openDirectory: nil,
            sessionJSON: nil, provenanceJSON: nil
        ).isEmpty)
    }

    @Test("The flagged set is what gets written, in order")
    func flaggedSetIsWritten() throws {
        let flagged = [
            record("100.hea", directory: try tempDir("a")),
            record("102.hea", directory: try tempDir("b")),
        ]
        let payloads = SessionSaveSet.payloads(
            flagged: flagged, openRecording: flagged[0].recording,
            openDirectory: flagged[0].directory,
            sessionJSON: sessionJSON, provenanceJSON: provenanceJSON
        )
        #expect(payloads.map(\.recording.id) == flagged.map(\.recording.id))
    }

    /// Session state and provenance describe where the analyst IS and what the
    /// on-screen numbers were made of. Neither is knowable for a record that is
    /// merely flagged, so copying the open record's viewport across the set
    /// would be a fabricated coordinate — the X32 error class.
    @Test("Only the open record carries session state and provenance")
    func liveStateGoesOnlyToTheOpenRecord() throws {
        let flagged = [
            record("100.hea", directory: try tempDir("a")),
            record("101.hea", directory: try tempDir("b")),
            record("102.hea", directory: try tempDir("c")),
        ]
        let payloads = SessionSaveSet.payloads(
            flagged: flagged,
            openRecording: flagged[1].recording,      // the MIDDLE one is open
            openDirectory: flagged[1].directory,
            sessionJSON: sessionJSON, provenanceJSON: provenanceJSON
        )
        #expect(payloads[0].sessionJSON == nil)
        #expect(payloads[0].provenanceJSON == nil)
        #expect(payloads[1].sessionJSON == sessionJSON)
        #expect(payloads[1].provenanceJSON == provenanceJSON)
        #expect(payloads[2].sessionJSON == nil)
        #expect(payloads[2].provenanceJSON == nil)
    }

    /// X86: a carried state is that record's OWN, captured when the analyst
    /// switched away — the opposite of a fabricated coordinate, so a flagged
    /// record that has one saves it. Provenance stays open-only.
    @Test("A flagged record with carried state saves its own state")
    func carriedStateRidesWithItsRecord() throws {
        let carriedJSON = Data(#"{"viewportStartSample":42}"#.utf8)
        let flagged = [
            record("100.hea", directory: try tempDir("a")),
            record("101.hea", directory: try tempDir("b")),
        ]
        let payloads = SessionSaveSet.payloads(
            flagged: flagged,
            openRecording: flagged[1].recording, openDirectory: flagged[1].directory,
            sessionJSON: sessionJSON, provenanceJSON: provenanceJSON,
            carriedSessionJSONByID: ["100.hea": carriedJSON]
        )
        #expect(payloads[0].sessionJSON == carriedJSON)
        #expect(payloads[0].provenanceJSON == nil)
        // The OPEN record's live snapshot still outranks anything carried —
        // it is the same state, newer.
        #expect(payloads[1].sessionJSON == sessionJSON)
    }

    /// An analyst can flag records without the open one being among them.
    @Test("A flagged set that excludes the open record carries no live state")
    func openRecordOutsideTheFlaggedSet() throws {
        let flagged = [record("100.hea", directory: try tempDir("a"))]
        let other = record("999.hea", directory: try tempDir("z"))
        let payloads = SessionSaveSet.payloads(
            flagged: flagged, openRecording: other.recording, openDirectory: other.directory,
            sessionJSON: sessionJSON, provenanceJSON: provenanceJSON
        )
        #expect(payloads.count == 1)
        #expect(payloads[0].recording.id == flagged[0].recording.id,
                "the flagged set is authoritative; the open record is not added to it")
        #expect(payloads[0].sessionJSON == nil)
    }

    // MARK: - What the save panel says

    @Test("The panel states the scope before writing")
    func scopeMessageNamesTheCount() {
        #expect(SessionSaveScope.message(recordCount: 1) == "Saving 1 recording.")
        #expect(SessionSaveScope.message(recordCount: 4).contains("4"))
        #expect(SessionSaveScope.message(recordCount: 4).contains("one session"))
    }

    @Test("A single-record save keeps its record's name; a set gets a neutral one")
    func defaultFileName() {
        #expect(SessionSaveScope.defaultFileName(recordCount: 1, singleSourceFileName: "100.hea")
                == "100.mur")
        #expect(SessionSaveScope.defaultFileName(recordCount: 4, singleSourceFileName: "100.hea")
                == "Session.mur", "a set must not borrow whichever record sorted first")
        #expect(SessionSaveScope.defaultFileName(recordCount: 1, singleSourceFileName: nil)
                == "Session.mur")
    }
}
