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
//  beat times the detector must find, and the episode boundaries (AF, noise,
//  X101 rate) a detector's sensitivity is measured against. Fixed seed →
//  bit-identical
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
        /// X105 (#176): electrode-disconnect spans — the SIGNAL goes to a
        /// hard zero on the named leads while the heart keeps beating: truth
        /// beats and the annotations sidecar are untouched, so a detector
        /// re-reading the signal MISSES beats there (that residual is the
        /// fixture's point) while the sidecar-driven pipeline still sees
        /// them. The artifact lane goes to 0.9 over each span (disconnect ≈
        /// total artifact; broadband noise is 0.35, clean 0.02).
        public var flatlineSpans: [FlatlineSpan]
        /// X105: leads flat for the WHOLE record while the others carry
        /// signal — the lead-dropout state (overlay/legend + primary-lead
        /// fallback surfaces). Names must be members of `leadNames`; a
        /// dropped lead does NOT elevate the artifact lane (one dead lead is
        /// not whole-record artifact).
        public var droppedLeads: [String]
        /// X104: times (seconds) near which an isolated wide-complex
        /// premature beat REPLACES the nearest sinus beat: it arrives at
        /// `pvcCouplingFraction` of the local R–R (the short coupling) while
        /// the next sinus beat stays on schedule (the full compensatory
        /// pause — coupling + following ≈ two sinus cycles, the signature
        /// `PrematureBeatDetector` keys on). Times must be ≥ 3 sinus R–R
        /// apart and clear of every episode span; a request that can't be
        /// honored is SKIPPED — truth records only what was constructed.
        public var pvcTimesSeconds: [Double]
        /// X104: spans of ≥ 3 consecutive wide-complex beats at a regular
        /// elevated rate. Morphology is deliberately crude (broad inverted
        /// complex, discordant T, no P) — it validates plumbing and
        /// thresholding, never classifier accuracy (the deliberate limit in
        /// this file's header). Boundaries are truth verbatim.
        public var wideComplexRuns: [WideComplexRun]
        /// X101: spans where the constructed rate holds a target bpm. The
        /// profile sits at `bpm` EXACTLY over each range — that range is the
        /// truth boundary — with short linear ramps immediately OUTSIDE it
        /// (`rateRampSeconds` per side), so band-edge crossing happens within
        /// one ramp of the truth boundary, never inside it. Episodes must be
        /// disjoint with ≥ 2×`rateRampSeconds` between them; bpm outside
        /// ~(30, 170) hits the physiological R–R clamps and flattens.
        public var rateEpisodes: [RateEpisode]

        public init(
            durationSeconds: Double = 180,
            ecgSampleRate: Double = 250,
            meanHeartRateBPM: Double = 72,
            rrStandardDeviationMs: Double = 45,
            lfHfRatio: Double = 1.5,
            seed: UInt64 = 0xEC6_5EED,
            noiseEpisodes: [ClosedRange<Double>] = [],
            afEpisode: ClosedRange<Double>? = nil,
            flatlineSpans: [FlatlineSpan] = [],
            droppedLeads: [String] = [],
            pvcTimesSeconds: [Double] = [],
            wideComplexRuns: [WideComplexRun] = [],
            rateEpisodes: [RateEpisode] = []
        ) {
            self.durationSeconds = durationSeconds
            self.ecgSampleRate = ecgSampleRate
            self.meanHeartRateBPM = meanHeartRateBPM
            self.rrStandardDeviationMs = rrStandardDeviationMs
            self.lfHfRatio = lfHfRatio
            self.seed = seed
            self.noiseEpisodes = noiseEpisodes
            self.afEpisode = afEpisode
            self.flatlineSpans = flatlineSpans
            self.droppedLeads = droppedLeads
            self.pvcTimesSeconds = pvcTimesSeconds
            self.wideComplexRuns = wideComplexRuns
            self.rateEpisodes = rateEpisodes
        }
    }

    /// X101 (#172): one constructed rate episode. HRV deviations from the
    /// spectral tachogram ride ON TOP of the episode's mean R–R, so the span
    /// is a rate change, not a variability change — SDNN-sized jitter around
    /// a bpm this far out of band never crosses back across a band edge
    /// inside the plateau.
    public struct RateEpisode: Equatable, Sendable, Codable {
        /// Seconds from record start; the profile is at `bpm` exactly here.
        public var range: ClosedRange<Double>
        public var bpm: Double

        public init(range: ClosedRange<Double>, bpm: Double) {
            self.range = range
            self.bpm = bpm
        }
    }

    /// X105 (#176): one electrode-disconnect span.
    public struct FlatlineSpan: Equatable, Sendable, Codable {
        /// Seconds from record start; samples inside are exactly zero.
        public var range: ClosedRange<Double>
        /// Leads to flatten, by `leadNames` name; nil or empty = every lead
        /// (a full disconnect).
        public var leadNames: [String]?

        public init(range: ClosedRange<Double>, leadNames: [String]? = nil) {
            self.range = range
            self.leadNames = leadNames
        }
    }

    /// X104 (#175): one constructed wide-complex run.
    public struct WideComplexRun: Equatable, Sendable, Codable {
        /// Seconds from record start; every beat inside is wide-complex,
        /// regularly spaced at `bpm`.
        public var range: ClosedRange<Double>
        public var bpm: Double

        public init(range: ClosedRange<Double>, bpm: Double = 160) {
            self.range = range
            self.bpm = bpm
        }
    }

    // MARK: - Ground truth

    public struct TruthEpisode: Equatable, Sendable, Codable {
        public enum Kind: String, Sendable, Codable {
            case atrialFibrillation
            case noise
            /// X101: rate episodes are labeled against the standard adult
            /// definitional coordinates (60 / 100 bpm — the same definitional
            /// edges `RhythmBandConfig` defaults to, not an app-chosen
            /// severity). A constructed rate episode INSIDE 60–100 gets no
            /// truth label at all: it is negative-truth material, a real rate
            /// change a default-band detector must stay silent about.
            case bradycardia
            case tachycardia
            /// X104: a constructed run of ≥ 3 wide-complex beats at elevated
            /// rate. Boundaries are the constructed range verbatim.
            case wideComplexRun
            /// X105: an electrode-disconnect span (see `FlatlineSpan`).
            /// Boundaries verbatim; recorded once per span regardless of
            /// which leads it silences.
            case flatline
        }
        public var kind: Kind
        public var startSeconds: Double
        public var endSeconds: Double
    }

    /// X104 (#175): what each constructed beat IS. Construction truth, not a
    /// clinical label — `.pvc` means "we built an early wide-complex beat
    /// with a compensatory pause here," which is exactly what a detector is
    /// entitled to find.
    public enum BeatKind: String, Sendable, Codable {
        case sinus
        case pvc
        case wideComplexRun
    }

    /// X103 (#174): per-beat fiducial truth, in the DELINEATOR'S vocabulary
    /// (pOnset/pOffset/qrsOnset/rPeak/qrsOffset/tOnset/tOffset — no P/T peak
    /// kinds exist downstream). Onset/offset convention: centre ±
    /// `fiducialHalfWidthMultiplier` Gaussian widths of the constructed bump
    /// (2σ — the point the wave has risen to ~13.5% of its peak). All in
    /// seconds from record start; P fields are nil where the P wave is
    /// suppressed (inside the AF span) — that absence IS truth.
    public struct TruthBeatFiducials: Equatable, Sendable, Codable {
        /// X104: `.sinus` unless this beat was constructed as ectopy.
        public var kind: BeatKind
        public var rPeakSeconds: Double
        public var pOnsetSeconds: Double?
        public var pOffsetSeconds: Double?
        public var qrsOnsetSeconds: Double
        public var qrsOffsetSeconds: Double
        public var tOnsetSeconds: Double
        public var tOffsetSeconds: Double
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
        /// X103: one entry per beat, parallel to `beatTimesSeconds`.
        public var beatFiducials: [TruthBeatFiducials]

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
        var (beats, kinds) = placeBeats(p, grid: grid, rng: &rng)
        insertPVCs(p, beats: &beats, kinds: &kinds)

        // 2. The waveform laid along it — from per-beat layouts that the
        // fiducial truth shares verbatim (X103).
        let beatLayouts = layouts(p, beats: beats, kinds: kinds)
        let sampleCount = Int(p.durationSeconds * p.ecgSampleRate)
        var dipole = [Double](repeating: 0, count: sampleCount)
        addBeatComplexes(p, beats: beats, layouts: beatLayouts, into: &dipole)
        addBaselineWander(p, into: &dipole)
        addNoiseEpisodes(p, into: &dipole, rng: &rng)

        var leads = leadGains.map { gain in dipole.map { $0 * gain } }
        applyFlatline(p, leads: &leads)

        // 3. Truth + consistent trend channels.
        let episodes = truthEpisodes(p)
        var rr: [Double] = []
        rr.reserveCapacity(max(0, beats.count - 1))
        for i in 1..<max(1, beats.count) {
            rr.append((beats[i] - beats[i - 1]) * 1000)
        }
        let truth = Truth(
            parameters: p,
            beatTimesSeconds: beats,
            rrIntervalsMs: rr,
            episodes: episodes.sorted { $0.startSeconds < $1.startSeconds },
            beatFiducials: fiducialTruth(beats: beats, kinds: kinds, layouts: beatLayouts)
        )
        return Output(
            leads: leads,
            truth: truth,
            artifactRatioPerSecond: artifactSeries(p),
            heartRatePerSecond: heartRateSeries(p, beats: beats)
        )
    }

    /// Episode truth is a pure function of the parameters — every span is
    /// recorded verbatim; rate episodes are classified at the definitional
    /// 60 / 100 coordinates (in-band episodes stay unlabeled, deliberately).
    private static func truthEpisodes(_ p: Parameters) -> [TruthEpisode] {
        var episodes: [TruthEpisode] = p.noiseEpisodes.map {
            TruthEpisode(kind: .noise, startSeconds: $0.lowerBound, endSeconds: $0.upperBound)
        }
        if let af = p.afEpisode {
            episodes.append(TruthEpisode(
                kind: .atrialFibrillation, startSeconds: af.lowerBound, endSeconds: af.upperBound
            ))
        }
        for span in p.flatlineSpans {
            episodes.append(TruthEpisode(
                kind: .flatline,
                startSeconds: span.range.lowerBound,
                endSeconds: span.range.upperBound
            ))
        }
        for run in p.wideComplexRuns {
            episodes.append(TruthEpisode(
                kind: .wideComplexRun,
                startSeconds: run.range.lowerBound,
                endSeconds: run.range.upperBound
            ))
        }
        for episode in p.rateEpisodes {
            let kind: TruthEpisode.Kind? = episode.bpm < 60 ? .bradycardia
                : episode.bpm > 100 ? .tachycardia : nil
            if let kind {
                episodes.append(TruthEpisode(
                    kind: kind,
                    startSeconds: episode.range.lowerBound,
                    endSeconds: episode.range.upperBound
                ))
            }
        }
        return episodes
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

    /// X101: ramp length OUTSIDE each rate-episode edge. Short enough that a
    /// detector's band-entry point lands within a couple of R–R of the truth
    /// boundary; the plateau itself never contains ramp samples, so the
    /// episode range IS the at-target span.
    static let rateRampSeconds = 1.5

    /// The constructed instantaneous heart rate at `t`: baseline mean
    /// everywhere, the episode's target inside its range, linear blend on
    /// the ramps just outside. This — not the detector — is what the truth
    /// episodes describe.
    private static func constructedBpm(_ p: Parameters, at t: Double) -> Double {
        for episode in p.rateEpisodes {
            if episode.range.contains(t) { return episode.bpm }
            let rampIn = episode.range.lowerBound - rateRampSeconds
            if t >= rampIn, t < episode.range.lowerBound {
                let f = (t - rampIn) / rateRampSeconds
                return p.meanHeartRateBPM + f * (episode.bpm - p.meanHeartRateBPM)
            }
            let rampOut = episode.range.upperBound + rateRampSeconds
            if t > episode.range.upperBound, t <= rampOut {
                let f = (t - episode.range.upperBound) / rateRampSeconds
                return episode.bpm + f * (p.meanHeartRateBPM - episode.bpm)
            }
        }
        return p.meanHeartRateBPM
    }

    /// Integrate the tachogram into beat times: each beat schedules the next
    /// one R–R later, reading the grid at the current time. Inside the AF
    /// span the grid is ignored: R–R draws are irregular and memoryless,
    /// which is the property AF detectors key on. Rate episodes shift the
    /// local mean R–R while the grid's HRV DEVIATION rides on top, so the
    /// spectral character survives the rate change. Wide-complex runs
    /// (X104) override everything inside their span: regular spacing at the
    /// run's bpm, beat kind tagged.
    private static func placeBeats(
        _ p: Parameters, grid: [Double], rng: inout SplitMix64
    ) -> (beats: [Double], kinds: [BeatKind]) {
        var beats: [Double] = []
        var kinds: [BeatKind] = []
        var t = 0.3   // first beat shortly after record start
        let meanRRMs = 60_000 / p.meanHeartRateBPM
        while t < p.durationSeconds - 0.2 {
            beats.append(t)
            var rrMs: Double
            if let run = p.wideComplexRuns.first(where: { $0.range.contains(t) }) {
                kinds.append(.wideComplexRun)
                rrMs = 60_000 / run.bpm
            } else if let af = p.afEpisode, af.contains(t) {
                kinds.append(.sinus)
                // Shorter mean, heavy jitter, hard clamps: irregularly
                // irregular without spectral structure.
                rrMs = 0.8 * meanRRMs + rng.gaussian() * 150
                rrMs = min(1500, max(280, rrMs))
            } else {
                kinds.append(.sinus)
                let idx = min(grid.count - 1, max(0, Int(t * rrGridHz)))
                let hrvDeviationMs = grid[idx] - meanRRMs
                rrMs = 60_000 / constructedBpm(p, at: t) + hrvDeviationMs
                rrMs = min(2000, max(350, rrMs))
            }
            t += rrMs / 1000
        }
        return (beats, kinds)
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
