//
//  MorphologyOrchestrator.swift
//  Murmur
//
//  X112 (#188, cardiologist review §2.2 option c) — computes the unlabelled
//  morphology clusters for the Context drawer's Morphology section and
//  publishes finished cards to `MorphologyContext`. Same invisible-view
//  orchestrator shape as `ArrhythmiaScanOrchestrator`.
//
//  Population: ALL annotator-coded beats (`Recording.annotatedBeats`), not
//  only "N" — the second conduction is exactly the population the annotator
//  coded away. Lead: the QT display lead (first conventional lead, II before
//  V5; first-channel fallback), matching what the analyst sees in the beat
//  inspector. Per-cluster QRS widths come from the same frozen delineator
//  the markings pipeline uses — no new measurement algorithm.
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct MorphologyOrchestrator: View {
    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var morphologyContext = MorphologyContext.shared
    @State private var store = PurchaseStore.shared

    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(recordingID: recordingContext.recording?.id,
                          owned: store.hasStudio)) {
                await recompute()
            }
    }

    private func recompute() async {
        guard store.hasStudio,
              let recording = recordingContext.recording,
              let directory = recordingContext.directory,
              let ecgChannel = recording.primaryECGChannel
        else {
            await MainActor.run { morphologyContext.clear() }
            return
        }
        var measuredBeatCount = 0
        let signpost = ComputeSignpost.begin("Morphology")
        defer { ComputeSignpost.end(signpost, workSize: measuredBeatCount) }

        // Bundle cache: the summary is a pure function of the record's beats
        // and samples — no analyst dials feed it (endorsements act downstream,
        // in the markings pipeline), so the parameters key is empty and the
        // app-version stamp carries all invalidation.
        if let hit = await Task.detached(priority: .userInitiated, operation: {
            BundleDerivedCache.load(
                MorphologyCachePayload.self, producer: "morphology",
                parametersKey: "", from: directory)
        }).value {
            measuredBeatCount = hit.beatCount
            guard !Task.isCancelled else { return }
            await MainActor.run { morphologyContext.set(summary: hit.summary) }
            return
        }

        let beats = recording.annotatedBeats()
        measuredBeatCount = beats.count
        // Same lead-selection order as the markings pipeline: conventional
        // QT lead when present, first channel otherwise.
        let conventional = recording.conventionalQTLeads(inDirectory: directory)
        let lead = conventional.first
        guard let samples = lead?.samples ?? recording.primaryECGSamples(inDirectory: directory),
              !beats.isEmpty
        else {
            await MainActor.run { morphologyContext.clear() }
            return
        }
        let leadName = lead?.channel.name ?? ecgChannel.name
        let sampleRate = ecgChannel.sampleRate
        let recordName = recording.sourceFileName

        let summary = await Task.detached(priority: .userInitiated) {
            Self.summarize(
                samples: samples, sampleRate: sampleRate, beats: beats,
                recordName: recordName, leadName: leadName)
        }.value

        // A recording swap cancels this .task but not the detached compute —
        // never publish a stale record's clusters over the new one's.
        guard !Task.isCancelled else { return }

        let cachePayload = MorphologyCachePayload(summary: summary, beatCount: beats.count)
        Task.detached(priority: .utility) {
            BundleDerivedCache.store(
                cachePayload, producer: "morphology", parametersKey: "", in: directory)
        }
        await MainActor.run { morphologyContext.set(summary: summary) }
    }

    /// Pure compute: cluster, measure, fold, format. `nonisolated` — it runs
    /// on the detached task, touching no actor state.
    nonisolated static func summarize(
        samples: [Float], sampleRate: Double,
        beats: [(sampleIndex: Int64, symbol: String)],
        recordName: String, leadName: String
    ) -> MorphologySummary {
        let parameters = MorphologyClustering.Parameters()
        let rPeaks = beats.map(\.sampleIndex)
        let clustering = MorphologyClustering.summarize(
            samples: samples, sampleRate: sampleRate, rPeaks: rPeaks,
            parameters: parameters)

        // Per-beat QRS widths from the frozen delineator — one pass over all
        // beats, joined to clusters by beat index.
        let (delineated, _) = WaveletBeatDelineator.delineateWithFeatures(
            samples: samples, sampleRate: sampleRate, rPeaks: rPeaks)
        let qrsByBeat = IntervalMeasurement.measureAll(store: delineated).map(\.qrsMs)

        // §3: small clusters (<1% AND <30 beats) fold into the remainder
        // rather than inviting endorsement of noise.
        let total = clustering.totalBeats
        let isSmall: (MorphologyClustering.Cluster) -> Bool = { cluster in
            cluster.count < 30 && Double(cluster.count) < 0.01 * Double(total)
        }
        let major = clustering.clusters.filter { !isSmall($0) }
        let folded = clustering.clusters.filter(isSmall)

        let cards = major.enumerated().map { rank, cluster -> MorphologyClusterCard in
            var codeCounts: [String: Int] = [:]
            for index in cluster.memberBeatIndices {
                codeCounts[beats[index].symbol, default: 0] += 1
            }
            let widths = cluster.memberBeatIndices
                .compactMap { $0 < qrsByBeat.count ? qrsByBeat[$0] : nil }
                .sorted()
            let qrs = widths.isEmpty
                ? nil
                : String(format: "median QRS %.0f ms", widths[widths.count / 2])
            // Geometric names only — A, B, C… — never a clinical label (§4.1).
            let letter = String(UnicodeScalar(UInt8(65 + min(rank, 25))))
            return MorphologyClusterCard(
                id: rank,
                title: "Cluster \(letter)",
                burden: MorphologyContext.burdenCaption(count: cluster.count, totalBeats: total),
                qrsWidth: qrs,
                annotatorCodes: MorphologyContext.annotatorCodesCaption(codeCounts: codeCounts),
                representative: cluster.representative)
        }

        let provenance = String(
            format: "%@ · %d beats · lead %@ · window −%.0f…+%.0f ms · distance ≤ %.2f",
            recordName, total, leadName,
            parameters.preSeconds * 1000, parameters.postSeconds * 1000,
            parameters.distanceThreshold)

        return MorphologySummary(
            cards: cards,
            remainderCaption: MorphologyContext.remainderCaption(
                foldedClusterCount: folded.count,
                foldedBeatCount: folded.reduce(0) { $0 + $1.count },
                unassignedCount: clustering.unassignedBeatIndices.count),
            provenance: provenance,
            totalBeats: total,
            matchThreshold: parameters.distanceThreshold)
    }
}


/// What the bundle cache holds for this producer.
private struct MorphologyCachePayload: Codable, Sendable {
    let summary: MorphologySummary
    let beatCount: Int
}
