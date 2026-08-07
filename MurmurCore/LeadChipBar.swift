//
//  LeadChipBar.swift
//  MurmurCore
//
//  The lead chips above the stage, with the Focus/Strips toggle. Plain-click
//  focuses a lead alone; ⌘-click adds or removes an overlaid lead (X64).
//  Extracted from BedsideView in X67.
//

import AppKit
import SwiftUI

/// Horizontal lead-chip bar with a Focus/Strips mode toggle. Single-tap a lead
/// to focus it; toggle to strips to see them all stacked.
struct LeadChipBar: View {
    let channels: [Channel]
    @Binding var layoutMode: BedsideLayoutMode

    var body: some View {
        HStack(spacing: 10) {
            modeToggle
            Divider().frame(maxHeight: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(channels) { channel in
                        chip(for: channel)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lead-chip-bar")
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

    /// Plain click selects this lead alone; ⌘-click adds or removes it from
    /// the overlay.
    ///
    /// The modifier is read from `NSEvent` rather than through a SwiftUI
    /// `TapGesture().modifiers(.command)` because that route needs the chip to
    /// stop being a `Button` — and a Button is what gives the chip its
    /// keyboard activation, its focus ring and its XCUI `.buttons` identity.
    /// Reading the flags inside the action keeps ONE code path for both
    /// clicks, so there is no gesture-precedence race between them.
    private func toggleOrSelect(_ channel: Channel) {
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        guard commandHeld, let selection = layoutMode.leadSelection else {
            // Plain click always collapses to this lead alone — the way out of
            // any overlay, from any state.
            layoutMode = .focus(only: channel.id)
            return
        }
        layoutMode = .focus(selection.toggling(channel.id))
    }

    private func chipHelp(channel: Channel, rank: Int?) -> String {
        switch rank {
        case 0:  return "\(channel.name) — primary lead. ⌘-click another lead to overlay it."
        case .some(let rank): return "\(channel.name) — overlaid in \(LeadPalette.ink(rank: rank).name). ⌘-click to remove."
        case nil: return "\(channel.name) — click to show alone, ⌘-click to overlay."
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
