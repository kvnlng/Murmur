//
//  Calibration.swift
//  MurmurCore
//
//  The calibration instrument's shared state + the pure readout computation
//  (X40 / project_calibration_instrument_spec.md). Amplitude and timebase are
//  the north star for cardiac readers; this is the "what am I looking at, in
//  clinical units" surface, and (in later phases) the home position that snaps
//  the view back to standard ECG paper (25 mm/s · 10 mm/mV).
//
//  Phase 1 is the persistent readout only — it reports the ACTUAL current
//  calibration derived from the on-screen geometry, marking non-standard
//  states, and falls back to points-per-mV when the display's physical size
//  can't be trusted (`DisplayMetrics`). Gain control, presets, and the lock
//  land in later phases; the canonical `gain`/`locked` fields grow here.
//

import CoreGraphics
import Foundation

/// Shared calibration state for one recording's bedside view. Gain is SHARED
/// across leads by design (clinical 12-lead printouts use one gain for every
/// lead, and per-lead gain would destroy cross-lead amplitude comparison —
/// the entire purpose of Strips mode), so this is owned once at the
/// `BedsideView` level and threaded down, exactly like `RecordingViewport`.
@MainActor
@Observable
final class Calibration {
    /// Lock-to-standard state. Placeholder in Phase 1; wired to hold
    /// calibration across zoom gestures in a later phase.
    var locked: Bool = false

    /// Geometry + amplitude span published by the FOCUSED channel panel each
    /// layout, so the readout — which renders a level up, beside the viewport
    /// indicator — can convert points → clinical units without reaching into
    /// per-channel state. Only the focus-sized panel writes these.
    var canvasSize: CGSize = .zero
    var visibleMillivoltSpan: Double = 0
}

/// Pure computation of the calibration readout from primitives — no view
/// geometry object, no screen access — so the honesty rule (fall back to
/// points when mm can't be substantiated) and the standard-detection band are
/// unit-testable. `DisplayMetrics` supplies `millimetersPerPoint`; nil means
/// "physical size untrustworthy → print points, claim no mm."
struct CalibrationReading: Equatable {
    /// Clinical ECG paper: 25 mm/s and 10 mm/mV.
    static let standardMillimetersPerSecond: Double = 25
    static let standardMillimetersPerMillivolt: Double = 10

    /// Human-readable readout, e.g. "25 mm/s · 10 mm/mV" /
    /// "50 mm/s · 20 mm/mV · non-standard" /
    /// "132 pt/s · 40 pt/mV · display size unavailable".
    let text: String
    /// True only when both axes sit on standard paper (and we can prove mm).
    let isStandard: Bool
    /// True when the physical size was untrustworthy and we printed points.
    let usesPointFallback: Bool

    static func make(
        windowSeconds: Double,
        canvasWidthPoints: Double,
        canvasHeightPoints: Double,
        visibleMillivoltSpan: Double,
        millimetersPerPoint: Double?
    ) -> CalibrationReading {
        // Degenerate geometry (pre-layout, empty channel) — say nothing false.
        guard windowSeconds > 0, canvasWidthPoints > 0,
              canvasHeightPoints > 0, visibleMillivoltSpan > 0 else {
            return CalibrationReading(text: "—", isStandard: false, usesPointFallback: false)
        }

        let pointsPerSecond = canvasWidthPoints / windowSeconds
        let pointsPerMillivolt = canvasHeightPoints / visibleMillivoltSpan

        guard let mmPerPoint = millimetersPerPoint, mmPerPoint > 0 else {
            // Honesty rule: no trustworthy physical size → print points, and
            // never claim "standard" (we can't verify mm precision).
            let text = "\(fmt(pointsPerSecond)) pt/s · \(fmt(pointsPerMillivolt)) pt/mV · display size unavailable"
            return CalibrationReading(text: text, isStandard: false, usesPointFallback: true)
        }

        let mmPerSecond = pointsPerSecond * mmPerPoint
        let mmPerMillivolt = pointsPerMillivolt * mmPerPoint
        let standard = abs(mmPerSecond - standardMillimetersPerSecond) <= 0.5
            && abs(mmPerMillivolt - standardMillimetersPerMillivolt) <= 0.2

        var text = "\(fmt(mmPerSecond)) mm/s · \(fmt(mmPerMillivolt)) mm/mV"
        if !standard { text += " · non-standard" }
        return CalibrationReading(text: text, isStandard: standard, usesPointFallback: false)
    }

    /// Round to 0.1 and drop a trailing ".0" so clinical values read as
    /// integers (25, 10) and derived values keep one decimal (24.7).
    private static func fmt(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", rounded)
    }
}
