//
//  DetectorInvariantTests.swift
//  MurmurTests
//
//  X102 (#173) — detector INVARIANTS over synthetic seed sweeps: properties
//  that hold by mechanism for every record, checked across a deterministic
//  seed grid. This is the CI-runnable complement to the PhysioNet benchmark
//  suite (external drive, not CI): no real-data accuracy numbers, just
//  claims that a regression cannot break silently.
//
//  Deliberately NOT here: "noise spans never mint rate candidates." That is
//  not mechanism-guaranteed — QRS detection over broadband noise can misfire,
//  and the DESIGNED mitigation is the reliability mask feeding
//  `reliableFraction` (the A3 lever), not suppression. Noisy records are in
//  the no-crash grid instead.
//
//  The seed grid stays small for local affected-test runs;
//  MURMUR_INVARIANT_SEED_COUNT widens it (Cloud or a manual sweep).
//

import CryptoKit
import Foundation
@testable import MurmurCore
import Testing

#if canImport(MurmurMetrics)
import MurmurMetrics

@Suite("Detector invariants over synthetic seed sweeps (X102)")
struct DetectorInvariantTests {
    /// Deterministic grid — seeds 1…N, never random-at-test-time.
    static let seedGrid: [UInt64] = {
        let count = ProcessInfo.processInfo.environment["MURMUR_INVARIANT_SEED_COUNT"]
            .flatMap(Int.init) ?? 6
        return (1...UInt64(max(1, count))).map { $0 }
    }()

    private func scan(
        _ output: SyntheticECG.Output,
        rhythmConfig: RhythmBandConfig = .init()
    ) -> ArrhythmiaScanResult {
        ArrhythmiaScanService.scan(
            leads: output.leads.map { $0.map(Float.init) },
            sampleRate: output.truth.parameters.ecgSampleRate,
            rhythmConfig: rhythmConfig
        )
    }

    private func rateCandidates(_ result: ArrhythmiaScanResult) -> [ArrhythmiaCandidate] {
        result.candidates.filter { $0.kind == .bradycardia || $0.kind == .tachycardia }
    }

    // MARK: - Band monotonicity

    @Test("Widening the rate band never increases the out-of-band interval count")
    func bandWideningIsMonotone() {
        // With minRun 1 and window 0, maximal runs PARTITION the out-of-band
        // intervals, so Σ candidate span is exactly the total out-of-band
        // time — and nested bands classify pointwise: an interval out-of-band
        // under the wide band is out-of-band under the narrow one too.
        let nestedBands: [RhythmBandConfig] = [
            .init(lowBpm: 60, highBpm: 100),
            .init(lowBpm: 50, highBpm: 110),
            .init(lowBpm: 40, highBpm: 140),
        ]
        for seed in Self.seedGrid {
            let output = SyntheticECG.generate(.init(
                durationSeconds: 120, seed: seed,
                rateEpisodes: [.init(range: 20...45, bpm: 45),
                               .init(range: 70...95, bpm: 130)]))
            let outOfBandSeconds = nestedBands.map { band in
                rateCandidates(scan(output, rhythmConfig: band))
                    .reduce(0.0) { $0 + ($1.endSeconds - $1.startSeconds) }
            }
            #expect(outOfBandSeconds[0] >= outOfBandSeconds[1]
                    && outOfBandSeconds[1] >= outOfBandSeconds[2],
                    "Seed \(seed): out-of-band time must fall as the band widens, got \(outOfBandSeconds)")
            #expect(outOfBandSeconds[0] > 0,
                    "Seed \(seed): the constructed 45/130 bpm episodes must be out-of-band at 60–100")
        }
    }

    // MARK: - Window monotonicity

    @Test("Raising minDurationSeconds only ever removes candidates — literal subset")
    func minDurationIsMonotone() {
        // Same band ⇒ identical pre-gate runs; the gate filters by span. So
        // the candidate set at a larger window is CONTAINED in the set at a
        // smaller one — element-for-element, not just by count.
        for seed in Self.seedGrid {
            let output = SyntheticECG.generate(.init(
                durationSeconds: 120, seed: seed,
                rateEpisodes: [.init(range: 30...70, bpm: 45)]))
            let windows: [Double] = [0, 5, 20, 60]
            let sets = windows.map { window in
                rateCandidates(scan(output, rhythmConfig: .init(minDurationSeconds: window)))
            }
            for i in 1..<sets.count {
                for candidate in sets[i] {
                    #expect(sets[i - 1].contains(candidate),
                            "Seed \(seed): window \(windows[i]) minted \(candidate) absent at window \(windows[i - 1])")
                }
            }
            #expect(sets.last?.isEmpty == true,
                    "Seed \(seed): a 60 s window must suppress every run of the 40 s episode")
        }
    }

    // MARK: - AF specificity

    @Test("Clean sinus never mints an AFib candidate at any grid seed")
    func sinusIsNeverAFib() {
        for seed in Self.seedGrid {
            let output = SyntheticECG.generate(.init(durationSeconds: 120, seed: seed))
            let afib = scan(output).candidates.filter { $0.kind == .atrialFibrillation }
            #expect(afib.isEmpty,
                    "Seed \(seed): spectral sinus HRV must not read as AF, got \(afib)")
        }
    }

    // MARK: - Totality

    @Test("No crash, no NaN, sane ranges — degenerate durations and every episode type")
    func scanIsTotalAndFinite() {
        var parameterFamilies: [SyntheticECG.Parameters] = [
            .init(durationSeconds: 1, seed: 11),     // zero constructed beats
            .init(durationSeconds: 5, seed: 12),     // a handful of beats
            .init(durationSeconds: 30, seed: 13),
            .init(durationSeconds: 120, seed: 14, noiseEpisodes: [20...50]),
            .init(durationSeconds: 120, seed: 15, afEpisode: 30...90),
            .init(durationSeconds: 120, seed: 16,
                  noiseEpisodes: [10...30], afEpisode: 50...100,
                  rateEpisodes: [.init(range: 105...115, bpm: 45)]),
        ]
        for seed in Self.seedGrid {
            parameterFamilies.append(.init(durationSeconds: 60, seed: seed))
        }
        for parameters in parameterFamilies {
            let result = scan(SyntheticECG.generate(parameters))
            #expect(result.quality.beatCount >= 0)
            #expect(result.quality.rrArtifactFraction.isFinite
                    && (0...1).contains(result.quality.rrArtifactFraction),
                    "rrArtifactFraction out of range for \(parameters.durationSeconds) s seed \(parameters.seed)")
            for candidate in result.candidates {
                #expect(candidate.startSeconds.isFinite && candidate.endSeconds.isFinite
                        && candidate.endSeconds >= candidate.startSeconds,
                        "Degenerate span \(candidate) (seed \(parameters.seed))")
                #expect((0...parameters.durationSeconds).contains(candidate.startSeconds),
                        "Candidate starts outside the record (seed \(parameters.seed))")
                #expect(candidate.confidence.isFinite && (0...1).contains(candidate.confidence),
                        "Confidence out of range in \(candidate) (seed \(parameters.seed))")
            }
        }
    }

    // MARK: - Construction determinism (the golden guard)

    /// SHA-256 over QUANTIZED construction: beat times at 1 µs, episode
    /// bounds at 1 µs, plus every 100th lead-I sample at 10 nV. Quantization
    /// makes the digest robust to sub-ulp libm drift across OS updates while
    /// still catching any real change to the tachogram or the waveform.
    ///
    /// If this fails after an INTENTIONAL generator change: re-record the
    /// constant from the failure message and say so in the PR — the digest
    /// moving is the event this test exists to make loud, because every
    /// downstream fixture (oracle tolerances, UI fixtures, detection counts)
    /// silently shifts with it.
    @Test("A pinned seed's construction hashes to the recorded golden digest")
    func constructionDigestIsPinned() {
        let output = SyntheticECG.generate(.init())   // the default fixture everything uses
        var signature = ""
        for t in output.truth.beatTimesSeconds {
            signature += "\(Int((t * 1e6).rounded()));"
        }
        for episode in output.truth.episodes {
            let start = Int((episode.startSeconds * 1e6).rounded())
            let end = Int((episode.endSeconds * 1e6).rounded())
            signature += "\(episode.kind.rawValue):\(start)-\(end);"
        }
        for i in stride(from: 0, to: output.leads[0].count, by: 100) {
            signature += "\(Int((output.leads[0][i] * 1e5).rounded()));"
        }
        let digest = SHA256.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let golden = "a2b21af65d0877b7357b4199e61f2d359955a07d2d5c85257d612eadd7a5c8d9"
        #expect(digest == golden,
                "Default-parameter construction changed. If intentional, re-record: \(digest)")
    }
}
#endif
