//
//  TimeDisplayContext.swift
//  MurmurCore
//
//  X28 — whether live time coordinates read as ELAPSED from record start or as
//  WALL-CLOCK time of day.
//
//  An app preference, not document state: an analyst who thinks in time-of-day
//  thinks that way across every record they open. Persisted in UserDefaults,
//  matching `IntervalTrendLaneContext`'s handling of the trend metric and bin.
//
//  THE RULE THIS TYPE EXISTS TO ENFORCE (X32): wall-clock is only ever shown
//  where the recording genuinely carried a start time. The preference may sit at
//  `.wallClock` while the open record has no time base — in that case the
//  EFFECTIVE mode is elapsed, and the toggle is unavailable rather than lying.
//  Callers ask for `effectiveMode(hasAbsoluteStart:)`, never the raw preference.
//

import Foundation
import Observation

@MainActor
@Observable
public final class TimeDisplayContext {

    public static let shared = TimeDisplayContext()

    /// The analyst's PREFERENCE. Not necessarily what is on screen — see
    /// `effectiveMode(hasAbsoluteStart:)`.
    public var mode: ViewportTimeFormat.Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Keys.mode)
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Keys.mode) ?? ""
        self.mode = ViewportTimeFormat.Mode(rawValue: raw) ?? .elapsed
    }

    /// What should actually be rendered for a recording. Wall-clock collapses to
    /// elapsed when the record carries no absolute start — the app does not
    /// invent one (X32).
    public func effectiveMode(hasAbsoluteStart: Bool) -> ViewportTimeFormat.Mode {
        (mode == .wallClock && hasAbsoluteStart) ? .wallClock : .elapsed
    }

    /// True when the toggle should be offered at all. Showing a disabled control
    /// is more honest than showing one that silently does nothing.
    public func isAvailable(hasAbsoluteStart: Bool) -> Bool { hasAbsoluteStart }

    private enum Keys {
        static let mode = "murmur.viewport.timeDisplayMode"
    }
}
