//
//  BedsideCommands.swift
//  Murmur
//
//  Bridge from the App scene's menu commands to the live BedsideView actions
//  (which own the viewport + markings + disposition state). Published by
//  BedsideView as a focused SCENE value; the menu reads it via
//  `@FocusedValue(\.bedsideCommands)`.
//
//  Why a menu command rather than the view's own key handling: the pan / zoom
//  / finding-jump / disposition keys used to live in `.onKeyPress` on a
//  `.focusable()` view, so they only fired while that view happened to hold
//  keyboard focus — clicking the findings list or the canvas silently moved
//  focus and the keys stopped (the intermittent-J/K defect, P13). A menu key
//  equivalent dispatches through the responder chain and does NOT depend on an
//  arbitrary subview holding focus, so it fires reliably AND is discoverable.
//
//  `textEntryActive` gates the character/arrow shortcuts off while the notes
//  editor is first responder: macOS matches menu key equivalents before the
//  focused control sees the key-down, and a DISABLED menu item passes its key
//  through — so disabling during note entry lets the editor keep its
//  keystrokes (typing "j" inserts "j" instead of jumping).
//

import SwiftUI

public struct BedsideCommands {
    public var panLeft: () -> Void
    public var panRight: () -> Void
    public var zoomIn: () -> Void
    public var zoomOut: () -> Void
    public var nextFinding: () -> Void
    public var previousFinding: () -> Void
    public var nextDeviationBeat: () -> Void
    public var previousDeviationBeat: () -> Void
    public var confirm: () -> Void
    public var dismiss: () -> Void
    public var reset: () -> Void
    /// Snap both axes back to standard ECG paper (25 mm/s · 10 mm/mV) — X40.
    public var standardView: () -> Void
    /// X28 — flip the viewport readout between elapsed and time-of-day.
    public var toggleTimeDisplay: () -> Void
    /// False when the record carries no real start time. The menu item is then
    /// shown DISABLED rather than hidden, so the analyst can see the capability
    /// exists and that THIS record cannot support it — never a fabricated
    /// clock (X32).
    public var timeDisplayAvailable: Bool
    /// Drives the menu item's checkmark.
    public var timeDisplayIsWallClock: Bool

    /// True while a text field (the notes editor) is the first responder. The
    /// App disables the bedside key commands then so typing isn't intercepted.
    public var textEntryActive: Bool
    /// True while the recording is unlocked for editing — the disposition
    /// commands (confirm / dismiss / reset) only act then, matching the
    /// existing C/D/X behavior.
    public var isEditing: Bool

    public init(
        panLeft: @escaping () -> Void,
        panRight: @escaping () -> Void,
        zoomIn: @escaping () -> Void,
        zoomOut: @escaping () -> Void,
        nextFinding: @escaping () -> Void,
        previousFinding: @escaping () -> Void,
        nextDeviationBeat: @escaping () -> Void,
        previousDeviationBeat: @escaping () -> Void,
        confirm: @escaping () -> Void,
        dismiss: @escaping () -> Void,
        reset: @escaping () -> Void,
        standardView: @escaping () -> Void,
        toggleTimeDisplay: @escaping () -> Void = {},
        timeDisplayAvailable: Bool = false,
        timeDisplayIsWallClock: Bool = false,
        textEntryActive: Bool,
        isEditing: Bool
    ) {
        self.panLeft = panLeft
        self.panRight = panRight
        self.zoomIn = zoomIn
        self.zoomOut = zoomOut
        self.nextFinding = nextFinding
        self.previousFinding = previousFinding
        self.nextDeviationBeat = nextDeviationBeat
        self.previousDeviationBeat = previousDeviationBeat
        self.confirm = confirm
        self.dismiss = dismiss
        self.reset = reset
        self.standardView = standardView
        self.toggleTimeDisplay = toggleTimeDisplay
        self.timeDisplayAvailable = timeDisplayAvailable
        self.timeDisplayIsWallClock = timeDisplayIsWallClock
        self.textEntryActive = textEntryActive
        self.isEditing = isEditing
    }
}

public struct BedsideCommandsFocusedValueKey: FocusedValueKey {
    public typealias Value = BedsideCommands
}

public extension FocusedValues {
    var bedsideCommands: BedsideCommands? {
        get { self[BedsideCommandsFocusedValueKey.self] }
        set { self[BedsideCommandsFocusedValueKey.self] = newValue }
    }
}
