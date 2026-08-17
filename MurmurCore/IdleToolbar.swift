//
//  IdleToolbar.swift
//  MurmurCore
//
//  12a's launch-state toolbar (#285): every item present with its real SF
//  Symbol, disabled, so opening a record changes a control's STATE and
//  never the frame. "No item appears or disappears on load" is the one
//  bullet the design states as an invariant rather than an appearance.
//
//  This is deliberately a MIRROR of BedsideView's registrations rather
//  than a shared builder: those ten items are entangled with BedsideView's
//  state (drawer animation, editing latch, panel arbitration, export
//  pipelines), and parameterising all of it into a shared component would
//  trade ten inert buttons for a second initialiser nobody can read. The
//  two copies cannot drift silently — ids and glyphs both come from single
//  authorities (the id strings are persisted in analysts' saved layouts;
//  the glyphs live in `ToolbarGlyph`), and `MurmurUILaunchShellTests`
//  asserts the same item set exists in both states.
//
//  `showsByDefault` mirrors the bedside exactly — a hidden-by-default item
//  that appeared at launch would itself be the frame moving.
//

import SwiftUI

/// The bedside toolbar's item set, idle. Mounted by `ContentView` whenever
/// no `BedsideView` is on screen; the ids collide by DESIGN with the
/// bedside's registrations, which is why the two are never mounted at once.
struct IdleToolbarItems: CustomizableToolbarContent {

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "notes-toggle", placement: .automatic, showsByDefault: true) {
            idle("Notes", systemImage: ToolbarGlyph.notes, id: "notes-toggle")
        }
        ToolbarItem(id: "edit-mode-toggle", placement: .automatic, showsByDefault: true) {
            idle("Locked", systemImage: ToolbarGlyph.editModeLocked, id: "edit-mode-toggle")
        }
        ToolbarItem(id: "window-lock-toggle", placement: .automatic, showsByDefault: true) {
            idle("10 s window", systemImage: ToolbarGlyph.windowFree, id: "window-lock-toggle")
        }
        ToolbarItem(id: "vtvf-scan-action", placement: .automatic, showsByDefault: true) {
            idle("Scan for VT/VF candidates", systemImage: ToolbarGlyph.scanVTVF, id: "vtvf-scan-action")
        }
        ToolbarItem(id: "attach-findings", placement: .automatic, showsByDefault: true) {
            idle("Attach findings…", systemImage: ToolbarGlyph.attachFindings, id: "attach-findings")
        }
        ToolbarItem(id: "export-report", placement: .automatic, showsByDefault: true) {
            idle("Export", systemImage: ToolbarGlyph.exportReport, id: "export-report")
        }
        ToolbarItem(id: "export-snapshot", placement: .automatic, showsByDefault: false) {
            idle("Export snapshot…", systemImage: ToolbarGlyph.exportSnapshot, id: "export-snapshot")
        }
        ToolbarItem(id: "export-wfdb", placement: .automatic, showsByDefault: false) {
            idle("Export WFDB annotations…", systemImage: ToolbarGlyph.exportWFDB, id: "export-wfdb")
        }
        #if DEBUG
        ToolbarItem(id: "producers-toggle", placement: .automatic, showsByDefault: true) {
            idle("Producers", systemImage: ToolbarGlyph.producers, id: "producers-toggle")
        }
        #endif
        ToolbarItem(id: "findings-toggle", placement: .automatic, showsByDefault: true) {
            idle("Review queue", systemImage: ToolbarGlyph.reviewQueue, id: "findings-toggle")
        }
    }

    /// One inert item: real glyph, disabled — macOS renders the standard
    /// ~32% disabled treatment, which is the 12a look. The button exists so
    /// the item participates in toolbar customisation like its live twin.
    private func idle(_ title: String, systemImage: String, id: String) -> some View {
        Button {} label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(true)
        .accessibilityIdentifier(id)
    }
}
