//
//  SourceFingerprintTests.swift
//  MurmurTests
//
//  The bundle-reuse contract: a folder open re-uses an existing recording
//  bundle exactly when the SOURCE files it was imported from are bit-for-bit
//  plausibly unchanged (name + size + mtime for every file the importer
//  reads, present or absent). Everything here protects one invariant — a
//  stale bundle must never be served for changed source data, and unchanged
//  source data must never pay a second import.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("SourceFingerprint — compute and compare")
struct SourceFingerprintTests {

    /// Write a minimal 2-channel record and return its .hea URL.
    private func writeFixture(recordName: String = "rec", in dir: URL) throws -> URL {
        try WFDBRecordWriter.write(
            recordName: recordName,
            channelSamples: [
                Array(repeating: Int32(100), count: 64),
                Array(repeating: Int32(-50), count: 64),
            ],
            sampleRateHz: 128,
            leadNames: ["ECG1", "ECG2"],
            calibration: .init(gain: 200, baseline: 0, unit: "mV"),
            in: dir
        )
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Same unchanged source computes an equal fingerprint")
    func stableAcrossReads() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hea = try writeFixture(in: dir)
        let a = try SourceFingerprint.compute(heaURL: hea)
        let b = try SourceFingerprint.compute(heaURL: hea)
        #expect(a == b)
    }

    @Test("Touching the .dat changes the fingerprint")
    func datMutationChangesFingerprint() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hea = try writeFixture(in: dir)
        let before = try SourceFingerprint.compute(heaURL: hea)
        let datURL = dir.appendingPathComponent("rec.dat")
        var data = try Data(contentsOf: datURL)
        data.append(contentsOf: [0x00, 0x01])
        try data.write(to: datURL)
        let after = try SourceFingerprint.compute(heaURL: hea)
        #expect(before != after)
    }

    @Test("An annotation file appearing changes the fingerprint")
    func atrAppearanceChangesFingerprint() throws {
        // The importer reads <name>.atr when present — a bundle imported
        // without one must not be served once one exists.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hea = try writeFixture(in: dir)
        let before = try SourceFingerprint.compute(heaURL: hea)
        try Data([0x01, 0x02, 0x03]).write(to: dir.appendingPathComponent("rec.atr"))
        let after = try SourceFingerprint.compute(heaURL: hea)
        #expect(before != after)
    }

    @Test("Round-trips through its bundle file")
    func bundleFileRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hea = try writeFixture(in: dir)
        let fingerprint = try SourceFingerprint.compute(heaURL: hea)

        let bundleDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        try fingerprint.write(to: bundleDir)
        #expect(SourceFingerprint.read(from: bundleDir) == fingerprint)
    }

    @Test("Reading from a bundle without a fingerprint is nil, never a throw")
    func absentFingerprintIsNil() throws {
        let bundleDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        #expect(SourceFingerprint.read(from: bundleDir) == nil)
    }

    @Test("Equal fingerprints digest equally; different ones don't (#341)")
    func stableDigestTracksEquality() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hea = try writeFixture(in: dir)
        let a = try SourceFingerprint.compute(heaURL: hea)
        let b = try SourceFingerprint.compute(heaURL: hea)
        #expect(a.stableDigest == b.stableDigest)
        #expect(a.stableDigest.count == 64)   // SHA-256 hex — a valid filename
        // A changed source digests differently.
        let datURL = dir.appendingPathComponent("rec.dat")
        var data = try Data(contentsOf: datURL)
        data.append(0)
        try data.write(to: datURL)
        let c = try SourceFingerprint.compute(heaURL: hea)
        #expect(a.stableDigest != c.stableDigest)
    }
}

@Suite("RecordingStore — bundle reuse on re-import")
@MainActor
struct RecordingStoreReuseTests {

    private func makeStore() throws -> (RecordingStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-reuse-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (RecordingStore(rootURL: root), root)
    }

    private func writeSource(in dir: URL) throws {
        try WFDBRecordWriter.write(
            recordName: "rec",
            channelSamples: [Array(0..<128).map { Int32($0 % 40) }],
            sampleRateHz: 128,
            leadNames: ["ECG1"],
            calibration: .init(gain: 200, baseline: 0, unit: "mV"),
            in: dir
        )
    }

    @Test("A second import of unchanged source reuses the bundle")
    func unchangedSourceReuses() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("reuse-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let first = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        let second = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")

        #expect(second.directory == first.directory)
        #expect(second.recording.id == first.recording.id)
    }

    @Test("A changed source imports fresh")
    func changedSourceImportsFresh() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("reuse-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let first = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        // Rewrite with different samples — same filenames, new content/size.
        try WFDBRecordWriter.write(
            recordName: "rec",
            channelSamples: [Array(0..<256).map { Int32($0 % 40) }],
            sampleRateHz: 128,
            leadNames: ["ECG1"],
            calibration: .init(gain: 200, baseline: 0, unit: "mV"),
            in: source
        )
        let second = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")

        #expect(second.directory != first.directory)
        #expect(second.recording.id != first.recording.id)
    }

    @Test("A gutted bundle is not served — reuse verifies the manifest loads")
    func corruptBundleIsNotReused() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("reuse-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let first = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        // Gut the bundle but leave the fingerprint in place.
        try FileManager.default.removeItem(
            at: first.directory.appendingPathComponent("recording.json"))
        let second = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")

        #expect(second.directory != first.directory)
    }

    // MARK: - Fingerprint index (#341)

    private func indexDir(in root: URL) -> URL {
        root.appendingPathComponent(".fingerprints", isDirectory: true)
    }

    @Test("A fresh import writes an index entry; a second import serves through it")
    func freshImportIndexesAndSecondImportHits() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("reuse-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let first = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")

        let fingerprint = try SourceFingerprint.compute(
            heaURL: source.appendingPathComponent("rec.hea"))
        let entryURL = indexDir(in: root).appendingPathComponent(fingerprint.stableDigest)
        let entry = try String(contentsOf: entryURL, encoding: .utf8)
        #expect(entry == first.directory.lastPathComponent)

        let second = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        #expect(second.directory == first.directory)
        #expect(second.recording.id == first.recording.id)
    }

    @Test("Reuse survives the index being deleted — migration rebuilds it")
    func reuseSurvivesIndexDeletion() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("reuse-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let first = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        // The pre-index-store case: bundles exist, no index at all.
        try FileManager.default.removeItem(at: indexDir(in: root))

        let second = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        #expect(second.directory == first.directory,
                "the index is a cache — its absence must cost a scan, never the reuse")
        // The migration pass rebuilt the entry and the complete marker.
        let fingerprint = try SourceFingerprint.compute(
            heaURL: source.appendingPathComponent("rec.hea"))
        #expect(FileManager.default.fileExists(
            atPath: indexDir(in: root).appendingPathComponent(fingerprint.stableDigest).path))
        #expect(FileManager.default.fileExists(
            atPath: indexDir(in: root).appendingPathComponent("complete").path))
    }

    @Test("A stale index entry falls back to the scan and recovers the real bundle")
    func staleEntryFallsBackToScan() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("reuse-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let first = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        // Corrupt the entry to point at a bundle that doesn't exist.
        let fingerprint = try SourceFingerprint.compute(
            heaURL: source.appendingPathComponent("rec.hea"))
        let entryURL = indexDir(in: root).appendingPathComponent(fingerprint.stableDigest)
        try Data("no-such-bundle".utf8).write(to: entryURL, options: .atomic)

        let second = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        #expect(second.directory == first.directory,
                "a stale entry must degrade to the linear scan, not to a duplicate import")
        // And the fallback repaired the entry.
        let repaired = try String(contentsOf: entryURL, encoding: .utf8)
        #expect(repaired == first.directory.lastPathComponent)
    }

    @Test("A gutted bundle is refused even when the index entry matches")
    func guttedBundleRefusedDespiteIndexEntry() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("reuse-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let first = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        // The invariant from the pre-index code's comment: a fingerprint file
        // that outlives recording.json must not be served — no matter that
        // the index entry is present and points straight at it.
        let fingerprint = try SourceFingerprint.compute(
            heaURL: source.appendingPathComponent("rec.hea"))
        let entryURL = indexDir(in: root).appendingPathComponent(fingerprint.stableDigest)
        #expect(FileManager.default.fileExists(atPath: entryURL.path))
        try FileManager.default.removeItem(
            at: first.directory.appendingPathComponent("recording.json"))

        let second = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        #expect(second.directory != first.directory)
        #expect(FileManager.default.fileExists(
            atPath: first.directory.appendingPathComponent(
                SourceFingerprint.bundleFileName).path),
            "precondition: the gutted bundle still carries its fingerprint")
    }
}
