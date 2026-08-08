//
//  ArrhythmiaScanContextTests.swift
//  MurmurTests
//
//  A2: the MurmurCore side of the arrhythmia scan bridge. The orchestrator
//  (App target — not linkable from here) stays thin; everything testable
//  lives in `ArrhythmiaCandidateSource` / `ArrhythmiaScanContext`, so these
//  tests pin the vocabulary the minted annotations and the review queue
//  agree on, and the sidecar separation that keeps arrhythmia dispositions
//  from cross-inheriting with VT/VF ones.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("ArrhythmiaCandidateSource — annotation vocabulary")
struct ArrhythmiaCandidateSourceTests {

    @Test("Minted annotation carries kind category, neutral label, detail, and reliability")
    func mintedAnnotation() {
        let ann = ArrhythmiaCandidateSource.makeAnnotation(
            kind: .bradycardia,
            startSample: 1000,
            endSample: 5000,
            detail: "median 48 bpm",
            confidence: 0.97,
            lead: "II"
        )
        #expect(ann.kind == .range)
        #expect(ann.sampleIndex == 1000)
        #expect(ann.endSampleIndex == 5000)
        #expect(ann.category == "BRADY_CANDIDATE")
        #expect(ann.displayLabel == "Bradycardia candidate")
        #expect(ann.note == "median 48 bpm")
        #expect(ann.confidence == 0.97)
        #expect(ann.source == ArrhythmiaCandidateSource.id)
        #expect(ann.matchesChannel("II"))
        #expect(!ann.matchesChannel("V1"))
    }

    @Test("Every kind mints a distinct category and a '… candidate' label")
    func kindVocabulary() {
        let categories = Set(ArrhythmiaCandidateSource.Kind.allCases.map(\.rawValue))
        #expect(categories.count == ArrhythmiaCandidateSource.Kind.allCases.count)
        #expect(categories == ArrhythmiaCandidateSource.categories)
        for kind in ArrhythmiaCandidateSource.Kind.allCases {
            // The label is a candidate, never a conclusion (RUO).
            #expect(kind.displayLabel.hasSuffix("candidate"))
        }
    }

    @Test("Lead-less candidate shows on every channel — honest about not knowing")
    func leadlessMatchesAll() {
        let ann = ArrhythmiaCandidateSource.makeAnnotation(
            kind: .pause, startSample: 0, endSample: 100,
            detail: "2.40 s gap", confidence: 1.0, lead: nil
        )
        #expect(ann.matchesChannel("II"))
        #expect(ann.matchesChannel("V5"))
    }
}

@Suite("Arrhythmia disposition sidecar — separate from VT/VF")
struct ArrhythmiaDispositionSidecarTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arr-disp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The two detectors' spans overlap freely (an AFib span can contain a
    /// pause), so a review call on a VT/VF region must never be inherited
    /// by an arrhythmia candidate over the same samples — and vice versa.
    @Test("Same-region dispositions in the two stores never cross-inherit")
    func storesAreIsolated() throws {
        let dir = try makeTempDir()
        let vtvf = VTVFCandidateDispositionStore(bundleDirectory: dir)
        let arr = VTVFCandidateDispositionStore(
            bundleDirectory: dir,
            fileName: ArrhythmiaCandidateSource.dispositionFileName
        )

        vtvf.dismiss(start: 1000, end: 2000)
        #expect(vtvf.state(forStart: 1000, end: 2000) == .dismissed)
        #expect(arr.state(forStart: 1000, end: 2000) == nil)

        arr.confirm(start: 1000, end: 2000, kind: nil)
        #expect(arr.state(forStart: 1000, end: 2000) == .confirmed)
        #expect(vtvf.state(forStart: 1000, end: 2000) == .dismissed)
    }

    @Test("Arrhythmia dispositions persist through their own sidecar reload")
    func sidecarPersists() throws {
        let dir = try makeTempDir()
        let first = VTVFCandidateDispositionStore(
            bundleDirectory: dir,
            fileName: ArrhythmiaCandidateSource.dispositionFileName
        )
        first.confirm(start: 500, end: 900, kind: nil)

        // Reload from disk — and the rescan-inheritance rule still applies:
        // a re-derived candidate overlapping the region inherits the call.
        let reloaded = VTVFCandidateDispositionStore(
            bundleDirectory: dir,
            fileName: ArrhythmiaCandidateSource.dispositionFileName
        )
        #expect(reloaded.state(forStart: 600, end: 1000) == .confirmed)

        // The default-named (VT/VF) sidecar in the same bundle stays empty.
        let vtvf = VTVFCandidateDispositionStore(bundleDirectory: dir)
        #expect(vtvf.records.isEmpty)
    }
}

@Suite("ArrhythmiaScanContext — quality caption")
struct ArrhythmiaScanQualityCaptionTests {

    @Test("Caption names lead, beat population, and artifact fraction")
    func fullCaption() {
        let caption = ArrhythmiaScanContext.qualityCaption(
            beatCount: 92384, leadName: "II", rrArtifactFraction: 0.032
        )
        // The count renders through `.formatted()` — compose the expectation
        // the same way so the assertion is locale-hermetic.
        #expect(caption == "lead II · \(92384.formatted()) beats detected · RR artifact 3.2%")
    }

    @Test("Unknown lead is omitted, not guessed")
    func noLeadCaption() {
        let caption = ArrhythmiaScanContext.qualityCaption(
            beatCount: 12, leadName: nil, rrArtifactFraction: 0
        )
        #expect(caption == "12 beats detected · RR artifact 0.0%")
    }
}
