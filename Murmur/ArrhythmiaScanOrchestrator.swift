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
//   2. Runs `ArrhythmiaScanService` off-main over ALL ECG leads (the
//      service picks the strongest-QRS lead itself) and publishes the
//      results to `ArrhythmiaScanContext` as range annotations.
//
//  Unlike VT/VF there is no scan dialog: the detectors are cheap RR-series
//  arithmetic (no Core ML, no operating-point preview), so the scan runs
//  automatically on load — the same trigger discipline as delineation.
//  Pause and AFib operating points are data-derived defaults (AFDB pRR50
//  bound, 2 s pause floor). The rate band is the analyst's own dials (X91,
//  `ArrhythmiaScanSettings`): the app still never ARBITRATES a threshold —
//  it defaults to the definitional 60/100 bands and echoes whatever the
//  analyst set into the caption, rescanning on every change.
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
        let lowBpm: Double
        let highBpm: Double
        let minDurationSeconds: Double
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio,
                lowBpm: settings.lowBpm,
                highBpm: settings.highBpm,
                minDurationSeconds: settings.minDurationSeconds
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
              let directory = recordingContext.directory,
              let ecgChannel = recording.primaryECGChannel,
              let leads = recording.ecgLeadSamples(inDirectory: directory) else {
            await MainActor.run { scanContext.clearCandidates() }
            return
        }
        let sampleRate = ecgChannel.sampleRate

        // Drop the previous candidates BEFORE the compute — on a long record
        // the scan takes real time, and stale spans rendering until it
        // finishes would be a lie. X91: publish a scanning placeholder
        // instead of clearing to nothing — an empty-and-caption-less context
        // unmounts the queue's group header, and with it the dials the
        // analyst may be mid-interaction with (a rescan is often CAUSED by
        // those dials).
        await MainActor.run { scanContext.setCandidates([], parametersCaption: "scanning…") }

        // Lead names in the same order `ecgLeadSamples` built the buffers.
        // An unreadable channel is dropped from the buffers but not from
        // this list, so on a count mismatch the attribution is unsafe —
        // omit the lead rather than guess (candidates then draw on every
        // channel, which is honest about not knowing).
        let leadNames = recording.channels
            .filter { !$0.isTrendChannel && $0.sampleCount > 0 }
            .map(\.name)
        let namesAligned = leadNames.count == leads.count

        // X91: the analyst's dials, snapshotted for this scan — the same
        // values the caption below echoes, so the citation can never drift
        // from the config that actually ran.
        let rhythmConfig = RhythmBandConfig(
            lowBpm: settings.lowBpm,
            highBpm: settings.highBpm,
            minDurationSeconds: settings.minDurationSeconds
        )
        let pauseConfig = PauseConfig()
        let afibConfig = AFibConfig()

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

        let leadName = namesAligned && result.quality.leadUsed < leadNames.count
            ? leadNames[result.quality.leadUsed]
            : nil
        let annotations = result.candidates.map { candidate in
            ArrhythmiaCandidateSource.makeAnnotation(
                kind: Self.coreKind(candidate.kind),
                startSample: Int64(candidate.startSeconds * sampleRate),
                endSample: Int64(candidate.endSeconds * sampleRate),
                detail: candidate.detail,
                confidence: candidate.confidence,
                lead: leadName
            )
        }

        let caption = Self.caption(
            rhythmConfig: rhythmConfig, pauseConfig: pauseConfig,
            afibConfig: afibConfig, quality: result.quality, leadName: leadName)

        await MainActor.run {
            scanContext.setCandidates(annotations, parametersCaption: caption)
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
            minDurationSeconds: rhythmConfig.minDurationSeconds
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
