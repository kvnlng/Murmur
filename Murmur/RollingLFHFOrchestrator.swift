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
//  is simply never computed without the entitlement. The SPECTRUM itself
//  stays `FrequencyDomainHRVAnalyzer`'s; this file owns only the windowing,
//  which is the same slicing the QTVI summary already does in
//  `VariabilityMetricsOrchestrator`.
//
//  A window the analyzer declines — too few clean beats, zero variance,
//  under 20 s of span — is simply absent from the series. The lane draws a
//  gap there; bridging it would draw a ratio where the method said there
//  isn't one.
//
//  Unlike the RMSSD lane this computes OFF the main actor: a 72 h record at
//  a 1-minute step is ~4,300 Lomb–Scargle windows, three orders of magnitude
//  more arithmetic than the O(N) rolling time-domain pass.
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
        let beats = recording.normalBeatSampleIndices()
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
            lfhfContext.set(
                samples: samples,
                caption: RollingLFHFContext.provenanceCaption
            )
        }
    }

    /// Slice the RR series into rolling windows (`RollingWindows.place`, the
    /// unit-tested slicer in MurmurCore) and run the frequency-domain
    /// analyzer on each. A window yields a sample only when the analyzer
    /// returns an LF/HF ratio — the analyzer owns every validity rule (min
    /// beats, min span, zero variance, artifact exclusion), and duplicating
    /// any of them here is how two copies diverge.
    nonisolated static func computeSeries(
        rr: RRSeries,
        windowSeconds: Double,
        stepSeconds: Double
    ) async -> [VariabilityLaneSample] {
        let windows = RollingWindows.place(
            timesSeconds: rr.endTimesSeconds,
            windowSeconds: windowSeconds,
            stepSeconds: stepSeconds
        )
        var out: [VariabilityLaneSample] = []
        out.reserveCapacity(windows.count)
        for window in windows {
            if Task.isCancelled { return [] }
            let slice = RRSeries(
                intervalsMs: Array(rr.intervalsMs[window.indices]),
                endTimesSeconds: Array(rr.endTimesSeconds[window.indices])
            )
            if let fd = FrequencyDomainHRVAnalyzer.analyze(rr: slice),
               let ratio = fd.lfhfRatio {
                out.append(VariabilityLaneSample(
                    windowStartSeconds: window.startSeconds,
                    windowEndSeconds: window.endSeconds,
                    value: ratio,
                    isEligible: true
                ))
            }
        }
        return out
    }
}
