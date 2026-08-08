//
//  TempScratchSweeperTests.swift
//  MurmurCoreTests
//
//  Out-of-module tests for the launch-time scratch sweep. Exercises the
//  public surface only (no `@testable`), like the rest of this target.
//

import Foundation
import Testing
import MurmurCore

@Suite("TempScratchSweeper — launch-time scratch sweep")
struct TempScratchSweeperTests {

    private let fm = FileManager.default

    /// A unique parent standing in for the container tmp, so tests never
    /// touch (or depend on) the real one.
    private func makeParent() throws -> URL {
        let parent = fm.temporaryDirectory
            .appendingPathComponent("sweeper-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }

    private func makeEntry(_ name: String, in parent: URL, ageSeconds: TimeInterval) throws -> URL {
        let url = parent.appendingPathComponent(name)
        if name.contains(".") && !name.hasSuffix(".mur") {
            try Data("x".utf8).write(to: url)
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if ageSeconds > 0 {
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -ageSeconds)],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    @Test("Removes stale entries for every owned prefix")
    func removesStaleOwnedEntries() throws {
        let parent = try makeParent()
        defer { try? fm.removeItem(at: parent) }

        let stale = try [
            makeEntry("csv-import-\(UUID().uuidString)", in: parent, ageSeconds: 7200),
            makeEntry("mur-session-\(UUID().uuidString)", in: parent, ageSeconds: 7200),
            makeEntry("ui-test-\(UUID().uuidString).mur", in: parent, ageSeconds: 7200),
            makeEntry("ui-test-\(UUID().uuidString).csv", in: parent, ageSeconds: 7200),
            makeEntry("murmur-ui-test-open", in: parent, ageSeconds: 7200),
        ]

        TempScratchSweeper.sweepAtLaunch(in: parent)

        for url in stale {
            #expect(!fm.fileExists(atPath: url.path), "\(url.lastPathComponent) should be swept")
        }
    }

    @Test("Spares entries younger than the cutoff")
    func sparesFreshEntries() throws {
        let parent = try makeParent()
        defer { try? fm.removeItem(at: parent) }

        let fresh = try [
            makeEntry("csv-import-\(UUID().uuidString)", in: parent, ageSeconds: 0),
            makeEntry("mur-session-\(UUID().uuidString)", in: parent, ageSeconds: 0),
            makeEntry("ui-test-\(UUID().uuidString).csv", in: parent, ageSeconds: 0),
        ]

        TempScratchSweeper.sweepAtLaunch(in: parent)

        for url in fresh {
            #expect(fm.fileExists(atPath: url.path), "\(url.lastPathComponent) should survive")
        }
    }

    @Test("Never touches entries outside the owned prefixes, however stale")
    func sparesForeignEntries() throws {
        let parent = try makeParent()
        defer { try? fm.removeItem(at: parent) }

        let foreign = try [
            makeEntry("unrelated-\(UUID().uuidString)", in: parent, ageSeconds: 7200),
            // Owned by SyntheticRecording's own sweep, not this one.
            makeEntry("plotting-ui-test", in: parent, ageSeconds: 7200),
        ]

        TempScratchSweeper.sweepAtLaunch(in: parent)

        for url in foreign {
            #expect(fm.fileExists(atPath: url.path), "\(url.lastPathComponent) should survive")
        }
    }

    @Test("Explicit cutoff wins over the default")
    func explicitCutoff() throws {
        let parent = try makeParent()
        defer { try? fm.removeItem(at: parent) }

        // 30 s old — fresh by the default one-hour cutoff, stale against an
        // explicit cutoff of "10 s ago".
        let entry = try makeEntry("csv-import-\(UUID().uuidString)", in: parent, ageSeconds: 30)

        TempScratchSweeper.sweepAtLaunch(in: parent, olderThan: Date(timeIntervalSinceNow: -10))

        #expect(!fm.fileExists(atPath: entry.path))
    }

    @Test("A missing parent is a quiet no-op")
    func missingParent() {
        let ghost = fm.temporaryDirectory
            .appendingPathComponent("sweeper-tests-missing-\(UUID().uuidString)", isDirectory: true)
        TempScratchSweeper.sweepAtLaunch(in: ghost)   // must not trap
        #expect(!fm.fileExists(atPath: ghost.path))
    }
}
