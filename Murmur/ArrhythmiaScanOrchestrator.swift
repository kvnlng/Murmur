//
//  ArrhythmiaScanOrchestrator.swift
//  Murmur (app target)
//
//  Invisible glue view for the arrhythmia scan (A2) — the same
//  App-orchestrator ↔ MurmurCore-context pattern as the interval-markings
//  and VT/VF orchestrators. It:
//
//   1. Enforces the entitlement gate on the paid side: the scan only runs
//      when Murmur Studio is owned AND a recording is loaded, so the free
//      viewer never runs the detectors or shows candidates.
//   2. Runs `ArrhythmiaScanService` off-main over exactly the analysis
//      lead (#357 — one designated channel for every calculation,
//      disclosed once; no per-run strongest-QRS pick over all leads) and
//      publishes the results to `ArrhythmiaScanContext` as range
//      annotations.
//
//  Unlike VT/VF there is no scan dialog: the detectors are cheap RR-series
//  arithmetic (no Core ML, no operating-point preview), so the scan runs
//  automatically on load — the same trigger discipline as delineation.
//  Pause and AFib operating points are data-derived defaults (AFDB pRR50
//  bound, 2 s pause floor). The rate band is the analyst's own dials (X91,
//  `ArrhythmiaScanSettings`): the app still never ARBITRATES a threshold —
//  it defaults to the cardiologist review's cited candidate-screen bounds
//  (45/120 bpm, ≥ 5 beats; X106, cardiologist-review-packet.md §1.3) and
//  echoes whatever the analyst set into the caption, rescanning on every
//  change.
//
//  MurmurCore never imports MurmurMetrics — the detectors and the
//  candidate→annotation minting all happen here.
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct ArrhythmiaScanOrchestrator: View {

    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var scanContext = ArrhythmiaScanContext.shared
    @State private var store = PurchaseStore.shared
    /// X91: the analyst's rate-band dials. Part of the task key, so turning
    /// a dial rescans the open recording with the new thresholds.
    @State private var settings = ArrhythmiaScanSettings.shared

    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
        /// #357: a designation re-runs the scan. The bundle cache key
        /// carries the lead's name, so the re-run recomputes on the new lead
        /// rather than re-serving the previous one's candidates.
        let analysisLeadRevision: Int
        let lowBpm: Double
        let highBpm: Double
        let minDurationSeconds: Double
        let minRunBeats: Double
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio,
                analysisLeadRevision: recordingContext.analysisLeadRevision,
                lowBpm: settings.lowBpm,
                highBpm: settings.highBpm,
                minDurationSeconds: settings.minDurationSeconds,
                minRunBeats: settings.minRunBeats
            )) {
                await rescan()
            }
    }

    private func rescan() async {
        #if DEBUG
        // XCUI candidate-injection bypass: BedsideView publishes a fixed
        // candidate set under this flag; running the real detectors over the
        // synthetic fixture would overwrite the values the test asserts on.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-arrhythmia-candidates") {
            return
        }
        #endif
        // Gate on entitlement + presence of a recording; clear otherwise so
        // a swap to an unentitled state never leaves stale candidates
        // rendering over the next recording.
        guard store.hasStudio,
              let recording = recordingContext.recording,
              let directory = recordingContext.directory else {
            await MainActor.run { scanContext.clearCandidates() }
            return
        }
        // #357: the scan runs on THE ANALYSIS LEAD, not on a per-run
        // strongest-QRS pick over all leads — one designated channel for
        // every calculation, disclosed once. Passing a single lead keeps
        // ArrhythmiaScanService's API unchanged (its internal pick trivially
        // selects the only lead given), and the A3 quality preflight runs on
        // the same lead, as before.
        guard let resolution = recording.analysisLead(inBundle: directory),
              let leadSamples = recording.samples(of: resolution.channel, inDirectory: directory)
        else {
            await MainActor.run { scanContext.clearCandidates() }
            return
        }
        let leads = [leadSamples]
        let sampleRate = resolution.channel.sampleRate
        let analysisLeadName = resolution.channel.name
        let signpost = ComputeSignpost.begin("ArrhythmiaScan")
        defer {
            ComputeSignpost.end(signpost, workSize: leads.reduce(0) { $0 + $1.count })
        }

        // Drop the previous candidates BEFORE the compute — on a long record
        // the scan takes real time, and stale spans rendering until it
        // finishes would be a lie. X91: publish a scanning placeholder
        // instead of clearing to nothing — an empty-and-caption-less context
        // unmounts the queue's group header, and with it the dials the
        // analyst may be mid-interaction with (a rescan is often CAUSED by
        // those dials).
        await MainActor.run { scanContext.setCandidates([], parametersCaption: "scanning…") }

        // X91: the analyst's dials, snapshotted for this scan — the same
        // values the caption below echoes, so the citation can never drift
        // from the config that actually ran.
        let rhythmConfig = RhythmBandConfig(
            lowBpm: settings.lowBpm,
            highBpm: settings.highBpm,
            minDurationSeconds: settings.minDurationSeconds,
            minRunBeats: Int(settings.minRunBeats)
        )
        let pauseConfig = PauseConfig()
        let afibConfig = AFibConfig()

        // Bundle cache: keyed by the dials — the same values the caption
        // echoes. Checked BEFORE the placeholder publish above would matter:
        // a hit replaces the placeholder within the same turn of the loop,
        // so the queue never flashes "scanning…" for work that isn't run.
        let parametersKey = ArrhythmiaScanCacheKey.make(
            lowBpm: rhythmConfig.lowBpm, highBpm: rhythmConfig.highBpm,
            minDurationSeconds: rhythmConfig.minDurationSeconds,
            minRunBeats: rhythmConfig.minRunBeats, analysisLeadName: analysisLeadName)
        if let hit = await Task.detached(priority: .userInitiated, operation: {
            BundleDerivedCache.load(
                ArrhythmiaCachePayload.self, producer: "arrhythmia-scan",
                parametersKey: parametersKey, from: directory)
        }).value {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                scanContext.setCandidates(hit.candidates, parametersCaption: hit.caption,
                                          preflightWindows: hit.preflightWindows)
            }
            return
        }

        // Detect off the main actor — QRS over a multi-hour record is real
        // work, and the RR detectors ride on its output.
        let result = await Task.detached(priority: .userInitiated) {
            ArrhythmiaScanService.scan(
                leads: leads,
                sampleRate: sampleRate,
                rhythmConfig: rhythmConfig,
                pauseConfig: pauseConfig,
                afibConfig: afibConfig
            )
        }.value

        // A recording swap cancels this task but not the detached compute —
        // publishing after cancellation would paint the PREVIOUS recording's
        // candidates onto the new one until its own scan lands.
        guard !Task.isCancelled else { return }

        // `result.quality.leadUsed` is an index into `leads`, which now
        // holds exactly the analysis lead — always 0, and always this lead.
        // Attribution no longer needs the array round-trip.
        let preflightWindows = Self.preflightWindows(from: result.quality)
        let annotations = Self.annotations(
            from: result.candidates, sampleRate: sampleRate,
            leadName: analysisLeadName, preflightWindows: preflightWindows)

        let caption = Self.caption(
            rhythmConfig: rhythmConfig, pauseConfig: pauseConfig,
            afibConfig: afibConfig, quality: result.quality, leadName: analysisLeadName)

        let cachePayload = ArrhythmiaCachePayload(
            candidates: annotations, caption: caption, preflightWindows: preflightWindows)
        Task.detached(priority: .utility) {
            BundleDerivedCache.store(
                cachePayload, producer: "arrhythmia-scan",
                parametersKey: parametersKey, in: directory)
        }
        await MainActor.run {
            scanContext.setCandidates(annotations, parametersCaption: caption,
                                      preflightWindows: preflightWindows)
        }
    }

    /// A3: the σ lookup, made publishable. The scan's windows carry the
    /// calibrated sensitivity; the error band comes from the same table the
    /// service scanned with (its default — if a custom table is ever passed
    /// to `scan`, look the bands up on THAT one).
    private static func preflightWindows(
        from quality: ArrhythmiaScanQuality
    ) -> [ArrhythmiaPreflightWindow] {
        let calibration = QRSQualityCalibration.builtInNSTDBElectrodeMotion
        return quality.qualityWindows.map { window in
            ArrhythmiaPreflightWindow(
                startSeconds: window.startSeconds,
                endSeconds: window.endSeconds,
                sensitivity: window.sensitivity,
                errP90Ms: calibration.band(forQuality: window.quality).p90AbsErrMs,
                flagged: window.flagged
            )
        }
    }

    /// A3: a candidate standing on flagged ground says so on its row — the
    /// detail stays factual (a calibrated number, not a verdict).
    private static func annotations(
        from candidates: [ArrhythmiaCandidate],
        sampleRate: Double,
        leadName: String?,
        preflightWindows: [ArrhythmiaPreflightWindow]
    ) -> [Annotation] {
        candidates.map { candidate in
            let qualifier = ArrhythmiaScanContext.flaggedWindowQualifier(
                spanStartSeconds: candidate.startSeconds,
                spanEndSeconds: candidate.endSeconds,
                windows: preflightWindows
            )
            return ArrhythmiaCandidateSource.makeAnnotation(
                kind: Self.coreKind(candidate.kind),
                startSample: Int64(candidate.startSeconds * sampleRate),
                endSample: Int64(candidate.endSeconds * sampleRate),
                detail: qualifier.map { "\(candidate.detail) · \($0)" } ?? candidate.detail,
                confidence: candidate.confidence,
                lead: leadName
            )
        }
    }

    /// Operating points first (they define what a candidate IS), then the
    /// per-recording quality read. The rate band is the analyst's dials
    /// (X91), echoed verbatim; pause and AFib stay data-derived defaults.
    private static func caption(
        rhythmConfig: RhythmBandConfig,
        pauseConfig: PauseConfig,
        afibConfig: AFibConfig,
        quality: ArrhythmiaScanQuality,
        leadName: String?
    ) -> String {
        let operatingPoints = ArrhythmiaScanSettings.rhythmCaption(
            lowBpm: rhythmConfig.lowBpm,
            highBpm: rhythmConfig.highBpm,
            minDurationSeconds: rhythmConfig.minDurationSeconds,
            minRunBeats: Double(rhythmConfig.minRunBeats)
        ) + String(
            format: " · pause ≥ %.1f s · pRR50 ≥ %.3f (AFDB)",
            pauseConfig.minGapMs / 1000.0,
            afibConfig.pRR50Threshold
        )
        let qualityCaption = ArrhythmiaScanContext.qualityCaption(
            beatCount: quality.beatCount,
            leadName: leadName,
            rrArtifactFraction: quality.rrArtifactFraction,
            flaggedWindows: quality.qualityWindows.filter(\.flagged).count,
            totalWindows: quality.qualityWindows.count
        )
        return "\(operatingPoints) · \(qualityCaption)"
    }

    // MARK: - Enum bridging

    private static func coreKind(_ kind: ArrhythmiaCandidate.Kind) -> ArrhythmiaCandidateSource.Kind {
        switch kind {
        case .bradycardia:        return .bradycardia
        case .tachycardia:        return .tachycardia
        case .pause:              return .pause
        case .atrialFibrillation: return .atrialFibrillation
        }
    }
}


/// What the bundle cache holds for this producer — the published triple.
private struct ArrhythmiaCachePayload: Codable, Sendable {
    let candidates: [Annotation]
    let caption: String?
    let preflightWindows: [ArrhythmiaPreflightWindow]
}
