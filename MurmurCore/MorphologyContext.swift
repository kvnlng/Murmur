//
//  MorphologyContext.swift
//  MurmurCore
//
//  X112 (#188, cardiologist review §2.2 option c) — transport for the
//  Morphology drawer section. The App target's orchestrator computes the
//  clusters with MurmurMetrics and hands finished cards here; MurmurCore
//  lays them out and records the analyst's endorsements. Same
//  App-writes / MurmurCore-reads pattern as `VariabilityMetricsContext`.
//
//  The governing rule, verbatim from the review: "the algorithm clusters,
//  but the human classifies." Nothing in this file (or anywhere else)
//  auto-promotes a cluster — a baseline exists only because a qualified
//  analyst deliberately endorsed it, and endorsements are session work
//  product persisted in the .mur like anchored notes.
//
//  Cluster identity across sessions is the region-disposition problem in
//  morphology space (VTVFCandidateDisposition rationale): clusters are
//  recomputed deterministically on load, so an endorsement stores the
//  cluster's REPRESENTATIVE WAVEFORM and re-attaches to the recomputed
//  cluster by nearest-representative match. A representative that no longer
//  matches any cluster surfaces as an orphan instead of silently dropping.
//

import Foundation
import Observation

/// One cluster, ready to render. Strings are pre-formatted by the
/// orchestrator (the paid side owns digits); the representative waveform
/// rides along for the thumbnail and for endorsement identity.
public struct MorphologyClusterCard: Sendable, Equatable, Identifiable {
    /// Positional rank (0 = largest cluster). Positional, not UUID —
    /// XCUI predicate cost, see ContextDrawer's note-row rationale.
    public let id: Int
    /// Geometric name only — "Cluster A". Never a clinical label (§4.1).
    public let title: String
    /// "312 beats · 12% of beats"
    public let burden: String
    /// "median QRS 142 ms" — nil when no member beat carried a QRS width.
    public let qrsWidth: String?
    /// Verbatim provenance: "annotator codes: N 96% · R 4%". nil when the
    /// record carries no annotator symbols.
    public let annotatorCodes: String?
    /// Normalized median complex (zero-mean, unit-L2). Thumbnail geometry
    /// AND the endorsement's re-attachment identity.
    public let representative: [Float]

    public init(
        id: Int, title: String, burden: String,
        qrsWidth: String?, annotatorCodes: String?, representative: [Float]
    ) {
        self.id = id
        self.title = title
        self.burden = burden
        self.qrsWidth = qrsWidth
        self.annotatorCodes = annotatorCodes
        self.representative = representative
    }
}

/// The whole-record morphology summary, ready to render.
public struct MorphologySummary: Sendable, Equatable {
    /// Descending by member count — card 0 is the majority shape.
    public let cards: [MorphologyClusterCard]
    /// "remainder: 23 beats in 4 small clusters · 6 windows unusable" —
    /// the folded small clusters and unusable windows, counted rather than
    /// hidden. nil when nothing folded.
    public let remainderCaption: String?
    /// What was clustered — record, beat population, window, threshold.
    public let provenance: String
    public let totalBeats: Int
    /// The distance bound endorsement re-attachment uses — the same d₀ the
    /// clustering ran with, published so Core never hardcodes a paid-side
    /// constant.
    public let matchThreshold: Double

    public init(
        cards: [MorphologyClusterCard], remainderCaption: String?,
        provenance: String, totalBeats: Int, matchThreshold: Double
    ) {
        self.cards = cards
        self.remainderCaption = remainderCaption
        self.provenance = provenance
        self.totalBeats = totalBeats
        self.matchThreshold = matchThreshold
    }
}

/// An analyst's endorsement of one morphology cluster as a patient
/// baseline. Session work product — persisted in `MurSessionState`.
public struct MorphologyEndorsement: Codable, Equatable, Hashable, Sendable {
    /// The endorsed cluster's representative at endorsement time.
    public var representative: [Float]
    /// When the analyst endorsed it — provenance for the caption
    /// ("analyst-endorsed · 2026-08-11", X112c).
    public var endorsedAt: Date

    public init(representative: [Float], endorsedAt: Date) {
        self.representative = representative
        self.endorsedAt = endorsedAt
    }
}

/// Process-wide morphology state. `@MainActor` because the only reader is
/// the bedside view hierarchy.
@MainActor
@Observable
public final class MorphologyContext {

    public static let shared = MorphologyContext()

    /// The computed summary, or nil when there is nothing to render —
    /// no entitlement, no recording, or no annotated beats.
    public private(set) var summary: MorphologySummary?

    /// X112c — mirror of the bedside view's endorsements, republished here
    /// so the App target's markings orchestrator (which cannot reach view
    /// `@State`) can rebuild the baseline from the endorsed clusters. The
    /// view remains the owner (session save/restore); this is transport,
    /// same as `CurrentRecordingContext.liveSessionState`.
    public private(set) var endorsements: [MorphologyEndorsement] = []

    public init() {}

    public func set(summary: MorphologySummary?) {
        self.summary = summary
    }

    public func setEndorsements(_ endorsements: [MorphologyEndorsement]) {
        guard endorsements != self.endorsements else { return }
        self.endorsements = endorsements
    }

    public func clear() {
        self.summary = nil
        self.endorsements = []
    }

    // MARK: - Endorsement re-attachment

    /// Correlation distance between two normalized windows (1 − dot; both
    /// are zero-mean unit-L2, so the dot IS Pearson r). Bookkeeping join
    /// for endorsement identity — the clinical distance lives with the
    /// clustering on the paid side; this mirrors its arithmetic so a saved
    /// endorsement can find its cluster without MurmurCore linking
    /// MurmurMetrics. `infinity` for mismatched lengths (a parameters
    /// change), which correctly reads as "no match" → orphan.
    nonisolated static func representativeDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return Double(1 - dot)
    }

    /// The card an endorsement re-attaches to: nearest representative
    /// within the summary's match threshold. nil = orphan — the record's
    /// clusters no longer contain the endorsed shape, and the panel
    /// surfaces that instead of silently dropping the endorsement.
    nonisolated public static func attachedCardIndex(
        of endorsement: MorphologyEndorsement,
        in summary: MorphologySummary
    ) -> Int? {
        var best: (index: Int, distance: Double)?
        for card in summary.cards {
            let d = representativeDistance(endorsement.representative, card.representative)
            if best == nil || d < best!.distance {
                best = (card.id, d)
            }
        }
        guard let best, best.distance <= summary.matchThreshold else { return nil }
        return best.index
    }

    // MARK: - Card-string builders

    /// "312 beats · 12% of beats". Sub-percent burdens say "<1%" rather
    /// than rounding a real minority shape down to a false zero.
    nonisolated public static func burdenCaption(count: Int, totalBeats: Int) -> String {
        let beats = "\(count) beat\(count == 1 ? "" : "s")"
        guard totalBeats > 0 else { return beats }
        let percent = Double(count) / Double(totalBeats) * 100
        let share = percent < 1 ? "<1%" : String(format: "%.0f%%", percent)
        return "\(beats) · \(share) of beats"
    }

    /// "annotator codes: N 96% · R 4%" — shares of the cluster's members,
    /// descending, whole percents (sub-percent shown as "<1%"). Verbatim
    /// provenance for the adjudicating analyst: the annotator layer is what
    /// today's template already rests on. nil when no symbols exist.
    nonisolated public static func annotatorCodesCaption(codeCounts: [String: Int]) -> String? {
        let total = codeCounts.values.reduce(0, +)
        guard total > 0 else { return nil }
        let parts = codeCounts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { code, count -> String in
                let percent = Double(count) / Double(total) * 100
                let share = percent < 1 ? "<1%" : String(format: "%.0f%%", percent)
                return "\(code) \(share)"
            }
        return "annotator codes: " + parts.joined(separator: " · ")
    }

    /// "remainder: 23 beats in 4 small clusters · 6 windows unusable".
    /// nil when nothing was folded and nothing was unusable.
    nonisolated public static func remainderCaption(
        foldedClusterCount: Int, foldedBeatCount: Int, unassignedCount: Int
    ) -> String? {
        var parts: [String] = []
        if foldedBeatCount > 0 {
            parts.append("\(foldedBeatCount) beat\(foldedBeatCount == 1 ? "" : "s") in "
                + "\(foldedClusterCount) small cluster\(foldedClusterCount == 1 ? "" : "s")")
        }
        if unassignedCount > 0 {
            parts.append("\(unassignedCount) window\(unassignedCount == 1 ? "" : "s") unusable")
        }
        guard !parts.isEmpty else { return nil }
        return "remainder: " + parts.joined(separator: " · ")
    }
}
