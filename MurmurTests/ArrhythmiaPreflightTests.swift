//
//  ArrhythmiaPreflightTests.swift
//  MurmurTests
//
//  A3 (#2) — the confidence lever's surfacing half: the σ lookup (window
//  quality → calibrated sensitivity / error band) published as a pre-flight
//  read, and a per-candidate qualifier naming flagged ground. Wording and
//  overlap logic are pure MurmurCore statics (testable without the app
//  target, same pattern as `qualityCaption`); the end-to-end suite drives
//  the real scan over constructed flat-line and noise spans — X105's
//  fixtures doing exactly the job they were built for.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Arrhythmia pre-flight wording + qualifier (A3)")
struct ArrhythmiaPreflightTests {
    private func window(
        _ start: Double, _ end: Double,
        sensitivity: Double = 0.995, errP90Ms: Double = 41.7, flagged: Bool = false
    ) -> ArrhythmiaPreflightWindow {
        ArrhythmiaPreflightWindow(
            startSeconds: start, endSeconds: end,
            sensitivity: sensitivity, errP90Ms: errP90Ms, flagged: flagged)
    }

    @Test("Summary: nil without windows, an all-clear line, a floor/ceiling line when flagged")
    func summaryWording() {
        #expect(ArrhythmiaScanContext.preflightSummary(windows: []) == nil,
                "No windows (record shorter than one stable read) → no line, not a fabricated clean bill")

        let clear = ArrhythmiaScanContext.preflightSummary(
            windows: [window(0, 10), window(10, 20)])
        #expect(clear == "All 2 × 10 s windows clear of the flagged quality band.")

        let flagged = ArrhythmiaScanContext.preflightSummary(windows: [
            window(0, 10),
            window(10, 20, sensitivity: 0.875, errP90Ms: 97.2, flagged: true),
            window(20, 30, sensitivity: 0.910, errP90Ms: 80.0, flagged: true),
        ])
        #expect(flagged == "2 of 3 × 10 s windows in the flagged quality band — "
                + "calibrated read there: beat detection sensitivity down to 0.88, "
                + "R-peak placement error P90 up to 97 ms.",
                "Floor over flagged Se and ceiling over flagged err, got \(flagged ?? "nil")")
    }

    @Test("Qualifier: nil on clear ground, worst flagged window when spans overlap, edges exclusive")
    func qualifierOverlap() {
        let windows = [
            window(0, 10),
            window(10, 20, sensitivity: 0.875, flagged: true),
            window(20, 30, sensitivity: 0.910, flagged: true),
        ]
        #expect(ArrhythmiaScanContext.flaggedWindowQualifier(
            spanStartSeconds: 2, spanEndSeconds: 8, windows: windows) == nil,
                "A span entirely on clear ground carries no qualifier")
        #expect(ArrhythmiaScanContext.flaggedWindowQualifier(
            spanStartSeconds: 5, spanEndSeconds: 10, windows: windows) == nil,
                "Touching a flagged window's edge is not standing in it")
        #expect(ArrhythmiaScanContext.flaggedWindowQualifier(
            spanStartSeconds: 15, spanEndSeconds: 25, windows: windows)
                == "flagged-quality window (Se ~0.88)",
                "A span across both flagged windows names the WORST one")
        #expect(ArrhythmiaScanContext.flaggedWindowQualifier(
            spanStartSeconds: 22, spanEndSeconds: 28, windows: windows)
                == "flagged-quality window (Se ~0.91)")
    }
}

#if canImport(MurmurMetrics)
import MurmurMetrics

@Suite("Arrhythmia pre-flight over constructed signal states (A3)")
struct ArrhythmiaPreflightScanTests {
    private func scanWindows(
        _ p: SyntheticECG.Parameters
    ) -> (result: ArrhythmiaScanResult, preflight: [ArrhythmiaPreflightWindow]) {
        let output = SyntheticECG.generate(p)
        let result = ArrhythmiaScanService.scan(
            leads: output.leads.map { $0.map(Float.init) }, sampleRate: p.ecgSampleRate)
        // The same mapping the orchestrator performs (it cannot be shared —
        // the app target is unlinkable from MurmurTests, so the mapping is
        // deliberately trivial: copy fields, look up the error band).
        let calibration = QRSQualityCalibration.builtInNSTDBElectrodeMotion
        let preflight = result.quality.qualityWindows.map { window in
            ArrhythmiaPreflightWindow(
                startSeconds: window.startSeconds,
                endSeconds: window.endSeconds,
                sensitivity: window.sensitivity,
                errP90Ms: calibration.band(forQuality: window.quality).p90AbsErrMs,
                flagged: window.flagged)
        }
        return (result, preflight)
    }

    @Test("A clean record reads all-clear")
    func cleanRecordIsClear() throws {
        let (_, preflight) = scanWindows(.init(durationSeconds: 180))
        #expect(preflight.count == 18, "180 s at the 10 s calibration window")
        #expect(!preflight.contains { $0.flagged })
        let summary = try #require(ArrhythmiaScanContext.preflightSummary(windows: preflight))
        #expect(summary.contains("clear of the flagged quality band"))
    }

    @Test("A flat-line span flags exactly its windows, at the calibration's bottom band")
    func flatlineFlagsItsWindows() throws {
        let (result, preflight) = scanWindows(.init(
            durationSeconds: 180, flatlineSpans: [.init(range: 60...90)]))
        let flagged = preflight.filter(\.flagged)
        #expect(flagged.count == 3, "The 30 s disconnect covers three 10 s windows")
        let bottom = try #require(QRSQualityCalibration.builtInNSTDBElectrodeMotion.bands.first)
        for window in flagged {
            #expect(window.startSeconds >= 60 && window.endSeconds <= 90,
                    "Flagged window \(window.startSeconds)–\(window.endSeconds) outside the constructed span")
            #expect(window.sensitivity == bottom.sensitivity
                    && window.errP90Ms == bottom.p90AbsErrMs,
                    "Zero-quality windows must read the table's bottom band")
        }

        // The candidates the flat gap mints stand on flagged ground and the
        // qualifier says so; a clean-region span stays unqualified.
        let pause = try #require(result.candidates.first { $0.kind == .pause })
        #expect(ArrhythmiaScanContext.flaggedWindowQualifier(
            spanStartSeconds: pause.startSeconds, spanEndSeconds: pause.endSeconds,
            windows: preflight) == "flagged-quality window (Se ~0.88)")
        #expect(ArrhythmiaScanContext.flaggedWindowQualifier(
            spanStartSeconds: 10, spanEndSeconds: 20, windows: preflight) == nil)
    }

    @Test("A noise span flags windows with ZERO candidates — the pre-flight speaks anyway")
    func noiseFlagsWithoutCandidates() throws {
        let (result, preflight) = scanWindows(.init(
            durationSeconds: 180, noiseEpisodes: [60...90]))
        let flagged = preflight.filter(\.flagged)
        #expect(flagged.count == 3)
        #expect(flagged.allSatisfy { $0.startSeconds >= 60 && $0.endSeconds <= 90 })
        #expect(result.candidates.isEmpty,
                "No detector trips on this noise — the flagged read alone says quality collapsed")
        let summary = try #require(ArrhythmiaScanContext.preflightSummary(windows: preflight))
        #expect(summary.contains("3 of 18"))
    }
}
#endif

// #357: `ArrhythmiaScanCacheKey` is the app-target static that builds the
// arrhythmia scan's derived-cache `parametersKey`. It's exercised directly
// (no `@testable import Murmur` — MurmurTests never does that) via the same
// symlink mechanism as `QRSProminenceLeadScorer`: the file is a dependency-
// free standalone type, symlinked from Murmur/ into MurmurTests/ so the
// file-system-synchronized group compiles it into this module too.
@Suite("Arrhythmia scan cache key carries the analysis lead (#357)")
struct ArrhythmiaScanCacheKeyTests {
    @Test("Two keys differing only by lead name are different — designating invalidates the cache")
    func keyCarriesLead() {
        let a = ArrhythmiaScanCacheKey.make(
            lowBpm: 40, highBpm: 120, minDurationSeconds: 10,
            minRunBeats: 5, analysisLeadName: "MLII")
        let b = ArrhythmiaScanCacheKey.make(
            lowBpm: 40, highBpm: 120, minDurationSeconds: 10,
            minRunBeats: 5, analysisLeadName: "V5")
        #expect(a != b)
    }

    @Test("Otherwise-identical dials produce identical keys")
    func keyStableAcrossRuns() {
        let a = ArrhythmiaScanCacheKey.make(
            lowBpm: 45, highBpm: 150, minDurationSeconds: 8,
            minRunBeats: 4, analysisLeadName: "MLII")
        let b = ArrhythmiaScanCacheKey.make(
            lowBpm: 45, highBpm: 150, minDurationSeconds: 8,
            minRunBeats: 4, analysisLeadName: "MLII")
        #expect(a == b)
    }
}
