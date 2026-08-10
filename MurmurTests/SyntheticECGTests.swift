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
