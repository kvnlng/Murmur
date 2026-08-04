//
//  QualifyingWindowOrchestrator.swift
//  Murmur (app target)
//
//  Invisible glue view that computes the per-bin qualifying-window facts (X42)
//  for the current recording + bin length and publishes them — as PRIMITIVE
//  `IntervalBinQualifier` values — to `QualifyingWindowContext.shared`, where
//  the MurmurCore trend lane joins them onto its bins (lighting up the X43
//  rate-stability marker + the X46 qualifying gate). Same pattern as
//  `IntervalMarkingsOrchestrator`; MurmurCore never sees MurmurMetrics.
//
//  Entitlement-gated (ECG Metrics): the qualifying facts are paid compute, so
//  the free viewer publishes nothing and every eligible bin reads as qualifying
//  by default.
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct QualifyingWindowOrchestrator: View {

    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var markingsContext = IntervalMarkingsContext.shared
    @State private var trendLaneContext = IntervalTrendLaneContext.shared
    @State private var store = PurchaseStore.shared

    /// Recompute whenever the recording, entitlement, bin length, or the
    /// delineated beat set changes. Beats are fingerprinted by count + ends so
    /// completion of delineation (which populates them) triggers a recompute.
    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
        let binSeconds: Double
        let beatCount: Int
        let firstBeat: Int64?
        let lastBeat: Int64?
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio,
                binSeconds: trendLaneContext.binSeconds,
                beatCount: markingsContext.beats.count,
                firstBeat: markingsContext.beats.first?.rPeakSampleIndex,
                lastBeat: markingsContext.beats.last?.rPeakSampleIndex
            )) {
                await recompute()
            }
    }

    private func recompute() async {
        let beats = markingsContext.beats
        let sampleRate = markingsContext.sampleRate
        let binSeconds = trendLaneContext.binSeconds
        guard store.hasStudio, sampleRate > 0, binSeconds > 0, beats.count > 1 else {
            await MainActor.run { QualifyingWindowContext.shared.clear() }
            return
        }
        let tolerance = QualifyingWindowComputer.defaultStabilityToleranceBpm

        // RR series straight off the delineated beats — the same series the
        // QTc trend is built from, so the qualifiers align with the bins.
        let computed: [IntervalBinQualifier] = await Task.detached(priority: .utility) {
            var intervalsMs: [Double] = []
            var endTimesSeconds: [Double] = []
            for beat in beats {
                guard let rr = beat.precedingRRMs, rr.isFinite, rr > 0 else { continue }
                intervalsMs.append(rr)
                endTimesSeconds.append(Double(beat.rPeakSampleIndex) / sampleRate)
            }
            guard !intervalsMs.isEmpty else { return [] }
            let rr = RRSeries(intervalsMs: intervalsMs, endTimesSeconds: endTimesSeconds)

            // Same bin grid the lane uses: k·binSeconds from the first beat.
            let firstSec = Double(beats.first!.rPeakSampleIndex) / sampleRate
            let lastSec  = Double(beats.last!.rPeakSampleIndex)  / sampleRate
            var binStart = floor(firstSec / binSeconds) * binSeconds
            let lastBinStart = floor(lastSec / binSeconds) * binSeconds

            var out: [IntervalBinQualifier] = []
            while binStart <= lastBinStart {
                let q = QualifyingWindowComputer.qualify(
                    binStartSeconds: binStart,
                    binEndSeconds: binStart + binSeconds,
                    rr: rr,
                    toleranceBpm: tolerance
                )
                out.append(IntervalBinQualifier(
                    startSeconds: binStart,
                    rateStable: q.rateStable,
                    rateMaxDeviationBpm: q.rateMaxDeviationBpm,
                    rateDriftBpm: q.rateDriftBpm,
                    excludedBeatFraction: q.excludedBeatFraction
                ))
                binStart += binSeconds
            }
            return out
        }.value

        await MainActor.run {
            QualifyingWindowContext.shared.set(
                qualifiers: computed,
                binSeconds: binSeconds,
                toleranceBpm: tolerance
            )
        }
    }
}
