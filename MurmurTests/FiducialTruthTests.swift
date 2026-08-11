//
//  FiducialTruthTests.swift
//  MurmurTests
//
//  X103 (#174) — per-beat fiducial truth, and the delineator accuracy oracle
//  it makes possible. Until now we only asserted the delineator PRODUCES
//  fiducials; against construction we can assert it PLACES them.
//
//  Tolerance derivation (stated, never tuned-to-pass): the truth convention
//  puts onset/offset at ±2σ of the constructed Gaussian bump; a wavelet
//  delineator keys on modulus extrema / baseline departure, so the two
//  conventions differ by a SYSTEMATIC offset of order σ of the wave — plus
//  a couple of samples of scale quantization (≈10 ms at 250 Hz). Hence:
//  |median error| ≤ σ + 10 ms, worst |error| ≤ 2σ + 20 ms (2.5σ for the
//  low-amplitude P, whose SNR is the worst by construction). A mark beyond
//  2–2.5σ is OUTSIDE the wave entirely — that is a placement bug, and a
//  wavelet-scale regression (factor-2 localization) blows these instantly.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Synthetic ECG fiducial truth (X103)")
struct SyntheticECGFiducialTruthTests {
    @Test("Every beat carries ordered fiducials; the ±2σ span convention is encoded")
    func constructionInvariants() throws {
        let truth = SyntheticECG.generate(.init(durationSeconds: 120)).truth
        #expect(truth.beatFiducials.count == truth.beatTimesSeconds.count,
                "Fiducial table must parallel the beat list")
        for (i, beat) in truth.beatFiducials.enumerated() {
            #expect(beat.rPeakSeconds == truth.beatTimesSeconds[i])
            let pOn = try #require(beat.pOnsetSeconds)
            let pOff = try #require(beat.pOffsetSeconds)
            #expect(pOn < pOff && pOff < beat.qrsOnsetSeconds
                    && beat.qrsOnsetSeconds < beat.rPeakSeconds
                    && beat.rPeakSeconds < beat.qrsOffsetSeconds
                    && beat.qrsOffsetSeconds < beat.tOnsetSeconds
                    && beat.tOnsetSeconds < beat.tOffsetSeconds,
                    "Fiducials out of order at beat \(i)")
            // Span = 2kσ with k = 2: the P bump's σ is 45 ms by construction.
            #expect(abs((pOff - pOn) - 4 * 0.045) < 1e-9,
                    "P span must encode the ±2σ convention, got \(pOff - pOn)")
        }
    }

    @Test("P truth is nil exactly where the AF span suppresses the wave")
    func pSuppressionMatchesAFEpisode() {
        let af: ClosedRange<Double> = 40...80
        let truth = SyntheticECG.generate(.init(durationSeconds: 120, afEpisode: af)).truth
        for (i, beat) in truth.beatFiducials.enumerated() {
            let inAF = af.contains(truth.beatTimesSeconds[i])
            #expect((beat.pOnsetSeconds == nil) == inAF,
                    "P truth presence must mirror suppression at beat \(i)")
            #expect((beat.pOffsetSeconds == nil) == inAF)
        }
    }
}

#if canImport(MurmurMetrics)
import MurmurMetrics

@Suite("Wavelet delineator vs constructed fiducial truth (X103)")
struct WaveletDelineatorAccuracyTests {
    private struct Delineated {
        let truth: SyntheticECG.Truth
        let byRPeak: [Int64: BeatFiducials]
        let sampleRate: Double
    }

    private func delineate(_ p: SyntheticECG.Parameters) -> Delineated {
        let output = SyntheticECG.generate(p)
        let store = WaveletBeatDelineator.delineate(
            samples: output.leads[1].map(Float.init),   // lead II
            sampleRate: p.ecgSampleRate,
            rPeaks: output.truth.beatSampleIndices)
        return Delineated(
            truth: output.truth,
            byRPeak: Dictionary(uniqueKeysWithValues: store.beats.map { ($0.rPeakSampleIndex, $0) }),
            sampleRate: p.ecgSampleRate)
    }

    /// Errors in ms (found − truth) for one fiducial kind, over beats where
    /// truth has the kind. A beat with the kind ABSENT from the delineation
    /// contributes to `absentCount` instead — absence is a finding, not a skip.
    private func errors(
        _ d: Delineated,
        truthSeconds: (SyntheticECG.TruthBeatFiducials) -> Double?,
        found: (BeatFiducials) -> Fiducial?
    ) -> (errorsMs: [Double], absentCount: Int) {
        var errorsMs: [Double] = []
        var absent = 0
        for (i, beat) in d.truth.beatFiducials.enumerated() {
            guard let truthSeconds = truthSeconds(beat),
                  let delineated = d.byRPeak[d.truth.beatSampleIndices[i]] else { continue }
            if let fiducial = found(delineated) {
                errorsMs.append((Double(fiducial.sampleIndex) / d.sampleRate - truthSeconds) * 1000)
            } else {
                absent += 1
            }
        }
        return (errorsMs, absent)
    }

    private func assertPlacement(
        _ label: String,
        _ result: (errorsMs: [Double], absentCount: Int),
        sigmaMs: Double,
        worstMultiplier: Double = 2.0
    ) throws {
        #expect(result.absentCount == 0,
                "\(label): \(result.absentCount) beat(s) missing the fiducial on a clean record")
        let sorted = try #require(result.errorsMs.isEmpty ? nil : result.errorsMs.sorted(),
                                  "\(label): no measurements")
        let median = sorted[sorted.count / 2]
        let worst = sorted.map { abs($0) }.max() ?? 0
        #expect(abs(median) <= sigmaMs + 10,
                "\(label): median error \(median) ms exceeds σ+10 = \(sigmaMs + 10)")
        #expect(worst <= worstMultiplier * sigmaMs + 20,
                "\(label): worst |error| \(worst) ms exceeds \(worstMultiplier)σ+20")
    }

    @Test("Placement accuracy per fiducial kind, against construction")
    func placementOracle() throws {
        // Default parameters: rr ≈ 0.83 s, so tScale ≈ 1 and the constructed
        // widths are P 45 / Q 12 / S 14 / T 55 ms.
        let d = delineate(.init(durationSeconds: 180))
        try assertPlacement("pOnset", errors(d, truthSeconds: { $0[keyPath: \.pOnsetSeconds] }, found: \.pOnset),
                            sigmaMs: 45, worstMultiplier: 2.5)
        try assertPlacement("pOffset", errors(d, truthSeconds: { $0[keyPath: \.pOffsetSeconds] }, found: \.pOffset),
                            sigmaMs: 45, worstMultiplier: 2.5)
        try assertPlacement("qrsOnset", errors(d, truthSeconds: { $0[keyPath: \.qrsOnsetSeconds] }, found: \.qrsOnset),
                            sigmaMs: 12)
        try assertPlacement("qrsOffset", errors(d, truthSeconds: { $0[keyPath: \.qrsOffsetSeconds] }, found: \.qrsOffset),
                            sigmaMs: 14)
        try assertPlacement("tOnset", errors(d, truthSeconds: { $0[keyPath: \.tOnsetSeconds] }, found: \.tOnset),
                            sigmaMs: 55)
        try assertPlacement("tOffset", errors(d, truthSeconds: { $0[keyPath: \.tOffsetSeconds] }, found: \.tOffset),
                            sigmaMs: 55)
    }

    @Test("Suppressed P is NOT confidently found — the first negative-truth oracle")
    func suppressedPStaysAbsent() {
        let d = delineate(.init(durationSeconds: 180, afEpisode: 120...160))
        var afBeats = 0
        var pReported: [Double] = []   // confidences of Ps claimed where none exists
        for (i, beat) in d.truth.beatFiducials.enumerated() {
            guard beat.pOnsetSeconds == nil,
                  let delineated = d.byRPeak[d.truth.beatSampleIndices[i]] else { continue }
            afBeats += 1
            if let claimed = delineated.pOnset { pReported.append(claimed.confidence) }
        }
        #expect(afBeats > 30, "The 40 s AF span should cover dozens of beats, got \(afBeats)")
        // The wavelet stage may see noise-shaped candidates on a few beats —
        // what must NOT happen is frequent or confident claims.
        #expect(Double(pReported.count) <= 0.1 * Double(afBeats),
                "P claimed on \(pReported.count)/\(afBeats) suppressed-P beats")
        #expect(pReported.allSatisfy { $0 <= 0.2 },
                "A claimed P on a P-less beat must carry low confidence, got \(pReported)")
    }
}
#endif
