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

    // MARK: - The pre-flag default

    @Test("A record carrying analyst work starts flagged")
    func preflagsRecordWithAnalystWork() throws {
        let dir = try tempDir("worked")
        try Data(#"{"schemaVersion":1,"dispositions":[]}"#.utf8)
            .write(to: dir.appendingPathComponent(DispositionFile.bundleFileName))

        let store = SessionFlagStore()
        store.register(record("100.hea", directory: dir))
        store.applyDefaultFlag(for: "100.hea", directory: dir)
        #expect(store.isFlagged("100.hea"))
    }

    /// The default is a convenience, not a decision the app keeps re-making.
    @Test("Unflagging a pre-flagged record stays unflagged on a later visit")
    func defaultDoesNotOverrideTheAnalyst() throws {
        let dir = try tempDir("worked")
        try Data(#"{"schemaVersion":1,"dispositions":[]}"#.utf8)
            .write(to: dir.appendingPathComponent(DispositionFile.bundleFileName))

        let store = SessionFlagStore()
        store.applyDefaultFlag(for: "100.hea", directory: dir)
        #expect(store.isFlagged("100.hea"))

        store.toggle("100.hea")                                  // analyst says no
        store.applyDefaultFlag(for: "100.hea", directory: dir)   // navigate away and back
        #expect(!store.isFlagged("100.hea"), "a default must not overrule the analyst")
    }

    @Test("Flagging a record with no analyst work sticks too")
    func explicitFlagOnUntouchedRecordSticks() throws {
        let dir = try tempDir("clean")
        let store = SessionFlagStore()
        store.toggle("100.hea")
        store.applyDefaultFlag(for: "100.hea", directory: dir)
        #expect(store.isFlagged("100.hea"))
    }

    // MARK: - What counts as analyst work

    /// THE case that decides whether pre-flagging is worth anything.
    /// `WFDBImporter` writes annotations.json on EVERY import from the record's
    /// own .atr, so treating "has findings" as analyst work would pre-flag the
    /// entire folder and the default would mean nothing.
    @Test("Imported findings are not analyst work")
    func importedAnnotationsDoNotCount() throws {
        let dir = try tempDir("imported")
        let imported = Annotation(kind: .point, sampleIndex: 10, category: "V", source: "wfdb.atr")
        try BundleAnnotationsFile.write([imported], to: dir)
        #expect(!AnalystLayerProbe.hasAnalystWork(in: dir))
    }

    @Test("An annotation the analyst authored is analyst work")
    func authoredAnnotationCounts() throws {
        let dir = try tempDir("authored")
        let authored = Annotation(kind: .range, sampleIndex: 10, category: "note",
                                  source: Annotation.analystAuthoredSource)
        try BundleAnnotationsFile.write([authored], to: dir)
        #expect(AnalystLayerProbe.hasAnalystWork(in: dir))
    }

    @Test("A candidate adjudication is analyst work")
    func candidateDispositionCounts() throws {
        let dir = try tempDir("adjudicated")
        try Data(#"{"schemaVersion":1,"dispositions":[]}"#.utf8)
            .write(to: dir.appendingPathComponent(RegionDispositionFile.bundleFileName))
        #expect(AnalystLayerProbe.hasAnalystWork(in: dir))
    }

    @Test("An untouched bundle is not analyst work")
    func emptyBundleIsNotWork() throws {
        #expect(!AnalystLayerProbe.hasAnalystWork(in: try tempDir("empty")))
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
