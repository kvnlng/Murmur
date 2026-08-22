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

    @Test("Sentinel values are recognized as carrying no information")
    func sentinelDetection() {
        #expect(HeaderField(key: "Age", value: "85").carriesInformation)
        #expect(HeaderField(key: "Dx", value: "164889003").carriesInformation)
        #expect(!HeaderField(key: "Rx", value: "Unknown").carriesInformation)
        #expect(!HeaderField(key: "Rx", value: "unknown").carriesInformation)
        #expect(!HeaderField(key: "Hx", value: "N/A").carriesInformation)
        #expect(!HeaderField(key: "Sx", value: "").carriesInformation)
        // A value that merely CONTAINS a sentinel word still informs.
        #expect(HeaderField(key: "Hx", value: "unknown origin syncope").carriesInformation)
    }
}

// MARK: - Navigator row

@Suite("Header metadata (#328) — navigator subtitle and search")
struct RecordListEntryMetadataTests {

    private func entry(comments: [String], samples: Int = 5000) throws -> RecordListEntry {
        let lines = comments.map { "#\($0)" }.joined(separator: "\n")
        let header = try WFDBHeaderParser.parse(text: """
        JS00001 1 500 \(samples)
        JS00001.mat 16+24 1000/mV 16 0 0 0 0 I
        \(lines)
        """)
        return RecordListEntry(WFDBRecordEntry(filename: "JS00001.hea", header: header))
    }

    @Test("A record with metadata shows every informative field, not just the first")
    func subtitleShowsAllFields() throws {
        let row = try entry(comments: ["Age: 85", "Sex: Male", "Dx: 164889003,59118001"])
        #expect(row.subtitle == "10 s · Age: 85 · Sex: Male · Dx: 164889003,59118001")
    }

    @Test("Sentinel-valued fields are dropped from the subtitle — the real corpus shape")
    func subtitleDropsNoInformationSentinels() throws {
        // Every record in PhysioNet ecg-arrhythmia carries these three.
        let row = try entry(comments: [
            "Age: 85", "Sex: Male", "Dx: 164889003",
            "Rx: Unknown", "Hx: Unknown", "Sx: Unknown",
        ])
        #expect(row.subtitle == "10 s · Age: 85 · Sex: Male · Dx: 164889003")
    }

    @Test("A dropped sentinel field is still searchable")
    func sentinelFieldsRemainSearchable() throws {
        let row = try entry(comments: ["Age: 85", "Rx: Unknown"])
        #expect(!row.subtitle.contains("Rx"))
        #expect(row.searchText.contains("Rx"))
        #expect(row.searchText.contains("Unknown"))
    }

    @Test("A record whose metadata is ALL sentinels falls back to the first comment")
    func allSentinelsFallsBackToComment() throws {
        let row = try entry(comments: ["Rx: Unknown", "Hx: Unknown"])
        #expect(row.subtitle == "10 s · Rx: Unknown")
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
