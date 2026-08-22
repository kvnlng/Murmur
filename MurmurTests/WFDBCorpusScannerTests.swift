//
//  WFDBCorpusScannerTests.swift
//  MurmurTests
//
//  #329 — opening a WFDB corpus from its `RECORDS` index.
//
//  The picker used to read ONE directory, non-recursively, for `.hea` files.
//  That is a MIT-BIH database directory and it is not a large PhysioNet
//  corpus: `ecg-arrhythmia/1.0.0` is 45,152 records in 452 leaf folders behind
//  a `RECORDS` index, and picking its root reported "No WFDB records found".
//
//  What these pin: the index is honoured recursively with root-relative paths,
//  a flat folder still behaves exactly as before, nothing is dropped silently
//  (a missing `.hea` is COUNTED), and the walk cannot leave the folder the
//  analyst granted — the app is sandboxed, so a security-scoped grant covers
//  the picked tree and nothing else.
//
//  Reference for the index format: WFDB Applications Guide, "Database
//  directories and the RECORDS file" — https://physionet.org/physiotools/wag/wag.htm
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("WFDB corpus scanner (#329)")
struct WFDBCorpusScannerTests {
    // MARK: - Fixture building

    /// A temp tree, removed when the test's `defer` fires.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A minimal single-signal header whose record name is the file's own —
    /// enough for `WFDBHeaderParser` and for asserting which record a row is.
    private func writeRecord(_ name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = """
        \(name) 1 500 5000
        \(name).mat 16+24 1000/mV 16 0 -254 21756 0 I
        """
        try header.write(
            to: directory.appendingPathComponent("\(name).hea"),
            atomically: true, encoding: .utf8
        )
    }

    private func writeIndex(_ lines: [String], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(
            to: directory.appendingPathComponent(WFDBCorpusScanner.indexFileName),
            atomically: true, encoding: .utf8
        )
    }

    // MARK: - The corpus shape

    @Test("A nested index resolves to root-relative paths, sorted")
    func walksNestedIndexes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // `a/` has its own index; `b/` has none and is scanned flat — both
        // shapes appear in published corpora, sometimes in the same tree.
        try writeIndex(["a/", "b/"], in: root)
        let dirA = root.appendingPathComponent("a")
        let dirB = root.appendingPathComponent("b")
        try writeIndex(["r1", "r2"], in: dirA)
        try writeRecord("r1", in: dirA)
        try writeRecord("r2", in: dirA)
        try writeRecord("r3", in: dirB)
        try writeRecord("r4", in: dirB)

        let result = try WFDBCorpusScanner.scan(root: root)

        #expect(result.entries.map(\.filename) == [
            "a/r1.hea", "a/r2.hea", "b/r3.hea", "b/r4.hea",
        ])
        #expect(result.skipped.isEmpty)
        #expect(result.unreadable.isEmpty)
        // The row's title is still the record's own name, not its path — the
        // navigator shows "r1", not "a/r1.hea".
        #expect(result.entries.first?.header.recordName == "r1")
    }

    @Test("A directory entry is recognised with or without its trailing slash")
    func recognisesDirectoryWithoutSlash() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeIndex(["a"], in: root)
        try writeRecord("r1", in: root.appendingPathComponent("a"))

        #expect(try WFDBCorpusScanner.scan(root: root).entries.map(\.filename) == ["a/r1.hea"])
    }

    @Test("A record name may itself carry subdirectories")
    func recordNameCarriesSubpath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The shape PhysioNet's ecg-arrhythmia actually publishes: one root
        // index naming deep record paths rather than a chain of indexes.
        try writeIndex(["01/010/JS00001"], in: root)
        try writeRecord("JS00001", in: root.appendingPathComponent("01/010"))

        let result = try WFDBCorpusScanner.scan(root: root)
        #expect(result.entries.map(\.filename) == ["01/010/JS00001.hea"])
    }

    @Test("A flat folder with no index behaves exactly as it did before #329")
    func flatFolderIsUnchanged() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeRecord("100", in: root)
        try writeRecord("101", in: root)

        let result = try WFDBCorpusScanner.scan(root: root)
        #expect(result.entries.map(\.filename) == ["100.hea", "101.hea"])
        #expect(result.skipped.isEmpty)
        #expect(result.unreadable.isEmpty)
    }

    // MARK: - Nothing dropped silently

    @Test("An index entry with no .hea is counted, and the rest still open")
    func missingRecordIsCountedNotFatal() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeIndex(["r1", "ghost", "r2"], in: root)
        try writeRecord("r1", in: root)
        try writeRecord("r2", in: root)

        let result = try WFDBCorpusScanner.scan(root: root)
        #expect(result.entries.map(\.filename) == ["r1.hea", "r2.hea"])
        // The PATH, not a count — an analyst told "1 was skipped" on a 45,000
        // row corpus has been told nothing actionable.
        #expect(result.skipped == ["ghost.hea"])
        #expect(result.shortfallSummary
            == "Opened 2 records; 1 index entry had no readable .hea (ghost.hea).")
    }

    @Test("Comments and blank lines are ignored")
    func ignoresCommentsAndBlanks() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeIndex(["# ecg-arrhythmia 1.0.0", "", "  ", "r1", "  r2  "], in: root)
        try writeRecord("r1", in: root)
        try writeRecord("r2", in: root)

        let result = try WFDBCorpusScanner.scan(root: root)
        #expect(result.entries.map(\.filename) == ["r1.hea", "r2.hea"])
        #expect(result.skipped.isEmpty)
    }

    @Test("A complete scan reports no shortfall at all")
    func cleanScanHasNoBanner() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeIndex(["r1"], in: root)
        try writeRecord("r1", in: root)

        #expect(try WFDBCorpusScanner.scan(root: root).shortfallSummary == nil)
    }

    // MARK: - Containment

    @Test("An entry escaping the picked folder is refused, not followed")
    func refusesEscapingPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A real record next door, to prove the refusal is about the PATH and
        // not about the target failing to exist.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)")
        try writeRecord("secret", in: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try writeIndex(["../\(outside.lastPathComponent)/", "/etc/", "r1"], in: root)
        try writeRecord("r1", in: root)

        let result = try WFDBCorpusScanner.scan(root: root)
        #expect(result.entries.map(\.filename) == ["r1.hea"])
        #expect(result.unreadable.count == 2)
        #expect(result.shortfallSummary?.contains("2 paths were not followed") == true)
    }

    @Test("A symlink pointing out of the picked folder is refused too")
    func refusesEscapingSymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The `..`-free case: nothing in the NAME says this leaves the tree,
        // so containment has to be re-checked after resolving the link.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)")
        try writeRecord("secret", in: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("elsewhere"), withDestinationURL: outside
        )

        try writeIndex(["elsewhere/"], in: root)

        let result = try WFDBCorpusScanner.scan(root: root)
        #expect(result.entries.isEmpty)
        #expect(result.unreadable == ["elsewhere/"])
    }

    // MARK: - Depth

    @Test("A tree deeper than maxDepth is reported, not walked forever")
    func stopsAtMaxDepth() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeIndex(["a/"], in: root)
        let dirA = root.appendingPathComponent("a")
        try writeIndex(["b/"], in: dirA)
        try writeRecord("deep", in: dirA.appendingPathComponent("b"))

        // maxDepth 1 admits `a/` and refuses the level below it.
        let result = try WFDBCorpusScanner.scan(root: root, maxDepth: 1)
        #expect(result.entries.isEmpty)
        #expect(result.unreadable == ["a/b/"])

        // The same tree at the real default resolves completely.
        #expect(try WFDBCorpusScanner.scan(root: root).entries.map(\.filename) == ["a/b/deep.hea"])
    }

    // MARK: - Progress

    @Test("Progress is reported in batches, never once per record")
    func reportsProgressInBatches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // 1,200 records: two callbacks at the 500-record stride, and the
        // scan's own point is that a 45,152-record walk must not call back
        // 45,152 times on the main actor.
        let names = (0..<1200).map { String(format: "r%04d", $0) }
        try writeIndex(names, in: root)
        for name in names { try writeRecord(name, in: root) }

        var reported: [Int] = []
        let result = try WFDBCorpusScanner.scan(root: root) { reported.append($0) }

        #expect(result.entries.count == 1200)
        #expect(reported == [500, 1000])
    }
}

@Suite("WFDB corpus scanner (#329) — against the real corpus")
struct WFDBCorpusScannerRealDataTests {
    /// Same convention as `BeatSourceAbsenceTests`: the fixtures above carry
    /// the contract, this proves the contract matches the corpus the issue was
    /// filed against. It has to be a CONDITION TRAIT — `try #require` in the
    /// body records a failure before it throws, so every machine without the
    /// drive (Xcode Cloud included) would report red.
    private static let root = URL(
        fileURLWithPath: "/Volumes/PRO-G40/Data/PhysioNet/arrhythmia"
    )

    private static var hasCorpus: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(WFDBCorpusScanner.indexFileName).path
        )
    }

    @Test("ecg-arrhythmia 1.0.0 opens whole from its root",
          .enabled(if: WFDBCorpusScannerRealDataTests.hasCorpus,
                   "ecg-arrhythmia not available on this machine"))
    func opensTheArrhythmiaCorpus() throws {
        let result = try WFDBCorpusScanner.scan(root: Self.root)

        // The index names 45,152 records and `find WFDBRecords -name '*.hea'`
        // returns the same 45,152 — the index and the disk agree, so any
        // difference here is about PARSING, not about finding.
        //
        // Two of those files do not parse. The corpus ships them with the
        // record line and the first signal line merged by a lost newline:
        //
        //   JS01052 12 500 500000/mV 16 0 15 31255 0 I
        //
        // — one line where there should be `JS01052 12 500 5000` followed by
        // `JS01052.mat 16+24 1000/mV 16 0 15 31255 0 I`. The result declares 12
        // signals and carries 11, which is a corpus defect, not a parser gap:
        // recovering a record from it would mean inventing the bytes the file
        // does not state. So they are SKIPPED and NAMED, and the other 45,150
        // open — which is the behaviour this whole scanner exists to have.
        #expect(result.entries.count == 45_150)
        #expect(result.skipped == [
            "WFDBRecords/01/019/JS01052.hea",
            "WFDBRecords/23/236/JS23074.hea",
        ])
        #expect(result.unreadable.isEmpty)
        #expect(result.shortfallSummary?.hasPrefix("Opened 45150 records; 2 index entries") == true)

        // The id a row carries is the path `RecordingStore.importWFDB` appends
        // to the picked root, so it must be root-relative with its folders.
        #expect(result.entries.first?.filename == "WFDBRecords/01/010/JS00001.hea")
        #expect(result.entries.first?.header.recordName == "JS00001")
        #expect(FileManager.default.fileExists(
            atPath: Self.root.appendingPathComponent(
                result.entries[0].filename
            ).path
        ))

        // Sorted by that path, which is what makes the navigator's order
        // stable across opens rather than filesystem-enumeration order.
        #expect(result.entries.map(\.filename) == result.entries.map(\.filename).sorted())
    }
}

@Suite("Corpus scan status line (#329)")
struct CorpusScanContextTests {
    @MainActor
    @Test("The line names the folder before any record has been found")
    func namesFolderFirst() {
        let context = CorpusScanContext()
        context.begin(folderName: "ecg-arrhythmia")
        #expect(context.summary == "Scanning ecg-arrhythmia…")
        #expect(context.isActive)
    }

    @MainActor
    @Test("The count is grouped, and singular when it should be")
    func countsAreReadable() {
        let context = CorpusScanContext()
        context.begin(folderName: "ecg-arrhythmia")
        context.update(recordsFound: 1)
        #expect(context.summary == "Scanning ecg-arrhythmia… 1 record")
        context.update(recordsFound: 45_152)
        #expect(context.summary == "Scanning ecg-arrhythmia… 45,152 records")
    }

    @MainActor
    @Test("A late callback from a superseded scan cannot revive the line")
    func staleUpdateIsIgnored() {
        let context = CorpusScanContext()
        context.begin(folderName: "ecg-arrhythmia")
        context.clear()
        context.update(recordsFound: 900)
        #expect(context.summary == nil)
        #expect(context.isActive == false)
    }
}
