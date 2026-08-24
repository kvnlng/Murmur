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
        category: String = "AFib",
        confirmedCategory: String? = nil,
        analysisLead: String? = nil,
        analysisLeadReason: String? = nil
    ) -> ReviewTableCSV.Row {
        ReviewTableCSV.Row(
            record: record, recordPath: path, annotationID: id, kind: "range",
            startSample: start, endSample: 5000,
            startSeconds: 0, endSeconds: 10,
            lead: "II", category: category, label: nil, source: "physionet-dx",
            confidence: nil, state: state, confirmedKind: nil,
            confirmedCategory: confirmedCategory, note: note,
            reviewedBy: nil, reviewedAt: nil, flagged: false, headerComments: [],
            analysisLead: analysisLead, analysisLeadReason: analysisLeadReason
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
        #expect(ReviewTableCSV.columns.last == "analysis_lead_reason")
        #expect(ReviewTableCSV.columns.count == 23)
        // #357 — the analysis-lead pair trails everything else, record-level
        // metadata like `flagged` and `header_comments` right before it.
        #expect(ReviewTableCSV.columns.contains("analysis_lead"))
        #expect(
            ReviewTableCSV.columns.firstIndex(of: "analysis_lead_reason")
            == (ReviewTableCSV.columns.firstIndex(of: "analysis_lead").map { $0 + 1 })
        )
        // #331 — the override column sits immediately after the kind it
        // generalises, so a consumer reading left-to-right meets "what the
        // analyst said" right where it used to meet the closed VT/VF enum.
        #expect(
            ReviewTableCSV.columns.firstIndex(of: "confirmed_category")
            == (ReviewTableCSV.columns.firstIndex(of: "confirmed_kind").map { $0 + 1 })
        )
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
        device: String, annotations: [Annotation], comments: [String] = [],
        channels: [Channel]? = nil
    ) -> Recording {
        Recording(
            version: 2, id: UUID(), device: device,
            createdAt: Date(timeIntervalSince1970: 0), sourceFileName: "\(device).hea",
            channels: channels ?? [Channel(
                id: UUID(), name: "II", unit: "mV", sampleRate: 500,
                startTimeUnixMS: 0, sampleCount: 5000,
                storageFileName: "ch.bin", pyramid: []
            )],
            annotations: annotations,
            headerComments: comments
        )
    }

    /// A fresh, empty bundle directory — no `analysis_lead.json`, so
    /// resolution falls through to `firstInFile`. Most of this suite
    /// doesn't care about the analysis-lead columns; this keeps those
    /// tests from having to think about them.
    private func emptyBundleDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-table-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("An un-imported record is counted and skipped, never silently dropped")
    func countsUnimportedRecords() {
        let imported = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation()]),
                dispositions: [:], headerComments: [], bundleDirectory: emptyBundleDir()
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
                dispositions: [:], headerComments: [], bundleDirectory: emptyBundleDir()
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
                headerComments: ["Dx: 164890007"], bundleDirectory: emptyBundleDir()
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
                dispositions: [:], headerComments: [], bundleDirectory: emptyBundleDir()
            )
        )
        let flagged = ReviewTableBuilder.build(sources: [source], flaggedIDs: ["a.hea"]).csv
        let plain = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv
        // Trailing fields: flagged, header_comments (empty), analysis_lead
        // ("II" — firstInFile, no sidecar written), analysis_lead_reason.
        #expect(flagged.split(separator: "\n")[1].hasSuffix(",true,,II,first in file"))
        #expect(plain.split(separator: "\n")[1].hasSuffix(",false,,II,first in file"))
    }

    @Test("Sample indices convert to seconds using the record's own rate")
    func convertsSamplesToSeconds() {
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation(start: 250)]),
                dispositions: [:], headerComments: [], bundleDirectory: emptyBundleDir()
            )
        )
        // 250 samples at 500 Hz = 0.5 s; end is 5250 samples = 10.5 s.
        let csv = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[6] == "0.500")
        #expect(fields[7] == "10.500")
    }

    // MARK: - #357: analysis lead columns

    @Test("A designated bundle exports the analyst-override reason and channel name")
    func designatedBundleExportsOverrideReason() throws {
        let dir = emptyBundleDir()
        try AnalysisLeadDesignator.designate(
            channelNamed: "II", inBundle: dir, reviewer: "kevin",
            at: Date(timeIntervalSince1970: 0)
        )
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation()]),
                dispositions: [:], headerComments: [], bundleDirectory: dir
            )
        )
        let csv = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[21] == "II")
        #expect(fields[22] == "analyst override — kevin")
    }

    @Test("An undesignated bundle with no scored default exports first-in-file")
    func undesignatedBundleExportsFirstInFile() {
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation()]),
                dispositions: [:], headerComments: [], bundleDirectory: emptyBundleDir()
            )
        )
        let csv = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[21] == "II")
        #expect(fields[22] == "first in file")
    }

    @Test("A scored default exports the r-peak score reason to two decimals")
    func scoredDefaultExportsRPeakScore() throws {
        let dir = emptyBundleDir()
        let file = AnalysisLeadFile(
            defaultChoice: .init(
                channelName: "II", reason: .rPeakScore,
                perLeadScores: ["II": 0.9137], scoredAt: Date(timeIntervalSince1970: 0),
                scorerVersion: 1
            ),
            designation: nil
        )
        try file.write(to: dir)
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(device: "A", annotations: [annotation()]),
                dispositions: [:], headerComments: [], bundleDirectory: dir
            )
        )
        let csv = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[21] == "II")
        #expect(fields[22] == "r-peak score 0.91")
    }

    @Test("A record with no populated non-trend channel leaves both columns empty")
    func noResolvableLeadLeavesColumnsEmpty() {
        // sampleRate < 5 Hz is what makes a channel a "trend" channel
        // (`Channel.isTrendChannel`) — no ECG candidate for analysis lead.
        let trendOnly = Channel(
            id: UUID(), name: "HR", unit: "bpm", sampleRate: 1,
            startTimeUnixMS: 0, sampleCount: 100, storageFileName: "hr.bin",
            pyramid: []
        )
        let source = ReviewTableBuilder.Source(
            recordPath: "a.hea",
            imported: .init(
                recording: recording(
                    device: "A", annotations: [annotation()], channels: [trendOnly]
                ),
                dispositions: [:], headerComments: [], bundleDirectory: emptyBundleDir()
            )
        )
        let csv = ReviewTableBuilder.build(sources: [source], flaggedIDs: []).csv
        let fields = csv.split(separator: "\n")[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[21].isEmpty)
        #expect(fields[22].isEmpty)
    }

    @Test("A never-imported record contributes no row at all, so no analysis-lead column to check")
    func neverImportedRecordContributesNoAnalysisLeadRow() {
        // #330's existing rule: an un-imported record contributes zero rows.
        // Documented here so the "empty = never imported" claim in the docs
        // has a test backing it, even though it collapses to the row-count
        // assertion `countsUnimportedRecords` already makes.
        let missing = ReviewTableBuilder.Source(recordPath: "b.hea", imported: nil)
        let result = ReviewTableBuilder.build(sources: [missing], flaggedIDs: [])
        #expect(result.annotationRows == 0)
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
