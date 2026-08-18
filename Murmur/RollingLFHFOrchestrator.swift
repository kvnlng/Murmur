//
//  RollingLFHFOrchestrator.swift
//  Murmur (app target)
//
//  Rolling LF/HF for the trend stack's LF/HF lane (X76).
//
//  Today's whole-record LF/HF is one Lomb–Scargle window; this computes the
//  same measurement per rolling 5-minute window at a 1-minute step and
//  publishes the series to `RollingLFHFContext` for the stack to render.
//
//  Same pattern and boundary as `VariabilityLaneOrchestrator`: the App target
//  is the only place MurmurCore and MurmurMetrics meet, so it owns the
//  entitlement gate — the free viewer never sees the lane because the series
//  is simply never computed without the entitlement.
//
//  The windowing moved into MurmurMetrics with #262
//  (`RollingLFHFSeriesComputer`, Murmur-Extensions v0.27.0): this file's
//  window loop was App-target code MurmurTests cannot link, so it was only
//  ever covered by a parallel reconstruction — and both paid rolling lanes
//  now share one set of placement rules. What remains here is extraction,
//  the entitlement gate, and the sample/caption mapping.
//
//  A window the analyzer declines — too few clean beats, zero variance,
//  under 20 s of span — is simply absent from the series. The lane draws a
//  gap there; bridging it would draw a ratio where the method said there
//  isn't one.
//
//  Unlike the RMSSD lane this computes OFF the main actor: a 72 h record at
//  a 1-minute step is ~4,300 Lomb–Scargle windows, three orders of magnitude
//  more arithmetic than the O(N) rolling time-domain pass — more still with
//  the ~13 sub-window re-estimates each band adds.
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct RollingLFHFOrchestrator: View {

    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var lfhfContext = RollingLFHFContext.shared
    @State private var store = PurchaseStore.shared

    /// 5-minute windows, per the design ("rolling 5 min"), which is also the
    /// Task Force's short-term analysis length.
    static let windowSeconds: Double = 300
    static let stepSeconds: Double = 60
    /// 13a ribbon sub-window width (#262). 2 min, not the RMSSD band's
    /// 1 min: the LF floor is 0.04 Hz, and a sub-window much under two
    /// minutes holds too few LF cycles for the re-estimate to mean
    /// anything — the same Task Force reasoning that puts the parent
    /// window at five.
    static let bandSubWindowSeconds: Double = 120

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
                await recompute()
            }
    }

    @MainActor
    private func recompute() async {
        #if DEBUG
        // X76 wire-up test: the injected series must not be clobbered by the
        // real compute (the X52 §5 pattern — IntervalMarkingsOrchestrator
        // does the same for the QTc injection). Read from ProcessInfo, like
        // that orchestrator: `UITestSupport` is internal to MurmurCore.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-inject-lfhf-lane") { return }
        #endif
        guard store.hasStudio,
              let recording = recordingContext.recording,
              let sampleRate = recording.channels.first?.sampleRate else {
            lfhfContext.clear()
            return
        }
        var measuredBeatCount = 0
        let signpost = ComputeSignpost.begin("RollingLFHF")
        defer { ComputeSignpost.end(signpost, workSize: measuredBeatCount) }
        let beats = recording.normalBeatSampleIndices()
        measuredBeatCount = beats.count
        guard let series = ECGMetricsExtractor.rrSeries(
            fromBeatSampleIndices: beats,
            sampleRate: sampleRate
        ) else {
            lfhfContext.clear()
            return
        }
        // Off the main actor — see the header. Cancellation is checked per
        // window, so switching records mid-compute abandons promptly.
        let samples = await Self.computeSeries(
            rr: series,
            windowSeconds: Self.windowSeconds,
            stepSeconds: Self.stepSeconds
        )
        if Task.isCancelled { return }
        if samples.isEmpty {
            lfhfContext.clear()
        } else {
            // The band is provenance-labelled where it renders (#262,
            // same rule as the RMSSD caption): DATA-driven, advertised
            // only when some computed sample actually carries one — a
            // band whose population isn't stated invites reading it as
            // a confidence interval, which it is not. Short records
            // legitimately band nothing (a 5-min window over 3 min of
            // data fits 5 of the 8 required sub-estimates) and their
            // caption says nothing.
            let hasBands = samples.contains { $0.band != nil }
            lfhfContext.set(
                samples: samples,
                caption: hasBands
                    ? RollingLFHFContext.provenanceCaption + " · 2-min band"
                    : RollingLFHFContext.provenanceCaption
            )
        }
    }

    /// Run the tested composition (`RollingLFHFSeriesComputer`, v0.27.0)
    /// and map its samples onto the lane's wire type. The analyzer owns
    /// every validity rule and the computer owns the windowing; this
    /// mapping is deliberately the only code left on this side.
    nonisolated static func computeSeries(
        rr: RRSeries,
        windowSeconds: Double,
        stepSeconds: Double
    ) async -> [VariabilityLaneSample] {
        let rolling = RollingLFHFSeriesComputer.compute(
            series: rr,
            windowSeconds: windowSeconds,
            stepSeconds: stepSeconds,
            bandSubWindowSeconds: Self.bandSubWindowSeconds,
            shouldContinue: { !Task.isCancelled }
        )
        return rolling.map { s in
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
    }
}
