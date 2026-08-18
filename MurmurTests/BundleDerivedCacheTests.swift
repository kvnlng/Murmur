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
