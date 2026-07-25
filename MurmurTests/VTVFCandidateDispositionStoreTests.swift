//
//  VTVFCandidateDispositionStoreTests.swift
//  MurmurTests
//
//  The load-bearing data-model rule for VT/VF candidates: dispositions
//  key on a TIME REGION, so a rescan that re-derives candidates (with new
//  ids) inherits the analyst's earlier confirm/dismiss on any region it
//  overlaps. This is the one rule the flow spec calls out as most likely
//  to be got wrong; these tests pin it (project_vtvf_candidate_review_flow).
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("VTVFCandidateDispositionStore — region-keyed dispositions")
struct VTVFCandidateDispositionStoreTests {

    /// A throwaway bundle directory so each store gets an isolated sidecar.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtvf-disp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Confirm on a region is inherited by an overlapping candidate")
    func overlapInherits() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateDispositionStore(bundleDirectory: dir)
        store.confirm(start: 1000, end: 2000, kind: .vt)

        // A candidate spanning [1500, 2500) overlaps → inherits confirmed.
        #expect(store.state(forStart: 1500, end: 2500) == .confirmed)
        // A candidate that doesn't overlap is still unreviewed.
        #expect(store.state(forStart: 5000, end: 6000) == nil)
    }

    @Test("Rescan: a shifted re-derived candidate inherits the disposition")
    func rescanInheritance() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateDispositionStore(bundleDirectory: dir)
        // Analyst dismisses a candidate at [10_000, 12_500).
        store.dismiss(start: 10_000, end: 12_500)

        // A rescan re-derives a candidate covering roughly the same span
        // (endpoints shifted by a stride). It must inherit "dismissed".
        #expect(store.state(forStart: 10_250, end: 12_750) == .dismissed)
        // And confirmed findings/dispositions are never dropped by rescan:
        #expect(store.records.count == 1)
    }

    @Test("Re-reviewing an overlapping region supersedes the prior call")
    func upsertSupersedes() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateDispositionStore(bundleDirectory: dir)
        store.confirm(start: 1000, end: 2000, kind: .vt)
        store.dismiss(start: 1200, end: 2200)   // overlaps → supersedes

        #expect(store.records.count == 1)
        #expect(store.state(forStart: 1500, end: 1800) == .dismissed)
    }

    @Test("Reset removes every overlapping region")
    func resetClearsOverlap() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateDispositionStore(bundleDirectory: dir)
        store.confirm(start: 1000, end: 2000, kind: .vf)
        store.reset(start: 1500, end: 2500)
        #expect(store.state(forStart: 1000, end: 2000) == nil)
        #expect(store.records.isEmpty)
    }

    @Test("Most-overlapping region wins when several are stored")
    func mostOverlapWins() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateDispositionStore(bundleDirectory: dir)
        store.confirm(start: 0, end: 1000, kind: .vt)       // small overlap with probe
        store.dismiss(start: 900, end: 3000)                 // large overlap with probe
        // Probe [800, 2000): overlaps region A by 200, region B by 1100 →
        // inherits B (dismissed).
        #expect(store.state(forStart: 800, end: 2000) == .dismissed)
    }

    @Test("Dispositions persist across store instances (sidecar round-trip)")
    func persistenceRoundTrip() throws {
        let dir = try makeTempDir()
        do {
            let store = VTVFCandidateDispositionStore(bundleDirectory: dir)
            store.confirm(start: 3000, end: 4000, kind: .unclassified, note: "looks real")
        }
        // A fresh store over the same bundle reads the sidecar back.
        let reopened = VTVFCandidateDispositionStore(bundleDirectory: dir)
        #expect(reopened.records.count == 1)
        let d = try #require(reopened.disposition(forStart: 3200, end: 3800))
        #expect(d.state == .confirmed)
        #expect(d.confirmedKind == .unclassified)
        #expect(d.note == "looks real")
    }

    @Test("Touching endpoints do not count as overlap (half-open)")
    func halfOpenNoTouch() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateDispositionStore(bundleDirectory: dir)
        store.confirm(start: 1000, end: 2000, kind: .vt)
        // [2000, 3000) starts exactly where the stored region ends.
        #expect(store.state(forStart: 2000, end: 3000) == nil)
    }

    @Test("Tally counts confirmed / dismissed / unreviewed across regions")
    func tally() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateDispositionStore(bundleDirectory: dir)
        store.confirm(start: 0, end: 1000, kind: .vt)
        store.dismiss(start: 5000, end: 6000)
        let regions: [(start: Int64, end: Int64)] = [
            (0, 1000),      // confirmed
            (5000, 6000),   // dismissed
            (9000, 10_000), // unreviewed
        ]
        let t = store.tally(forRegions: regions)
        #expect(t.confirmed == 1)
        #expect(t.dismissed == 1)
        #expect(t.unreviewed == 1)
    }
}
