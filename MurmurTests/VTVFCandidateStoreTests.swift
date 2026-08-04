//
//  VTVFCandidateStoreTests.swift
//  MurmurTests
//
//  Candidates and their dispositions must have the SAME lifetime. Before this
//  store existed they did not: `VTVFCandidateDispositionStore` persisted the
//  analyst's confirm/dismiss decisions to the bundle, while the candidates
//  themselves lived only in `VTVFScanContext` and were dropped on the next
//  recording change. Reopening a scanned record showed an empty queue with the
//  verdicts still on disk, bound to regions nothing was rendering.
//
//  These pin the round trip and the two ways a stale sidecar could lie.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("VTVFCandidateStore — committed scans survive a recording change")
struct VTVFCandidateStoreTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vtvf-cand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func candidate(start: Int64, end: Int64, score: Double) -> Annotation {
        VTVFCandidateSource.makeAnnotation(startSample: start, endSample: end, score: score)
    }

    @Test("A committed scan round-trips with its operating point")
    func roundTrip() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateStore(bundleDirectory: dir)
        let candidates = [
            candidate(start: 1000, end: 2000, score: 0.93),
            candidate(start: 5000, end: 6500, score: 0.81),
        ]
        store.save(
            candidates: candidates,
            parametersCaption: "τ 0.87 · min 4s · gap 5s · vtvf_seres_lstm",
            modelIdentifier: "vtvf_seres_lstm",
            modelVersion: "1.2.0",
            tau: 0.87
        )

        let restored = try #require(VTVFCandidateStore(bundleDirectory: dir).load())
        #expect(restored.candidates.count == 2)
        #expect(restored.candidates.map(\.sampleIndex) == [1000, 5000])
        #expect(restored.candidates.map(\.endSampleIndex) == [2000, 6500])
        // The operating point is the point of persisting rather than rescanning:
        // a later model or τ must not silently redefine what was reviewed.
        #expect(restored.modelIdentifier == "vtvf_seres_lstm")
        #expect(restored.modelVersion == "1.2.0")
        #expect(restored.tau == 0.87)
        #expect(restored.parametersCaption?.contains("0.87") == true)
        // Candidates stay recognisable to the review queue after the trip.
        #expect(restored.candidates.allSatisfy { $0.source == VTVFCandidateSource.id })
        #expect(restored.candidates.allSatisfy { $0.category == VTVFCandidateSource.category })
    }

    @Test("A never-scanned recording loads nothing")
    func absentSidecar() throws {
        let dir = try makeTempDir()
        #expect(VTVFCandidateStore(bundleDirectory: dir).load() == nil)
    }

    /// The failure that would be worst in practice: rescanning and finding
    /// nothing, then reopening to see the PREVIOUS scan's candidates resurrected
    /// as if they were current. Saving an empty set must remove the sidecar,
    /// not leave the old one standing.
    @Test("Committing an empty scan clears any previous one from disk")
    func emptyScanRemovesSidecar() throws {
        let dir = try makeTempDir()
        let store = VTVFCandidateStore(bundleDirectory: dir)
        store.save(
            candidates: [candidate(start: 10, end: 20, score: 0.9)],
            parametersCaption: "τ 0.87",
            modelIdentifier: "m", modelVersion: nil, tau: 0.87
        )
        #expect(store.load() != nil)

        store.save(
            candidates: [],
            parametersCaption: "τ 0.99",
            modelIdentifier: "m", modelVersion: nil, tau: 0.99
        )
        #expect(store.load() == nil, "an empty rescan must not leave the old candidates readable")
        #expect(
            !FileManager.default.fileExists(atPath: VTVFCandidateStore.fileURL(in: dir).path),
            "the sidecar file itself should be gone, not merely empty"
        )
    }

    /// A sidecar written by a future version must read as "no saved scan"
    /// rather than as a partially-understood one — same discipline the
    /// disposition sidecars use.
    @Test("A future schema version is ignored rather than half-read")
    func futureSchemaIgnored() throws {
        let dir = try makeTempDir()
        let file = VTVFCandidateFile(
            schemaVersion: VTVFCandidateFile.currentSchemaVersion + 1,
            parametersCaption: "τ 0.87",
            modelIdentifier: "m",
            modelVersion: nil,
            tau: 0.87,
            candidates: [candidate(start: 10, end: 20, score: 0.9)]
        )
        let data = try JSONEncoder().encode(file)
        try data.write(to: VTVFCandidateStore.fileURL(in: dir))

        #expect(VTVFCandidateStore(bundleDirectory: dir).load() == nil)
    }

    @Test("The candidate sidecar travels in a .mur session package")
    func packagedWithSession() {
        // A package carrying the verdicts but not what was judged would reopen
        // with the same orphaned-disposition problem this store exists to fix.
        let names = MurSessionPackage.analystSidecars.map(\.file)
        #expect(names.contains(VTVFCandidateFile.bundleFileName))
        #expect(names.contains(RegionDispositionFile.bundleFileName))
    }
}
