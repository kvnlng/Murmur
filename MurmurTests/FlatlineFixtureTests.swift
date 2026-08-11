//
//  FlatlineFixtureTests.swift
//  MurmurTests
//
//  X105 (#176) — the electrode-disconnect states: flat-line spans and
//  whole-record lead dropout, checked against construction. The sharp
//  instrument here is EXACT equality against a baseline generation: the
//  flat-line pass consumes no randomness and runs after lead projection, so
//  every untouched lead (and every untouched sample of a touched lead) must
//  be bit-identical to the same seed without the span.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Synthetic ECG flat-line states (X105)")
struct SyntheticECGFlatlineTests {
    @Test("A full-disconnect span zeroes every lead exactly there, and the artifact lane agrees")
    func fullDisconnectSpan() {
        let span: ClosedRange<Double> = 60...75
        let output = SyntheticECG.generate(.init(
            durationSeconds: 180, flatlineSpans: [.init(range: span)]))
        let rate = output.truth.parameters.ecgSampleRate
        let lo = Int(span.lowerBound * rate), hi = Int(span.upperBound * rate)

        for (leadIndex, lead) in output.leads.enumerated() {
            #expect(lead[lo...hi].allSatisfy { $0 == 0 },
                    "Lead \(SyntheticECG.leadNames[leadIndex]) must be exactly zero inside the span")
            #expect(lead[..<lo].contains { $0 != 0 } && lead[(hi + 1)...].contains { $0 != 0 },
                    "Lead \(SyntheticECG.leadNames[leadIndex]) must carry signal outside the span")
        }
        #expect(output.truth.episodes.contains {
            $0.kind == .flatline && $0.startSeconds == 60 && $0.endSeconds == 75
        }, "The disconnect is truth, bounds verbatim")

        for (second, value) in output.artifactRatioPerSecond.enumerated() {
            let inSpan = span.lowerBound <= Double(second) + 1 && Double(second) <= span.upperBound
            #expect(value == (inSpan ? 0.9 : 0.02),
                    "Artifact lane at second \(second): \(value)")
        }
        // The heart kept beating: truth beats and the sidecar are untouched.
        #expect(output.truth.beatTimesSeconds.contains { span.contains($0) },
                "Truth beats persist through the disconnect — signal loss, not asystole")
    }

    @Test("A per-lead span silences only its lead; everything else is bit-identical to baseline")
    func perLeadSpanIsSurgical() throws {
        let baseline = SyntheticECG.generate(.init(durationSeconds: 120))
        let flat = SyntheticECG.generate(.init(
            durationSeconds: 120,
            flatlineSpans: [.init(range: 40...60, leadNames: ["V1"])]))
        let v1 = try #require(SyntheticECG.leadNames.firstIndex(of: "V1"))

        for (leadIndex, lead) in flat.leads.enumerated() where leadIndex != v1 {
            #expect(lead == baseline.leads[leadIndex],
                    "Untouched lead \(SyntheticECG.leadNames[leadIndex]) must be bit-identical to baseline")
        }
        let rate = 250.0
        let lo = Int(40 * rate), hi = Int(60 * rate)
        #expect(flat.leads[v1][lo...hi].allSatisfy { $0 == 0 })
        #expect(Array(flat.leads[v1][..<lo]) == Array(baseline.leads[v1][..<lo])
                && Array(flat.leads[v1][(hi + 1)...]) == Array(baseline.leads[v1][(hi + 1)...]),
                "V1 outside the span must be bit-identical to baseline")
        #expect(flat.truth.beatTimesSeconds == baseline.truth.beatTimesSeconds,
                "The tachogram is untouched by a lead-level state")
    }

    @Test("A dropped lead is flat for the whole record and does not elevate the artifact lane")
    func droppedLead() throws {
        let baseline = SyntheticECG.generate(.init(durationSeconds: 120))
        let dropped = SyntheticECG.generate(.init(durationSeconds: 120, droppedLeads: ["I"]))
        let leadI = try #require(SyntheticECG.leadNames.firstIndex(of: "I"))

        #expect(dropped.leads[leadI].allSatisfy { $0 == 0 })
        for (leadIndex, lead) in dropped.leads.enumerated() where leadIndex != leadI {
            #expect(lead == baseline.leads[leadIndex])
        }
        #expect(dropped.artifactRatioPerSecond.allSatisfy { $0 == 0.02 },
                "One dead lead is not whole-record artifact")
        #expect(!dropped.truth.episodes.contains { $0.kind == .flatline },
                "Dropout is a parameters fact, not a time episode")
    }

    @Test("The dropout record imports with the dead lead present and flat")
    func dropoutImportsFlat() throws {
        let parameters = SyntheticECG.Parameters(
            durationSeconds: 60, seed: 5, droppedLeads: ["I"])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x105-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let heaURL = try SyntheticRecording.makeRichRecord(into: dir, parameters: parameters)
        let outputDir = dir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outputDir)

        // The dead lead stays a first-class channel — dropout is a flat
        // trace the analyst can see, not a missing entry.
        #expect(summary.recording.channels.contains { $0.name == "I" },
                "Lead I must import even though it is flat")
        for lead in SyntheticECG.leadNames {
            #expect(summary.recording.channels.contains { $0.name == lead })
        }
    }
}
