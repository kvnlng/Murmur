//
//  QTAbstentionTests.swift
//  MurmurTests
//
//  X109 (#185, cardiologist review §2.4) — the unit-testable half of QT
//  abstention: the markings context carries the withheld status with the
//  same lifecycle as the data it explains, and the no-conventional
//  fixture's lead renaming genuinely removes every conventional lead.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("QT abstention plumbing (X109)")
struct QTAbstentionTests {
    @Test("The withheld reason lives and dies with the published data")
    @MainActor
    func reasonLifecycle() {
        let context = IntervalMarkingsContext()
        #expect(context.qtWithheldReason == nil)

        let beat = MarkingsBeat(
            rPeakSampleIndex: 100, rPeakConfidence: 1,
            pOnset: nil, pOffset: nil, qrsOnset: nil, qrsOffset: nil,
            tOnset: nil, tOffset: nil,
            prMs: 160, qrsMs: 90, qtMs: nil, qtcMs: nil,
            precedingRRMs: 800, jtMs: nil, jtcMs: nil,
            tOffsetCensored: false, qtCalibratedHalfWidthMs: nil,
            tOffsetIsoelectricSampleIndex: nil,
            isImplausible: false, isUnreliable: false)
        context.set(beats: [beat], sampleRate: 250, template: nil,
                    qtWithheldReason: "QT: Conventional leads (II, V5) absent.")
        #expect(context.qtWithheldReason == "QT: Conventional leads (II, V5) absent.")

        // A re-publish WITHOUT the reason (a swap to a conventional-lead
        // recording) must drop the stale status.
        context.set(beats: [beat], sampleRate: 250, template: nil)
        #expect(context.qtWithheldReason == nil)

        context.set(beats: [beat], sampleRate: 250, template: nil,
                    qtWithheldReason: "QT: Conventional leads (II, V5) absent.")
        context.clear()
        #expect(context.qtWithheldReason == nil)
    }

    @Test("The no-conventional fixture rename removes every conventional QT lead")
    @MainActor
    func fixtureRenameRemovesConventionalLeads() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qt-abstention-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let heaURL = try SyntheticRecording.makeRichRecord(
            into: workDir,
            parameters: .init(durationSeconds: 20),
            leadRenames: ["II": "MCL1"])
        let outputDir = workDir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outputDir)
        let recording = try RecordingStore.shared.loadManifest(at: summary.directory)

        #expect(recording.conventionalQTChannels.isEmpty,
                "II → MCL1 must leave no conventional QT lead")
        #expect(recording.channels.contains { $0.name == "MCL1" },
                "The renamed lead itself must survive with its signal")
    }
}
