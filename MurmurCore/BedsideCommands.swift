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

    /// X72 — the Context drawer. Toggle is ⌘⇧N (safe during text entry, so
    /// never gated on `textEntryActive`); the note steps are ⌥J/⌥K and follow
    /// the same text-entry gate as the other bare-ish keys.
    public var toggleNotesDrawer: () -> Void
    public var nextNote: () -> Void
    public var previousNote: () -> Void
    /// False when the record carries no anchored notes — the step items show
    /// DISABLED rather than silently doing nothing.
    public var notesAvailable: Bool
    /// Drives the toggle item's title (Show vs Hide).
    public var notesDrawerVisible: Bool

    // MARK: - The toolbar's own actions (#253)
    //
    // Eight toolbar buttons had no menu-bar equivalent at all. That was
    // survivable only because the toolbar seeds Icon AND Text: the label under
    // the glyph was the entire affordance, since `.help()` renders no tooltip
    // anywhere in this app on macOS 26 (X60). The design's icon-only toolbar
    // removes that label and justifies it with "every action keeps its
    // menu-bar equivalent" — a claim about this file, which was false. These
    // make it true, and must land BEFORE the display-mode seed flips.
    //
    // Reached through the same focused-value bridge as the navigation
    // commands, for the same reason: a menu key equivalent dispatches through
    // the responder chain rather than depending on a subview holding focus.

    /// Toggle the Editing latch. `isEditing` below already reports its state
    /// and drives the item's title.
    public var toggleEditing: () -> Void

    /// Hold the viewport to a 10 s window so jumps recenter without
    /// re-zooming. A manual zoom releases it.
    public var toggleWindowHold: () -> Void
    /// Drives the item's title (Hold vs Release) — held is a MODE, so the
    /// menu says which way the item will move it.
    public var windowHeldTo10s: Bool

    /// Open the VT/VF candidate scan dialog over the visible window.
    public var scanForVTVF: () -> Void
    /// False for the free viewer — the VT/VF scan is behind an IAP, and the
    /// App-target orchestrator owns the entitlement. The item is HIDDEN rather
    /// than disabled in that case: a disabled item advertises a capability the
    /// analyst has not bought, which is a different message from X32's
    /// "this record cannot support it".
    public var scanAvailable: Bool

    /// Merge a producer's annotations JSON into this recording.
    public var attachFindings: () -> Void

    public var exportReport: () -> Void
    public var exportSnapshot: () -> Void
    public var exportWFDBAnnotations: () -> Void
    /// False when no finding has been confirmed — there is nothing to write.
    /// Shown DISABLED (X32), matching the toolbar menu's own gating.
    public var wfdbExportAvailable: Bool

    /// Show or hide the review queue.
    public var toggleReviewQueue: () -> Void
    /// Drives the item's checkmark.
    public var reviewQueueVisible: Bool

    /// True while a text field (the notes editor) is the first responder. The
    /// App disables the bedside key commands then so typing isn't intercepted.
    public var textEntryActive: Bool
    /// True while the recording is unlocked for editing — the disposition
    /// commands (confirm / dismiss / reset) only act then, matching the
    /// existing C/D/X behavior.
    public var isEditing: Bool

    /// #236 — which trend lanes this record can show, and which are showing.
    ///
    /// The picker used to be a `Menu` in the trend stack's own header. That
    /// header is the last thing in a long scrolling column, so on a short
    /// display the control lands at the bottom edge of the screen and its
    /// dropdown has nowhere to open — it rendered under the Variability
    /// Metrics strip, and XCUI saw no menu items at all. Relocating it inside
    /// the window only moves the edge around; the menu bar is the one surface
    /// that is never near one.
    ///
    /// Empty when no record is loaded, or when the record supports no lanes.
    public var trendLanes: [TrendLaneMenuItem]
    /// Show or hide one lane by id. No-op for an unknown id.
    public var toggleTrendLane: (String) -> Void

    /// #248 — the fiducial layers, moved out of the in-window chip.
    ///
    /// Three states per layer, not two, which is the whole reason this is not
    /// a plain toggle list: a layer can be enabled and rendering, enabled but
    /// SUPPRESSED by the current zoom, or disabled. `FiducialRenderPolicy`
    /// resolves which — the same instance `FiducialOverlay` draws from, so
    /// the menu cannot claim a state the canvas is not honouring. That was
    /// X61's bug and it is not worth reintroducing on a new surface.
    public var fiducialLayers: [FiducialLayerMenuItem]
    /// Toggle one layer by id (`MarkingsFiducialLayer.rawValue`). Enabled but
    /// suppressed stays toggleable: the intent is recorded and takes effect on
    /// zoom-in.
    public var toggleFiducialLayer: (String) -> Void
    /// One sentence naming the binding zoom constraint, or nil when nothing
    /// the analyst enabled is being dropped.
    public var fiducialLayerExplanation: String?

    /// One row of the View ▸ Fiducial Layers menu.
    public struct FiducialLayerMenuItem: Identifiable, Equatable {
        public let id: String
        public let label: String
        /// The analyst's toggle — drives the checkmark.
        public let isEnabled: Bool
        /// False when the zoom is holding this layer back despite it being
        /// enabled. Drives the "hidden at this zoom" suffix.
        public let isRendering: Bool

        public init(id: String, label: String, isEnabled: Bool, isRendering: Bool) {
            self.id = id
            self.label = label
            self.isEnabled = isEnabled
            self.isRendering = isRendering
        }

        /// What the menu row says. Only names the zoom when the analyst has
        /// asked for a layer the canvas is not drawing — a disabled layer is
        /// not "hidden at this zoom", it is just off.
        public var menuTitle: String {
            isEnabled && !isRendering ? "\(label) — hidden at this zoom" : label
        }
    }

    /// One row of the View ▸ Trend Lanes menu.
    public struct TrendLaneMenuItem: Identifiable, Equatable {
        public let id: String
        public let label: String
        public let isVisible: Bool

        public init(id: String, label: String, isVisible: Bool) {
            self.id = id
            self.label = label
            self.isVisible = isVisible
        }
    }

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
        toggleNotesDrawer: @escaping () -> Void = {},
        nextNote: @escaping () -> Void = {},
        previousNote: @escaping () -> Void = {},
        notesAvailable: Bool = false,
        notesDrawerVisible: Bool = false,
        trendLanes: [TrendLaneMenuItem] = [],
        toggleTrendLane: @escaping (String) -> Void = { _ in },
        fiducialLayers: [FiducialLayerMenuItem] = [],
        toggleFiducialLayer: @escaping (String) -> Void = { _ in },
        fiducialLayerExplanation: String? = nil,
        toggleEditing: @escaping () -> Void = {},
        toggleWindowHold: @escaping () -> Void = {},
        windowHeldTo10s: Bool = false,
        scanForVTVF: @escaping () -> Void = {},
        scanAvailable: Bool = false,
        attachFindings: @escaping () -> Void = {},
        exportReport: @escaping () -> Void = {},
        exportSnapshot: @escaping () -> Void = {},
        exportWFDBAnnotations: @escaping () -> Void = {},
        wfdbExportAvailable: Bool = false,
        toggleReviewQueue: @escaping () -> Void = {},
        reviewQueueVisible: Bool = false,
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
        self.toggleNotesDrawer = toggleNotesDrawer
        self.nextNote = nextNote
        self.previousNote = previousNote
        self.notesAvailable = notesAvailable
        self.notesDrawerVisible = notesDrawerVisible
        self.trendLanes = trendLanes
        self.toggleTrendLane = toggleTrendLane
        self.fiducialLayers = fiducialLayers
        self.toggleFiducialLayer = toggleFiducialLayer
        self.fiducialLayerExplanation = fiducialLayerExplanation
        self.toggleEditing = toggleEditing
        self.toggleWindowHold = toggleWindowHold
        self.windowHeldTo10s = windowHeldTo10s
        self.scanForVTVF = scanForVTVF
        self.scanAvailable = scanAvailable
        self.attachFindings = attachFindings
        self.exportReport = exportReport
        self.exportSnapshot = exportSnapshot
        self.exportWFDBAnnotations = exportWFDBAnnotations
        self.wfdbExportAvailable = wfdbExportAvailable
        self.toggleReviewQueue = toggleReviewQueue
        self.reviewQueueVisible = reviewQueueVisible
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
