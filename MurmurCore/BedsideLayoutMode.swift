//
//  BedsideLayoutMode.swift
//  MurmurCore
//
//  Which way the bedside view is laid out: the focus stage (1..n overlaid
//  leads) or strips (every lead stacked). Extracted from BedsideView in X67.
//
//  The two modes are not symmetric, and deliberately so — strips mode is the
//  ratified exception to the persistent stage, because its ergonomic is
//  cross-lead vertical alignment, which pinning would fight. See
//  `project_layout_persistent_stage.md`.
//

import Foundation


enum BedsideLayoutMode: Equatable {
    /// The focus stage: 1..n leads overlaid on one time axis and one
    /// amplitude axis, full available height. One lead is the analyst's
    /// default and stays the common case; the overlay is X64.
    case focus(LeadSelection)
    /// All leads stacked in compact strips — opt-in cross-lead comparison.
    case strips

    /// Focus a single lead, discarding any overlay. Spelled `only:` because
    /// `.focus(id)` would read equally well as "make this the primary and keep
    /// the rest", which is emphatically not what it does.
    static func focus(only id: Channel.ID) -> BedsideLayoutMode {
        .focus(LeadSelection(primary: id))
    }

    /// The leads on the stage, or nil in strips mode.
    var leadSelection: LeadSelection? {
        guard case .focus(let selection) = self else { return nil }
        return selection
    }
}
