//
//  EctopyTruthTests.swift
//  MurmurTests
//
//  X104 (#175) — constructed ectopy: isolated PVCs (short coupling + full
//  compensatory pause) and wide-complex runs, with per-beat kind truth and
//  verbatim episode boundaries. Detection is pinned ONLY on the rule-based
//  paths; the VT/VF model gets a totality smoke and no accuracy claims —
//  the deliberate limit in SyntheticECG.swift's header (agreed 2026-08-10).
//
//  Operating point for the premature-beat known-answer, derived not tuned:
//  constructed coupling is 0.62 of the local R–R → prematurity 0.38; HRV
//  jitter alone reaches ~0.19 (≈3.5 σ of SDNN 45 ms against an 833 ms mean,
//  and the probe's worst jitter candidate sat at 0.18). minPrematurity 0.25
//  splits the gap with margin on both sides, so the detector must find
//  EXACTLY the constructed beats — on a fixed seed, forever.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Synthetic ECG ectopy construction (X104)")
struct SyntheticECGEctopyTests {
    @Test("Requested PVCs replace sinus beats: early, compensated, wide, P-less")
    func pvcConstruction() {
        let requested: [Double] = [40, 75, 110, 145]
        let truth = SyntheticECG.generate(.init(
            durationSeconds: 180, pvcTimesSeconds: requested)).truth
        let pvcIndices = truth.beatFiducials.indices.filter {
            truth.beatFiducials[$0].kind == .pvc
        }
        #expect(pvcIndices.count == requested.count)
        for (target, k) in zip(requested, pvcIndices) {
            let beat = truth.beatTimesSeconds[k]
            #expect(abs(beat - target) < 1.5,
                    "PVC landed at \(beat) for request \(target)")
            // The RR signature the detector keys on, from truth itself:
            // short coupling (≈0.62 of the prior sinus R–R), long pause.
            let priorRR = truth.beatTimesSeconds[k - 1] - truth.beatTimesSeconds[k - 2]
            let coupling = beat - truth.beatTimesSeconds[k - 1]
            let following = truth.beatTimesSeconds[k + 1] - beat
            #expect(coupling < 0.75 * priorRR, "Coupling \(coupling) not premature vs \(priorRR)")
            #expect(following > 1.15 * priorRR, "Pause \(following) not compensatory vs \(priorRR)")
            // Morphology truth: no P, wide QRS.
            let fiducials = truth.beatFiducials[k]
            #expect(fiducials.pOnsetSeconds == nil, "A PVC carries no P truth")
            #expect(fiducials.qrsOffsetSeconds - fiducials.qrsOnsetSeconds > 0.12,
                    "PVC QRS truth must be wide")
        }
    }

    @Test("A wide-complex run is regular, elevated, bounded verbatim, and ≥3 beats")
    func runConstruction() {
        let range: ClosedRange<Double> = 80...100
        let truth = SyntheticECG.generate(.init(
            durationSeconds: 180, wideComplexRuns: [.init(range: range)])).truth

        let episode = truth.episodes.filter { $0.kind == .wideComplexRun }
        #expect(episode.map { ($0.startSeconds, $0.endSeconds) == (80, 100) } == [true],
                "Exactly one wideComplexRun episode with verbatim bounds, got \(episode)")

        let runIndices = truth.beatFiducials.indices.filter {
            truth.beatFiducials[$0].kind == .wideComplexRun
        }
        #expect(runIndices.count >= 3)
        for k in runIndices {
            #expect(range.contains(truth.beatTimesSeconds[k]))
            #expect(truth.beatFiducials[k].pOnsetSeconds == nil)
            let fiducials = truth.beatFiducials[k]
            #expect(fiducials.qrsOffsetSeconds - fiducials.qrsOnsetSeconds > 0.12)
        }
        // Interior spacing is the run's constructed R–R exactly (60/160 s).
        for pair in zip(runIndices.dropLast(), runIndices.dropFirst()) where pair.1 == pair.0 + 1 {
            let rr = truth.beatTimesSeconds[pair.1] - truth.beatTimesSeconds[pair.0]
            #expect(abs(rr - 60.0 / 160.0) < 1e-9,
                    "Run spacing must be exactly 60/bpm, got \(rr)")
        }
        let outside = truth.beatFiducials.indices.filter {
            !range.contains(truth.beatTimesSeconds[$0])
        }
        #expect(outside.allSatisfy { truth.beatFiducials[$0].kind == .sinus },
                "No wide beats outside the run")
    }

    @Test("A PVC request inside the AF span is skipped — truth records only what was built")
    func pvcRequestInsideAFIsSkipped() {
        let truth = SyntheticECG.generate(.init(
            durationSeconds: 180, afEpisode: 40...80, pvcTimesSeconds: [60])).truth
        #expect(!truth.beatFiducials.contains { $0.kind == .pvc },
                "No eligible sinus neighbourhood exists at t=60 inside AF")
    }

    @Test("Ectopic beats are annotator-coded V, and the import excludes them from normals")
    func ectopicBeatsCodeAsVAndImportExcludesThem() throws {
        let parameters = SyntheticECG.Parameters(
            durationSeconds: 60, seed: 5, pvcTimesSeconds: [20, 40])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x104-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let heaURL = try SyntheticRecording.makeRichRecord(into: dir, parameters: parameters)
        let outputDir = dir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outputDir)

        let truth = SyntheticECG.generate(parameters).truth
        let sinusSamples = zip(truth.beatSampleIndices, truth.beatFiducials)
            .filter { $0.1.kind == .sinus }.map { $0.0 }
        #expect(sinusSamples.count == truth.beatSampleIndices.count - 2,
                "Both PVCs must have been constructed")
        #expect(summary.recording.normalBeatSampleIndices() == sinusSamples,
                "Normals must exclude the V-coded ectopic beats — same rule as a real annotator file")
    }
}

#if canImport(MurmurMetrics)
import MurmurMetrics

@Suite("Synthetic ectopy → rule-based detectors (X104)")
struct EctopyDetectorTests {
    /// See the file header for the 0.25 derivation.
    private static let operatingPoint = PrematureBeatConfig(minPrematurityFraction: 0.25)

    private func truthRR(_ truth: SyntheticECG.Truth) -> RRSeries {
        RRSeries(intervalsMs: truth.rrIntervalsMs,
                 endTimesSeconds: Array(truth.beatTimesSeconds.dropFirst()))
    }

    @Test("The premature-beat detector finds EXACTLY the constructed PVCs at the derived operating point")
    func prematureBeatKnownAnswer() {
        let truth = SyntheticECG.generate(.init(
            durationSeconds: 180, pvcTimesSeconds: [40, 75, 110, 145])).truth
        let constructed = truth.beatFiducials.indices
            .filter { truth.beatFiducials[$0].kind == .pvc }
            .map { truth.beatTimesSeconds[$0] }

        let found = PrematureBeatDetector.detect(rr: truthRR(truth), config: Self.operatingPoint)
        #expect(found.count == constructed.count,
                "Expected exactly the \(constructed.count) constructed PVCs, got \(found.map(\.timeSeconds))")
        for (candidate, truthTime) in zip(found.sorted { $0.timeSeconds < $1.timeSeconds }, constructed) {
            #expect(abs(candidate.timeSeconds - truthTime) < 0.02,
                    "Candidate at \(candidate.timeSeconds) vs constructed \(truthTime)")
            #expect(candidate.prematurityFraction > 0.25 && abs(candidate.compensationRatio - 1) < 0.2)
        }

        let clean = SyntheticECG.generate(.init(durationSeconds: 180)).truth
        #expect(PrematureBeatDetector.detect(rr: truthRR(clean), config: Self.operatingPoint).isEmpty,
                "A clean sinus record mints nothing at the derived operating point")
    }

    @Test("A wide-complex run reaches the rate band end-to-end: QRS finds the inverted beats, tachy bounds match truth")
    func runReachesRateBandEndToEnd() throws {
        let output = SyntheticECG.generate(.init(
            durationSeconds: 180, wideComplexRuns: [.init(range: 80...100)]))
        let result = ArrhythmiaScanService.scan(
            leads: output.leads.map { $0.map(Float.init) },
            sampleRate: output.truth.parameters.ecgSampleRate)

        // QRS detection must not lose the inverted wide complexes.
        #expect(result.quality.beatCount >= output.truth.beatTimesSeconds.count - 2,
                "QRS found \(result.quality.beatCount) of \(output.truth.beatTimesSeconds.count) constructed beats")

        // 160 bpm is out-of-band at the 60–100 default; boundaries within
        // two sinus R–R + one run R–R of quantization (≈2.5 s) of truth.
        let tachy = result.candidates.filter { $0.kind == .tachycardia }
        let longest = try #require(
            tachy.max { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) },
            "The run must mint a tachycardia candidate at defaults")
        #expect(abs(longest.startSeconds - 80) < 2.5, "Start \(longest.startSeconds) vs truth 80")
        #expect(abs(longest.endSeconds - 100) < 2.5, "End \(longest.endSeconds) vs truth 100")
    }
}
#endif

#if canImport(MurmurInference)
import MurmurInference

@Suite("Synthetic ectopy → VT/VF scanner totality (X104)")
struct VTVFScannerTotalityTests {
    /// In-memory `VTVFSampleSource` over a generated lead.
    private final class ArraySource: VTVFSampleSource {
        let samples: [Float]
        let sampleRateHz: Double
        private var cursor = 0
        init(samples: [Float], sampleRateHz: Double) {
            self.samples = samples
            self.sampleRateHz = sampleRateHz
        }
        var sampleCount: Int { samples.count }
        func rewind() { cursor = 0 }
        func readSamples(maxCount: Int) -> [Float] {
            let end = min(samples.count, cursor + maxCount)
            defer { cursor = end }
            return Array(samples[cursor..<end])
        }
    }

    /// TOTALITY ONLY. Whether the model fires on crude synthetic morphology
    /// is deliberately unpinned — "no synthetic VT/VF accuracy claims"
    /// (SyntheticECG.swift header, agreed 2026-08-10): the model is trained,
    /// K6 will retrain it, and synthetic wide bumps aren't pathology. What
    /// must hold regardless of any retraining: the scan pipeline windows,
    /// scores, and clusters a synthetic record without crashing, every
    /// score finite and in [0, 1], every candidate inside the record.
    @Test("The VT/VF scan pipeline is total over a synthetic wide-complex record")
    func scannerIsTotal() throws {
        let durationSeconds = 120.0
        let output = SyntheticECG.generate(.init(
            durationSeconds: durationSeconds, wideComplexRuns: [.init(range: 50...70)]))
        let model = try VTVFModel()
        #expect(abs(model.sampleRateHz - 250) < 1e-9,
                "The synthetic record speaks the model's native rate")

        let result = try VTVFScanner(model: model).scan(
            source: ArraySource(samples: output.leads[1].map(Float.init), sampleRateHz: 250),
            parameters: .init(tau: model.thresholdTau))

        let sampleCount = Int(durationSeconds * 250)
        let expectedWindows = (sampleCount - model.windowSamples) / model.strideSamples + 1
        #expect(result.windowScores.count == expectedWindows,
                "Every stride position scored: \(result.windowScores.count) of \(expectedWindows)")
        #expect(result.windowScores.allSatisfy { $0.score.isFinite && (0...1).contains($0.score) },
                "Scores must be finite probabilities")
        #expect(result.candidates.allSatisfy {
            $0.startSeconds >= 0 && $0.endSeconds <= durationSeconds
                && $0.endSeconds > $0.startSeconds
        }, "Candidates must lie inside the record")
    }
}
#endif
