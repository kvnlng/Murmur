//
//  SyntheticECGWaveform.swift
//  MurmurCore
//
//  X103 (#174) — the waveform half of the generator, split from
//  SyntheticECG.swift for length. `BeatLayout` is the SINGLE source both the
//  waveform renderer and the per-beat fiducial truth read, so signal and
//  truth cannot drift apart. Members are internal, not private: the
//  generation entry point in SyntheticECG.swift calls them.
//

import Foundation

extension SyntheticECG {
    // MARK: - Flat-line states (X105)

    /// Zero the named leads over each disconnect span, and dropped leads
    /// over the whole record. Runs AFTER lead projection so baseline wander
    /// and noise are silenced too — a disconnected electrode records
    /// nothing, not "signal minus QRS."
    static func applyFlatline(_ p: Parameters, leads: inout [[Double]]) {
        guard !leads.isEmpty else { return }
        let sampleCount = leads[0].count

        func indices(of names: [String]?) -> [Int] {
            guard let names, !names.isEmpty else { return Array(leads.indices) }
            return names.compactMap { leadNames.firstIndex(of: $0) }
        }
        for span in p.flatlineSpans {
            let lo = max(0, Int(span.range.lowerBound * p.ecgSampleRate))
            let hi = min(sampleCount - 1, Int(span.range.upperBound * p.ecgSampleRate))
            guard lo <= hi else { continue }
            for leadIndex in indices(of: span.leadNames) {
                for s in lo...hi { leads[leadIndex][s] = 0 }
            }
        }
        guard !p.droppedLeads.isEmpty else { return }
        for leadIndex in indices(of: p.droppedLeads) {
            leads[leadIndex] = [Double](repeating: 0, count: sampleCount)
        }
    }

    // MARK: - Ectopy (X104)

    /// X104: the PVC coupling — the premature beat arrives at this fraction
    /// of the local sinus R–R. 0.62 is comfortably past the detector's
    /// default 15 % prematurity floor, and leaving the NEXT sinus beat on
    /// schedule makes the pause fully compensatory by construction:
    /// coupling + following = two sinus cycles exactly.
    static let pvcCouplingFraction = 0.62

    /// Replace the nearest eligible sinus beat with a premature one. A
    /// request whose neighbourhood isn't three consecutive sinus beats
    /// (record edges, episode spans, an already-converted neighbour) is
    /// skipped — truth records only what was actually constructed.
    static func insertPVCs(
        _ p: Parameters, beats: inout [Double], kinds: inout [BeatKind]
    ) {
        guard !p.pvcTimesSeconds.isEmpty, beats.count >= 3 else { return }
        for target in p.pvcTimesSeconds {
            let candidates = beats.indices.dropFirst().dropLast().filter { k in
                (k - 1...k + 1).allSatisfy { i in
                    kinds[i] == .sinus && p.afEpisode?.contains(beats[i]) != true
                }
            }
            guard let k = candidates.min(by: { abs(beats[$0] - target) < abs(beats[$1] - target) }),
                  abs(beats[k] - target) < 2.0   // an eligible beat must exist NEAR the
                                                 // request — otherwise it's a skip, not a
                                                 // silent relocation to the far side of a span
            else { continue }
            beats[k] = beats[k - 1] + pvcCouplingFraction * (beats[k] - beats[k - 1])
            kinds[k] = .pvc
        }
    }

    // MARK: - Waveform

    struct WaveBump {
        let centre: Double   // seconds relative to the R peak
        let width: Double    // Gaussian σ, seconds
        let amp: Double      // mV
    }

    /// One beat's named bumps — the SINGLE source both the waveform renderer
    /// and the fiducial truth read, so signal and truth cannot drift apart.
    struct BeatLayout {
        let p: WaveBump?     // nil where the P wave is suppressed (AF span)
        let q: WaveBump
        let r: WaveBump
        let s: WaveBump
        let t: WaveBump

        var allBumps: [WaveBump] {
            var bumps = [q, r, s, t]
            if let p { bumps.append(p) }
            return bumps
        }
    }

    /// X103: onset/offset sit at centre ± 2σ of the constructed bump — the
    /// wave has risen to e^{-2} ≈ 13.5% of its peak there, the outermost
    /// point a departure-from-baseline delineator can defensibly call the
    /// wave's edge. The convention is part of the truth contract; oracle
    /// tolerances are stated against it.
    static let fiducialHalfWidthMultiplier = 2.0

    /// Gaussian event bumps per beat (amplitudes in mV, times in seconds
    /// relative to the R peak). QT scales as √RR with QTc ≈ 410 ms — the
    /// dependence the QTc lane exists to remove.
    static func beatLayout(
        _ p: Parameters, beat: Double, rrS: Double, kind: BeatKind
    ) -> BeatLayout {
        guard kind == .sinus else { return wideComplexLayout() }
        let qt = 0.410 * sqrt(max(0.3, min(1.5, rrS)))     // Bazett, QTc 410 ms
        let tScale = sqrt(max(0.3, min(1.5, rrS)) / 0.8)
        let pSuppressed = p.afEpisode?.contains(beat) == true
        return BeatLayout(
            p: pSuppressed ? nil : WaveBump(centre: -0.170, width: 0.045, amp: 0.12),
            q: WaveBump(centre: -0.030, width: 0.012, amp: -0.12),
            r: WaveBump(centre: 0.000, width: 0.014, amp: 1.10),
            s: WaveBump(centre: 0.032, width: 0.014, amp: -0.22),
            t: WaveBump(centre: -0.045 + qt - 0.070 * tScale, width: 0.055 * tScale, amp: 0.32)
        )
    }

    /// X104: the crude ventricular morphology — a broad INVERTED complex
    /// with a slurred onset, discordant (upright, late) T, and no P.
    /// Deliberately not rr-adaptive and not lifelike: it exists so
    /// rule-based plumbing has a wide-QRS-shaped signal to chew on, never
    /// as a classifier fixture (the deliberate limit in SyntheticECG.swift's
    /// header). Fiducial truth still derives from these bumps verbatim —
    /// qrsOnset→qrsOffset spans ≈ 200 ms, "wide" by any definition.
    static func wideComplexLayout() -> BeatLayout {
        BeatLayout(
            p: nil,
            q: WaveBump(centre: -0.055, width: 0.020, amp: 0.18),
            r: WaveBump(centre: 0.000, width: 0.045, amp: -1.15),
            s: WaveBump(centre: 0.060, width: 0.022, amp: 0.25),
            t: WaveBump(centre: 0.220, width: 0.055, amp: 0.45)
        )
    }

    static func layouts(_ p: Parameters, beats: [Double], kinds: [BeatKind]) -> [BeatLayout] {
        let meanRRs = 60.0 / p.meanHeartRateBPM
        return beats.enumerated().map { i, beat in
            let rrS = i + 1 < beats.count ? beats[i + 1] - beat : meanRRs
            return beatLayout(p, beat: beat, rrS: rrS, kind: kinds[i])
        }
    }

    static func fiducialTruth(
        beats: [Double], kinds: [BeatKind], layouts: [BeatLayout]
    ) -> [TruthBeatFiducials] {
        let k = fiducialHalfWidthMultiplier
        return beats.indices.map { i in
            let beat = beats[i]
            let layout = layouts[i]
            return TruthBeatFiducials(
                kind: kinds[i],
                rPeakSeconds: beat + layout.r.centre,
                pOnsetSeconds: layout.p.map { beat + $0.centre - k * $0.width },
                pOffsetSeconds: layout.p.map { beat + $0.centre + k * $0.width },
                qrsOnsetSeconds: beat + layout.q.centre - k * layout.q.width,
                qrsOffsetSeconds: beat + layout.s.centre + k * layout.s.width,
                tOnsetSeconds: beat + layout.t.centre - k * layout.t.width,
                tOffsetSeconds: beat + layout.t.centre + k * layout.t.width
            )
        }
    }

    static func addBeatComplexes(
        _ p: Parameters, beats: [Double], layouts: [BeatLayout], into dipole: inout [Double]
    ) {
        let rate = p.ecgSampleRate
        for (beat, layout) in zip(beats, layouts) {
            for bump in layout.allBumps {
                let lo = max(0, Int((beat + bump.centre - 4 * bump.width) * rate))
                let hi = min(dipole.count - 1, Int((beat + bump.centre + 4 * bump.width) * rate))
                guard lo <= hi else { continue }
                for s in lo...hi {
                    let dt = Double(s) / rate - (beat + bump.centre)
                    dipole[s] += bump.amp * exp(-dt * dt / (2 * bump.width * bump.width))
                }
            }
        }
    }

    static func addBaselineWander(_ p: Parameters, into dipole: inout [Double]) {
        for s in 0..<dipole.count {
            let t = Double(s) / p.ecgSampleRate
            dipole[s] += 0.04 * sin(2 * .pi * 0.18 * t) + 0.02 * sin(2 * .pi * 0.33 * t + 1.1)
        }
    }

    static func addNoiseEpisodes(
        _ p: Parameters, into dipole: inout [Double], rng: inout SplitMix64
    ) {
        for episode in p.noiseEpisodes {
            let lo = max(0, Int(episode.lowerBound * p.ecgSampleRate))
            let hi = min(dipole.count - 1, Int(episode.upperBound * p.ecgSampleRate))
            guard lo <= hi else { continue }
            for s in lo...hi { dipole[s] += rng.gaussian() * 0.15 }
        }
    }

    // MARK: - Trend channels

    /// 0.02 clean baseline, 0.35 during a noise episode, 0.9 during a
    /// flat-line span (X105: disconnect ≈ total artifact) — all comfortably
    /// across the quality lane's 10% outline threshold. Dropped leads do not
    /// elevate the lane: one dead lead is not whole-record artifact.
    static func artifactSeries(_ p: Parameters) -> [Double] {
        (0..<Int(p.durationSeconds)).map { second in
            let t = Double(second)
            let flat = p.flatlineSpans.contains { $0.range.lowerBound <= t + 1 && t <= $0.range.upperBound }
            if flat { return 0.9 }
            let noisy = p.noiseEpisodes.contains { $0.lowerBound <= t + 1 && t <= $0.upperBound }
            return noisy ? 0.35 : 0.02
        }
    }

    static func heartRateSeries(_ p: Parameters, beats: [Double]) -> [Double] {
        var out = [Double](repeating: p.meanHeartRateBPM, count: Int(p.durationSeconds))
        guard beats.count > 1 else { return out }
        var beatIdx = 1
        for second in 0..<out.count {
            let t = Double(second)
            while beatIdx < beats.count - 1, beats[beatIdx] < t { beatIdx += 1 }
            let rr = beats[beatIdx] - beats[beatIdx - 1]
            if rr > 0 { out[second] = 60.0 / rr }
        }
        return out
    }
}
