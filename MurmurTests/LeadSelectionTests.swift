//
//  LeadSelectionTests.swift
//  MurmurTests
//
//  X64-A acceptance for the focus-stage selection model. The rules under test
//  are the ones that would otherwise be re-derived (differently) at each read
//  site: the selection is never empty, never duplicated, and its ORDER is
//  stable — X64-C assigns trace inks by selection order, so an operation that
//  quietly reshuffles it would reshuffle the palette with it.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("LeadSelection — focus-stage lead set")
struct LeadSelectionTests {

    private let leadA = UUID()
    private let leadB = UUID()
    private let leadC = UUID()

    // MARK: - Construction

    @Test("A single lead is its own primary with nothing overlaid")
    func singleLeadIsPrimary() {
        let selection = LeadSelection(primary: leadA)
        #expect(selection.primary == leadA)
        #expect(selection.secondaries.isEmpty)
        #expect(selection.isSingle)
        #expect(selection.count == 1)
        #expect(selection.ordered == [leadA])
    }

    @Test("An ordered list takes its first element as primary")
    func orderedListPromotesFirst() throws {
        let selection = try #require(LeadSelection(ordered: [leadA, leadB, leadC]))
        #expect(selection.primary == leadA)
        #expect(selection.secondaries == [leadB, leadC])
        #expect(!selection.isSingle)
    }

    @Test("An empty list is not a selection")
    func emptyListIsNil() {
        // Focus mode focusing nothing has no meaning, and inventing a lead to
        // avoid returning nil would put a trace on screen the analyst never
        // asked for.
        #expect(LeadSelection(ordered: []) == nil)
    }

    @Test("Duplicates collapse to their first position")
    func duplicatesKeepFirstPosition() throws {
        // First position, not last: position IS selection order, and selection
        // order is what X64-C hands out trace inks by. Re-adding a lead must
        // not move its ink.
        let selection = try #require(LeadSelection(ordered: [leadA, leadB, leadA, leadC, leadB]))
        #expect(selection.ordered == [leadA, leadB, leadC])
    }

    // MARK: - Membership

    @Test("Membership covers the primary and the overlay alike")
    func containsBothRoles() throws {
        let selection = try #require(LeadSelection(ordered: [leadA, leadB]))
        #expect(selection.contains(leadA))
        #expect(selection.contains(leadB))
        #expect(!selection.contains(leadC))
        #expect(selection.isPrimary(leadA))
        #expect(!selection.isPrimary(leadB))
    }

    @Test("Rank is selection order with the primary at zero")
    func rankFollowsSelectionOrder() throws {
        let selection = try #require(LeadSelection(ordered: [leadA, leadB, leadC]))
        #expect(selection.rank(of: leadA) == 0)
        #expect(selection.rank(of: leadB) == 1)
        #expect(selection.rank(of: leadC) == 2)
        #expect(selection.rank(of: UUID()) == nil)
    }

    // MARK: - ⌘-click

    @Test("Toggling an unselected lead appends it to the overlay")
    func togglingAddsToEnd() {
        let selection = LeadSelection(primary: leadA).toggling(leadB)
        #expect(selection.primary == leadA)
        #expect(selection.secondaries == [leadB])
    }

    @Test("Toggling a secondary removes it and leaves the rest in order")
    func togglingRemovesSecondary() throws {
        let selection = try #require(LeadSelection(ordered: [leadA, leadB, leadC]))
        let after = selection.toggling(leadB)
        #expect(after.primary == leadA)
        #expect(after.secondaries == [leadC])
    }

    @Test("Toggling the primary promotes the next lead rather than refusing")
    func togglingPrimaryPromotesNext() throws {
        // "⌘-click removes a lead" with a silent exception for the primary
        // would be a hole the analyst finds by hitting a lead they cannot
        // remove, with nothing on screen saying why.
        let selection = try #require(LeadSelection(ordered: [leadA, leadB, leadC]))
        let after = selection.toggling(leadA)
        #expect(after.primary == leadB)
        #expect(after.secondaries == [leadC])
        #expect(!after.contains(leadA))
    }

    @Test("Toggling the last remaining lead holds — the stage is never empty")
    func togglingLastLeadHolds() {
        let selection = LeadSelection(primary: leadA)
        #expect(selection.toggling(leadA) == selection)
    }

    @Test("Toggling a lead twice returns the original selection")
    func togglingIsItsOwnInverse() throws {
        let selection = try #require(LeadSelection(ordered: [leadA, leadB]))
        #expect(selection.toggling(leadC).toggling(leadC) == selection)
    }

}
