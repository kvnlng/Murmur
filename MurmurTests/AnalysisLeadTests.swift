//
//  AnalysisLeadTests.swift
//  MurmurTests
//
//  #357: the analysis-lead resolution contract. A calculation may never
//  be gated on a lead's NAME — resolution is designation → stored
//  default → first-in-file, and every branch carries its provenance.
//

import Foundation
@testable import MurmurCore
import MurmurMetrics
import Testing

@Suite("Analysis lead — sidecar and resolution")
struct AnalysisLeadTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func channel(_ name: String, sampleCount: Int64 = 3600, storageFileName: String? = nil) -> Channel {
        Channel(
            id: UUID(), name: name, unit: "mV", sampleRate: 360,
            startTimeUnixMS: 0, sampleCount: sampleCount,
            storageFileName: storageFileName ?? "channel_\(name).bin", pyramid: [])
    }

    /// Two-ECG-channel recording; channel binaries are not needed for
    /// resolution tests (only for scoring, which Task 2 covers).
    private func makeRecording(channels: [Channel]? = nil) -> Recording {
        Recording(
            version: Recording.currentVersion, id: UUID(), device: "test",
            createdAt: Date(timeIntervalSince1970: 0), sourceFileName: "rec.hea",
            channels: channels ?? [
                channel("MLII", storageFileName: "channel_MLII.bin"),
                channel("V5", storageFileName: "channel_V5.bin"),
            ]
        )
    }

    @Test("Sidecar round-trips; absent file reads nil, never a throw")
    func sidecarRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AnalysisLeadFile.read(from: dir) == nil)

        let file = AnalysisLeadFile(
            defaultChoice: .init(channelName: "V5", reason: .rPeakScore,
                                 perLeadScores: ["MLII": 3.2, "V5": 6.1],
                                 scoredAt: Date(timeIntervalSince1970: 100),
                                 scorerVersion: 1),
            designation: nil
        )
        try file.write(to: dir)
        #expect(AnalysisLeadFile.read(from: dir) == file)
    }

    @Test("No sidecar resolves first-in-file with that provenance")
    func noSidecarIsFirstInFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "MLII")
        #expect(resolution?.provenance == .firstInFile)
        #expect(resolution?.staleDesignation == nil)
    }

    @Test("Stored default wins over first-in-file, with score provenance")
    func storedDefaultWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AnalysisLeadFile(
            defaultChoice: .init(channelName: "V5", reason: .rPeakScore,
                                 perLeadScores: ["MLII": 3.2, "V5": 6.1],
                                 scoredAt: .now, scorerVersion: 1),
            designation: nil
        ).write(to: dir)
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "V5")
        #expect(resolution?.provenance == .rPeakScore(score: 6.1, perLead: ["MLII": 3.2, "V5": 6.1]))
    }

    @Test("Designation wins over the stored default")
    func designationWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 200)
        try AnalysisLeadFile(
            defaultChoice: .init(channelName: "V5", reason: .rPeakScore,
                                 perLeadScores: [:], scoredAt: .now, scorerVersion: 1),
            designation: .init(channelName: "MLII", reviewer: "kevin", designatedAt: date)
        ).write(to: dir)
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "MLII")
        #expect(resolution?.provenance == .designated(reviewer: "kevin", date: date))
    }

    @Test("A designation naming a missing channel is disclosed and ignored")
    func staleDesignationFallsThrough() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AnalysisLeadFile(
            defaultChoice: .init(channelName: "V5", reason: .rPeakScore,
                                 perLeadScores: [:], scoredAt: .now, scorerVersion: 1),
            designation: .init(channelName: "V9", reviewer: "kevin", designatedAt: .now)
        ).write(to: dir)
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "V5")
        #expect(resolution?.staleDesignation == "V9")
    }

    @Test("A stored default naming a missing channel falls to first-in-file")
    func staleDefaultFallsThrough() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AnalysisLeadFile(
            defaultChoice: .init(channelName: "GONE", reason: .rPeakScore,
                                 perLeadScores: [:], scoredAt: .now, scorerVersion: 1),
            designation: nil
        ).write(to: dir)
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "MLII")
        #expect(resolution?.provenance == .firstInFile)
    }

    @Test("Duplicate names resolve to the first match (X96's rule)")
    func duplicateNamesFirstMatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = makeRecording(channels: [
            channel("MLII", sampleCount: 3600, storageFileName: "channel_MLII.bin"),
            channel("V5", sampleCount: 3600, storageFileName: "channel_V5.bin"),
            channel("MLII", sampleCount: 100, storageFileName: "channel_MLII_2.bin"),
        ])
        try AnalysisLeadFile(
            defaultChoice: nil,
            designation: .init(channelName: "MLII", reviewer: "kevin", designatedAt: .now)
        ).write(to: dir)
        let resolution = recording.analysisLead(inBundle: dir)
        #expect(resolution?.channel.sampleCount == 3600)   // the first MLII
    }

    @Test("An empty leading channel is not a candidate — first-in-file skips to the populated one")
    func emptyLeadingChannelSkippedForFirstInFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = makeRecording(channels: [
            channel("MLII", sampleCount: 0, storageFileName: "channel_MLII.bin"),
            channel("V5", sampleCount: 3600, storageFileName: "channel_V5.bin"),
        ])
        let resolution = recording.analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "V5")
        #expect(resolution?.provenance == .firstInFile)
        #expect(resolution?.staleDesignation == nil)
    }

    @Test("A designation naming an empty channel falls through exactly like a missing name")
    func designationNamingEmptyChannelFallsThrough() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recording = makeRecording(channels: [
            channel("MLII", sampleCount: 0, storageFileName: "channel_MLII.bin"),
            channel("V5", sampleCount: 3600, storageFileName: "channel_V5.bin"),
        ])
        try AnalysisLeadFile(
            defaultChoice: nil,
            designation: .init(channelName: "MLII", reviewer: "kevin", designatedAt: .now)
        ).write(to: dir)
        let resolution = recording.analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "V5")
        #expect(resolution?.provenance == .firstInFile)
        #expect(resolution?.staleDesignation == "MLII")
    }

    @Test("Registry registers, serves, and clears a scorer")
    func registryLifecycle() {
        struct Fake: AnalysisLeadScorer {
            func scoreLeads(_ leads: [(name: String, samples: [Float])],
                            sampleRate: Double) -> [String: Double]? { [:] }
        }
        let registry = AnalysisLeadScoring()
        #expect(registry.currentScorer() == nil)
        registry.register(Fake())
        #expect(registry.currentScorer() != nil)
        registry.clearForTesting()
        #expect(registry.currentScorer() == nil)
    }
}

// MARK: - Header disclosure line (§1.6)

/// The spec's §1.6 strings, pinned character for character. The renderer
/// exists to produce THESE sentences — a wording change here is a spec
/// change, not a refactor, which is why the expectations are literals and
/// not compositions of the implementation's own helpers.
@Suite("Analysis lead — header disclosure line")
struct AnalysisLeadHeaderLineTests {

    private func channel(_ name: String) -> Channel {
        Channel(
            id: UUID(), name: name, unit: "mV", sampleRate: 360,
            startTimeUnixMS: 0, sampleCount: 3600,
            storageFileName: "channel_\(name).bin", pyramid: [])
    }

    private func resolution(_ name: String,
                            _ provenance: AnalysisLeadProvenance,
                            stale: String? = nil) -> AnalysisLeadResolution {
        AnalysisLeadResolution(channel: channel(name), provenance: provenance,
                               staleDesignation: stale)
    }

    /// 2026-08-24 00:30 UTC — deliberately an instant whose LOCAL date is
    /// the 23rd in every zone behind UTC. A renderer that formatted in the
    /// machine's own time zone would print "2026-08-23" here and fail.
    private var designationDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 24
        components.hour = 0
        components.minute = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    @Test("Designated")
    func designated() {
        let line = AnalysisLeadHeaderLine.text(
            for: resolution("V4", .designated(reviewer: "kevin", date: designationDate)),
            excludedSummary: nil)
        #expect(line == "analysis lead: V4 — designated by kevin, 2026-08-24")
    }

    @Test("Scored")
    func scored() {
        let scored = resolution("MLII", .rPeakScore(score: 6.1,
                                                    perLead: ["MLII": 6.1, "V5": 3.2]))
        #expect(AnalysisLeadHeaderLine.text(for: scored, excludedSummary: nil)
            == "analysis lead: MLII — strongest R peaks")
        // A per-lead exclusion summary, when the caller has one, rides in
        // parentheses after the reason — the choice first, the qualifier after.
        #expect(AnalysisLeadHeaderLine.text(for: scored,
                                            excludedSummary: "V5: 18% of beats excluded")
            == "analysis lead: MLII — strongest R peaks (V5: 18% of beats excluded)")
    }

    @Test("First in file")
    func firstInFile() {
        #expect(AnalysisLeadHeaderLine.text(for: resolution("MLII", .firstInFile),
                                            excludedSummary: nil)
            == "analysis lead: MLII — first in file")
    }

    @Test("Stale designation is reported")
    func stale() {
        let fellThrough = resolution("MLII", .rPeakScore(score: 6.1, perLead: [:]),
                                     stale: "V9")
        #expect(AnalysisLeadHeaderLine.text(for: fellThrough, excludedSummary: nil)
            == "designated lead V9 not in this record — using default"
            + " · analysis lead: MLII — strongest R peaks")
    }

    @Test("The revert menu item names what a revert lands on")
    func defaultLabelIsTheReasonPhrase() {
        // The context menu's "Revert to default (…)" slot — the same
        // name-and-reason pair the header line states, without the prefix.
        #expect(AnalysisLeadHeaderLine.label(
            for: resolution("MLII", .rPeakScore(score: 6.1, perLead: [:])))
            == "MLII — strongest R peaks")
        #expect(AnalysisLeadHeaderLine.label(for: resolution("V5", .firstInFile))
            == "V5 — first in file")
    }
}

// MARK: - Designation write path

@Suite("Analysis lead — designating and reverting")
struct AnalysisLeadDesignatorTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-designate-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func channel(_ name: String) -> Channel {
        Channel(
            id: UUID(), name: name, unit: "mV", sampleRate: 360,
            startTimeUnixMS: 0, sampleCount: 3600,
            storageFileName: "channel_\(name).bin", pyramid: [])
    }

    private func makeRecording() -> Recording {
        Recording(
            version: Recording.currentVersion, id: UUID(), device: "test",
            createdAt: Date(timeIntervalSince1970: 0), sourceFileName: "rec.hea",
            channels: [channel("MLII"), channel("V5")]
        )
    }

    private func scoredDefault() -> AnalysisLeadFile {
        AnalysisLeadFile(
            defaultChoice: .init(channelName: "MLII", reason: .rPeakScore,
                                 perLeadScores: ["MLII": 6.1, "V5": 3.2],
                                 scoredAt: Date(timeIntervalSince1970: 100),
                                 scorerVersion: 1),
            designation: nil)
    }

    @Test("Designating writes the analyst's assertion and leaves the default alone")
    func designateWritesDesignation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = scoredDefault()
        try original.write(to: dir)

        let date = Date(timeIntervalSince1970: 500)
        try AnalysisLeadDesignator.designate(
            channelNamed: "V5", inBundle: dir, reviewer: "kevin", at: date)

        let written = AnalysisLeadFile.read(from: dir)
        #expect(written?.designation
            == .init(channelName: "V5", reviewer: "kevin", designatedAt: date))
        // The import-time stamp is never rewritten — scope decision 2.
        #expect(written?.defaultChoice == original.defaultChoice)
        #expect(makeRecording().analysisLead(inBundle: dir)?.channel.name == "V5")
    }

    @Test("Designating a bundle with no sidecar yet writes one with no default")
    func designateWithoutSidecar() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AnalysisLeadDesignator.designate(
            channelNamed: "V5", inBundle: dir, reviewer: "kevin",
            at: Date(timeIntervalSince1970: 500))
        let written = AnalysisLeadFile.read(from: dir)
        #expect(written?.designation?.channelName == "V5")
        // Absent stays absent: nothing fabricates a default that was never
        // scored (a bundle cut before the stamp existed keeps saying so).
        #expect(written?.defaultChoice == nil)
    }

    @Test("Reverting deletes the designation and keeps the default")
    func revertClearsDesignationOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = scoredDefault()
        try original.write(to: dir)
        try AnalysisLeadDesignator.designate(
            channelNamed: "V5", inBundle: dir, reviewer: "kevin",
            at: Date(timeIntervalSince1970: 500))

        try AnalysisLeadDesignator.revertToDefault(inBundle: dir)

        let written = AnalysisLeadFile.read(from: dir)
        #expect(written?.designation == nil)
        #expect(written?.defaultChoice == original.defaultChoice)
        #expect(makeRecording().analysisLead(inBundle: dir)?.channel.name == "MLII")
    }

    @Test("Reverting a bundle that was never designated is a no-op, not a throw")
    func revertWithoutDesignation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try scoredDefault().write(to: dir)
        try AnalysisLeadDesignator.revertToDefault(inBundle: dir)
        #expect(AnalysisLeadFile.read(from: dir) == scoredDefault())
    }

    @Test("The default resolution ignores a standing designation")
    func defaultResolutionIgnoresDesignation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try scoredDefault().write(to: dir)
        try AnalysisLeadDesignator.designate(
            channelNamed: "V5", inBundle: dir, reviewer: "kevin",
            at: Date(timeIntervalSince1970: 500))

        let recording = makeRecording()
        #expect(recording.analysisLead(inBundle: dir)?.channel.name == "V5")
        // What the menu's "Revert to default (…)" names, and where a revert
        // lands: the stored default, as if the designation were not there.
        let fallback = recording.analysisLeadDefault(inBundle: dir)
        #expect(fallback?.channel.name == "MLII")
        #expect(fallback?.provenance == .rPeakScore(score: 6.1,
                                                    perLead: ["MLII": 6.1, "V5": 3.2]))
        #expect(fallback?.staleDesignation == nil)
    }

    @Test("An undesignated record offers designation on every lead, revert on none")
    func undesignatedRecordOffersDesignateEverywhere() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try scoredDefault().write(to: dir)
        let designation = AnalysisLeadFile.read(from: dir)?.designation
        #expect(designation == nil)

        let recording = makeRecording()
        // MLII is what the stored default RESOLVES to — and it still offers
        // "Use as analysis lead", because pinning the default explicitly is
        // an assertion the analyst is entitled to make.
        #expect(recording.analysisLead(inBundle: dir)?.channel.name == "MLII")
        for channel in recording.channels {
            #expect(AnalysisLeadMenuEntry.resolve(for: channel, designation: designation)
                == .designate)
        }
    }

    @Test("Designating the default lead pins it, and its menu flips to revert")
    func designatingTheDefaultPinsIt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try scoredDefault().write(to: dir)
        // The lead the default already resolves to.
        try AnalysisLeadDesignator.designate(
            channelNamed: "MLII", inBundle: dir, reviewer: "kevin",
            at: Date(timeIntervalSince1970: 500))

        let designation = AnalysisLeadFile.read(from: dir)?.designation
        #expect(designation?.channelName == "MLII")
        #expect(designation?.reviewer == "kevin")

        let recording = makeRecording()
        let leads = Dictionary(uniqueKeysWithValues: recording.channels.map {
            ($0.name, AnalysisLeadMenuEntry.resolve(for: $0, designation: designation))
        })
        #expect(leads["MLII"] == .revert)
        #expect(leads["V5"] == .designate)
        // The resolved lead is unchanged — but its provenance is now the
        // analyst's assertion, not the import-time score.
        let resolution = recording.analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "MLII")
        #expect(resolution?.provenance == .designated(reviewer: "kevin",
                                                      date: Date(timeIntervalSince1970: 500)))
    }

    @Test("An empty channel is never offered as an analysis lead")
    func emptyChannelHasNoDesignationAffordance() {
        // Resolution only considers populated channels, so designating an
        // empty one would write an assertion that never resolves — and a
        // header line calling a visibly-present lead "not in this record".
        let empty = Channel(
            id: UUID(), name: "V5", unit: "mV", sampleRate: 360,
            startTimeUnixMS: 0, sampleCount: 0,
            storageFileName: "channel_V5.bin", pyramid: [])
        #expect(AnalysisLeadMenuEntry.resolve(for: empty, designation: nil) == .none)

        // A designation naming it is still withdrawable, though — otherwise
        // the analyst could not clear the stale designation the header line
        // is reporting.
        let standing = AnalysisLeadFile.Designation(
            channelName: "V5", reviewer: "kevin", designatedAt: Date(timeIntervalSince1970: 500))
        #expect(AnalysisLeadMenuEntry.resolve(for: empty, designation: standing) == .revert)
    }

    @Test("The revision stamp advances on every write")
    @MainActor
    func revisionStampAdvances() {
        // The orchestrators' `.task(id:)` values carry this number, so a
        // designation re-runs every calculation exactly as a record swap does.
        let context = CurrentRecordingContext()
        // Arithmetic stays OUT of the #expect expression — the macro
        // miscompares an arithmetic right-hand side against a plain value.
        let expected = context.analysisLeadRevision + 2
        context.bumpAnalysisLeadRevision()
        context.bumpAnalysisLeadRevision()
        #expect(context.analysisLeadRevision == expected)
    }
}

// MARK: - Import-time stamping

/// All tests here register into the process-wide `AnalysisLeadScoring.shared`
/// singleton (Task 2 wires import to consult it) — kept in ONE `.serialized`
/// suite so Swift Testing never runs two of these concurrently and stomps
/// on each other's registration. Every test that registers a scorer clears
/// it in a `defer`, whatever the outcome.
@Suite("Analysis lead — import-time default", .serialized)
@MainActor
struct AnalysisLeadImportTests {
    struct RiggedScorer: AnalysisLeadScorer {
        let scores: [String: Double]?
        func scoreLeads(_ leads: [(name: String, samples: [Float])],
                        sampleRate: Double) -> [String: Double]? { scores }
    }

    private func makeStore() throws -> (RecordingStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-import-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (RecordingStore(rootURL: root), root)
    }

    /// Two-channel source: ECG1 low-amplitude flatline-ish, ECG2 a clear
    /// repeating spike — real scoring content, though every test here
    /// substitutes a `RiggedScorer` so the actual samples never drive the
    /// assertions.
    private func writeSource(in dir: URL) throws {
        try WFDBRecordWriter.write(
            recordName: "rec",
            channelSamples: [
                Array(repeating: Int32(2), count: 128),
                (0..<128).map { $0 % 20 == 0 ? Int32(200) : Int32(0) },
            ],
            sampleRateHz: 128,
            leadNames: ["ECG1", "ECG2"],
            calibration: .init(gain: 200, baseline: 0, unit: "mV"),
            in: dir
        )
    }

    @Test("A fresh import with a scorer stamps the highest-scoring lead")
    func importStampsScoredDefault() async throws {
        AnalysisLeadScoring.shared.register(
            RiggedScorer(scores: ["ECG1": 1.0, "ECG2": 9.0]))
        defer { AnalysisLeadScoring.shared.clearForTesting() }

        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let summary = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        let file = AnalysisLeadFile.read(from: summary.directory)
        #expect(file?.defaultChoice?.channelName == "ECG2")
        #expect(file?.defaultChoice?.reason == .rPeakScore)
        #expect(file?.defaultChoice?.perLeadScores?["ECG2"] == 9.0)
    }

    @Test("No scorer registered stamps firstInFile explicitly")
    func importStampsFirstInFileWithoutScorer() async throws {
        AnalysisLeadScoring.shared.clearForTesting()

        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let summary = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        let file = AnalysisLeadFile.read(from: summary.directory)
        #expect(file?.defaultChoice?.reason == .firstInFile)
        #expect(file?.defaultChoice?.channelName == "ECG1")
        #expect(file?.defaultChoice?.perLeadScores == nil)
    }

    @Test("A scorer that declines (nil) stamps firstInFile")
    func decliningScorerStampsFirstInFile() async throws {
        AnalysisLeadScoring.shared.register(RiggedScorer(scores: nil))
        defer { AnalysisLeadScoring.shared.clearForTesting() }

        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let summary = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        let file = AnalysisLeadFile.read(from: summary.directory)
        #expect(file?.defaultChoice?.reason == .firstInFile)
        #expect(file?.defaultChoice?.channelName == "ECG1")
    }

    @Test("Equal scores tie-break to file order, recorded as a score choice")
    func equalScoresTieBreakToFileOrder() async throws {
        AnalysisLeadScoring.shared.register(
            RiggedScorer(scores: ["ECG1": 5.0, "ECG2": 5.0]))
        defer { AnalysisLeadScoring.shared.clearForTesting() }

        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let summary = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        let file = AnalysisLeadFile.read(from: summary.directory)
        #expect(file?.defaultChoice?.channelName == "ECG1")
        #expect(file?.defaultChoice?.reason == .rPeakScore)
    }

    @Test("Bundle reuse keeps the original stamp — never re-scored (#341 composition)")
    func reuseKeepsOriginalStamp() async throws {
        AnalysisLeadScoring.shared.register(
            RiggedScorer(scores: ["ECG1": 1.0, "ECG2": 9.0]))
        defer { AnalysisLeadScoring.shared.clearForTesting() }

        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try writeSource(in: source)

        let first = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        // Re-register a scorer preferring ECG1 and re-import the same,
        // unchanged source — reuse must serve the original stamp untouched.
        // The top-level defer covers this second registration too.
        AnalysisLeadScoring.shared.register(
            RiggedScorer(scores: ["ECG1": 9.0, "ECG2": 1.0]))
        let second = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")

        #expect(second.directory == first.directory)
        #expect(AnalysisLeadFile.read(from: second.directory)?
            .defaultChoice?.channelName == "ECG2")
    }

    /// The end-to-end acceptance test (spec §1.7, first bullet): a real
    /// scorer, a real import, a real resolution — noise on channel 0,
    /// signal on channel 1, and the default lands on the clean lead with
    /// score provenance. Registers the real `QRSProminenceLeadScorer`
    /// (reachable via the `MurmurTests/QRSProminenceLeadScorer.swift`
    /// symlink), so this belongs in the serialized suite like every other
    /// test here that touches `AnalysisLeadScoring.shared`.
    @Test("Noisy ch0 / clean ch1 defaults to ch1 with score provenance, end-to-end")
    func noisyFirstChannelDefaultsToClean() async throws {
        AnalysisLeadScoring.shared.register(QRSProminenceLeadScorer(entitled: { true }))
        defer { AnalysisLeadScoring.shared.clearForTesting() }

        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-e2e-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }

        // Same generators as Task 3's QRSProminenceLeadScorerTests.makeLeads
        // (seeded LCG noise; a crude repeating QRS spike train), scaled to
        // Int32 for WFDBRecordWriter — qrsProminence is a P95/median ratio,
        // so the amplitude scale itself is immaterial to which lead wins.
        let n = 360 * 30
        var state: UInt64 = 0x5DEECE66D
        var noisy = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(Int64(bitPattern: state) % 1000) / 1000.0
            noisy[i] = Int32((unit * 1000).rounded())
        }
        var clean = [Int32](repeating: 0, count: n)
        for beat in stride(from: 0, to: n, by: 360) { // 60 bpm at 360 Hz
            clean[beat] = 1000
            if beat + 1 < n { clean[beat + 1] = -400 }
        }

        try WFDBRecordWriter.write(
            recordName: "rec",
            channelSamples: [noisy, clean],
            sampleRateHz: 360,
            leadNames: ["NOISY", "CLEAN"],
            calibration: .init(gain: 1000, baseline: 0, unit: "mV"),
            in: source
        )

        let summary = try await store.importWFDB(folderURL: source, heaFilename: "rec.hea")
        let resolution = try #require(summary.recording.analysisLead(inBundle: summary.directory))
        #expect(resolution.channel.name == "CLEAN")
        if case .rPeakScore = resolution.provenance {} else {
            Issue.record("expected score provenance, got \(resolution.provenance)")
        }
    }
}

// MARK: - QRS-prominence scorer (App target)

/// The scorer struct is testable without the app running because
/// entitlement is injected. These tests construct `QRSProminenceLeadScorer`
/// directly and never touch `AnalysisLeadScoring.shared`, so they stay in
/// their own (non-serialized) suite — only tests that register into the
/// shared registry belong in `AnalysisLeadImportTests` above.
@Suite("Analysis lead — QRS prominence scorer")
struct QRSProminenceLeadScorerTests {
    /// Deterministic noisy vs clean pair: clean = repeating sharp spike
    /// train (a crude QRS), noisy = seeded LCG white noise. No
    /// SystemRandomNumberGenerator — the test must not flake.
    private func makeLeads() -> [(name: String, samples: [Float])] {
        let n = 360 * 30
        var clean = [Float](repeating: 0, count: n)
        for beat in stride(from: 0, to: n, by: 360) { // 60 bpm at 360 Hz
            clean[beat] = 1.0
            if beat + 1 < n { clean[beat + 1] = -0.4 }
        }
        var state: UInt64 = 0x5DEECE66D
        var noisy = [Float](repeating: 0, count: n)
        for i in 0..<n {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            noisy[i] = Float(Int64(bitPattern: state) % 1000) / 1000.0
        }
        return [("NOISY", noisy), ("CLEAN", clean)]
    }

    @Test("Entitled: the clean lead outscores the noisy one")
    func cleanOutscoresNoisy() {
        let scorer = QRSProminenceLeadScorer(entitled: { true })
        let scores = scorer.scoreLeads(makeLeads(), sampleRate: 360)
        let clean = scores?["CLEAN"] ?? 0
        let noisy = scores?["NOISY"] ?? 0
        #expect(clean > noisy)
    }

    @Test("Unentitled: the scorer declines (firstInFile downstream)")
    func unentitledDeclines() {
        let scorer = QRSProminenceLeadScorer(entitled: { false })
        #expect(scorer.scoreLeads(makeLeads(), sampleRate: 360) == nil)
    }
}

// MARK: - No-name-gate source guard

/// A code-shape test in the repo's `LayoutFitSupport`-style precedent: reads
/// the calculation sources at test time and asserts a fixed set of banned
/// shapes stays out of them (#357). `primaryECGChannel` itself deliberately
/// survives elsewhere — `RecordListEntry`, `MurSessionPackage` — because
/// those are display paths, not calculation paths; that is why this guard
/// walks only the four files named below, not the whole app target.
@Suite("Analysis lead — no-name-gate guard")
struct AnalysisLeadNoNameGateTests {
    /// Resolved from this test file's own `#filePath` rather than the
    /// process's current directory, so the guard works the same way under
    /// `xcrun xctest` (this repo's `xcodebuild test` workaround) as under a
    /// normal `xcodebuild test` run.
    private var calculationSources: [URL] {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // MurmurTests/
            .deletingLastPathComponent() // repo root
        let murmur = repoRoot.appendingPathComponent("Murmur", isDirectory: true)
        return [
            "ArrhythmiaScanOrchestrator.swift",
            "MorphologyOrchestrator.swift",
            "IntervalMarkingsOrchestrator.swift",
            "VTVFScanView.swift",
        ].map { murmur.appendingPathComponent($0) }
    }

    @Test("No calculation path selects a channel by name or channels.first (#357)")
    func noNameGatesInCalculationPaths() throws {
        let banned = ["conventionalQTChannels", "primaryECGSamples(",
                      "channels.first", "hasPrefix(\"ML\")"]
        var filesChecked = 0
        for file in calculationSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            filesChecked += 1
            for pattern in banned {
                #expect(!text.contains(pattern),
                        "\(file.lastPathComponent) contains banned shape \(pattern)")
            }
        }
        // A guard that silently reads zero files is not a guard — assert the
        // #filePath resolution actually reached all four calculation sources.
        #expect(filesChecked == 4)
    }
}
