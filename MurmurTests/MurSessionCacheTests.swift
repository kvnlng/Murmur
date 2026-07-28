//
//  MurSessionCacheTests.swift
//  MurmurTests
//
//  The load-bearing cache discipline for `.mur`: a stamped blob decodes to its
//  payload ONLY when the stamp matches the running app; a version/param change
//  or corruption is a cache miss (nil → recompute), never a stale render.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("MurSessionCache — version-stamped, drop-on-mismatch")
struct MurSessionCacheTests {

    private let stamp = CacheStamp(producer: "delineator", version: "v2-tangent", parametersKey: "qtc=fridericia;ceiling=500")
    private let payload = Data([0x10, 0x20, 0x30, 0x40, 0x50])

    @Test("Matching stamp returns the exact payload")
    func matchingStampRoundTrips() throws {
        let blob = try MurSessionCache.encode(stamp: stamp, payload: payload)
        #expect(MurSessionCache.decode(blob, expected: stamp) == payload)
    }

    @Test("A different model/delineator version is a cache miss")
    func versionMismatchIsMiss() throws {
        let blob = try MurSessionCache.encode(stamp: stamp, payload: payload)
        let newerApp = CacheStamp(producer: "delineator", version: "v3", parametersKey: stamp.parametersKey)
        #expect(MurSessionCache.decode(blob, expected: newerApp) == nil)
    }

    @Test("A parameter change is a cache miss")
    func parameterMismatchIsMiss() throws {
        let blob = try MurSessionCache.encode(stamp: stamp, payload: payload)
        let reparam = CacheStamp(producer: "delineator", version: "v2-tangent", parametersKey: "qtc=bazett;ceiling=500")
        #expect(MurSessionCache.decode(blob, expected: reparam) == nil)
    }

    @Test("Corrupt / truncated / foreign bytes are a miss, never a throw")
    func corruptIsMiss() throws {
        let blob = try MurSessionCache.encode(stamp: stamp, payload: payload)
        #expect(MurSessionCache.decode(Data([0x00, 0x01]), expected: stamp) == nil)
        #expect(MurSessionCache.decode(blob.prefix(6), expected: stamp) == nil)
        #expect(MurSessionCache.decode(Data("not a blob".utf8), expected: stamp) == nil)
    }

    @Test("Empty payload round-trips under a matching stamp")
    func emptyPayload() throws {
        let blob = try MurSessionCache.encode(stamp: stamp, payload: Data())
        #expect(MurSessionCache.decode(blob, expected: stamp) == Data())
    }
}
