//
//  BundleDerivedCacheTests.swift
//  MurmurTests
//
//  The per-bundle derived cache must serve a payload back only under the
//  exact (producer, app version, parameters) it was stored under — anything
//  else is a miss, never a stale value and never a throw.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("BundleDerivedCache — stamped blob per producer")
struct BundleDerivedCacheTests {

    private struct Payload: Codable, Equatable {
        let values: [Double]
        let caption: String
    }

    private func makeBundleDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Round-trips under the same producer and parameters")
    func roundTrip() throws {
        let dir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Payload(values: [1.5, -2.25], caption: "5-min window")
        BundleDerivedCache.store(payload, producer: "lfhf", parametersKey: "w=300;s=60", in: dir)
        let loaded = BundleDerivedCache.load(
            Payload.self, producer: "lfhf", parametersKey: "w=300;s=60", from: dir)
        #expect(loaded == payload)
    }

    @Test("A parameter change is a miss")
    func parameterMismatchMisses() throws {
        let dir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        BundleDerivedCache.store(
            Payload(values: [1], caption: "a"),
            producer: "lfhf", parametersKey: "w=300;s=60", in: dir)
        let loaded = BundleDerivedCache.load(
            Payload.self, producer: "lfhf", parametersKey: "w=60;s=15", from: dir)
        #expect(loaded == nil)
    }

    @Test("Producers do not read each other's blobs")
    func producerIsolation() throws {
        let dir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        BundleDerivedCache.store(
            Payload(values: [1], caption: "a"),
            producer: "lfhf", parametersKey: "", in: dir)
        let loaded = BundleDerivedCache.load(
            Payload.self, producer: "morphology", parametersKey: "", from: dir)
        #expect(loaded == nil)
    }

    @Test("A blob written under a different app version is a miss")
    func versionMismatchMisses() throws {
        let dir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Forge a blob stamped by "another build" directly through the
        // underlying vault — BundleDerivedCache always stamps the running
        // build, so this is the only way to simulate an update.
        let stale = CacheStamp(producer: "lfhf", version: "0.0+0", parametersKey: "")
        let payload = try JSONEncoder().encode(Payload(values: [1], caption: "a"))
        let blob = try MurSessionCache.encode(stamp: stale, payload: payload)
        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try blob.write(to: cacheDir.appendingPathComponent("lfhf.blob"))

        let loaded = BundleDerivedCache.load(
            Payload.self, producer: "lfhf", parametersKey: "", from: dir)
        #expect(loaded == nil)
    }

    @Test("Absent bundle dir and corrupt blob are misses, never throws")
    func absentAndCorruptMiss() throws {
        let dir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BundleDerivedCache.load(
            Payload.self, producer: "lfhf", parametersKey: "", from: dir) == nil)
        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: cacheDir.appendingPathComponent("lfhf.blob"))
        #expect(BundleDerivedCache.load(
            Payload.self, producer: "lfhf", parametersKey: "", from: dir) == nil)
    }
}

@Suite("Derived cache blobs travel with .mur saves")
struct DerivedCacheBlobPayloadTests {

    @Test("payloads() collects a bundle's cache blobs; reconstitution restores them")
    @MainActor
    func blobsRoundTripThroughPayloads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-payload-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        struct Payload: Codable, Equatable { let x: Int }
        BundleDerivedCache.store(Payload(x: 7), producer: "morphology", parametersKey: "", in: dir)

        let blobs = SessionSaveSet.derivedCacheBlobs(in: dir)
        #expect(blobs.count == 1)
        #expect(blobs["morphology.blob"] != nil)

        // The blob is verbatim — writing it into another bundle's cache dir
        // (what package read does) must decode under the same stamp.
        let restored = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-payload-restored-\(UUID().uuidString)", isDirectory: true)
        let restoredCache = restored.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: restoredCache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: restored) }
        try blobs["morphology.blob"]!.write(to: restoredCache.appendingPathComponent("morphology.blob"))
        let loaded = BundleDerivedCache.load(
            Payload.self, producer: "morphology", parametersKey: "", from: restored)
        #expect(loaded == Payload(x: 7))
    }

    @Test("A bundle without a cache dir contributes no blobs")
    @MainActor
    func absentCacheDirIsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-payload-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SessionSaveSet.derivedCacheBlobs(in: dir).isEmpty)
    }
}

@Suite("BundleDerivedCache — payload compression")
struct BundleDerivedCacheCompressionTests {
    private struct Payload: Codable, Equatable {
        let values: [Double]
        let caption: String
    }

    private func makeBundleDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived-cache-zip-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A legacy raw-JSON blob (no compression prefix) still loads")
    func legacyRawBlobLoads() throws {
        // Forge a blob the way builds before compression wrote them: stamp +
        // raw JSON payload, no magic prefix. Blobs restored out of .mur saves
        // written by those builds surface exactly this format, so it must
        // stay a HIT, not a migration.
        let dir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Payload(values: [3.5, 4.25], caption: "legacy")
        let stamp = CacheStamp(
            producer: "lfhf", version: BundleDerivedCache.appVersionStamp,
            parametersKey: "w=300")
        let blob = try MurSessionCache.encode(
            stamp: stamp, payload: JSONEncoder().encode(payload))
        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try blob.write(to: cacheDir.appendingPathComponent("lfhf.blob"))

        let loaded = BundleDerivedCache.load(
            Payload.self, producer: "lfhf", parametersKey: "w=300", from: dir)
        #expect(loaded == payload)
    }

    @Test("A markings-scale payload round-trips and lands far smaller on disk")
    func markingsScalePayloadShrinks() throws {
        let dir = try makeBundleDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 100k synthetic beats shaped like the field payload that measured
        // 47 MB: fiducials present, every interval populated — the highly
        // repetitive JSON this change exists to shrink. Values vary per beat
        // so the corpus is not trivially constant.
        let beats = (0..<100_000).map { (i: Int) -> MarkingsBeat in
            let r = Int64(i) * 180
            return MarkingsBeat(
                rPeakSampleIndex: r,
                rPeakConfidence: 0.90 + Double(i % 10) / 100.0,
                qrsOnset: MarkingsFiducial(kind: .qrsOnset, sampleIndex: r - 12, confidence: 0.9),
                qrsOffset: MarkingsFiducial(kind: .qrsOffset, sampleIndex: r + 14, confidence: 0.9),
                tOnset: MarkingsFiducial(kind: .tOnset, sampleIndex: r + 40, confidence: 0.8),
                tOffset: MarkingsFiducial(kind: .tOffset, sampleIndex: r + 88, confidence: 0.8),
                prMs: 150.0 + Double(i % 20),
                qrsMs: 90.0 + Double(i % 12),
                qtMs: 380.0 + Double(i % 40),
                qtcMs: 400.0 + Double(i % 35),
                precedingRRMs: 700.0 + Double(i % 90)
            )
        }
        struct BeatsPayload: Codable, Equatable { let beats: [MarkingsBeat] }
        let payload = BeatsPayload(beats: beats)

        BundleDerivedCache.store(payload, producer: "interval-markings",
                                 parametersKey: "bench", in: dir)
        let loaded = BundleDerivedCache.load(
            BeatsPayload.self, producer: "interval-markings",
            parametersKey: "bench", from: dir)
        #expect(loaded == payload)

        let rawJSONBytes = try JSONEncoder().encode(payload).count
        let blobURL = dir.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("interval-markings.blob")
        let blobBytes = try Data(contentsOf: blobURL).count
        // LZFSE on this corpus measures well past this bound; 4x is the
        // conservative floor the change must clear to be worth its seam.
        let shrinkFloor = rawJSONBytes / 4
        #expect(blobBytes < shrinkFloor)
        print("markings-scale bench: raw JSON \(rawJSONBytes) bytes, blob on disk \(blobBytes) bytes")
    }
}
