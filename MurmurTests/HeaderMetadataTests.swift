//
//  HeaderMetadataTests.swift
//  MurmurTests
//
//  #328 — PhysioNet's modern 12-lead corpora carry structured metadata as
//  `#Key: value` comment lines (`#Age: 85`, `#Sex: Male`, `#Dx: 164889003`),
//  a convention shared by every CinC 2020/2021 source. Murmur captured those
//  lines verbatim but surfaced only the FIRST one as the navigator subtitle
//  and searched only title + subtitle — so on a 45,000-record corpus every
//  row read `Age: 85` and the diagnosis codes were unreachable.
//
//  Values are transcribed, never interpreted: a `Dx` code stays a code.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("Header metadata (#328) — parsing `#Key: value` comments")
struct HeaderFieldParsingTests {

    private func header(comments: [String]) throws -> WFDBHeader {
        let lines = comments.map { "#\($0)" }.joined(separator: "\n")
        return try WFDBHeaderParser.parse(text: """
        rec 1 500 5000
        rec.mat 16 1000/mV 16 0 0 0 0 I
        \(lines)
        """)
    }

    @Test("A Dx line becomes one field, code transcribed verbatim")
    func parsesDxField() throws {
        let h = try header(comments: ["Dx: 164889003,59118001"])
        #expect(h.metadata == [HeaderField(key: "Dx", value: "164889003,59118001")])
    }

    @Test("Age, Sex and Dx keep header order")
    func keepsHeaderOrder() throws {
        let h = try header(comments: ["Age: 85", "Sex: Male", "Dx: 164889003"])
        #expect(h.metadata.map(\.key) == ["Age", "Sex", "Dx"])
        #expect(h.metadata.map(\.value) == ["85", "Male", "164889003"])
    }

    @Test("An `Unknown` value is a value like any other")
    func keepsUnknownValues() throws {
        let h = try header(comments: ["Rx: Unknown"])
        #expect(h.metadata == [HeaderField(key: "Rx", value: "Unknown")])
    }

    @Test("A MIT-BIH comment has no key/value shape and yields no fields")
    func mitBIHCommentYieldsNoFields() throws {
        let h = try header(comments: ["69 M 1085 1629 x1", "Aldomet, Inderal"])
        #expect(h.metadata.isEmpty)
        // …and the raw comments are untouched.
        #expect(h.comments == ["69 M 1085 1629 x1", "Aldomet, Inderal"])
    }

    @Test("A comment containing a URL is never split at the scheme's colon")
    func urlCommentYieldsNoField() throws {
        let h = try header(comments: ["see http://example.org: notes"])
        #expect(h.metadata.isEmpty)
    }

    @Test("Prose with a colon is rejected — a key is not a sentence")
    func proseIsNotAField() throws {
        let h = try header(comments: ["Note, taken at rest: patient reported no symptoms"])
        #expect(h.metadata.isEmpty)
    }

    @Test("An empty value is kept as a field with an empty string")
    func emptyValueIsStillAField() throws {
        let h = try header(comments: ["Hx:"])
        #expect(h.metadata == [HeaderField(key: "Hx", value: "")])
    }

    @Test("Mixed comments contribute only their key/value lines")
    func mixedCommentsPartiallyContribute() throws {
        let h = try header(comments: ["Age: 85", "free-form note with no colon"])
        #expect(h.metadata == [HeaderField(key: "Age", value: "85")])
        #expect(h.comments.count == 2)
    }

    @Test("`display` renders `Key: value`, and bare key when the value is empty")
    func displayRendering() {
        #expect(HeaderField(key: "Age", value: "85").display == "Age: 85")
        #expect(HeaderField(key: "Hx", value: "").display == "Hx")
    }
}

// MARK: - Navigator row

@Suite("Header metadata (#328) — navigator subtitle and search")
struct RecordListEntryMetadataTests {

    private func record(
        _ name: String = "JS00001", comments: [String], samples: Int = 5000
    ) throws -> WFDBRecordEntry {
        let lines = comments.map { "#\($0)" }.joined(separator: "\n")
        let header = try WFDBHeaderParser.parse(text: """
        \(name) 1 500 \(samples)
        \(name).mat 16+24 1000/mV 16 0 0 0 0 I
        \(lines)
        """)
        return WFDBRecordEntry(filename: "\(name).hea", header: header)
    }

    /// One row built in isolation — nothing suppressed, as a single record.
    private func entry(comments: [String], samples: Int = 5000) throws -> RecordListEntry {
        RecordListEntry(try record(comments: comments, samples: samples))
    }

    /// Rows built the way `ContentView.adopt(scan:)` builds them: the folder's
    /// constant keys computed once, then applied to every row.
    private func folder(_ records: [WFDBRecordEntry]) -> [RecordListEntry] {
        let constant = RecordListEntry.constantMetadataKeys(in: records)
        return records.map { RecordListEntry($0, suppressing: constant) }
    }

    /// The three lines every ecg-arrhythmia record carries, verbatim.
    private let corpusConstants = ["Rx: Unknown", "Hx: Unknown", "Sx: Unknown"]

    @Test("A record with metadata shows every informative field, not just the first")
    func subtitleShowsAllFields() throws {
        let row = try entry(comments: ["Age: 85", "Sex: Male", "Dx: 164889003,59118001"])
        #expect(row.subtitle == "10 s · Age: 85 · Sex: Male · Dx: 164889003,59118001")
    }

    // MARK: X56 for metadata — the folder decides, never the value

    @Test("A key identical on every record is dropped from the subtitle — the real corpus shape")
    func constantKeysAreDropped() throws {
        let rows = folder([
            try record("JS00001", comments: ["Age: 85", "Sex: Male", "Dx: 164889003"] + corpusConstants),
            try record("JS00002", comments: ["Age: 42", "Sex: Female", "Dx: 426783006"] + corpusConstants),
            try record("JS00003", comments: ["Age: 67", "Sex: Male", "Dx: 427084000"] + corpusConstants),
        ])
        #expect(rows[0].subtitle == "10 s · Age: 85 · Sex: Male · Dx: 164889003")
        #expect(rows[1].subtitle == "10 s · Age: 42 · Sex: Female · Dx: 426783006")
    }

    @Test("The rule needs no word list: an arbitrary constant is dropped just the same")
    func anyConstantIsDropped() throws {
        // Nothing about "Site" or "ZG-7" is on any list. It is dropped because
        // it is the same on every row, which is the only reason that exists.
        let rows = folder([
            try record("a", comments: ["Age: 85", "Site: ZG-7"]),
            try record("b", comments: ["Age: 42", "Site: ZG-7"]),
        ])
        #expect(rows.allSatisfy { !$0.subtitle.contains("Site") })
        #expect(rows.allSatisfy { $0.subtitle.contains("Age") })
    }

    @Test("`Sex: Unknown` among Male/Female is SHOWN — the word list hid it and was wrong")
    func unknownIsShownWhenItDiscriminates() throws {
        // 22 of ecg-arrhythmia's 45,152 records say this. On those rows it is
        // the discriminating fact, not the absence of one.
        let rows = folder([
            try record("a", comments: ["Sex: Male"] + corpusConstants),
            try record("b", comments: ["Sex: Unknown"] + corpusConstants),
            try record("c", comments: ["Sex: Female"] + corpusConstants),
        ])
        #expect(rows[1].subtitle == "10 s · Sex: Unknown")
        #expect(!rows[1].subtitle.contains("Rx"))
    }

    @Test("A value that differs on ONE record keeps the key on EVERY record")
    func oneDifferenceKeepsTheKeyEverywhere() throws {
        let rows = folder([
            try record("a", comments: ["Rx: Unknown"]),
            try record("b", comments: ["Rx: Unknown"]),
            try record("c", comments: ["Rx: Metoprolol"]),
        ])
        #expect(rows.allSatisfy { $0.subtitle.contains("Rx") })
    }

    @Test("A key present on only SOME records is kept — presence discriminates")
    func partialPresenceIsKept() throws {
        let rows = folder([
            try record("a", comments: ["Age: 85", "Hx: Unknown"]),
            try record("b", comments: ["Age: 42"]),
        ])
        #expect(rows[0].subtitle.contains("Hx: Unknown"))
        #expect(RecordListEntry.constantMetadataKeys(in: [
            try record("a", comments: ["Age: 85", "Hx: Unknown"]),
            try record("b", comments: ["Age: 42"]),
        ]).isEmpty)
    }

    @Test("A single-record folder suppresses nothing")
    func singleRecordSuppressesNothing() throws {
        // Every key is trivially constant across one record; suppressing them
        // all would blank the subtitle for the one row there is.
        let one = try record(comments: ["Age: 85"] + corpusConstants)
        #expect(RecordListEntry.constantMetadataKeys(in: [one]).isEmpty)
        #expect(folder([one])[0].subtitle.contains("Rx: Unknown"))
    }

    @Test("A suppressed field is still searchable")
    func suppressedFieldsRemainSearchable() throws {
        let rows = folder([
            try record("a", comments: ["Age: 85", "Rx: Unknown"]),
            try record("b", comments: ["Age: 42", "Rx: Unknown"]),
        ])
        #expect(!rows[0].subtitle.contains("Rx"))
        #expect(rows[0].searchText.contains("Rx"))
        #expect(rows[0].searchText.contains("Unknown"))
    }

    @Test("When every field is constant, the first comment is shown rather than nothing")
    func allConstantFallsBackToComment() throws {
        let rows = folder([
            try record("a", comments: ["Rx: Unknown", "Hx: Unknown"]),
            try record("b", comments: ["Rx: Unknown", "Hx: Unknown"]),
        ])
        #expect(rows[0].subtitle == "10 s · Rx: Unknown")
    }

    @Test("A comment-only record keeps the original first-comment subtitle")
    func subtitleUnchangedForCommentOnlyRecords() throws {
        let row = try entry(comments: ["69 M 1085 1629 x1", "Aldomet, Inderal"])
        #expect(row.subtitle == "10 s · 69 M 1085 1629 x1")
    }

    @Test("Search text carries a Dx code even when the subtitle truncates")
    func searchTextCarriesDxCodes() throws {
        let row = try entry(comments: ["Age: 85", "Dx: 164889003,59118001,164934002"])
        #expect(row.searchText.contains("59118001"))
        #expect(row.searchText.contains("164934002"))
    }

    @Test("Search text carries the record name and the metadata keys")
    func searchTextCarriesNameAndKeys() throws {
        let row = try entry(comments: ["Sex: Female"])
        #expect(row.searchText.contains("JS00001"))
        #expect(row.searchText.contains("Sex"))
        #expect(row.searchText.contains("Female"))
    }

    @Test("Search text still carries a non-key/value comment")
    func searchTextCarriesRawComments() throws {
        let row = try entry(comments: ["69 M 1085 1629 x1"])
        #expect(row.searchText.contains("1085"))
    }
}

// MARK: - Against the real corpus

@Suite("Header metadata (#328) — against the real corpus")
struct HeaderMetadataRealDataTests {
    /// Same convention as `WFDBCorpusScannerRealDataTests`: a condition trait,
    /// so a machine without the drive declines the test instead of failing it.
    private static let root = URL(
        fileURLWithPath: "/Volumes/PRO-G40/Data/PhysioNet/arrhythmia"
    )

    private static var hasCorpus: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(WFDBCorpusScanner.indexFileName).path
        )
    }

    @Test("ecg-arrhythmia's constants are exactly Rx, Hx, Sx — and `Sex: Unknown` is shown where it occurs",
          .enabled(if: HeaderMetadataRealDataTests.hasCorpus,
                   "ecg-arrhythmia not available on this machine"))
    func constantsOnTheRealCorpus() throws {
        let scan = try WFDBCorpusScanner.scan(root: Self.root)
        let constant = RecordListEntry.constantMetadataKeys(in: scan.entries)

        // Measured on disk: these three are `Unknown` on all 45,152 records;
        // Age, Sex and Dx vary. The rule finds exactly that with no word list.
        #expect(constant == ["Rx", "Hx", "Sx"])

        let rows = scan.entries.map { RecordListEntry($0, suppressing: constant) }
        let first = try #require(rows.first)
        #expect(!first.subtitle.contains("Rx"))
        #expect(first.subtitle.hasPrefix("10 s · Age: "))

        // 22 records say `Sex: Unknown`. The word list hid it on every one of
        // them; on those rows it is the discriminating fact, so it shows.
        let unknownSex = rows.filter { $0.subtitle.contains("Sex: Unknown") }
        #expect(unknownSex.count == 22)
        #expect(unknownSex.contains { $0.id == "WFDBRecords/34/346/JS34080.hea" })
    }
}
