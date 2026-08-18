//
//  RecordingBundleSweeperTests.swift
//  MurmurTests
//
//  The sweep must delete ONLY what is provably an unreusable recording
//  bundle — a manifest-carrying directory with no readable fingerprint,
//  past the age cutoff — and must treat everything else in the root as
//  not its business. Deleting user-relevant data here is unrecoverable
//  by design review, so every keep-rule gets its own case.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("RecordingBundleSweeper — unreusable bundles only")
struct RecordingBundleSweeperTests {
    private let oldDate = Date(timeIntervalSinceNow: -86_400)

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-sweep-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A directory with a manifest, optionally fingerprinted, backdated.
    @discardableResult
    private func makeBundle(
        in root: URL, fingerprinted: Bool, backdated: Bool, manifest: Bool = true
    ) throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if manifest {
            try Data("{}".utf8).write(to: dir.appendingPathComponent("recording.json"))
        }
        if fingerprinted {
            try SourceFingerprint(files: [], absentNames: ["a.atr"]).write(to: dir)
        }
        if backdated {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate], ofItemAtPath: dir.path)
        }
        return dir
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("An old, manifest-carrying, unfingerprinted bundle is swept")
    func sweepsUnreusable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dead = try makeBundle(in: root, fingerprinted: false, backdated: true)
        let removed = RecordingBundleSweeper.sweepUnreusableBundles(in: root)
        #expect(removed == 1)
        #expect(!exists(dead))
    }

    @Test("A fingerprinted bundle is the reuse cache and is kept")
    func keepsFingerprinted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try makeBundle(in: root, fingerprinted: true, backdated: true)
        let removed = RecordingBundleSweeper.sweepUnreusableBundles(in: root)
        #expect(removed == 0)
        #expect(exists(kept))
    }

    @Test("A young bundle is spared — it may be a parallel import mid-flight")
    func keepsYoung() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let young = try makeBundle(in: root, fingerprinted: false, backdated: false)
        let removed = RecordingBundleSweeper.sweepUnreusableBundles(in: root)
        #expect(removed == 0)
        #expect(exists(young))
    }

    @Test("A directory without a manifest is not ours and is never touched")
    func keepsForeignDirectories() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign = try makeBundle(
            in: root, fingerprinted: false, backdated: true, manifest: false)
        let removed = RecordingBundleSweeper.sweepUnreusableBundles(in: root)
        #expect(removed == 0)
        #expect(exists(foreign))
    }

    @Test("Plain files in the root are never touched")
    func keepsPlainFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("stray.txt")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: file.path)
        let removed = RecordingBundleSweeper.sweepUnreusableBundles(in: root)
        #expect(removed == 0)
        #expect(exists(file))
    }

    @Test("An absent root is a no-op, never a throw")
    func absentRootNoOp() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-sweep-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(RecordingBundleSweeper.sweepUnreusableBundles(in: missing) == 0)
    }

    @Test("A mixed root sweeps the dead and keeps everything else")
    func mixedRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dead1 = try makeBundle(in: root, fingerprinted: false, backdated: true)
        let dead2 = try makeBundle(in: root, fingerprinted: false, backdated: true)
        let cache = try makeBundle(in: root, fingerprinted: true, backdated: true)
        let young = try makeBundle(in: root, fingerprinted: false, backdated: false)
        let removed = RecordingBundleSweeper.sweepUnreusableBundles(in: root)
        #expect(removed == 2)
        #expect(!exists(dead1))
        #expect(!exists(dead2))
        #expect(exists(cache))
        #expect(exists(young))
    }
}
