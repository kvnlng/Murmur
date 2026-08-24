//
//  LeadChipBar.swift
//  MurmurCore
//
//  The lead chips above the stage, with the Focus/Strips toggle. A click
//  toggles a lead in or out of the overlaid stage; ⌥-click shows a lead
//  alone (X94 — clicking was X64's ⌘-click, but that gesture's only
//  affordance was a `.help()` tooltip, which renders nowhere on macOS 26,
//  so to a user multi-lead selection simply "didn't work").
//  Extracted from BedsideView in X67.
//

import AppKit
import SwiftUI

/// Horizontal lead-chip bar with a Focus/Strips mode toggle. Single-tap a lead
/// to focus it; toggle to strips to see them all stacked.
struct LeadChipBar: View {
    let channels: [Channel]
    @Binding var layoutMode: BedsideLayoutMode

    /// #358 — this record's id in the navigator's id space, threaded from
    /// `BedsideView.recordID` unchanged. Used only to look up analyst-
    /// declared placements for preset resolution (`declaredPlacements`
    /// below); `nil` (previews, or no record open) resolves presets against
    /// recorded names only, same as before #358.
    var recordID: String?

    /// Record length, for choosing which ladder rungs apply. Zero hides the
    /// ladder entirely — a record with no duration has nothing to zoom.
    var recordDurationSeconds: Double = 0
    /// Current viewport width, so the ladder can show which rung is active.
    var viewportDurationSeconds: Double = 0
    /// Sets the viewport width. Nil hides the ladder; supplied by the stage,
    /// which owns both the viewport and the window-hold latch the click
    /// releases (DECISIONS §5).
    var onSelectZoom: ((Double) -> Void)?

    /// #304 / 12a — the launch shell's idle rendering. With no channels this
    /// draws the dashed "no leads" placeholder chip, and the ladder shows
    /// every canonical rung disabled with no current selection: the frame at
    /// its final size, values absent. Only the launch shell sets this.
    var idle: Bool = false

    /// #332 — the analyst's saved lead sets. Shared so a preset saved here is
    /// in the menu on the next record without a reload, which is the whole
    /// point of a preset.
    @State private var presetStore = LeadPresetStore.shared
    @State private var isSavingPreset = false
    @State private var newPresetName = ""
    @State private var isManagingPresets = false
    /// Set only for the case the chips CANNOT show: a preset whose leads are
    /// none of this record's, where applying it would change nothing on screen
    /// and read as a broken menu item.
    @State private var unresolvedPresetName: String?

    var body: some View {
        HStack(spacing: 10) {
            modeToggle
            Divider().frame(maxHeight: 18)
            presetsMenu
            Divider().frame(maxHeight: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if idle && channels.isEmpty {
                        noLeadsChip
                    }
                    ForEach(channels) { channel in
                        chip(for: channel)
                    }
                }
                .padding(.vertical, 2)
            }
            if !ladderSteps.isEmpty, onSelectZoom != nil || idle {
                Divider().frame(maxHeight: 18)
                zoomLadder(steps: ladderSteps, onSelect: onSelectZoom)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lead-chip-bar")
        .alert("Save Lead Preset", isPresented: $isSavingPreset) {
            TextField("Name", text: $newPresetName)
                .accessibilityIdentifier("lead-preset-name-field")
            Button("Save") {
                presetStore.add(name: newPresetName, leads: stagedLeadNames)
            }
            .accessibilityIdentifier("lead-preset-save-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves \(stagedLeadNames.joined(separator: " · ")) by lead NAME, "
                 + "so it applies to any record carrying those leads.")
        }
        .alert(
            "Preset Not In This Record",
            isPresented: Binding(
                get: { unresolvedPresetName != nil },
                set: { if !$0 { unresolvedPresetName = nil } }
            )
        ) {
            Button("OK") { unresolvedPresetName = nil }
        } message: {
            Text("None of \(unresolvedPresetName ?? "")'s leads are in this record, "
                 + "so the stage is unchanged.")
        }
        .sheet(isPresented: $isManagingPresets) {
            LeadPresetManagerSheet(store: presetStore) { isManagingPresets = false }
        }
    }

    // MARK: - Presets (#332)

    /// The analyst-declared placements for this record (#358) — folder
    /// baseline overlaid by this record's overrides — that preset
    /// resolution may also match against, per `LeadPreset.resolve(in:
    /// declaredPlacements:)`. Read directly from `.shared` rather than an
    /// injected property, the same way `BedsideView.declaredPlacement(
    /// forChannelNamed:)` reads it, since presets never need a fake map in
    /// a test (the binding ruling: tests exercise `resolve` and the
    /// accessor directly, never through this view).
    private var declaredPlacements: [String: String] {
        LeadPlacementMapContext.shared.declaredPlacements(forRecordID: recordID)
    }

    /// The leads currently on the stage, by NAME and in selection order —
    /// what a saved preset stores, and what the save dialog quotes back.
    private var stagedLeadNames: [String] {
        guard let selection = layoutMode.leadSelection else { return [] }
        let namesByID = Dictionary(
            channels.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return selection.ordered.compactMap { namesByID[$0] }
    }

    /// Menu of built-ins and saved sets.
    ///
    /// Each row says up front how much of itself this record can satisfy —
    /// "Precordial — 3 of 6" — rather than staging a partial set and leaving
    /// the analyst to notice. A preset the record cannot satisfy at all is
    /// disabled, so the menu never offers an action that would do nothing.
    private var presetsMenu: some View {
        Menu {
            ForEach(presetStore.allPresets) { preset in
                let resolution = idle ? nil : preset.resolve(in: channels, declaredPlacements: declaredPlacements)
                Button(presetRowTitle(preset, resolution: resolution)) {
                    apply(preset)
                }
                .disabled(idle || resolution == nil)
                .accessibilityIdentifier("lead-preset-\(preset.id.uuidString)")
            }
            Divider()
            Button("Save current selection as preset…") {
                newPresetName = ""
                isSavingPreset = true
            }
            .disabled(stagedLeadNames.isEmpty)
            .accessibilityIdentifier("lead-preset-save")
            Button("Manage presets…") { isManagingPresets = true }
                .disabled(presetStore.userPresets.isEmpty)
                .accessibilityIdentifier("lead-preset-manage")
        } label: {
            Label("Presets", systemImage: "square.stack.3d.up")
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.06))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(idle)
        .help("Apply or save a named set of leads")
        .accessibilityLabel("Lead presets")
        .accessibilityIdentifier("lead-presets-menu")
    }

    private func presetRowTitle(
        _ preset: LeadPreset, resolution: LeadPreset.Resolution?
    ) -> String {
        // `All leads` names no leads, so "n of m" would be meaningless for it.
        guard !preset.isEveryLead, !idle else { return preset.name }
        guard let resolution else { return "\(preset.name) — none in this record" }
        guard resolution.missing.isEmpty else {
            return "\(preset.name) — \(resolution.selection.count) of \(preset.leads.count)"
        }
        return preset.name
    }

    private func apply(_ preset: LeadPreset) {
        guard let resolution = preset.resolve(in: channels, declaredPlacements: declaredPlacements) else {
            unresolvedPresetName = preset.name
            return
        }
        layoutMode = .focus(resolution.selection)
    }

    private var ladderSteps: [ZoomLadderStep] {
        idle ? ZoomLadder.allSteps
             : ZoomLadder.steps(forDurationSeconds: recordDurationSeconds)
    }

    /// The chip row's empty state: a dashed capsule where the lead chips
    /// will be, so the row holds its height and says why it is empty.
    private var noLeadsChip: some View {
        Text("no leads")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
            )
            .accessibilityLabel("No leads — no record open")
            .accessibilityIdentifier("lead-chip-none")
    }

    /// The zoom ladder. Trailing, so the bar reads left-to-right as
    /// "which layout, which leads, how wide a window". A nil `onSelect`
    /// (idle) draws every rung disabled with no current selection.
    private func zoomLadder(steps: [ZoomLadderStep], onSelect: ((Double) -> Void)?) -> some View {
        let current = onSelect == nil ? nil : ZoomLadder.currentStep(
            forDurationSeconds: viewportDurationSeconds,
            in: steps
        )
        return HStack(spacing: 6) {
            Text("Zoom")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(steps) { step in
                    let isOn = current == step
                    Button {
                        onSelect?(step.seconds)
                    } label: {
                        Text(step.label)
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 30)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isOn ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(onSelect == nil)
                    // Nothing is selected after a manual pinch, and that is the
                    // honest state — the ladder must not claim a rung the
                    // analyst is not on.
                    .help("Set the window to \(step.label)")
                    .accessibilityLabel("Zoom to \(step.label)\(isOn ? ", current" : "")")
                    .accessibilityIdentifier("zoom-ladder-\(step.label.replacingOccurrences(of: " ", with: ""))")
                }
            }
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeButton(
                systemImage: "rectangle.fill",
                label: "Focus",
                isOn: isFocusMode,
                action: switchToFocus
            )
            modeButton(
                systemImage: "rectangle.split.1x2.fill",
                label: "Strips",
                isOn: layoutMode == .strips,
                action: { layoutMode = .strips }
            )
        }
    }

    private func modeButton(systemImage: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isOn ? Color.accentColor : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityIdentifier("layout-mode-\(label.lowercased())")
    }

    private func chip(for channel: Channel) -> some View {
        let selection = layoutMode.leadSelection
        let rank = selection?.rank(of: channel.id)
        let isPrimary = rank == 0
        let isStaged = rank != nil
        // The swatch appears only while more than one lead is on the stage.
        // On the single-lead stage there is nothing to tell apart, and a black
        // dot beside the only chip would be noise claiming to be information.
        let showsSwatch = isStaged && (selection?.isSingle == false)
        return Button {
            toggleOrSelect(channel)
        } label: {
            HStack(spacing: 5) {
                if showsSwatch, let rank {
                    Capsule()
                        .fill(LeadPalette.ink(rank: rank).color)
                        .frame(width: 10, height: 3)
                }
                Text(channel.name)
                    .font(.caption.monospaced().weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isStaged ? Color.accentColor.opacity(isPrimary ? 0.22 : 0.10) : Color.secondary.opacity(0.10))
            )
            .overlay(
                // Solid ring for the primary, dashed for an overlaid lead —
                // the two roles are not interchangeable (marks and the
                // inspector follow the primary), so they must not look
                // interchangeable either.
                Capsule()
                    .strokeBorder(
                        isStaged ? Color.accentColor : .clear,
                        style: StrokeStyle(lineWidth: 1, dash: isPrimary ? [] : [3, 2])
                    )
            )
        }
        .buttonStyle(.plain)
        .help(chipHelp(channel: channel, rank: rank))
        .accessibilityLabel(chipHelp(channel: channel, rank: rank))
        .accessibilityIdentifier("lead-chip-\(channel.name)")
    }

    /// A click toggles this lead in or out of the stage; ⌥-click shows it
    /// alone. ⌘-click still toggles — X64 muscle memory keeps working.
    ///
    /// X94: toggling used to be ⌘-click only, with plain click collapsing to
    /// the clicked lead. The additive gesture's sole affordance was a
    /// `.help()` tooltip that renders nowhere on macOS 26, so the natural
    /// gesture — just clicking another lead — silently REPLACED the stage
    /// instead, and multi-lead selection read as broken. Now the natural
    /// gesture is the feature, and the escape to a single lead moves to ⌥.
    ///
    /// The modifier is read from `NSEvent` rather than through a SwiftUI
    /// `TapGesture().modifiers(…)` because that route needs the chip to
    /// stop being a `Button` — and a Button is what gives the chip its
    /// keyboard activation, its focus ring and its XCUI `.buttons` identity.
    /// Reading the flags inside the action keeps ONE code path for all
    /// clicks, so there is no gesture-precedence race between them.
    private func toggleOrSelect(_ channel: Channel) {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        guard let selection = layoutMode.leadSelection, !optionHeld else {
            // ⌥-click — or any click from strips mode, where there is no
            // selection to toggle against — shows this lead alone.
            layoutMode = .focus(only: channel.id)
            return
        }
        layoutMode = .focus(selection.toggling(channel.id))
    }

    private func chipHelp(channel: Channel, rank: Int?) -> String {
        switch rank {
        case 0:  return "\(channel.name) — primary lead. Click another lead to overlay it; ⌥-click one to show it alone."
        case .some(let rank): return "\(channel.name) — overlaid in \(LeadPalette.ink(rank: rank).name). Click to remove."
        case nil: return "\(channel.name) — click to overlay, ⌥-click to show alone."
        }
    }

    private var isFocusMode: Bool {
        if case .focus = layoutMode { return true }
        return false
    }

    private func switchToFocus() {
        if case .focus = layoutMode { return }
        if let first = channels.first { layoutMode = .focus(only: first.id) }
    }
}
