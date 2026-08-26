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
//  coded away. Lead: the analysis lead (#357), full stop — calculations run
//  on the designated lead, no per-feature name gate. Per-cluster QRS widths
//  come from the same frozen delineator the markings pipeline uses — no new
//  measurement algorithm.
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
        /// #357: a designation re-clusters on the newly designated lead —
        /// the cache key carries the lead's name, so this recomputes.
        let analysisLeadRevision: Int
    }

    /// #381: the attachment verdicts belong to one (summary, endorsements)
    /// pair. The summary is fingerprinted by its provenance line (record ·
    /// beats · lead · window · threshold — clustering is deterministic, so
    /// same provenance ⇒ same cards) rather than hashing every
    /// representative.
    private struct AttachKey: Hashable {
        let provenance: String?
        let cardCount: Int
        let matchThreshold: Double?
        let endorsements: [MorphologyEndorsement]
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(recordingID: recordingContext.recording?.id,
                          owned: store.hasStudio,
                          analysisLeadRevision: recordingContext.analysisLeadRevision)) {
                await recompute()
            }
            .task(id: AttachKey(provenance: morphologyContext.summary?.provenance,
                                cardCount: morphologyContext.summary?.cards.count ?? 0,
                                matchThreshold: morphologyContext.summary?.matchThreshold,
                                endorsements: morphologyContext.endorsements)) {
                resolveAttachments()
            }
    }

    /// #381: resolve each endorsement's card through the PAID verdict
    /// (`MorphologyClustering.nearestRepresentativeIndex`) and publish —
    /// MurmurCore renders verdicts, never computes them. Cheap (a few
    /// endorsements × a few cards), so it runs inline on the task.
    private func resolveAttachments() {
        guard let summary = morphologyContext.summary else { return }
        let candidates = summary.cards.map(\.representative)
        var verdicts: [MorphologyEndorsement: Int?] = [:]
        for endorsement in morphologyContext.endorsements {
            let position = MorphologyClustering.nearestRepresentativeIndex(
                of: endorsement.representative,
                among: candidates,
                threshold: summary.matchThreshold
            )
            // updateValue, not subscript assignment: the value type is Int?
            // and a subscript-assigned nil DELETES the key — an orphan must
            // be recorded as .some(nil), not silently dropped.
            verdicts.updateValue(position.map { summary.cards[$0].id }, forKey: endorsement)
        }
        morphologyContext.setAttachments(verdicts)
    }

    private func recompute() async {
        guard store.hasStudio,
              let recording = recordingContext.recording,
              let directory = recordingContext.directory,
              let resolution = recording.analysisLead(inBundle: directory)
        else {
            await MainActor.run { morphologyContext.clear() }
            return
        }
        var measuredBeatCount = 0
        let signpost = ComputeSignpost.begin("Morphology")
        defer { ComputeSignpost.end(signpost, workSize: measuredBeatCount) }

        // #357: calculations run on the designated lead, full stop — no
        // name-gated preference (was: conventional QT lead first, II before
        // V5). One source, no name consultation.
        let leadName = resolution.channel.name

        // Bundle cache: the summary is a pure function of the record's beats
        // and samples — no analyst dial feeds it (endorsements act downstream,
        // in the markings pipeline) — but the resolved lead can change (a
        // new analysis-lead designation), so the key carries that lead's
        // name; the app-version stamp carries the rest of invalidation.
        let parametersKey = MorphologyCacheKey.make(analysisLeadName: leadName)
        if let hit = await Task.detached(priority: .userInitiated, operation: {
            BundleDerivedCache.load(
                MorphologyCachePayload.self, producer: "morphology",
                parametersKey: parametersKey, from: directory)
        }).value {
            measuredBeatCount = hit.beatCount
            guard !Task.isCancelled else { return }
            await MainActor.run { morphologyContext.set(summary: hit.summary) }
            return
        }

        // Cache missed — the compute ahead takes real seconds on a long
        // record. Name that cost while it is paid (task #11, X91's
        // "scanning…" reasoning): the drawer shows a "computing…" row
        // instead of nothing. Every exit below publishes or clears, which
        // resets the flag.
        await MainActor.run { morphologyContext.beginCompute() }

        let beats = recording.annotatedBeats()
        measuredBeatCount = beats.count
        guard let samples = recording.samples(of: resolution.channel, inDirectory: directory),
              !beats.isEmpty
        else {
            await MainActor.run { morphologyContext.clear() }
            return
        }
        let sampleRate = resolution.channel.sampleRate
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
                cachePayload, producer: "morphology", parametersKey: parametersKey, in: directory)
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

        // §3 fold rule — single-source on the paid side since #382
        // (`MorphologyClustering.isFolded`), consumed here and by the
        // endorsed-mode rebuild so the two can never drift.
        let total = clustering.totalBeats
        let major = clustering.majorClusters
        let folded = clustering.foldedClusters

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
            // Geometric names only — A, B, C… — never a clinical label
            // (§4.1). #382: one letter mapping, owned by the clustering.
            let letter = MorphologyClustering.letter(forRank: rank)
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
