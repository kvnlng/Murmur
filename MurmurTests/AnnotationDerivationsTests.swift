//
//  AnnotationDerivationsTests.swift
//  MurmurTests
//
//  The memoized render arrays must be EXACTLY what the computed-property
//  chain produced — same union, same rename overlay, same filter, same
//  per-channel lead matching — or the screen quietly diverges from what the
//  persistence paths write.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("AnnotationDerivations — equivalence with the computed chain")
struct AnnotationDerivationsTests {

    private func ann(
        _ category: String, sample: Int64, lead: String? = nil,
        source: String = "wfdb.atr", confidence: Double? = nil
    ) -> Annotation {
        Annotation(
            kind: .point, sampleIndex: sample, category: category,
            confidence: confidence, source: source, lead: lead
        )
    }

    @Test("Union + rename overlay matches the naive chain")
    func unionAndRename() {
        let base = [ann("N", sample: 0), ann("VT", sample: 100, source: "detector")]
        let attached = [ann("PVC", sample: 50, source: "attached")]
        let renamed = [base[1].id: "Renamed VT"]

        let d = AnnotationDerivations.build(
            recordingAnnotations: base, attached: attached,
            renamedLabels: renamed, filter: FindingFilter(), channelNames: ["ECG1"]
        )
        #expect(d.all.count == 3)
        let expectedLabels = (base + attached).map { renamed[$0.id] ?? $0.label }
        #expect(d.all.map(\.label) == expectedLabels)
    }

    @Test("Filter semantics match FindingFilter.matches")
    func filterMatches() {
        var filter = FindingFilter()
        filter.categories = ["VT"]
        let anns = [ann("N", sample: 0), ann("VT", sample: 10), ann("VF", sample: 20)]
        let d = AnnotationDerivations.build(
            recordingAnnotations: anns, attached: [], renamedLabels: [:],
            filter: filter, channelNames: []
        )
        #expect(d.filtered.map(\.category) == ["VT"])
        #expect(d.all.count == 3)
    }

    @Test("Lead-tagged findings land on their channel; lead-less on every channel")
    func channelMatching() {
        let anns = [
            ann("VT", sample: 0, lead: "ECG1"),
            ann("AFib", sample: 10),          // lead-less — whole-recording
            ann("PVC", sample: 20, lead: "ECG2"),
        ]
        let d = AnnotationDerivations.build(
            recordingAnnotations: anns, attached: [], renamedLabels: [:],
            filter: FindingFilter(), channelNames: ["ECG1", "ECG2"]
        )
        #expect(d.byChannel["ECG1"]?.map(\.category) == ["VT", "AFib"])
        #expect(d.byChannel["ECG2"]?.map(\.category) == ["AFib", "PVC"])
    }

    @Test("Filter applies before channel partition")
    func filterBeforePartition() {
        var filter = FindingFilter()
        filter.sources = ["detector"]
        let anns = [
            ann("VT", sample: 0, lead: "ECG1", source: "detector"),
            ann("N", sample: 5, lead: "ECG1"),   // filtered out
        ]
        let d = AnnotationDerivations.build(
            recordingAnnotations: anns, attached: [], renamedLabels: [:],
            filter: filter, channelNames: ["ECG1"]
        )
        #expect(d.byChannel["ECG1"]?.map(\.category) == ["VT"])
    }

    @Test("Empty init renders nothing and equals a build from nothing")
    func emptyEquivalence() {
        let empty = AnnotationDerivations()
        let built = AnnotationDerivations.build(
            recordingAnnotations: [], attached: [], renamedLabels: [:],
            filter: FindingFilter(), channelNames: []
        )
        #expect(empty.all == built.all)
        #expect(empty.filtered == built.filtered)
    }
}
