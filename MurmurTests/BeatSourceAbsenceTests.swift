//
//  BeatSourceAbsenceTests.swift
//  MurmurTests
//
//  #206 — a record whose annotations carry no beats.
//
//  Every beat-derived surface (Variability Metrics, the Trend stack's beat
//  lanes, Morphology) reads annotator-coded beats out of the `.atr`, and
//  Murmur has no beat detector. On vfdb — 22 records, 592 annotations, every
//  one a rhythm change and not one beat — all three surfaces unmounted
//  silently, each through its own reasonable-looking gate.
//
//  These pin the question that decides all three, now asked in one place:
//  does this record have beats, and if not, why not. The two reasons are kept
//  apart because they read differently to an analyst — a full review queue
//  with no metrics looks like a broken import, and no annotations at all
//  looks like what it is.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Beat-source absence (#206)")
struct BeatSourceAbsenceTests {

    private func recording(_ annotations: [Annotation]) -> Recording {
        Recording(
            version: 1, id: UUID(), device: "test", createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "418.hea",
            channels: [Channel(id: UUID(), name: "ECG", unit: "mV", sampleRate: 250,
                               startTimeUnixMS: 0, sampleCount: 250_000,
                               storageFileName: "418.bin", pyramid: [])],
            annotations: annotations)
    }

    /// A rhythm-change marker as the WFDB adapter writes one: `+` in the
    /// category, the rhythm in the label. This is the whole of vfdb.
    private func rhythm(_ at: Int64) -> Annotation {
        Annotation(kind: .point, sampleIndex: at, category: "+", source: "wfdb.atr")
    }

    private func beat(_ at: Int64, _ symbol: String = "N") -> Annotation {
        Annotation(kind: .point, sampleIndex: at, category: symbol, source: "wfdb.atr")
    }

    @Test("A record with beats reports no absence")
    func beatsPresent() {
        let r = recording([beat(100), rhythm(0), beat(350)])
        #expect(r.beatSourceAbsence() == nil,
                "This record has beats; nothing should be disclosed")
    }

    @Test("Rhythm-only annotations are named as such, with the marker count")
    func rhythmOnly() {
        // vfdb 418's shape: 121 rhythm markers, zero beats. The count travels
        // because it is what makes the record look healthy — the analyst can
        // see those 121 in the review queue and is owed the connection.
        let r = recording((0..<121).map { rhythm(Int64($0) * 1000) })
        #expect(r.beatSourceAbsence() == .rhythmAnnotationsOnly(rhythmCount: 121))
    }

    @Test("No WFDB annotations at all is a different statement")
    func noAnnotationsAtAll() {
        #expect(recording([]).beatSourceAbsence() == .noAnnotations)
    }

    @Test("Only `.atr` annotations count toward the rhythm tally")
    func nonAtrSourcesAreNotTheRecordsAnnotations() {
        // An analyst's own note, or a producer's finding, is not evidence
        // about what the ANNOTATOR coded — counting it would report a record
        // as rhythm-annotated because someone typed a note into it.
        let r = recording([
            Annotation(kind: .point, sampleIndex: 10, category: "note", source: "murmur.note"),
            Annotation(kind: .point, sampleIndex: 20, category: "PVC", source: "producer.x"),
        ])
        #expect(r.beatSourceAbsence() == .noAnnotations)
    }

    @Test("Non-`N` beat symbols still count as beats")
    func anyBeatSymbolCounts() {
        // Morphology takes ALL beats, not just normals, so a record coded
        // entirely `V` has a beat source even though HRV would decline it.
        let r = recording([beat(100, "V"), beat(400, "V")])
        #expect(r.beatSourceAbsence() == nil)
    }

    // MARK: - The sibling beat file

    @Test("A sibling .qrs is found and named; nothing is invented when absent")
    func siblingBeatFile() throws {
        // afdb is the case this exists for: its `.atr` is rhythm-only exactly
        // like vfdb's, but the beats are right there in `<record>.qrs`. The
        // difference between "no beats" and "beats in a file we don't open"
        // is the difference between a dead end and a next step.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("beat-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(BeatSourceDisclosure.siblingBeatFileName(forRecordNamed: "04015", in: dir) == nil,
                "Nothing on disk — nothing should be claimed")

        try Data().write(to: dir.appendingPathComponent("04015.qrs"))
        #expect(BeatSourceDisclosure.siblingBeatFileName(forRecordNamed: "04015", in: dir) == "04015.qrs")

        // Another record's beat file is not this record's.
        #expect(BeatSourceDisclosure.siblingBeatFileName(forRecordNamed: "418", in: dir) == nil,
                "A sibling belonging to a different record must not be offered")
    }

    @Test("The wqrs detector's output is recognised too")
    func siblingWqrsFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("beat-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("100.wqrs"))
        #expect(BeatSourceDisclosure.siblingBeatFileName(forRecordNamed: "100", in: dir) == "100.wqrs")
    }

    // MARK: - Against the real databases

    /// Where the local PhysioNet copies live. Absent on CI and on any machine
    /// without the drive, and these tests skip rather than fail there — the
    /// fixtures above carry the contract; these prove the fixtures match the
    /// data the issue was filed against.
    ///
    /// The skip has to be a CONDITION TRAIT. `try #require(fileExists…)` in
    /// the body reads like a skip and isn't one: it records an expectation
    /// failure before it throws, so every machine without the drive — Xcode
    /// Cloud included — reported these as red. `.enabled(if:)` is the only
    /// thing Swift Testing offers that actually declines to run the test.
    private static let physioNet = URL(fileURLWithPath: "/Volumes/PRO-G40/Data/PhysioNet")

    /// Whether a PhysioNet record is on this machine, for the traits below.
    /// Static because a trait's condition is evaluated outside any instance.
    private static func hasRecord(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: physioNet.appendingPathComponent(relativePath).path)
    }

    private func importRecord(_ hea: URL) throws -> Recording {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return try WFDBImporter.importRecord(heaURL: hea, outputDirectory: out).recording
    }

    @Test("vfdb 418, imported for real, reports rhythm-only",
          .enabled(if: BeatSourceAbsenceTests.hasRecord("vfdb/418.hea"),
                   "vfdb not available on this machine"))
    func realVFDBRecordIsRhythmOnly() throws {
        let hea = Self.physioNet.appendingPathComponent("vfdb/418.hea")
        let recording = try importRecord(hea)
        let absence = try #require(recording.beatSourceAbsence(),
                                   "418 is the record #206 was filed against; it must report an absence")
        guard case .rhythmAnnotationsOnly(let count) = absence else {
            Issue.record("418 reported \(absence), expected rhythm-only")
            return
        }
        // The issue counted 121 rhythm markers by parsing the `.atr` directly.
        // Reproducing that number through the app's own importer is what makes
        // this a check on the app rather than on my arithmetic.
        #expect(count == 121, "Expected 418's 121 rhythm markers, got \(count)")
    }

    @Test("afdb is rhythm-only too, but its beats are in a sibling file we can name",
          .enabled(if: BeatSourceAbsenceTests.hasRecord("afdb/04015.hea"),
                   "afdb not available on this machine"))
    func realAFDBRecordOffersItsSiblingFile() throws {
        let dir = Self.physioNet.appendingPathComponent("afdb")
        let hea = dir.appendingPathComponent("04015.hea")
        let recording = try importRecord(hea)
        #expect(recording.beatSourceAbsence() != nil,
                "afdb's .atr is rhythm-annotated like vfdb's")
        #expect(BeatSourceDisclosure.siblingBeatFileName(forRecordNamed: "04015", in: dir) == "04015.qrs",
                "afdb ships the beats in a .qrs the importer ignores — the whole point of naming it")
    }
}
