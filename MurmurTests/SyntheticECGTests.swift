//
//  SyntheticECGTests.swift
//  MurmurTests
//
//  X99 (#164) — the ECGSYN-style generator, and the known-answer oracles it
//  makes possible: the R–R tachogram exists BEFORE the waveform, so the
//  variability pipeline's output is compared against construction, not
//  against another estimate.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Synthetic ECG generator (X99)")
struct SyntheticECGTests {
    private func params(
        seconds: Double = 300,
        lfhf: Double = 1.5,
        seed: UInt64 = 7
    ) -> SyntheticECG.Parameters {
        SyntheticECG.Parameters(
            durationSeconds: seconds,
            lfHfRatio: lfhf,
            seed: seed
        )
    }

    // MARK: - Determinism

    @Test("Same seed → bit-identical record and truth; different seed → different")
    func determinism() {
        let a = SyntheticECG.generate(params())
        let b = SyntheticECG.generate(params())
        #expect(a.truth == b.truth)
        #expect(a.leads == b.leads)

        let c = SyntheticECG.generate(params(seed: 8))
        #expect(a.truth.beatTimesSeconds != c.truth.beatTimesSeconds,
                "A different seed must produce a different record")
        // …but a statistically equivalent one: same configured mean rate.
        let meanA = a.truth.rrIntervalsMs.reduce(0, +) / Double(a.truth.rrIntervalsMs.count)
        let meanC = c.truth.rrIntervalsMs.reduce(0, +) / Double(c.truth.rrIntervalsMs.count)
        #expect(abs(meanA - meanC) < 40,
                "Seed families should agree statistically (means \(meanA) vs \(meanC))")
    }

    // MARK: - The tachogram honors its configuration

    @Test("Mean rate and R–R spread track the configured parameters")
    func rrStatisticsTrackParameters() {
        let p = params()
        let truth = SyntheticECG.generate(p).truth
        let rr = truth.rrIntervalsMs
        #expect(rr.count > 300, "5 minutes at 72 bpm should carry ~360 intervals")

        let mean = rr.reduce(0, +) / Double(rr.count)
        #expect(abs(mean - 60_000 / p.meanHeartRateBPM) < 25,
                "Mean R–R should sit at the configured rate, got \(mean)")

        let sd = sqrt(rr.reduce(0) { $0 + pow($1 - mean, 2) } / Double(rr.count))
        #expect(sd > p.rrStandardDeviationMs * 0.6 && sd < p.rrStandardDeviationMs * 1.4,
                "R–R spread should track the configured SD (\(p.rrStandardDeviationMs)), got \(sd)")
    }

    @Test("The waveform puts a local maximum at every true R peak")
    func rPeaksAreWhereTruthSaysTheyAre() {
        let output = SyntheticECG.generate(params(seconds: 60))
        let leadII = output.leads[1]
        let rate = output.truth.parameters.ecgSampleRate
        for beat in output.truth.beatTimesSeconds.prefix(50) {
            let s = Int(beat * rate)
            guard s > 2, s < leadII.count - 3 else { continue }
            let window = Array(leadII[(s - 2)...(s + 2)])
            let peak = window.max() ?? 0
            #expect(peak > 0.8,
                    "An R peak should be a prominent positive deflection, got \(peak) at \(beat)s")
        }
    }

    // MARK: - Episodes carry exact boundaries

    @Test("The AF span is irregular where truth says, regular where it doesn't")
    func afEpisodeIsIrregularExactlyWhereLabeled() {
        var p = params(seconds: 300)
        p.afEpisode = 100...200
        let truth = SyntheticECG.generate(p).truth
        #expect(truth.episodes.contains {
            $0.kind == .atrialFibrillation && $0.startSeconds == 100 && $0.endSeconds == 200
        })

        func rmssd(_ values: [Double]) -> Double {
            guard values.count > 1 else { return 0 }
            var sum = 0.0
            for i in 1..<values.count { sum += pow(values[i] - values[i - 1], 2) }
            return sqrt(sum / Double(values.count - 1))
        }
        var inside: [Double] = [], outside: [Double] = []
        for (i, rr) in truth.rrIntervalsMs.enumerated() {
            let t = truth.beatTimesSeconds[i]
            // Margins keep boundary-straddling intervals out of both bins.
            if t > 105, t < 195 { inside.append(rr) }
            if t < 95 || t > 205 { outside.append(rr) }
        }
        let irregularity = rmssd(inside) / max(1, rmssd(outside))
        #expect(irregularity > 3,
                "AF R–R should be far more irregular than sinus (ratio \(irregularity))")
    }

    @Test("The artifact channel is elevated exactly over the noise episodes")
    func artifactChannelMatchesNoiseEpisodes() {
        var p = params(seconds: 120)
        p.noiseEpisodes = [30...45, 80...90]
        let output = SyntheticECG.generate(p)
        for (second, ratio) in output.artifactRatioPerSecond.enumerated() {
            let t = Double(second)
            let shouldBeNoisy = p.noiseEpisodes.contains { $0.lowerBound <= t + 1 && t <= $0.upperBound }
            if shouldBeNoisy {
                #expect(ratio > 0.1, "second \(second) should read artifacted")
            } else {
                #expect(ratio < 0.1, "second \(second) should read clean")
            }
        }
    }
}

#if canImport(MurmurMetrics)
import MurmurMetrics

// MARK: - Known-answer oracles (X99)

/// The point of the whole exercise: the pipeline's variability numbers are
/// checked against the record's CONSTRUCTION.
@Suite("Variability metrics against generated ground truth (X99)")
struct SyntheticECGOracleTests {
    private let output = SyntheticECG.generate(
        SyntheticECG.Parameters(durationSeconds: 600, lfHfRatio: 1.5, seed: 21)
    )

    /// Independent 5-line implementations — deliberately NOT the package's
    /// math, so agreement means two derivations concur, not one copied twice.
    private func oracleRMSSD(_ rr: [Double]) -> Double {
        var sum = 0.0
        for i in 1..<rr.count { sum += pow(rr[i] - rr[i - 1], 2) }
        return sqrt(sum / Double(rr.count - 1))
    }
    /// Sample (Bessel-corrected, ÷(N−1)) standard deviation — SDNN's standard
    /// definition in HRV practice and the one ECGMetricsService documents.
    private func oracleSDNN(_ rr: [Double]) -> Double {
        let mean = rr.reduce(0, +) / Double(rr.count)
        return sqrt(rr.reduce(0) { $0 + pow($1 - mean, 2) } / Double(rr.count - 1))
    }

    @Test("RMSSD and SDNN equal an independent computation over the true tachogram")
    func timeDomainOracle() throws {
        let rr = output.truth.rrIntervalsMs
        let report = try #require(ECGMetricsService.compute(fromRRIntervalsMs: rr))
        #expect(abs(report.rmssdMs - oracleRMSSD(rr)) < 1e-6,
                "service \(report.rmssdMs) vs oracle \(oracleRMSSD(rr))")
        #expect(abs(report.sdnnMs - oracleSDNN(rr)) < 1e-6,
                "service \(report.sdnnMs) vs oracle \(oracleSDNN(rr))")
    }

    /// The full pipeline seam: TRUE beat sample indices — exactly what the
    /// generated annotations sidecar carries and `normalBeatSampleIndices()`
    /// returns — through `ECGMetricsExtractor` must reproduce the truth
    /// tachogram, so the app's strip shows construction, not an estimate.
    @Test("Beat indices → extractor → metrics equals metrics over the truth tachogram")
    func extractorPipelineMatchesTruth() throws {
        let series = try #require(ECGMetricsExtractor.rrSeries(
            fromBeatSampleIndices: output.truth.beatSampleIndices,
            sampleRate: output.truth.parameters.ecgSampleRate
        ))
        let viaPipeline = try #require(ECGMetricsService.compute(from: series))
        let viaTruth = try #require(ECGMetricsService.compute(
            fromRRIntervalsMs: output.truth.rrIntervalsMs
        ))
        // Sample-index quantization at 250 Hz is ±4 ms per interval; RMSSD
        // of quantization noise stays well under 3 ms.
        #expect(abs(viaPipeline.rmssdMs - viaTruth.rmssdMs) < 3,
                "pipeline \(viaPipeline.rmssdMs) vs truth \(viaTruth.rmssdMs)")
        #expect(abs(viaPipeline.sdnnMs - viaTruth.sdnnMs) < 3)
        #expect(abs(viaPipeline.meanRRMs - viaTruth.meanRRMs) < 2)
    }

    /// LF/HF, two claims. (1) Pipeline correctness: the estimator over the
    /// generated tachogram lands in a sane band around the CONFIGURED ratio.
    /// (2) Discrimination: raising the configured ratio raises the estimate.
    /// The tolerance on (1) is statistical — Lomb–Scargle over finite
    /// windows has variance — while (2) is the assertion that survives any
    /// estimator bias.
    @Test("The LF/HF estimator recovers the configured spectral ratio")
    func lfhfRecovery() {
        func medianEstimate(configured: Double, seed: UInt64) -> Double? {
            let truth = SyntheticECG.generate(SyntheticECG.Parameters(
                durationSeconds: 900, lfHfRatio: configured, seed: seed
            )).truth
            let times = truth.beatTimesSeconds.dropFirst()
            let windows = RollingWindows.place(
                timesSeconds: Array(times), windowSeconds: 300, stepSeconds: 120
            )
            var ratios: [Double] = []
            for window in windows {
                let slice = RRSeries(
                    intervalsMs: Array(truth.rrIntervalsMs[window.indices]),
                    endTimesSeconds: Array(Array(times)[window.indices])
                )
                if let r = FrequencyDomainHRVAnalyzer.analyze(rr: slice)?.lfhfRatio {
                    ratios.append(r)
                }
            }
            guard !ratios.isEmpty else { return nil }
            return ratios.sorted()[ratios.count / 2]
        }

        let low = medianEstimate(configured: 0.5, seed: 33)
        let mid = medianEstimate(configured: 1.5, seed: 33)
        let high = medianEstimate(configured: 4.0, seed: 33)
        #expect(low != nil && mid != nil && high != nil,
                "The estimator should produce ratios on every configuration")
        guard let low, let mid, let high else { return }

        #expect(low < 1.0, "Configured 0.5 should read HF-dominant, got \(low)")
        #expect(high > 1.5, "Configured 4.0 should read LF-dominant, got \(high)")
        #expect(low < mid && mid < high,
                "Estimates must be monotonic in the configured ratio: \(low), \(mid), \(high)")
        #expect(mid > 0.6 && mid < 3.5,
                "Configured 1.5 should land in a sane band, got \(mid)")
    }
}
#endif

// MARK: - The written fixture round-trips

@Suite("Rich fixture files (X99)")
struct SyntheticRichFixtureTests {
    @Test("The rich record imports, and its truth sidecar decodes to the generated truth")
    func richRecordRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x99-rich-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let parameters = SyntheticECG.Parameters(durationSeconds: 60, seed: 5)
        let heaURL = try SyntheticRecording.makeRichRecord(into: dir, parameters: parameters)

        let truthURL = dir.appendingPathComponent("synthrich.synthesis-truth.json")
        let truth = try JSONDecoder().decode(
            SyntheticECG.Truth.self, from: Data(contentsOf: truthURL)
        )
        #expect(truth == SyntheticECG.generate(parameters).truth,
                "The sidecar must BE the generated truth — same seed, same record")

        let outputDir = dir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outputDir)

        // The imported record's annotator-coded normals ARE the true beats —
        // this is the seam the whole variability pipeline hangs off.
        #expect(summary.recording.normalBeatSampleIndices() == truth.beatSampleIndices,
                "Imported normal beats must equal the truth's R peaks")

        let leadNames = summary.recording.channels.map(\.name)
        for lead in SyntheticECG.leadNames {
            #expect(leadNames.contains(lead), "Missing lead \(lead)")
        }
        #expect(leadNames.contains("HR_bpm") && leadNames.contains("ecg_artifact_ratio"),
                "Trend channels should import alongside the leads")
    }
}

/// X101 (#172): the constructed rate profile and its truth labels — checked
/// against construction only, no detector involved.
@Suite("Synthetic ECG rate episodes (X101)")
struct SyntheticECGRateEpisodeTests {
    @Test("Out-of-band episodes are labeled at the definitional 60/100 edges; an in-band episode is unlabeled")
    func truthLabeling() {
        let output = SyntheticECG.generate(.init(
            durationSeconds: 180,
            rateEpisodes: [
                .init(range: 30...55, bpm: 45),    // < 60 → bradycardia
                .init(range: 80...100, bpm: 90),   // inside the band → negative truth, no label
                .init(range: 130...160, bpm: 130), // > 100 → tachycardia
            ]))
        let rate = output.truth.episodes
        #expect(rate.map(\.kind) == [.bradycardia, .tachycardia],
                "Exactly the two out-of-band episodes get labels, got \(rate.map(\.kind))")
        #expect(rate.first?.startSeconds == 30 && rate.first?.endSeconds == 55,
                "The truth boundary is the constructed range verbatim")
        #expect(rate.last?.startSeconds == 130 && rate.last?.endSeconds == 160)
    }

    @Test("The tachogram actually holds the target rate over the plateau and the baseline elsewhere")
    func profileIsRealized() {
        let p = SyntheticECG.Parameters(
            durationSeconds: 180,
            rateEpisodes: [.init(range: 70...110, bpm: 45)])
        let beats = SyntheticECG.generate(p).truth.beatTimesSeconds

        func meanRRMs(over range: ClosedRange<Double>) -> Double {
            var intervals: [Double] = []
            for i in 1..<beats.count where range.contains(beats[i - 1]) && range.contains(beats[i]) {
                intervals.append((beats[i] - beats[i - 1]) * 1000)
            }
            return intervals.reduce(0, +) / Double(intervals.count)
        }
        // HRV deviations average out over spans this long; ±25 ms is the
        // same statistical tolerance the X99 mean-rate test uses.
        #expect(abs(meanRRMs(over: 70...110) - 60_000 / 45) < 25,
                "Plateau must sit at the target R–R, got \(meanRRMs(over: 70...110))")
        #expect(abs(meanRRMs(over: 0...68) - 60_000 / p.meanHeartRateBPM) < 25,
                "Before the ramp the baseline rate must hold, got \(meanRRMs(over: 0...68))")
        #expect(abs(meanRRMs(over: 113...180) - 60_000 / p.meanHeartRateBPM) < 25,
                "After the exit ramp the baseline rate must return, got \(meanRRMs(over: 113...180))")
    }
}

#if canImport(MurmurMetrics)
/// X91: the arrhythmia scan service over the generated record — the dials'
/// detection path with constructed truth. The fixture's ~72 bpm sinus sits
/// inside the default 60–100 band (no rate candidates); a bradycardia
/// threshold raised above the mean rate must find the slow rhythm, and a
/// time window longer than any run must suppress it again.
@Suite("Synthetic ECG → arrhythmia scan (X91)")
struct SyntheticECGArrhythmiaScanTests {
    @Test("Raised brady threshold finds the constructed slow rhythm; a long window suppresses it")
    func rateDialsGoverning() {
        let output = SyntheticECG.generate(.init(durationSeconds: 180))
        let leads = output.leads.map { $0.map(Float.init) }
        let rate = output.truth.parameters.ecgSampleRate

        let defaults = ArrhythmiaScanService.scan(leads: leads, sampleRate: rate)
        #expect(defaults.quality.beatCount > 150,
                "QRS detection should find the ~216 constructed beats, got \(defaults.quality.beatCount)")
        let defaultRate = defaults.candidates.filter {
            $0.kind == .bradycardia || $0.kind == .tachycardia
        }
        #expect(defaultRate.isEmpty,
                "A ~72 bpm sinus record has no rate candidates at the 60–100 default")

        let raised = ArrhythmiaScanService.scan(
            leads: leads, sampleRate: rate,
            rhythmConfig: .init(lowBpm: 80))
        let brady = raised.candidates.filter { $0.kind == .bradycardia }
        #expect(!brady.isEmpty, "lowBpm 80 over a ~72 bpm record must mint bradycardia runs")

        let windowed = ArrhythmiaScanService.scan(
            leads: leads, sampleRate: rate,
            rhythmConfig: .init(lowBpm: 80, minDurationSeconds: 175))
        #expect(windowed.candidates.filter { $0.kind == .bradycardia }.isEmpty,
                "A 175 s window over a 180 s record suppresses every run")
    }
}

/// X101 (#172): rate-episode truth turns the X91 directional checks into
/// known-answer tests — detected boundaries against constructed boundaries,
/// at the DEFAULT band, with a mechanism-derived tolerance:
/// ramp (1.5 s, band-edge crossing happens inside it) + two R–R of start/end
/// quantization at the slowest constructed rate (2 × 60/45 ≈ 2.7 s) → 4.5 s.
/// Never loosened to pass — a failure beyond it is a boundary bug.
@Suite("Synthetic ECG rate episodes → arrhythmia scan (X101)")
struct SyntheticECGRateEpisodeScanTests {
    private static let edgeSlopSeconds = 4.5

    private func scanned(
        _ p: SyntheticECG.Parameters,
        rhythmConfig: RhythmBandConfig = .init()
    ) -> (truth: SyntheticECG.Truth, result: ArrhythmiaScanResult) {
        let output = SyntheticECG.generate(p)
        let leads = output.leads.map { $0.map(Float.init) }
        return (output.truth,
                ArrhythmiaScanService.scan(leads: leads, sampleRate: p.ecgSampleRate,
                                           rhythmConfig: rhythmConfig))
    }

    @Test("A constructed bradycardia episode is found AT DEFAULTS with boundary-exact truth")
    func bradyBoundariesKnownAnswer() throws {
        let (truth, result) = scanned(.init(
            durationSeconds: 180,
            rateEpisodes: [.init(range: 70...110, bpm: 45)]))
        let expected = try #require(truth.episodes.first { $0.kind == .bradycardia })

        let brady = result.candidates.filter { $0.kind == .bradycardia }
        let longest = try #require(
            brady.max { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) },
            "The 40 s @ 45 bpm episode must mint a candidate at the 60–100 default")
        #expect(abs(longest.startSeconds - expected.startSeconds) < Self.edgeSlopSeconds,
                "Start \(longest.startSeconds) vs truth \(expected.startSeconds)")
        #expect(abs(longest.endSeconds - expected.endSeconds) < Self.edgeSlopSeconds,
                "End \(longest.endSeconds) vs truth \(expected.endSeconds)")
        // Every brady candidate (ramp fragments included) lives at the
        // episode — a candidate elsewhere is a false positive, full stop.
        for candidate in brady {
            #expect(candidate.endSeconds > expected.startSeconds - Self.edgeSlopSeconds
                    && candidate.startSeconds < expected.endSeconds + Self.edgeSlopSeconds,
                    "Brady candidate at \(candidate.startSeconds)–\(candidate.endSeconds) is outside the constructed episode")
        }
        #expect(result.candidates.filter { $0.kind == .tachycardia }.isEmpty,
                "Nothing tachycardic was constructed")
    }

    @Test("A constructed tachycardia episode is found at defaults with boundary-exact truth")
    func tachyBoundariesKnownAnswer() throws {
        let (truth, result) = scanned(.init(
            durationSeconds: 180,
            rateEpisodes: [.init(range: 40...80, bpm: 130)]))
        let expected = try #require(truth.episodes.first { $0.kind == .tachycardia })

        let tachy = result.candidates.filter { $0.kind == .tachycardia }
        let longest = try #require(
            tachy.max { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) },
            "The 40 s @ 130 bpm episode must mint a candidate at the 60–100 default")
        #expect(abs(longest.startSeconds - expected.startSeconds) < Self.edgeSlopSeconds,
                "Start \(longest.startSeconds) vs truth \(expected.startSeconds)")
        #expect(abs(longest.endSeconds - expected.endSeconds) < Self.edgeSlopSeconds,
                "End \(longest.endSeconds) vs truth \(expected.endSeconds)")
        #expect(result.candidates.filter { $0.kind == .bradycardia }.isEmpty,
                "Nothing bradycardic was constructed")
    }

    @Test("The minDurationSeconds gate is exact at the run's own boundary")
    func minDurationGateIsExact() throws {
        let p = SyntheticECG.Parameters(
            durationSeconds: 180,
            rateEpisodes: [.init(range: 70...110, bpm: 45)])
        let open = scanned(p).result.candidates.filter { $0.kind == .bradycardia }
        let longest = try #require(
            open.max { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) })
        let runSeconds = longest.endSeconds - longest.startSeconds

        // Gate is `span >= window`: a window 0.1 s under the measured run
        // keeps it, 0.1 s over kills it — and nothing longer exists to survive.
        let under = scanned(p, rhythmConfig: .init(minDurationSeconds: runSeconds - 0.1))
            .result.candidates.filter { $0.kind == .bradycardia }
        #expect(under.contains { abs(($0.endSeconds - $0.startSeconds) - runSeconds) < 0.001 },
                "The \(runSeconds) s run must survive a \(runSeconds - 0.1) s window")
        let over = scanned(p, rhythmConfig: .init(minDurationSeconds: runSeconds + 0.1))
            .result.candidates.filter { $0.kind == .bradycardia }
        #expect(over.isEmpty,
                "A window past the longest run must suppress every brady candidate, got \(over.count)")
    }

    @Test("An in-band rate change gets no truth label and mints nothing SUSTAINED — negative truth")
    func inBandEpisodeStaysSilent() {
        // 90 bpm is 667 ms R–R; the default 45 ms SDNN jitter legitimately
        // pushes single intervals under 600 ms (> 100 bpm), so the policy-free
        // core (minRun 1) factually reports momentary grazes — those are
        // constructed reality, not false positives. The negative-truth claim
        // is that nothing SUSTAINED exists: a 5 s time-in-band window (the
        // X91 dial, far below the 40 s plateau, far above any jitter
        // excursion's fraction of the ~10 s LF cycle) must leave silence.
        let p = SyntheticECG.Parameters(
            durationSeconds: 180,
            rateEpisodes: [.init(range: 70...110, bpm: 90)])
        let (truth, windowed) = scanned(p, rhythmConfig: .init(minDurationSeconds: 5))
        #expect(truth.episodes.isEmpty, "An in-band episode gets no truth label")
        let rateKinds = windowed.candidates.filter {
            $0.kind == .bradycardia || $0.kind == .tachycardia
        }
        #expect(rateKinds.isEmpty,
                "A 72→90→72 bpm record sustains nothing outside 60–100; got \(rateKinds)")
    }
}
#endif
