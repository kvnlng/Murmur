//
//  WaveformZoomTier.swift
//  MurmurCore
//
//  Semantic zoom tier for the waveform rendering, keyed on
//  `pointsPerBeat` per project_waveform_zoom_lod_spec.md. A single beat
//  is only correctly rendered as an individually resolved P-QRS-T
//  complex while it gets enough on-screen points to be legible; below
//  that, "one line per beat" stops meaning *a beat is here* and starts
//  meaning *this column is occupied* → the vertical-smear regression the
//  spec's Move A + Move B remove.
//
//  The tier is a pure function of pointsPerBeat and the CURRENT tier
//  (for hysteresis). Callers drive their rendering off the tier — the
//  annotation-rail chip visibility, the fiducial detail level, whether
//  the density lane appears beneath the trace, etc. — without duplicating
//  the threshold math.
//
//  Not `WaveformCanvas`-specific: the same tier is used by overlays
//  drawn on top of the canvas (chips, fiducial ticks, category
//  landmarks) so every surface stays in lockstep with what the trace
//  itself is showing.
//

import Foundation

/// Three-regime semantic zoom for the waveform view. Peer of
/// `MarkingsDetailLevel` (which drives the fiducial overlay's P/QRS/T
/// detail), but keyed on the different metric that matters for the
/// annotation rail + envelope switch.
public enum WaveformZoomTier: String, Sendable, Equatable, CaseIterable {
    /// pointsPerBeat ≥ inspectEnter. Trace shows full P-QRS-T on the
    /// ECG-paper grid; rail shows per-beat chips; fiducials + brackets
    /// as ususal. Focus beat gets the full-height locator line.
    case inspect
    /// inspectExit ≤ pointsPerBeat < inspectEnter (with hysteresis
    /// against context). Beats still individually resolved but too
    /// tight for chips; rail switches to hairline top-ticks for normals
    /// + colored ticks for flagged categories. Focus keeps its label.
    case scan
    /// pointsPerBeat ≤ contextEnter. Per-beat rules become a
    /// column-occupation smear; the trace renders as a min/max envelope
    /// silhouette. Rail collapses: rare categories become individually
    /// locatable landmarks; the bulk category collapses into a thin
    /// density lane beneath the trace. Focus still shows its locator.
    case context
}

/// Threshold + hysteresis math for `WaveformZoomTier` selection.
/// Extracted from any rendering call so it's unit-testable and
/// deterministic — no rendering state, no view geometry, just numbers.
///
/// Thresholds retuned 2026-07-07 after Kevin's real-workflow test: at a
/// typical Mac canvas (~1000 pt), 20 beats visible resolves to
/// ~50 pt/beat, and the spec's original 24/20 boundaries left that
/// zoom in Inspect (pink paper still on) even though the mockup's
/// rough "≈ 2–17 s window → Inspect" guidance meant it should be
/// Scan. The spec explicitly sanctions retuning
/// (project_waveform_zoom_lod_spec.md: "Thresholds below are starting
/// values … revisable pre-users").
public enum WaveformZoomTierSelector {
    /// Enter Inspect at ≥ 70 points/beat — corresponds to ≲ 14 beats in
    /// a 1000 pt canvas, i.e. the "few beats, individually readable"
    /// regime the mockup illustrates.
    public static let inspectEnter: Double = 70
    /// Drop out of Inspect only below 60 points/beat (hysteresis band).
    public static let inspectExit: Double = 60
    /// Drop into Context at ≤ 8 points/beat — corresponds to ≳ 125
    /// beats in a 1000 pt canvas, i.e. the "column-occupation smear"
    /// regime the envelope silhouette answers.
    public static let contextEnter: Double = 8
    /// Leave Context only above 12 points/beat (hysteresis band).
    public static let contextExit: Double = 12

    /// Pure function: given the current tier + a fresh `pointsPerBeat`
    /// reading, return the next tier. The hysteresis bands (20–24 and
    /// 6–8) prevent strobing between renderings when the analyst
    /// zooms slowly across a threshold.
    ///
    /// `pointsPerBeat` is expected to be positive and finite. Non-finite
    /// or non-positive inputs (no beats in window, empty recording)
    /// preserve the current tier — no reason to force a switch on
    /// missing data.
    public static func select(
        pointsPerBeat: Double,
        current: WaveformZoomTier
    ) -> WaveformZoomTier {
        guard pointsPerBeat.isFinite, pointsPerBeat > 0 else {
            return current
        }
        switch current {
        case .inspect:
            if pointsPerBeat < inspectExit {
                return pointsPerBeat <= contextEnter ? .context : .scan
            }
            return .inspect
        case .scan:
            if pointsPerBeat >= inspectEnter { return .inspect }
            if pointsPerBeat <= contextEnter { return .context }
            return .scan
        case .context:
            if pointsPerBeat > contextExit {
                return pointsPerBeat >= inspectEnter ? .inspect : .scan
            }
            return .context
        }
    }

    /// Cold-start tier for a viewport where no prior tier is known.
    /// Uses hard thresholds (no hysteresis) since there's no direction
    /// of motion to prefer. Callers should feed this the very first
    /// `pointsPerBeat` reading and store the result as the tier from
    /// then on.
    public static func initial(pointsPerBeat: Double) -> WaveformZoomTier {
        guard pointsPerBeat.isFinite, pointsPerBeat > 0 else {
            return .context
        }
        if pointsPerBeat >= inspectEnter { return .inspect }
        if pointsPerBeat <= contextEnter { return .context }
        return .scan
    }

    /// Convenience for callers that already have raw viewport
    /// measurements: computes `plotWidthPoints / beatsInWindow`,
    /// guarding against divide-by-zero. Returns a non-finite value
    /// when there are no beats — `select(pointsPerBeat:current:)`
    /// treats that as "preserve tier."
    public static func pointsPerBeat(
        plotWidthPoints: Double,
        beatsInWindow: Int
    ) -> Double {
        guard beatsInWindow > 0, plotWidthPoints > 0 else { return .nan }
        return plotWidthPoints / Double(beatsInWindow)
    }
}
