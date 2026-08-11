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
    static func beatLayout(_ p: Parameters, beat: Double, rrS: Double) -> BeatLayout {
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

    static func layouts(_ p: Parameters, beats: [Double]) -> [BeatLayout] {
        let meanRRs = 60.0 / p.meanHeartRateBPM
        return beats.enumerated().map { i, beat in
            let rrS = i + 1 < beats.count ? beats[i + 1] - beat : meanRRs
            return beatLayout(p, beat: beat, rrS: rrS)
        }
    }

    static func fiducialTruth(beats: [Double], layouts: [BeatLayout]) -> [TruthBeatFiducials] {
        let k = fiducialHalfWidthMultiplier
        return zip(beats, layouts).map { beat, layout in
            TruthBeatFiducials(
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
}
