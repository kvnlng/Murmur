//
//  SidePanelCoexistence.swift
//  MurmurCore
//
//  X82 — side panels render whole or not at all.
//
//  The defect this exists to prevent: with the record navigator AND the
//  review-queue inspector both open, a window below ~1154 pt of content
//  width cannot hold [navigator][bedside floor][inspector], and SwiftUI's
//  answer is to clip the row at BOTH edges — the navigator loses its left
//  ~27 pt and the inspector its right ~27 pt (AX-measured on macOS 26 at
//  the 1100 pt production minimum). A partially-drawn sidebar looks broken
//  and hides controls; the ratified resize behaviour is that the MIDDLE
//  stays readable and side panels yield entirely.
//
//  The rule: below `coexistenceWidth` the two panels may not both be open.
//  The most recently REQUESTED panel wins; the other yields — fully. Both
//  wanted-states survive, so widening the window brings the yielded panel
//  straight back. Either panel alone fits at the production minimum
//  (verified empirically for both), so the rule only ever arbitrates the
//  pair.
//

import Foundation
import Observation

/// The two side panels that flank the bedside detail.
public enum SidePanel: Sendable, Equatable {
    case navigator
    case inspector
}

/// What actually shows, after the coexistence rule arbitrates.
public struct SidePanelResolution: Equatable, Sendable {
    public let navigatorVisible: Bool
    public let inspectorVisible: Bool
}

/// Shared state: what the analyst asked for, what the window allows.
///
/// Two writers by design (the same shape as `MetricsScopeContext`): the
/// browse shell writes the window width and owns the navigator's wanted
/// state; BedsideView owns the inspector's. Deriving both visibilities from
/// one object means a resize and a toggle cannot race into a frame where
/// both panels believe they fit.
@MainActor
@Observable
public final class SidePanelCoexistenceContext {

    public static let shared = SidePanelCoexistenceContext()

    /// Minimum window content width at which the navigator column (at its
    /// 160 pt minimum) and the 340 pt review-queue inspector can flank the
    /// bedside detail's floor without clipping. Measured at 1154 on
    /// macOS 26; 1160 carries a small margin. If the bedside chrome grows,
    /// the X82 UI test's frame assertions catch the drift.
    public static let coexistenceWidth: CGFloat = 1160

    /// Analyst intent, not effective visibility.
    public var navigatorWanted: Bool = true
    public var inspectorWanted: Bool = true

    /// Whether a navigator exists at all right now. The browse shell (folder
    /// or multi-record session) has one; the direct single-record shell does
    /// not — and a stale width from an earlier browse must not make the rule
    /// arbitrate against a panel that is not on screen.
    public var navigatorPresent: Bool = false

    /// Which panel the analyst asked for most recently — the winner when
    /// both are wanted and the window can't hold both. Defaults to the
    /// inspector: the review queue is the working surface (dispositions
    /// live there); the record list is navigation.
    public var lastRequested: SidePanel = .inspector

    /// Window content width, written by the browse shell's geometry. Zero
    /// before first layout — treated as "fits" so nothing collapses during
    /// the first frame.
    public var windowContentWidth: CGFloat = 0

    public init() {}

    /// Record an explicit analyst request to open/close a panel.
    public func request(_ panel: SidePanel, open: Bool) {
        switch panel {
        case .navigator: navigatorWanted = open
        case .inspector: inspectorWanted = open
        }
        if open { lastRequested = panel }
    }

    public var resolution: SidePanelResolution {
        Self.resolve(
            width: windowContentWidth,
            navigatorWanted: navigatorWanted && navigatorPresent,
            inspectorWanted: inspectorWanted,
            lastRequested: lastRequested
        )
    }

    /// The pure rule, separated for unit tests.
    public nonisolated static func resolve(
        width: CGFloat,
        navigatorWanted: Bool,
        inspectorWanted: Bool,
        lastRequested: SidePanel
    ) -> SidePanelResolution {
        let bothFit = width <= 0 || width >= coexistenceWidth
        guard navigatorWanted, inspectorWanted, !bothFit else {
            return SidePanelResolution(
                navigatorVisible: navigatorWanted,
                inspectorVisible: inspectorWanted
            )
        }
        return SidePanelResolution(
            navigatorVisible: lastRequested == .navigator,
            inspectorVisible: lastRequested == .inspector
        )
    }
}
