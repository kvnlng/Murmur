//
//  ToolbarDisplayModeDefault.swift
//  MurmurCore
//
//  Opens the toolbar showing Icon AND Text.
//
//  X60: `.help()` renders no tooltip anywhere in this app on macOS 26, so an
//  icon-only button has no way to say what it is. Customize Toolbar… makes
//  labels reachable; this makes them the state the analyst starts in, which is
//  the point — an affordance nobody discovers is not an affordance.
//
//  ## Why this seeds a preference instead of setting `toolbar.displayMode`
//
//  The obvious implementation — reach the window's `NSToolbar` after layout
//  and assign `.iconAndLabel` — WAS tried, and it breaks accessibility.
//  Mutating `displayMode` on a SwiftUI-built toolbar makes SwiftUI rebuild the
//  items, and the rebuilt `NSToolbarItem`s lose the accessibility identifiers
//  their `Button`s carry. Measured: with the mutation running, every toolbar
//  identifier is gone for that launch (`app.buttons["export-report"]` finds
//  nothing) and the whole XCUI suite fails; on the next launch, with the
//  mutation skipped, all ten identifiers are back and everything passes.
//
//  That is not merely a test problem. **Xcode Cloud starts from clean state on
//  every run**, so the "first launch" path is the ONLY path CI ever takes —
//  the suite would have failed every time. And a real analyst's first launch
//  after updating would have a toolbar that assistive technology cannot
//  address.
//
//  So instead of mutating a live toolbar, seed the preference AppKit reads
//  when it CONSTRUCTS one. No rebuild, no lost identifiers.
//
//  ## Why it only ever writes once
//
//  This is a DEFAULT, not a policy. It writes only when no saved toolbar
//  configuration exists at all — a fresh install. From then on macOS owns the
//  key and the analyst's Customize Toolbar… choice is the only thing that
//  changes it. Re-asserting the mode on every launch would silently undo their
//  choice, and a customisation sheet whose result evaporates on relaunch is
//  worse than not offering one.
//
//  ## The one fragile part, stated plainly
//
//  `NSToolbar Configuration <identifier>` and its `TB Display Mode` key are
//  AppKit's own persistence format, not documented API. If either changes, the
//  seed silently does nothing and the toolbar opens icon-only — the previous
//  behaviour. It degrades to the old default rather than breaking, which is
//  the reason this is acceptable at all.
//

import Foundation

public enum ToolbarDisplayModeDefault {

    /// AppKit's persistence key for a toolbar's saved configuration.
    private static var configurationKey: String {
        "NSToolbar Configuration \(MurmurToolbar.identifier)"
    }

    /// `NSToolbar.DisplayMode.iconAndLabel`.
    private static let iconAndLabel = 1

    /// Seed Icon and Text as the opening display mode on a fresh install.
    /// Call before any window is created — from the App's `init()` — so AppKit
    /// reads it while building the toolbar rather than being told afterwards.
    ///
    /// No-ops once any saved configuration exists, which is what keeps the
    /// analyst's own choice authoritative.
    public static func seedIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.dictionary(forKey: configurationKey) == nil else { return }
        defaults.set(["TB Display Mode": iconAndLabel], forKey: configurationKey)
    }
}
