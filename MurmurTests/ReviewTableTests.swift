//
//  ReviewTableTests.swift
//  MurmurTests
//
//  #330 — the cohort review table. One CSV row per annotation across every
//  record in the open folder or session, carrying the analyst's disposition,
//  so verdicts can go back to whatever produced the annotations.
//
//  The two rules worth pinning: unreviewed rows are INCLUDED (a review table
//  needs its denominator), and records the analyst never opened are counted
//  and reported rather than silently dropped.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("Review table (#330) — CSV generation")
struct ReviewTableCSVTests {

    private func row(
        record: String = "JS00001",
        path: String = "01/010/JS00001.hea",
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        start: Int64 = 0,
        state: String = "unreviewed",
        note: String? = nil,
        category: String = "AFib"
    ) -> ReviewTableCSV.Row {
        ReviewTableCSV.Row(
            record: record, recordPath: path, annotationID: id, kind: "range",
            startSample: start, endSample: 5000,
            startSeconds: 0, endSeconds: 10,
            lead: "II", category: category, label: nil, source: "physionet-dx",
            confidence: nil, state: state, confirmedKind: nil, note: note,
            reviewedBy: nil, reviewedAt: nil, flagged: false, headerComments: []
        )
    }

    @Test("Zero rows still emits the header line")
    func headerOnlyForEmptyInput() {
        let csv = ReviewTableCSV.generate(rows: [])
        #expect(csv == ReviewTableCSV.columns.joined(separator: ",") + "\n")
    }

    @Test("The column order is the documented contract")
    func columnOrderIsStable() {
        #expect(ReviewTableCSV.columns.first == "record")
        #expect(ReviewTableCSV.columns.last == "header_comments")
        #expect(ReviewTableCSV.columns.count == 20)
    }

    @Test("A note containing a comma, a quote and a newline is RFC 4180 quoted")
    func quotesTroublesomeNotes() {
        let csv = ReviewTableCSV.generate(rows: [
            row(note: "flutter, not fib; the \"P\" waves\nare sawtooth"),
        ])
        let body = csv.split(separator: "\n", omittingEmptySubsequences: false)
        // The embedded newline means the record spans two physical lines:
        // header + 2 = 3, plus the trailing empty from the final newline.
        #expect(body.count == 4)
        #expect(csv.contains("\"flutter, not fib; the \"\"P\"\" waves\nare sawtooth\""))
    }

    @Test("A field with no special characters is emitted bare")
    func plainFieldsAreNotQuoted() {
        #expect(ReviewTableCSV.escape("AFib") == "AFib")
        #expect(ReviewTableCSV.escape("164889003,59118001") == "\"164889003,59118001\"")
    }

    @Test("Rows sort by record path, then start sample, then id")
    func sortsDeterministically() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let csv = ReviewTableCSV.generate(rows: [
            row(path: "b.hea", id: b, start: 10),
            row(path: "a.hea", id: a, start: 99),
            row(path: "a.hea", id: b, start: 5),
        ])
        let paths = csv.split(separator: "\n").dropFirst().map { $0.split(separator: ",")[1] }
        #expect(Array(paths) == ["a.hea", "a.hea", "b.hea"])
        let starts = csv.split(separator: "\n").dropFirst().map { $0.split(separator: ",")[4] }
        #expect(Array(starts) == ["5", "99", "10"])
    }

    @Test("An unreviewed row carries the state but no review fields")
    func unreviewedRowHasNoReviewFields() {
        let csv = ReviewTableCSV.generate(rows: [row(state: "unreviewed")])
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[13] == "unreviewed")   // state
        #expect(fields[15].isEmpty)            // note
        #expect(fields[16].isEmpty)            // reviewed_by
        #expect(fields[17].isEmpty)            // reviewed_at
    }

    @Test("Timestamps render as fixed-locale ISO 8601 regardless of analyst locale")
    func isoTimestampIsLocaleIndependent() {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(ReviewTableCSV.formatISO(stamp) == "2025-06-15T15:06:40Z")
    }
}

// MARK: - Row collection

@Suite("Review table (#330) — row collection")
struct ReviewTableBuilderTests {

    private func annotation(
        id: UUID = UUID(), category: String = "AFib", start: Int64 = 0
    ) -> Annotation {
        Annotation(
            id: id, kind: .range, sampleIndex: start, endSampleIndex: start + 5000,
            category: category, source: "physionet-dx"
        )
    }

    private func recording(
        device: String, annotations: [Annotation], comments: [String] = []
    ) -> Recording {
        Recording(
            version: 2, id: UUID(), device: device,
            createdAt: Date(timeIntervalSince1970: 0), sourceFileName: "\(device).hea",
            channels: [Channel(
                id: UUID(), name: "II", unit: "mV", sampleRate: 500,
                startTimeUnixMS: 0, sampleCount: 5000,
                storageFileName: "ch.bin", pyramid: []
            )],
            annotations: annotations,
            headerComments: comments
        )
    }

    @Test("An un-imported record is counted and skipped, never silently dropped")
    func countsUnimportedRecords() {
        let imported = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation()]),
                dispositions: [:], headerComments: []
            )
        )
        let missing = ReviewTableBuilder.Source(recordPath: "b.hea", imported: nil)

        let result = ReviewTableBuilder.build(sources: [imported, missing], flaggedIDs: [])
        #expect(result.recordsIncluded == 1)
        #expect(result.annotationRows == 1)
        #expect(result.notImported == 1)
        #expect(result.summary.contains("not imported"))
    }

    @Test("The summary stays silent about skipped records when there are none")
    func summaryOmitsSkipCountWhenZero() {
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation(), annotation()]),
                dispositions: [:], headerComments: []
            )
        )
        let result = ReviewTableBuilder.build(sources: [source], flaggedIDs: [])
        #expect(result.summary == "Exported 2 findings across 1 record.")
    }

    @Test("A disposition attaches to its annotation; others stay unreviewed")
    func attachesDispositions() {
        let reviewed = UUID()
        let untouched = UUID()
        let disposition = AnnotationDisposition(
            annotationID: reviewed, state: .dismissed, confirmedKind: nil,
            note: "flutter, not fib", reviewedAt: Date(timeIntervalSince1970: 1_750_000_000),
            reviewedBy: "kevin"
        )
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [
                    annotation(id: reviewed), annotation(id: untouched, start: 100),
                ]),
                dispositions: [reviewed: disposition],
                headerComments: ["Dx: 164890007"]
            )
        )
        let csv = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv

        #expect(csv.contains("dismissed"))
        #expect(csv.contains("\"flutter, not fib\""))
        #expect(csv.contains("kevin"))
        #expect(csv.contains("unreviewed"))
        #expect(csv.contains("Dx: 164890007"))
    }

    @Test("A flagged record marks every one of its rows")
    func flagsPropagateToRows() {
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation()]),
                dispositions: [:], headerComments: []
            )
        )
        let flagged = ReviewTableBuilder.build(sources: [source], flaggedIDs: ["a.hea"]).csv
        let plain = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv
        #expect(flagged.split(separator: "\n")[1].hasSuffix(",true,"))
        #expect(plain.split(separator: "\n")[1].hasSuffix(",false,"))
    }

    @Test("Sample indices convert to seconds using the record's own rate")
    func convertsSamplesToSeconds() {
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation(start: 250)]),
                dispositions: [:], headerComments: []
            )
        )
        // 250 samples at 500 Hz = 0.5 s; end is 5250 samples = 10.5 s.
        let csv = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[6] == "0.500")
        #expect(fields[7] == "10.500")
    }

    @Test("Zero sources produce a header-only table, not an error")
    func emptyCohortIsHeaderOnly() {
        let result = ReviewTableBuilder.build(sources: [], flaggedIDs: [])
        #expect(result.annotationRows == 0)
        #expect(result.csv == ReviewTableCSV.columns.joined(separator: ",") + "\n")
    }

    @Test("A missing disposition sidecar reads as nothing reviewed, not a failure")
    func missingSidecarIsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ReviewTableBuilder.dispositions(inBundle: dir).isEmpty)
    }

    @Test("Filename is derived from the folder or session name")
    func suggestedFilename() {
        #expect(ReviewTableBuilder.suggestedFilename(sourceDisplayName: "010") == "010-review.csv")
        #expect(ReviewTableBuilder.suggestedFilename(sourceDisplayName: "study.mur") == "study-review.csv")
        #expect(ReviewTableBuilder.suggestedFilename(sourceDisplayName: "") == "cohort-review.csv")
    }
}
