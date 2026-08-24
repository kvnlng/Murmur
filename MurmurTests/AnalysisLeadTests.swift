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
}
