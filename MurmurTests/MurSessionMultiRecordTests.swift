//
//  MurSessionMultiRecordTests.swift
//  MurmurTests
//
//  X63-A acceptance: a `.mur` holds MANY records.
//
//  Split from MurSessionPackageTests so both stay under SwiftLint's type-body
//  cap, and because these test a different claim. The tests over there all run
//  through the single-record convenience — they would pass unchanged even if
//  the multi-record path were broken, since that convenience wraps one payload
//  and reads `records[0]` back. These drive the array API directly.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("MurSessionPackage — multi-record sessions (X63-A)")
struct MurSessionMultiRecordTests {

    private func tempDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mur-multi-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    //
    // The tests above all run through the single-record convenience, so they
    // would pass unchanged even if the multi-record path were broken — the
    // convenience wraps one payload and reads `records[0]` back. These drive
    // the array API directly.

    /// Builds N independent bundles, each with a distinguishable channel blob
    /// so a mix-up between records is visible rather than merely absent.
    private func makeBundles(_ count: Int) throws -> [(dir: URL, recording: Recording, marker: Data)] {
        try (0..<count).map { index in
            let dir = try tempDir("bundle-\(index)")
            let channel = Channel(name: "II", unit: "mV", sampleRate: 250,
                                  startTimeUnixMS: 0, sampleCount: 4, storageFileName: "ch0.bin")
            let recording = Recording(version: 1, id: UUID(), device: "record-\(index)",
                                      createdAt: Date(timeIntervalSince1970: 1000),
                                      sourceFileName: "rec\(index).hea", channels: [channel])
            let marker = Data([UInt8(index), UInt8(index), UInt8(index), UInt8(index)])
            try JSONEncoder().encode(recording).write(to: dir.appendingPathComponent("recording.json"))
            try marker.write(to: dir.appendingPathComponent("ch0.bin"))
            return (dir, recording, marker)
        }
    }

    @Test("Three records round-trip, each into its own directory, in order")
    func multiRecordRoundTrip() throws {
        let bundles = try makeBundles(3)
        let pkg = try tempDir("pkg").appendingPathComponent("Set.mur")

        let manifest = try MurSessionPackage.write(
            records: bundles.map {
                MurSessionPackage.RecordPayload(recording: $0.recording, recordingDirectory: $0.dir)
            },
            to: pkg
        )
        #expect(manifest.records.count == 3)
        #expect(manifest.records.map(\.recordingID) == bundles.map(\.recording.id),
                "manifest.records IS the analyst's order")

        let out = try tempDir("open")
        let result = try MurSessionPackage.read(packageURL: pkg, into: out)
        #expect(result.records.count == 3)

        for (index, bundle) in bundles.enumerated() {
            let record = result.records[index]
            #expect(record.identity.recordingID == bundle.recording.id)
            // The marker proves each subtree reconstituted ITS OWN source —
            // three records that all read back record 0's bytes would satisfy
            // a mere "three directories exist" assertion.
            let bytes = try Data(contentsOf: record.recordingDirectory.appendingPathComponent("ch0.bin"))
            #expect(bytes == bundle.marker, "record \(index) should carry its own channel bytes")
        }

        // Directories are distinct — keyed by recordingID, not by filename
        // (two records in one folder can share a base name).
        #expect(Set(result.records.map(\.recordingDirectory)).count == 3)
    }

    @Test("Per-record session state stays with its own record")
    func perRecordSessionStateIsIsolated() throws {
        let bundles = try makeBundles(2)
        let pkg = try tempDir("pkg").appendingPathComponent("Set.mur")
        let first = Data(#"{"viewportStartSample":11}"#.utf8)
        let second = Data(#"{"viewportStartSample":22}"#.utf8)

        try MurSessionPackage.write(
            records: [
                .init(recording: bundles[0].recording, recordingDirectory: bundles[0].dir, sessionJSON: first),
                .init(recording: bundles[1].recording, recordingDirectory: bundles[1].dir, sessionJSON: second),
            ],
            to: pkg
        )

        let result = try MurSessionPackage.read(packageURL: pkg, into: try tempDir("open"))
        #expect(result.records[0].sessionJSON == first)
        #expect(result.records[1].sessionJSON == second)
    }

    @Test("The active record is the one the analyst had open at save")
    func activeRecordHonoursCollectionState() throws {
        let bundles = try makeBundles(3)
        let pkg = try tempDir("pkg").appendingPathComponent("Set.mur")
        let wanted = bundles[2].recording.id

        try MurSessionPackage.write(
            records: bundles.map { .init(recording: $0.recording, recordingDirectory: $0.dir) },
            collectionJSON: try JSONEncoder().encode(MurCollectionState(activeRecordingID: wanted)),
            to: pkg
        )

        let result = try MurSessionPackage.read(packageURL: pkg, into: try tempDir("open"))
        #expect(result.activeRecord.identity.recordingID == wanted,
                "a reopen should land on the record the analyst chose, not whichever sorted first")
    }

    @Test("With no active record recorded, the first is presented")
    func activeRecordFallsBackToFirst() throws {
        let bundles = try makeBundles(2)
        let pkg = try tempDir("pkg").appendingPathComponent("Set.mur")
        try MurSessionPackage.write(
            records: bundles.map { .init(recording: $0.recording, recordingDirectory: $0.dir) },
            to: pkg
        )
        let result = try MurSessionPackage.read(packageURL: pkg, into: try tempDir("open"))
        #expect(result.activeRecord.identity.recordingID == bundles[0].recording.id)
    }

    /// An active id naming a record that is not in the package must not crash
    /// or return nothing — it degrades to the first record.
    @Test("An unknown active record degrades to the first, not to a crash")
    func activeRecordSurvivesStaleID() throws {
        let bundles = try makeBundles(2)
        let pkg = try tempDir("pkg").appendingPathComponent("Set.mur")
        try MurSessionPackage.write(
            records: bundles.map { .init(recording: $0.recording, recordingDirectory: $0.dir) },
            collectionJSON: try JSONEncoder().encode(MurCollectionState(activeRecordingID: UUID())),
            to: pkg
        )
        let result = try MurSessionPackage.read(packageURL: pkg, into: try tempDir("open"))
        #expect(result.activeRecord.identity.recordingID == bundles[0].recording.id)
    }

    @Test("A session with no records is refused rather than written")
    func refusesEmptySession() throws {
        let pkg = try tempDir("pkg").appendingPathComponent("Empty.mur")
        #expect(throws: MurSessionError.noRecords) {
            try MurSessionPackage.write(records: [], to: pkg)
        }
        #expect(!FileManager.default.fileExists(atPath: pkg.path))
    }

    /// Subtrees are keyed by recordingID, so the same record twice would
    /// silently overwrite and produce a smaller set than the analyst asked for.
    @Test("The same record twice is refused, not silently collapsed")
    func refusesDuplicateRecordingID() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Dupe.mur")
        let payload = MurSessionPackage.RecordPayload(
            recording: bundles[0].recording, recordingDirectory: bundles[0].dir
        )
        #expect(throws: MurSessionError.duplicateRecordingID(bundles[0].recording.id)) {
            try MurSessionPackage.write(records: [payload, payload], to: pkg)
        }
    }

    @Test("Analyst sidecars follow their own record")
    func sidecarsFollowTheirRecord() throws {
        let bundles = try makeBundles(2)
        // Only the SECOND record carries findings.
        let findings = Data(#"{"schemaVersion":1,"annotations":[]}"#.utf8)
        try findings.write(to: bundles[1].dir.appendingPathComponent(BundleAnnotationsFile.filename))

        let pkg = try tempDir("pkg").appendingPathComponent("Set.mur")
        try MurSessionPackage.write(
            records: bundles.map { .init(recording: $0.recording, recordingDirectory: $0.dir) },
            to: pkg
        )
        let result = try MurSessionPackage.read(packageURL: pkg, into: try tempDir("open"))

        let fm = FileManager.default
        let zero = result.records[0].recordingDirectory.appendingPathComponent(BundleAnnotationsFile.filename)
        let one = result.records[1].recordingDirectory.appendingPathComponent(BundleAnnotationsFile.filename)
        #expect(!fm.fileExists(atPath: zero.path), "record 0 had no findings and must not inherit record 1's")
        #expect(try Data(contentsOf: one) == findings)
    }
}
