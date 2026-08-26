//
//  TrendBinsOrchestrator.swift
//  Murmur (app target)
//
//  Invisible glue view that produces the interval-trend bins for the
//  current recording + metric + bin length via `TrendBinComputer`
//  (MurmurMetrics) and publishes them — as finished `IntervalTrendBin`
//  values — to `TrendBinsContext.shared`, where the MurmurCore trend lane
//  renders them. #380 moved the per-bin production (exclusion policy,
//  estimators, K9, qualifier join) behind the paid boundary; this
//  orchestrator is the translation layer and contains NO policy — dumb
//  field copies in (`MarkingsBeat` → `TrendBeatSample`) and out
//  (`TrendBinRow` → `IntervalTrendBin`), same contract as
//  `QualifyingWindowOrchestrator`. MurmurCore never sees MurmurMetrics.
//
//  Entitlement-gated (Murmur Pro): bins are paid compute, so the free
//  viewer publishes nothing and the lane (which also needs paid beats)
//  stays empty.
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct TrendBinsOrchestrator: View {

    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var markingsContext = IntervalMarkingsContext.shared
    @State private var trendLaneContext = IntervalTrendLaneContext.shared
    @State private var qualifyingContext = QualifyingWindowContext.shared
    @State private var store = PurchaseStore.shared

    /// Recompute whenever the recording, entitlement, metric, bin length,
    /// the delineated beat set, or the qualifying facts change. Beats are
    /// fingerprinted by count + ends (the delineator writes them
    /// atomically); qualifiers are small enough to key whole, so their
    /// async arrival re-stamps the bins.
    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
        let metric: IntervalTrendMetric
        let binSeconds: Double
        let beatCount: Int
        let firstBeat: Int64?
        let lastBeat: Int64?
        let qualifiers: [IntervalBinQualifier]
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio,
                metric: trendLaneContext.metric,
                binSeconds: trendLaneContext.binSeconds,
                beatCount: markingsContext.beats.count,
                firstBeat: markingsContext.beats.first?.rPeakSampleIndex,
                lastBeat: markingsContext.beats.last?.rPeakSampleIndex,
                qualifiers: qualifyingContext.qualifiers(forBinSeconds: trendLaneContext.binSeconds)
            )) {
                await recompute()
            }
    }

    private func recompute() async {
        let beats = markingsContext.beats
        let sampleRate = markingsContext.sampleRate
        let metric = trendLaneContext.metric
        let binSeconds = trendLaneContext.binSeconds
        let qualifiers = qualifyingContext.qualifiers(forBinSeconds: binSeconds)
        guard store.hasStudio, sampleRate > 0, binSeconds > 0, !beats.isEmpty else {
            await MainActor.run { TrendBinsContext.shared.clear() }
            return
        }
        let signpost = ComputeSignpost.begin("TrendBins")
        defer { ComputeSignpost.end(signpost, workSize: beats.count) }

        let computed: [IntervalTrendBin] = await Task.detached(priority: .utility) {
            // Field selection is naming, not policy — which value/confidence
            // fields a metric reads. Every rule about what they MEAN lives in
            // TrendBinComputer.
            let kind: TrendMetricKind
            switch metric {
            case .qtc: kind = .qtc
            case .pr:  kind = .pr
            case .qrs: kind = .qrs
            }
            let samples = beats.map { beat in
                TrendBeatSample(
                    timeSeconds: Double(beat.rPeakSampleIndex) / sampleRate,
                    valueMs: {
                        switch metric {
                        case .qtc: return beat.qtcMs
                        case .pr:  return beat.prMs
                        case .qrs: return beat.qrsMs
                        }
                    }(),
                    precedingRRMs: beat.precedingRRMs,
                    isImplausible: beat.isImplausible,
                    isUnreliableTOffset: beat.isUnreliable,
                    tOffsetCensored: beat.tOffsetCensored,
                    tOffsetConfidence: beat.tOffset?.confidence,
                    qrsOnsetConfidence: beat.qrsOnset?.confidence,
                    qrsOffsetConfidence: beat.qrsOffset?.confidence,
                    pOnsetConfidence: beat.pOnset?.confidence
                )
            }
            let facts = qualifiers.map {
                TrendBinQualifierFacts(
                    startSeconds: $0.startSeconds,
                    rateStable: $0.rateStable,
                    rateMaxDeviationBpm: $0.rateMaxDeviationBpm,
                    rateDriftBpm: $0.rateDriftBpm,
                    excludedBeatFraction: $0.excludedBeatFraction
                )
            }
            let rows = TrendBinComputer.computeBins(
                samples: samples,
                metric: kind,
                binSeconds: binSeconds,
                qualifiers: facts
            )
            return rows.map { row in
                IntervalTrendBin(
                    startSeconds: row.startSeconds,
                    endSeconds: row.endSeconds,
                    median: row.median,
                    q1: row.q1,
                    q3: row.q3,
                    bandLowerMs: row.bandLowerMs,
                    bandUpperMs: row.bandUpperMs,
                    hasCensoredBeats: row.hasCensoredBeats,
                    isEligible: row.isEligible,
                    beatCount: row.beatCount,
                    perBeatValues: row.perBeatValues,
                    rrCVPercent: row.rrCVPercent,
                    rateMaxDeviationBpm: row.rateMaxDeviationBpm,
                    rateDriftBpm: row.rateDriftBpm,
                    rateStable: row.rateStable,
                    excludedBeatFraction: row.excludedBeatFraction,
                    qtImplausibleFraction: row.qtImplausibleFraction,
                    qtUnreliableFraction: row.qtUnreliableFraction
                )
            }
        }.value

        await MainActor.run {
            TrendBinsContext.shared.set(bins: computed, metric: metric, binSeconds: binSeconds)
        }
    }
}
