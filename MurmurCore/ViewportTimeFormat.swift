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
//  ELAPSED FROM RECORD START ONLY. Absolute wall-clock stays gated on X28's
//  optional time base + X32's fabricated-start fix; this must never become a
//  second place a synthesised timestamp appears.
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

    /// Just the window: `start–end` (no total). For the channel header.
    public static func window(startSeconds: Double, endSeconds: Double) -> String {
        "\(elapsed(startSeconds))–\(elapsed(endSeconds))"
    }

    /// The full readout: `start–end of total`. For the viewport indicator.
    public static func span(startSeconds: Double, endSeconds: Double, totalSeconds: Double) -> String {
        "\(elapsed(startSeconds))–\(elapsed(endSeconds)) of \(elapsed(totalSeconds, tenths: false))"
    }
}
