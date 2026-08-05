//
//  LeadSelection.swift
//  MurmurCore
//
//  The ordered set of leads shown on the focus stage (X64-A).
//
//  Focus mode used to be one lead: `BedsideLayoutMode.focus(Channel.ID)`. X64
//  turns it into an overlay of 1..n leads on ONE time axis and ONE amplitude
//  axis, so the state it carries has to grow. This is that state, and only
//  that state — no rendering, no colour, no marks. Those are X64-B and X64-C.
//
//  ## Why a struct and not `[Channel.ID]`
//
//  An array makes two illegal states representable: empty (a focus mode
//  focusing nothing) and duplicated (one lead drawn twice, which would also
//  hand it two palette entries in X64-C). Both would have to be defended
//  against at every read site. A non-optional `primary` plus deduplicated
//  `secondaries` makes them unrepresentable instead, so no read site checks.
//
//  ## Why the primary is distinguished at all
//
//  Per the ratified spec (`project_lead_overlay_focus_spec.md` §4), fiducial
//  ticks, annotation marks, the docked inspector and the calibration readout
//  follow ONE designated lead. Marks drawn over a trace they were not measured
//  from would imply a measurement nobody made. So "which lead is primary" is
//  not a display preference — it is the answer to "what were these numbers
//  measured on", and it must be a stored fact rather than a convention about
//  element zero that some later caller forgets.
//

import Foundation

/// The leads overlaid on the focus stage, in selection order, with the first
/// one designated primary.
///
/// Always holds at least one lead: there is no such thing as focus mode with
/// nothing focused, and callers should never have to handle that case.
public struct LeadSelection: Equatable, Sendable {

    /// The designated lead. Marks, the docked inspector, the calibration
    /// readout and the deviation-nav all follow this one — see §4 of the spec.
    public let primary: Channel.ID

    /// Overlaid leads beneath the primary, in the order the analyst added
    /// them. Never contains `primary`, never contains a duplicate.
    public let secondaries: [Channel.ID]

    /// Single-lead selection — the state focus mode has always been in, and
    /// still is by default.
    public init(primary: Channel.ID) {
        self.primary = primary
        self.secondaries = []
    }

    /// Build from an ordered list, first element primary. Duplicates are
    /// dropped keeping their FIRST position, because position is selection
    /// order and selection order is what X64-C assigns palette entries by —
    /// re-adding a lead must not silently move its ink.
    ///
    /// Returns nil for an empty list rather than inventing a lead.
    public init?(ordered: [Channel.ID]) {
        var seen = Set<Channel.ID>()
        let unique = ordered.filter { seen.insert($0).inserted }
        guard let first = unique.first else { return nil }
        self.primary = first
        self.secondaries = Array(unique.dropFirst())
    }

    private init(primary: Channel.ID, uncheckedSecondaries: [Channel.ID]) {
        self.primary = primary
        self.secondaries = uncheckedSecondaries
    }

    /// Every selected lead, primary first. The render order for X64-B: the
    /// primary is drawn last so it sits on top of the muted secondaries.
    public var ordered: [Channel.ID] {
        [primary] + secondaries
    }

    public var count: Int { secondaries.count + 1 }

    /// True when this is the plain single-lead case. X64-B's "single lead
    /// renders exactly as it did before" guarantee keys off this.
    public var isSingle: Bool { secondaries.isEmpty }

    public func contains(_ id: Channel.ID) -> Bool {
        primary == id || secondaries.contains(id)
    }

    public func isPrimary(_ id: Channel.ID) -> Bool { primary == id }

    /// Position in selection order, or nil when the lead isn't selected.
    ///
    /// X64-C assigns trace inks by this, NOT by lead name — WFDB sources do
    /// not agree on a closed set of lead names, so a name-keyed palette would
    /// have no entry for the first unfamiliar record someone opens.
    public func rank(of id: Channel.ID) -> Int? {
        ordered.firstIndex(of: id)
    }

    /// ⌘-click: add the lead to the overlay, or take it back out.
    ///
    /// Removing the primary promotes the next lead in selection order rather
    /// than refusing. "⌘-click removes a lead" with a silent exception for the
    /// primary would be a hole the analyst discovers by finding a lead they
    /// cannot remove, with nothing on screen explaining why.
    ///
    /// The one case that IS refused: ⌘-clicking the last remaining lead. There
    /// is no zero-lead focus mode to fall into, and emptying the stage is not
    /// a plausible intent — so it holds rather than doing something arbitrary.
    public func toggling(_ id: Channel.ID) -> LeadSelection {
        if id == primary {
            guard let promoted = secondaries.first else { return self }
            return LeadSelection(
                primary: promoted,
                uncheckedSecondaries: Array(secondaries.dropFirst())
            )
        }
        if let index = secondaries.firstIndex(of: id) {
            var remaining = secondaries
            remaining.remove(at: index)
            return LeadSelection(primary: primary, uncheckedSecondaries: remaining)
        }
        return LeadSelection(primary: primary, uncheckedSecondaries: secondaries + [id])
    }

    // Plain click — "that lead, alone" — is `LeadSelection(primary:)`, reached
    // through `BedsideLayoutMode.focus(only:)`. It gets no method here: it
    // discards the current selection entirely, so there is nothing for an
    // instance method to do with `self`.
}
