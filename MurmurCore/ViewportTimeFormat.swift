//
//  ViewportTimeFormat.swift
//  MurmurCore
//
//  The ONE human-facing formatter for the viewport time span (X49). Three
//  renderers — the channel header (`time-window-label`), the viewport readout
//  (`viewport-indicator`) and the overview strip — used to print the same
//  window three different ways at three precisions (2 dp seconds / whole m:ss /
//  adaptive decimal-minutes). Decimal minutes is a unit no cardiac reader
//  works in; it existed only because the overview picked its unit by magnitude.
//
//  Decision: `m:ss.d` everywhere the span is printed, `h:mm:ss.d` above an
//  hour, tenths (not hundredths — hundredths jitter under pan). The total
//  duration keeps whole `m:ss` since it is a fixed property of the record, not
//  a live coordinate. Raw seconds at full precision stays available in the
//  docked inspector / on hover — it is what gets pasted into a methods section
//  — but it stops being a third competing headline.
//
//  WALL-CLOCK (X28) is now available alongside elapsed — but ONLY where the
//  source genuinely carried a start time. `wallClock` takes a NON-OPTIONAL
//  `startUnixMillis`, so a caller with nothing to pass cannot call it; that is
//  deliberate. This must never become a second place a synthesised timestamp
//  appears (X32), and a type that cannot express "no time base" is the cheapest
//  guarantee of that.
//
//  Every renderer MUST route through here — three call sites is how the formats
//  drifted apart in the first place.
//

import Foundation

public enum ViewportTimeFormat {

    /// Elapsed time from record start.
    /// - `tenths: true`  → `m:ss.d` (or `h:mm:ss.d` at ≥ 1 h) — a live coordinate.
    /// - `tenths: false` → `m:ss`   (or `h:mm:ss`)            — the fixed total.
    public static func elapsed(_ seconds: Double, tenths: Bool = true) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        // Round to the DISPLAY precision first, so a value like 59.96 rolls into
        // the next minute (→ 1:00.0) instead of formatting as 0:60.0.
        let rounded = tenths ? (clamped * 10).rounded() / 10 : clamped.rounded()
        let hours = Int(rounded / 3600)
        let minutes = Int(rounded.truncatingRemainder(dividingBy: 3600) / 60)
        let secs = rounded.truncatingRemainder(dividingBy: 60)

        if hours > 0 {
            return tenths
                ? String(format: "%d:%02d:%04.1f", hours, minutes, secs)
                : String(format: "%d:%02d:%02d", hours, minutes, Int(secs))
        }
        return tenths
            ? String(format: "%d:%04.1f", minutes, secs)
            : String(format: "%d:%02d", minutes, Int(secs))
    }

    // MARK: - Wall-clock (X28)

    /// How a live time coordinate is rendered. Elapsed is always available;
    /// wall-clock requires the recording to carry a real start time.
    public enum Mode: String, Sendable, Codable, CaseIterable {
        case elapsed
        case wallClock

        public var label: String {
            switch self {
            case .elapsed:   return "Elapsed"
            case .wallClock: return "Time of day"
            }
        }
    }

    /// Absolute time of day at `seconds` into the recording — `HH:mm:ss.d`, or
    /// `HH:mm:ss` for a fixed quantity.
    ///
    /// `startUnixMillis` is non-optional ON PURPOSE: there is no wall-clock for a
    /// recording without a base time, and the X32 rule is that we never
    /// substitute the system clock. A caller who cannot supply a real base must
    /// render `elapsed` instead — see `coordinate(_:mode:startUnixMillis:)`,
    /// which encodes that fallback once so no call site has to remember it.
    ///
    /// Rendered in the LOCAL time zone: the analyst reads a clock, and a record
    /// annotated "14:32" was annotated in somebody's local afternoon.
    public static func wallClock(_ seconds: Double,
                                 startUnixMillis: Int64,
                                 tenths: Bool = true) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        // Round to display precision BEFORE converting, so 59.96 s rolls the
        // clock into the next second rather than printing :60.0.
        let rounded = tenths ? (clamped * 10).rounded() / 10 : clamped.rounded()
        let whole = rounded.rounded(.down)
        let date = Date(timeIntervalSince1970: Double(startUnixMillis) / 1000.0 + whole)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0, s = c.second ?? 0
        guard tenths else { return String(format: "%02d:%02d:%02d", h, m, s) }
        let frac = Int(((rounded - whole) * 10).rounded()) % 10
        return String(format: "%02d:%02d:%02d.%d", h, m, s, frac)
    }

    /// The one entry point a renderer should use for a live coordinate. Falls
    /// back to elapsed whenever wall-clock is asked for but unavailable, so the
    /// "never fabricate" rule lives HERE rather than at every call site.
    public static func coordinate(_ seconds: Double,
                                  mode: Mode,
                                  startUnixMillis: Int64?,
                                  tenths: Bool = true) -> String {
        if mode == .wallClock, let base = startUnixMillis {
            return wallClock(seconds, startUnixMillis: base, tenths: tenths)
        }
        return elapsed(seconds, tenths: tenths)
    }

    /// Just the window: `start–end` (no total). For the channel header.
    public static func window(startSeconds: Double, endSeconds: Double) -> String {
        "\(elapsed(startSeconds))–\(elapsed(endSeconds))"
    }

    /// The full readout: `start–end of total`. For the viewport indicator.
    public static func span(startSeconds: Double, endSeconds: Double, totalSeconds: Double) -> String {
        "\(elapsed(startSeconds))–\(elapsed(endSeconds)) of \(elapsed(totalSeconds, tenths: false))"
    }
}
