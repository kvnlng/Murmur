//
//  CurrentRecordingContext.swift
//  MurmurCore
//
//  Process-wide "which recording is currently loaded?" state. The
//  main window's ContentView drives it as the analyst opens / closes
//  recordings; auxiliary windows (the ECG Metrics window, future
//  citation-report window, etc.) read from it via
//  `CurrentRecordingContext.shared` and re-render when the recording
//  changes.
//
//  Public so the App target (which is where the app's paid-feature
//  orchestration lives) can observe recording changes without
//  ContentView having to know about downstream consumers — inverting
//  the dependency in the direction that keeps MurmurCore ignorant of
//  the paid frameworks.
//

import Foundation
import Observation

/// Live "current recording" state. `@MainActor` because every UI
/// surface that reads it runs on main, and every ContentView state
/// transition that writes to it is already main-actor isolated.
@MainActor
@Observable
public final class CurrentRecordingContext {

    /// Shared instance the app uses at runtime. Tests should construct
    /// a fresh `CurrentRecordingContext()` to keep parallel runs
    /// isolated from each other and from the app's live state.
    public static let shared = CurrentRecordingContext()

    /// The recording the analyst is currently looking at, or `nil`
    /// when the viewer is showing the welcome screen / browsing a
    /// folder. Auxiliary windows should treat `nil` as their empty
    /// state.
    public private(set) var recording: Recording?

    /// Directory containing the currently-loaded recording's bundle,
    /// for callers that need to read sidecar files (annotations.json,
    /// disposition-store JSON, etc.) alongside the manifest.
    public private(set) var directory: URL?

    /// X59 — the live session snapshot, republished by the bedside view
    /// whenever the analyst moves the viewport, locks the window, or changes
    /// the focused lead. `saveSessionPanel()` reads this at save time: the
    /// state lives in `BedsideView`'s `@State`, which the App target's menu
    /// commands cannot reach directly, so the view publishes it here rather
    /// than the menu reaching in.
    ///
    /// Snapshot only — never the source of truth for what is on screen.
    public var liveSessionState = MurSessionState()

    /// X59 — session state decoded from a `.mur` that has just been opened,
    /// waiting for the bedside view to appear and apply it. The view CONSUMES
    /// this (sets it back to `nil`) so a later re-render can't re-apply a stale
    /// restore over the analyst's own subsequent navigation.
    ///
    /// `nil` for a raw WFDB/CSV import, and for a `.mur` written before session
    /// capture existed — absent must stay absent, never a fabricated default.
    public var pendingSessionRestore: MurSessionState?

    public init() {}

    /// Publish that `recording` is now current, loaded from `directory`.
    public func set(recording: Recording, directory: URL) {
        self.recording = recording
        self.directory = directory
    }

    /// Publish that no recording is currently loaded (welcome screen,
    /// folder-browsing view, etc.).
    public func clear() {
        recording = nil
        directory = nil
        // Don't let one recording's session state leak into the next.
        liveSessionState = MurSessionState()
        pendingSessionRestore = nil
    }
}
