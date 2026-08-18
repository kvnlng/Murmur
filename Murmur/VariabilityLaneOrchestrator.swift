//
//  VariabilityLaneOrchestrator.swift
//  Murmur (app target)
//
//  The invisible glue that lets `MurmurMetrics` stay ignorant of
//  `MurmurCore` and vice versa. Attached to the main window as a
//  hidden background view; watches `CurrentRecordingContext` +
//  `PurchaseStore` + the lane's own `windowPreset` / `stepSeconds`
//  config for the state changes that should recompute the
//  variability-lane samples, and publishes the result to
//  `VariabilityLaneContext.shared` for `BedsideView` to render.
//
//  Enforces the paid-feature gate on THIS side of the boundary — the
//  free viewer (MurmurCore) never sees measurements the analyst hasn't
//  paid for, because we simply don't compute them when the entitlement
//  is absent. That matches the "no arithmetic on measurements in
//  MurmurCore" module-boundary decision.
//
//  Fixed for now (until follow-up slices expose them):
//    - metric: RMSSD                        (per the variability-lane spec)
//    - min:    30 RR endpoints per window   (conservative first-slice floor)
//    - max artifact fraction: 20 %          (spec default)
//
//  User-configurable via `VariabilityLaneContext`:
//    - window preset / custom window seconds
//    - step seconds
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct VariabilityLaneOrchestrator: View {

    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var laneContext = VariabilityLaneContext.shared
    @State private var store = PurchaseStore.shared

    private nonisolated static let minimumBeatCount: Int = 30
    private nonisolated static let metric: RollingMetric = .rmssd
    private static let metricLabel: String = "RMSSD"
    private static let metricUnit: String = "ms"
    /// A window with more than 20 % artifactual RRs fails the quality
    /// floor and renders dimmed on the lane. Matches the default
    /// documented in `project_variability_lane_design.md`.
    private nonisolated static let maxArtifactFraction: Double = 0.20
    /// 13a ribbon sub-window width. 1 min against the 5-min default
    /// window gives 49 sub-values per band at the computer's 5 s
    /// sub-step — the "spread of the indicator itself" decision on
    /// #261 (2026-08-16).
    private nonisolated static let bandSubWindowSeconds: Double = 60

    /// Task key that changes whenever recompute is warranted. Includes
    /// the recording identity, the entitlement flag, and the lane
    /// config so a purchase completing mid-session or a preset flip
    /// refreshes the lane.
    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
        let preset: VariabilityWindowPreset
        let customWindowSeconds: Double
        let stepSeconds: Double
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio,
                preset: laneContext.windowPreset,
                customWindowSeconds: laneContext.customWindowSeconds,
                stepSeconds: laneContext.stepSeconds
            )) {
                await recompute()
            }
    }

    /// Compute (or clear) the lane samples for the current
    /// (recording, entitlement) state.
    ///
    /// The chain (beat walk → RR series → artifact mask → rolling
    /// computer) runs in `Task.detached` — it measured 2.2 s of blocked
    /// main thread on a 25-hour nsrdb record (100k beats), against an
    /// original design assumption of "thousands of beats". Inputs are
    /// gathered on the main actor before detaching; only the publish
    /// hops back.
    private func recompute() async {
        guard store.hasStudio,
              let recording = recordingContext.recording,
              let sampleRate = recording.channels.first?.sampleRate else {
            laneContext.clear()
            return
        }
        // `defer` so every early return still reports.
        var measuredBeatCount = 0
        let signpost = ComputeSignpost.begin("VariabilityLane")
        defer { ComputeSignpost.end(signpost, workSize: measuredBeatCount) }
        let windowSeconds = laneContext.effectiveWindowSeconds
        let stepSeconds = laneContext.stepSeconds
        let computed = await Task.detached(priority: .userInitiated) {
            Self.computeLaneSamples(
                recording: recording,
                sampleRate: sampleRate,
                windowSeconds: windowSeconds,
                stepSeconds: stepSeconds
            )
        }.value
        measuredBeatCount = computed.beatCount

        // A recording swap cancels this .task but not the detached compute —
        // never publish a stale record's lane over the new one's (the
        // Morphology precedent).
        guard !Task.isCancelled else { return }

        let laneSamples = computed.samples
        if laneSamples.isEmpty {
            laneContext.clear()
        } else {
            laneContext.set(
                samples: laneSamples,
                metricLabel: Self.metricLabel,
                unit: Self.metricUnit,
                windowCaption: makeCaption(
                    windowSeconds: windowSeconds,
                    stepSeconds: stepSeconds,
                    hasBands: laneSamples.contains { $0.band != nil }
                )
            )
        }
    }

    /// The full chain, pure over its inputs: beat walk → RR series →
    /// artifact mask → rolling computer → lane-sample mapping.
    /// `nonisolated static` so the detached task can run it without touching
    /// the View's main-actor-inferred members (the Swift 6 isolation warning
    /// RollingLFHF already carries).
    private nonisolated static func computeLaneSamples(
        recording: Recording,
        sampleRate: Double,
        windowSeconds: Double,
        stepSeconds: Double
    ) -> (beatCount: Int, samples: [VariabilityLaneSample]) {
        let beats = recording.normalBeatSampleIndices()
        guard let series = ECGMetricsExtractor.rrSeries(
            fromBeatSampleIndices: beats,
            sampleRate: sampleRate
        ) else {
            return (beatCount: beats.count, samples: [])
        }
        // Per-RR artifact detection is the "quality floor" from the
        // variability-lane spec — a single bad RR can spike RMSSD by
        // 50 ms or more, and the spec explicitly forbids silently
        // plotting such windows. Compute the mask once per recording;
        // rolling windows aggregate the flags.
        let artifactMask = RRArtifactFilter.mask(
            for: series.intervalsMs,
            rules: RRArtifactFilter.defaultRules
        )
        let rolling = RollingMetricComputer.compute(
            metric: metric,
            series: series,
            windowSeconds: windowSeconds,
            stepSeconds: stepSeconds,
            minimumBeatCount: minimumBeatCount,
            artifactMask: artifactMask,
            maxArtifactFraction: maxArtifactFraction,
            // 13a ribbon (#261): percentiles of 1-min sub-window RMSSD
            // inside each window. The computer opts itself out when the
            // sub-window isn't strictly narrower than the window, which
            // is exactly the 1-min preset's case — no gating needed here.
            bandSubWindowSeconds: bandSubWindowSeconds
        )
        let samples: [VariabilityLaneSample] = rolling.map { s in
            VariabilityLaneSample(
                windowStartSeconds: s.windowStartSeconds,
                windowEndSeconds: s.windowEndSeconds,
                value: s.value,
                isEligible: s.meetsMinimum,
                band: s.band.map {
                    VariabilityLaneBand(p5: $0.p5, p25: $0.p25, p75: $0.p75, p95: $0.p95)
                }
            )
        }
        return (beatCount: beats.count, samples: samples)
    }

    /// Human-readable caption for the current window/step config —
    /// echoed into the lane header. Also the string "Copy citation"
    /// emits for the lane's active config per the citation-strategy
    /// memory.
    private func makeCaption(windowSeconds: Double, stepSeconds: Double, hasBands: Bool) -> String {
        let windowText: String = {
            if windowSeconds >= 60 && windowSeconds.truncatingRemainder(dividingBy: 60) == 0 {
                return "\(Int(windowSeconds / 60))-min window"
            }
            return String(format: "%.0f-s window", windowSeconds)
        }()
        let stepText: String = {
            if stepSeconds >= 60 && stepSeconds.truncatingRemainder(dividingBy: 60) == 0 {
                return "\(Int(stepSeconds / 60)) min step"
            }
            return String(format: "%.0f s step", stepSeconds)
        }()
        // The band is provenance-labelled where it renders (#261): the
        // ribbon summarizes 1-min sub-window RMSSD, and a band whose
        // population isn't stated invites reading it as a confidence
        // interval, which it is not. DATA-driven, not config-driven —
        // the caption may only advertise a band some sample actually
        // carries, which also makes the caption the end-to-end UI
        // assertion surface for the whole compute → map → render chain.
        let bandText: String? = hasBands ? "1-min band" : nil
        return ([windowText, stepText, bandText].compactMap { $0 }).joined(separator: " · ")
    }
}
