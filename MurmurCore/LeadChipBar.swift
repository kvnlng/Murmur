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

    /// Record length, for choosing which ladder rungs apply. Zero hides the
    /// ladder entirely — a record with no duration has nothing to zoom.
    var recordDurationSeconds: Double = 0
    /// Current viewport width, so the ladder can show which rung is active.
    var viewportDurationSeconds: Double = 0
    /// Sets the viewport width. Nil hides the ladder; supplied by the stage,
    /// which owns both the viewport and the window-hold latch the click
    /// releases (DECISIONS §5).
    var onSelectZoom: ((Double) -> Void)?

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
            if let onSelectZoom, !ladderSteps.isEmpty {
                Divider().frame(maxHeight: 18)
                zoomLadder(steps: ladderSteps, onSelect: onSelectZoom)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lead-chip-bar")
    }

    private var ladderSteps: [ZoomLadderStep] {
        ZoomLadder.steps(forDurationSeconds: recordDurationSeconds)
    }

    /// The zoom ladder. Trailing, so the bar reads left-to-right as
    /// "which layout, which leads, how wide a window".
    private func zoomLadder(steps: [ZoomLadderStep], onSelect: @escaping (Double) -> Void) -> some View {
        let current = ZoomLadder.currentStep(
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
                        onSelect(step.seconds)
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
