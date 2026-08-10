//
//  SyntheticECG.swift
//  MurmurCore
//
//  X99 — a dynamical synthetic ECG with KNOWN ground truth (#164).
//
//  The old fixture is a metronomic spike train: no P/T waves, zero R–R
//  variability, so every measurement surface either stays dark or is fed by
//  inject flags that bypass the pipeline under test. This generator follows
//  ECGSYN (McSharry, Clifford, Tarassenko & Smith 2003; PhysioNet): the R–R
//  tachogram is synthesized FIRST from a bimodal spectrum — a ~0.1 Hz Mayer
//  band and a ~0.25 Hz respiratory band whose power ratio is the configured
//  LF/HF — and the waveform is laid along it as Gaussian event bumps for
//  P/Q/R/S/T, with QT scaling as √RR (Bazett-consistent).
//
//  Because the truth is generated before the signal, every record carries an
//  exact oracle: the R–R series the variability metrics must recover, the
//  beat times the detector must find, and the episode boundaries (AF, noise)
//  a detector's sensitivity is measured against. Fixed seed → bit-identical
//  record; varied seed at fixed parameters → statistically equivalent
//  families for detection-rate measurement.
//
//  Deliberate limit (agreed 2026-08-10): no synthetic VT/VF accuracy claims —
//  that detector is a trained model and synthetic morphology can't stand in
//  for real pathology. Episodes here are rhythm/rate/noise phenomena that
//  rule-based detectors and the variability pipeline measure.
//
//  Pure math, no I/O — `SyntheticRecording` owns writing it to WFDB.
//

import Foundation

public enum SyntheticECG {
    // MARK: - Parameters

    public struct Parameters: Equatable, Sendable, Codable {
        public var durationSeconds: Double
        public var ecgSampleRate: Double
        public var meanHeartRateBPM: Double
        /// Target standard deviation of the R–R tachogram (≈ SDNN), ms.
        public var rrStandardDeviationMs: Double
        /// Power ratio of the LF (~0.1 Hz) to HF (~0.25 Hz) band in the R–R
        /// spectrum — the quantity the LF/HF lane estimates.
        public var lfHfRatio: Double
        public var seed: UInt64
        /// Spans (seconds from record start) of added broadband noise; the
        /// artifact-ratio channel is elevated over the same spans, so the
        /// quality lane and the signal agree by construction.
        public var noiseEpisodes: [ClosedRange<Double>]
        /// Optional AF-like span: irregular R–R (no spectral structure) with
        /// suppressed P waves. Boundaries are exact truth for detectors that
        /// key on R–R irregularity.
        public var afEpisode: ClosedRange<Double>?

        public init(
            durationSeconds: Double = 180,
            ecgSampleRate: Double = 250,
            meanHeartRateBPM: Double = 72,
            rrStandardDeviationMs: Double = 45,
            lfHfRatio: Double = 1.5,
            seed: UInt64 = 0xEC6_5EED,
            noiseEpisodes: [ClosedRange<Double>] = [],
            afEpisode: ClosedRange<Double>? = nil
        ) {
            self.durationSeconds = durationSeconds
            self.ecgSampleRate = ecgSampleRate
            self.meanHeartRateBPM = meanHeartRateBPM
            self.rrStandardDeviationMs = rrStandardDeviationMs
            self.lfHfRatio = lfHfRatio
            self.seed = seed
            self.noiseEpisodes = noiseEpisodes
            self.afEpisode = afEpisode
        }
    }

    // MARK: - Ground truth

    public struct TruthEpisode: Equatable, Sendable, Codable {
        public enum Kind: String, Sendable, Codable {
            case atrialFibrillation
            case noise
        }
        public var kind: Kind
        public var startSeconds: Double
        public var endSeconds: Double
    }

    /// What the record REALLY contains — written beside the signal so tests
    /// compare pipeline output against construction, not against another
    /// estimate.
    public struct Truth: Equatable, Sendable, Codable {
        public var parameters: Parameters
        /// R-peak times, seconds from record start.
        public var beatTimesSeconds: [Double]
        /// rr[i] = beat[i+1] − beat[i], in ms — the tachogram the variability
        /// metrics must recover (same convention as `ECGMetricsExtractor`:
        /// N beats → N−1 intervals).
        public var rrIntervalsMs: [Double]
        public var episodes: [TruthEpisode]

        /// R-peak positions in ECG samples — what the annotations sidecar
        /// carries and `normalBeatSampleIndices()` returns.
        public var beatSampleIndices: [Int64] {
            beatTimesSeconds.map { Int64(($0 * parameters.ecgSampleRate).rounded()) }
        }
    }

    public struct Output: Sendable {
        /// One buffer per lead, `leadNames.count` × (duration × rate) samples,
        /// in mV.
        public var leads: [[Double]]
        public var truth: Truth
        /// 1 Hz artifact-ratio series (0…1), elevated over noise episodes.
        public var artifactRatioPerSecond: [Double]
        /// 1 Hz heart-rate series from the true tachogram, bpm.
        public var heartRatePerSecond: [Double]
    }

    /// Standard 8-lead set the demo fixture already speaks.
    public static let leadNames = ["I", "II", "III", "aVR", "aVL", "aVF", "V1", "V2"]
    /// Per-lead projection of the single dipole waveform. aVR inverted, the
    /// one lead an analyst instantly notices is wrong when it isn't.
    static let leadGains: [Double] = [1.0, 1.15, 0.5, -0.9, 0.45, 0.85, 0.7, 1.25]

    // MARK: - Generation

    public static func generate(_ p: Parameters) -> Output {
        var rng = SplitMix64(seed: p.seed)

        // 1. The R–R tachogram, before any waveform exists (ECGSYN's order).
        let grid = rrTachogramGrid(p, rng: &rng)
        let beats = placeBeats(p, grid: grid, rng: &rng)

        // 2. The waveform laid along it.
        let sampleCount = Int(p.durationSeconds * p.ecgSampleRate)
        var dipole = [Double](repeating: 0, count: sampleCount)
        addBeatComplexes(p, beats: beats, into: &dipole)
        addBaselineWander(p, into: &dipole)
        addNoiseEpisodes(p, into: &dipole, rng: &rng)

        let leads = leadGains.map { gain in dipole.map { $0 * gain } }

        // 3. Truth + consistent trend channels.
        var episodes: [TruthEpisode] = p.noiseEpisodes.map {
            TruthEpisode(kind: .noise, startSeconds: $0.lowerBound, endSeconds: $0.upperBound)
        }
        if let af = p.afEpisode {
            episodes.append(TruthEpisode(
                kind: .atrialFibrillation, startSeconds: af.lowerBound, endSeconds: af.upperBound
            ))
        }
        var rr: [Double] = []
        rr.reserveCapacity(max(0, beats.count - 1))
        for i in 1..<max(1, beats.count) {
            rr.append((beats[i] - beats[i - 1]) * 1000)
        }
        let truth = Truth(
            parameters: p,
            beatTimesSeconds: beats,
            rrIntervalsMs: rr,
            episodes: episodes.sorted { $0.startSeconds < $1.startSeconds }
        )
        return Output(
            leads: leads,
            truth: truth,
            artifactRatioPerSecond: artifactSeries(p),
            heartRatePerSecond: heartRateSeries(p, beats: beats)
        )
    }

    // MARK: - R–R process

    /// Uniform 4 Hz grid of instantaneous R–R (ms) synthesized from the
    /// bimodal spectrum: cosines at each frequency bin with seeded random
    /// phase, band weights set so LF power / HF power = `lfHfRatio`, then
    /// scaled to the target standard deviation. This IS the ground truth the
    /// LF/HF estimator is later asked to recover.
    static let rrGridHz = 4.0

    private static func rrTachogramGrid(_ p: Parameters, rng: inout SplitMix64) -> [Double] {
        let n = max(8, Int(p.durationSeconds * rrGridHz))
        let df = 1.0 / p.durationSeconds
        // Weights: w_lf/w_hf = ratio, normalized. Band shapes follow ECGSYN's
        // defaults: Gaussians at 0.1 and 0.25 Hz with c1 = c2 = 0.01 Hz as
        // standard deviations (McSharry 2003). σ = 0.01 keeps each bump
        // entirely inside its Task Force band (LF 0.04–0.15, HF 0.15–0.40),
        // so the integrated band-power ratio equals the configured weight
        // ratio — the property the LF/HF oracle test relies on.
        let wLF = p.lfHfRatio / (1 + p.lfHfRatio)
        let wHF = 1 / (1 + p.lfHfRatio)
        func spectrum(_ f: Double) -> Double {
            func g(_ centre: Double) -> Double {
                let sigma = 0.01
                return exp(-pow(f - centre, 2) / (2 * sigma * sigma)) / (sqrt(2 * .pi) * sigma)
            }
            return wLF * g(0.10) + wHF * g(0.25)
        }
        // Sum of cosines up to 0.45 Hz — everything above is meaningless for
        // an R–R process sampled by ~1 Hz beats.
        struct SpectralBin {
            let amp: Double
            let f: Double
            let phase: Double
        }
        var bins: [SpectralBin] = []
        var f = df
        while f <= 0.45 {
            bins.append(SpectralBin(amp: sqrt(2 * spectrum(f) * df), f: f,
                                    phase: rng.uniform() * 2 * .pi))
            f += df
        }
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rrGridHz
            var v = 0.0
            for bin in bins { v += bin.amp * cos(2 * .pi * bin.f * t + bin.phase) }
            x[i] = v
        }
        // Scale to the target SD around the configured mean.
        let mean = x.reduce(0, +) / Double(n)
        let sd = sqrt(x.reduce(0) { $0 + pow($1 - mean, 2) } / Double(n))
        let meanRRMs = 60_000 / p.meanHeartRateBPM
        let scale = sd > 0 ? p.rrStandardDeviationMs / sd : 0
        return x.map { meanRRMs + ($0 - mean) * scale }
    }

    /// Integrate the tachogram into beat times: each beat schedules the next
    /// one R–R later, reading the grid at the current time. Inside the AF
    /// span the grid is ignored: R–R draws are irregular and memoryless,
    /// which is the property AF detectors key on.
    private static func placeBeats(
        _ p: Parameters, grid: [Double], rng: inout SplitMix64
    ) -> [Double] {
        var beats: [Double] = []
        var t = 0.3   // first beat shortly after record start
        let meanRRMs = 60_000 / p.meanHeartRateBPM
        while t < p.durationSeconds - 0.2 {
            beats.append(t)
            var rrMs: Double
            if let af = p.afEpisode, af.contains(t) {
                // Shorter mean, heavy jitter, hard clamps: irregularly
                // irregular without spectral structure.
                rrMs = 0.8 * meanRRMs + rng.gaussian() * 150
                rrMs = min(1500, max(280, rrMs))
            } else {
                let idx = min(grid.count - 1, max(0, Int(t * rrGridHz)))
                rrMs = min(2000, max(350, grid[idx]))
            }
            t += rrMs / 1000
        }
        return beats
    }

    // MARK: - Waveform

    /// Gaussian event bumps per beat (amplitudes in mV, times in seconds
    /// relative to the R peak). QT scales as √RR with QTc ≈ 410 ms — the
    /// dependence the QTc lane exists to remove.
    private static func addBeatComplexes(
        _ p: Parameters, beats: [Double], into dipole: inout [Double]
    ) {
        let rate = p.ecgSampleRate
        let meanRRs = 60.0 / p.meanHeartRateBPM
        struct WaveBump {
            let centre: Double
            let width: Double
            let amp: Double
        }
        for (i, beat) in beats.enumerated() {
            let rrS = i + 1 < beats.count ? beats[i + 1] - beat : meanRRs
            let qt = 0.410 * sqrt(max(0.3, min(1.5, rrS)))     // Bazett, QTc 410 ms
            let tScale = sqrt(max(0.3, min(1.5, rrS)) / 0.8)
            let pSuppressed = p.afEpisode?.contains(beat) == true
            var bumps: [WaveBump] = [
                WaveBump(centre: -0.030, width: 0.012, amp: -0.12),                      // Q
                WaveBump(centre: 0.000, width: 0.014, amp: 1.10),                        // R
                WaveBump(centre: 0.032, width: 0.014, amp: -0.22),                       // S
                WaveBump(centre: -0.045 + qt - 0.070 * tScale, width: 0.055 * tScale, amp: 0.32), // T
            ]
            if !pSuppressed {
                bumps.append(WaveBump(centre: -0.170, width: 0.045, amp: 0.12))          // P
            }
            for bump in bumps {
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

    private static func addBaselineWander(_ p: Parameters, into dipole: inout [Double]) {
        for s in 0..<dipole.count {
            let t = Double(s) / p.ecgSampleRate
            dipole[s] += 0.04 * sin(2 * .pi * 0.18 * t) + 0.02 * sin(2 * .pi * 0.33 * t + 1.1)
        }
    }

    private static func addNoiseEpisodes(
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

    /// 0.02 clean baseline, 0.35 during a noise episode — comfortably across
    /// the quality lane's 10% outline threshold in both directions.
    private static func artifactSeries(_ p: Parameters) -> [Double] {
        (0..<Int(p.durationSeconds)).map { second in
            let t = Double(second)
            let noisy = p.noiseEpisodes.contains { $0.lowerBound <= t + 1 && t <= $0.upperBound }
            return noisy ? 0.35 : 0.02
        }
    }

    private static func heartRateSeries(_ p: Parameters, beats: [Double]) -> [Double] {
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

    // MARK: - Seeded RNG

    /// SplitMix64 — tiny, well-mixed, and OURS, so a Swift stdlib change can
    /// never silently re-randomize every "deterministic" fixture.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func uniform() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }

        /// Standard normal via Box–Muller.
        mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-12)
            let u2 = uniform()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }
}
