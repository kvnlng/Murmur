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

    private static let minimumBeatCount: Int = 30
    private static let metric: RollingMetric = .rmssd
    private static let metricLabel: String = "RMSSD"
    private static let metricUnit: String = "ms"
    /// A window with more than 20 % artifactual RRs fails the quality
    /// floor and renders dimmed on the lane. Matches the default
    /// documented in `project_variability_lane_design.md`.
    private static let maxArtifactFraction: Double = 0.20

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
                owned: store.owns(.ecgMetrics),
                preset: laneContext.windowPreset,
                customWindowSeconds: laneContext.customWindowSeconds,
                stepSeconds: laneContext.stepSeconds
            )) {
                recompute()
            }
    }

    /// Compute (or clear) the lane samples for the current
    /// (recording, entitlement) state. Runs on the main actor —
    /// series are small even for multi-hour recordings (thousands of
    /// beats), and the rolling computer is O(N).
    @MainActor
    private func recompute() {
        guard store.owns(.ecgMetrics),
              let recording = recordingContext.recording,
              let sampleRate = recording.channels.first?.sampleRate else {
            laneContext.clear()
            return
        }
        let beats = recording.normalBeatSampleIndices()
        guard let series = ECGMetricsExtractor.rrSeries(
            fromBeatSampleIndices: beats,
            sampleRate: sampleRate
        ) else {
            laneContext.clear()
            return
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
        let windowSeconds = laneContext.effectiveWindowSeconds
        let stepSeconds = laneContext.stepSeconds
        let rolling = RollingMetricComputer.compute(
            metric: Self.metric,
            series: series,
            windowSeconds: windowSeconds,
            stepSeconds: stepSeconds,
            minimumBeatCount: Self.minimumBeatCount,
            artifactMask: artifactMask,
            maxArtifactFraction: Self.maxArtifactFraction
        )
        let laneSamples: [VariabilityLaneSample] = rolling.map { s in
            VariabilityLaneSample(
                windowStartSeconds: s.windowStartSeconds,
                windowEndSeconds: s.windowEndSeconds,
                value: s.value,
                isEligible: s.meetsMinimum
            )
        }
        if laneSamples.isEmpty {
            laneContext.clear()
        } else {
            laneContext.set(
                samples: laneSamples,
                metricLabel: Self.metricLabel,
                unit: Self.metricUnit,
                windowCaption: makeCaption(windowSeconds: windowSeconds, stepSeconds: stepSeconds)
            )
        }
    }

    /// Human-readable caption for the current window/step config —
    /// echoed into the lane header. Also the string "Copy citation"
    /// emits for the lane's active config per the citation-strategy
    /// memory.
    private func makeCaption(windowSeconds: Double, stepSeconds: Double) -> String {
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
        return "\(windowText) · \(stepText)"
    }
}
