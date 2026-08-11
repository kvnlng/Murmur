//
//  MorphologyContextTests.swift
//  MurmurTests
//
//  X112 (#188) — the free-side half of the morphology panel: endorsement
//  re-attachment by representative match, the card-string builders, and
//  the .mur persistence contract for endorsements.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Morphology endorsement re-attachment (X112)")
struct MorphologyAttachmentTests {

    private func card(_ id: Int, representative: [Float]) -> MorphologyClusterCard {
        MorphologyClusterCard(id: id, title: "Cluster \(id)", burden: "",
                              qrsWidth: nil, annotatorCodes: nil,
                              representative: representative)
    }

    /// Unit-norm zero-mean two-point windows make hand-checkable distances.
    private let up: [Float] = [0.7071068, -0.7071068]
    private let down: [Float] = [-0.7071068, 0.7071068]

    @Test("An endorsement re-attaches to the nearest cluster within threshold")
    func attachesNearest() {
        let summary = MorphologySummary(
            cards: [card(0, representative: up), card(1, representative: down)],
            remainderCaption: nil, provenance: "", totalBeats: 10,
            matchThreshold: 0.30)
        let endorsement = MorphologyEndorsement(representative: up, endorsedAt: .distantPast)
        #expect(MorphologyContext.attachedCardIndex(of: endorsement, in: summary) == 0)
        let other = MorphologyEndorsement(representative: down, endorsedAt: .distantPast)
        #expect(MorphologyContext.attachedCardIndex(of: other, in: summary) == 1)
    }

    @Test("Beyond the threshold the endorsement is an orphan, never force-attached")
    func orphanBeyondThreshold() {
        // The only cluster is the INVERSE shape — distance 2, far past d₀.
        let summary = MorphologySummary(
            cards: [card(0, representative: down)],
            remainderCaption: nil, provenance: "", totalBeats: 10,
            matchThreshold: 0.30)
        let endorsement = MorphologyEndorsement(representative: up, endorsedAt: .distantPast)
        #expect(MorphologyContext.attachedCardIndex(of: endorsement, in: summary) == nil)
    }

    @Test("A parameters change (different window length) reads as no match")
    func lengthMismatchIsOrphan() {
        let summary = MorphologySummary(
            cards: [card(0, representative: up)],
            remainderCaption: nil, provenance: "", totalBeats: 10,
            matchThreshold: 0.30)
        let endorsement = MorphologyEndorsement(
            representative: [0.5, 0.5, -0.5, -0.5], endorsedAt: .distantPast)
        #expect(MorphologyContext.attachedCardIndex(of: endorsement, in: summary) == nil)
    }
}

@Suite("Morphology card strings (X112)")
struct MorphologyCardStringTests {

    @Test("Burden: count, share, and the sub-percent floor")
    func burden() {
        #expect(MorphologyContext.burdenCaption(count: 312, totalBeats: 2600)
                == "312 beats · 12% of beats")
        #expect(MorphologyContext.burdenCaption(count: 1, totalBeats: 2600)
                == "1 beat · <1% of beats")
        #expect(MorphologyContext.burdenCaption(count: 3, totalBeats: 0) == "3 beats")
    }

    @Test("Annotator codes: descending share, symbol tiebreak, verbatim symbols")
    func annotatorCodes() {
        #expect(MorphologyContext.annotatorCodesCaption(codeCounts: ["N": 96, "R": 4])
                == "annotator codes: N 96% · R 4%")
        // Equal counts break ties by symbol so the string is deterministic.
        #expect(MorphologyContext.annotatorCodesCaption(codeCounts: ["V": 5, "A": 5])
                == "annotator codes: A 50% · V 50%")
        #expect(MorphologyContext.annotatorCodesCaption(codeCounts: [:]) == nil)
        #expect(MorphologyContext.annotatorCodesCaption(codeCounts: ["N": 999, "V": 1])
                == "annotator codes: N 100% · V <1%")
    }

    @Test("Remainder: folded clusters and unusable windows, counted not hidden")
    func remainder() {
        #expect(MorphologyContext.remainderCaption(
            foldedClusterCount: 4, foldedBeatCount: 23, unassignedCount: 6)
            == "remainder: 23 beats in 4 small clusters · 6 windows unusable")
        #expect(MorphologyContext.remainderCaption(
            foldedClusterCount: 0, foldedBeatCount: 0, unassignedCount: 1)
            == "remainder: 1 window unusable")
        #expect(MorphologyContext.remainderCaption(
            foldedClusterCount: 0, foldedBeatCount: 0, unassignedCount: 0) == nil)
    }
}

@Suite("Morphology endorsement persistence (X112)")
struct MorphologyPersistenceTests {

    @Test("Endorsements round-trip through the session JSON")
    func roundTrip() throws {
        let endorsement = MorphologyEndorsement(
            representative: [0.1, -0.2, 0.3],
            endorsedAt: Date(timeIntervalSince1970: 1_770_000_000))
        var state = MurSessionState(viewportStartSample: 100)
        state.morphologyEndorsements = [endorsement]
        let decoded = try JSONDecoder().decode(
            MurSessionState.self, from: JSONEncoder().encode(state))
        #expect(decoded.morphologyEndorsements == [endorsement])
    }

    @Test("nil-when-empty: a session without endorsements is byte-identical to a pre-X112 one")
    func nilWhenEmpty() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(MurSessionState(viewportStartSample: 100))
        var state = MurSessionState(viewportStartSample: 100)
        state.morphologyEndorsements = nil
        let after = try encoder.encode(state)
        #expect(before == after)
    }

    @Test("replacingViewState carries endorsements — the X11 wipe guard")
    func replacingViewStateCarries() {
        let endorsement = MorphologyEndorsement(
            representative: [1, 0], endorsedAt: .distantPast)
        var fromView = MurSessionState(viewportStartSample: 5)
        fromView.morphologyEndorsements = [endorsement]
        // The live baseline carries scan dials the view doesn't own; the
        // merge must adopt the view's endorsements without touching those.
        let live = MurSessionState(tau: 3.5)
        let merged = live.replacingViewState(with: fromView)
        #expect(merged.morphologyEndorsements == [endorsement])
        #expect(merged.tau == 3.5)
    }
}
