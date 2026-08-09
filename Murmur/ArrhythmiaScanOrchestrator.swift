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
//  Every operating point is a data-derived default (AFDB pRR50 bound,
//  60/100 bands, 2 s pause floor); the app never arbitrates a dial.
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

    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio
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

        // Drop the previous recording's candidates BEFORE the compute — on a
        // long record the scan takes real time, and stale spans rendering
        // over the new recording until it finishes would be a lie.
        await MainActor.run { scanContext.clearCandidates() }

        // Lead names in the same order `ecgLeadSamples` built the buffers.
        // An unreadable channel is dropped from the buffers but not from
        // this list, so on a count mismatch the attribution is unsafe —
        // omit the lead rather than guess (candidates then draw on every
        // channel, which is honest about not knowing).
        let leadNames = recording.channels
            .filter { !$0.isTrendChannel && $0.sampleCount > 0 }
            .map(\.name)
        let namesAligned = leadNames.count == leads.count

        let rhythmConfig = RhythmBandConfig()
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

        // Operating points first (they define what a candidate IS), then the
        // per-recording quality read. All data-derived defaults, named so the
        // caption stays a citation rather than decoration.
        let operatingPoints = String(
            format: "outside %.0f–%.0f bpm · pause ≥ %.1f s · pRR50 ≥ %.3f (AFDB)",
            rhythmConfig.lowBpm, rhythmConfig.highBpm,
            pauseConfig.minGapMs / 1000.0,
            afibConfig.pRR50Threshold
        )
        let quality = ArrhythmiaScanContext.qualityCaption(
            beatCount: result.quality.beatCount,
            leadName: leadName,
            rrArtifactFraction: result.quality.rrArtifactFraction,
            flaggedWindows: result.quality.qualityWindows.filter(\.flagged).count,
            totalWindows: result.quality.qualityWindows.count
        )
        let caption = "\(operatingPoints) · \(quality)"

        await MainActor.run {
            scanContext.setCandidates(annotations, parametersCaption: caption)
        }
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
