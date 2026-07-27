//
//  WFDBAnnotationExportTests.swift
//  MurmurTests
//
//  The three load-bearing acceptance tests from the export spec — amber-only,
//  non-clobber, round-trip — plus the reserved-annotator guard.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("WFDB annotation export — amber filter + safe writes")
struct WFDBAnnotationExportTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfdb-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func region(
        _ start: Int64, _ end: Int64,
        state: AnnotationDisposition.State,
        kind: AnnotationDisposition.ConfirmedKind? = nil,
        note: String? = nil
    ) -> RegionDisposition {
        RegionDisposition(
            startSample: start, endSample: end, state: state,
            confirmedKind: kind, note: note, reviewedAt: .now, reviewedBy: "tester"
        )
    }

    // MARK: - Amber-only

    @Test("Confirmed candidates export; dismissed and unreviewed do not")
    func amberOnlyForRegions() {
        // Confirmed, dismissed, and confirmed-again regions. Unreviewed
        // candidates simply have no RegionDisposition record, so they can't
        // appear here — the store only holds reviewed regions.
        let regions = [
            region(1000, 2000, state: .confirmed, kind: .vt),
            region(3000, 4000, state: .dismissed),
            region(5000, 6000, state: .confirmed, kind: .vf, note: "sustained run"),
        ]
        let findings = WFDBAnnotationExport.amberFindings(
            annotations: [],
            annotationDispositions: [:],
            confirmedRegions: regions
        )
        #expect(findings.map(\.startSample) == [1000, 5000])
        #expect(findings.map(\.text) == ["VT", "sustained run"])   // note wins over kind
    }

    @Test("Only confirmed annotations export; dismissed and unreviewed excluded")
    func amberOnlyForAnnotations() {
        let confirmed = Annotation(kind: .range, sampleIndex: 100, endSampleIndex: 200,
                                   category: "PVC", label: "PVC couplet", source: "wfdb.atr")
        let dismissed = Annotation(kind: .point, sampleIndex: 300, category: "N",
                                   label: "beat", source: "wfdb.atr")
        let unreviewed = Annotation(kind: .point, sampleIndex: 400, category: "N",
                                    label: "beat", source: "wfdb.atr")
        let dispositions: [UUID: AnnotationDisposition] = [
            confirmed.id: AnnotationDisposition(annotationID: confirmed.id, state: .confirmed,
                                                confirmedKind: nil, note: nil, reviewedAt: .now, reviewedBy: "t"),
            dismissed.id: AnnotationDisposition(annotationID: dismissed.id, state: .dismissed,
                                                confirmedKind: nil, note: nil, reviewedAt: .now, reviewedBy: "t"),
        ]
        let findings = WFDBAnnotationExport.amberFindings(
            annotations: [confirmed, dismissed, unreviewed],
            annotationDispositions: dispositions,
            confirmedRegions: []
        )
        #expect(findings.count == 1)
        #expect(findings.first?.startSample == 100)
        #expect(findings.first?.text == "PVC couplet")
    }

    // MARK: - Round-trip write

    @Test("Full export writes an annotator file with the confirmed count")
    func fullExportWritesFile() throws {
        let dir = try tempDir()
        let result = try WFDBAnnotationExport.export(
            annotations: [],
            annotationDispositions: [:],
            confirmedRegions: [region(1000, 2000, state: .confirmed, kind: .vt)],
            recordName: "rec",
            in: dir
        )
        #expect(result.annotator == "mur")
        #expect(result.findingCount == 1)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        // Reads back through Murmur's own parser at the right sample.
        let decoded = WFDBAnnotationParser.parse(data: try Data(contentsOf: result.url))
        #expect(decoded.map(\.sampleIndex) == [1000])
    }

    // MARK: - Non-clobber

    @Test("A pre-existing annotator file is byte-identical after a refused export")
    func nonClobber() throws {
        let dir = try tempDir()
        let existing = dir.appendingPathComponent("rec.mur")
        let sentinel = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try sentinel.write(to: existing)

        #expect(throws: WFDBAnnotationWriter.WriteError.self) {
            try WFDBAnnotationExport.export(
                annotations: [],
                annotationDispositions: [:],
                confirmedRegions: [region(1000, 2000, state: .confirmed, kind: .vt)],
                recordName: "rec",
                in: dir,
                overwrite: false
            )
        }
        #expect(try Data(contentsOf: existing) == sentinel)   // untouched
    }

    @Test("Refuses to write the reserved .atr annotator")
    func refusesAtr() throws {
        let dir = try tempDir()
        #expect(throws: WFDBAnnotationWriter.WriteError.reservedAnnotator("atr")) {
            try WFDBAnnotationExport.export(
                annotations: [],
                annotationDispositions: [:],
                confirmedRegions: [region(1000, 2000, state: .confirmed, kind: .vt)],
                recordName: "rec",
                annotator: "ATR",
                in: dir
            )
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("rec.atr").path))
    }

    @Test("Explicit overwrite replaces an existing annotator")
    func overwriteReplaces() throws {
        let dir = try tempDir()
        let existing = dir.appendingPathComponent("rec.mur")
        try Data([0x00]).write(to: existing)
        let result = try WFDBAnnotationExport.export(
            annotations: [],
            annotationDispositions: [:],
            confirmedRegions: [region(1000, 2000, state: .confirmed, kind: .vt)],
            recordName: "rec",
            in: dir,
            overwrite: true
        )
        #expect(result.findingCount == 1)
        let decoded = WFDBAnnotationParser.parse(data: try Data(contentsOf: result.url))
        #expect(decoded.map(\.sampleIndex) == [1000])
    }
}
