//
//  FiducialGeometry.swift
//  MurmurCore
//
//  Whether fiducial letter tags fit at this zoom (#249).
//
//  Split out of the view for the reason X61's summary was: a rule nobody can
//  test is how a control comes to lie. The overlay's own copy of this would be
//  reachable only through XCUI at specific window sizes, which is exactly the
//  geometry-dependent testing that has been the least reliable thing in this
//  project's suite (#231, #236, #277).
//

import CoreGraphics

public enum FiducialGeometry {

    /// Whether a set of letter positions can all be drawn without touching.
    ///
    /// Takes the ACTUAL x-positions the overlay is about to draw rather than
    /// modelling them from heart rate and window length. The modelled version
    /// was written first and was wrong in a way worth recording: it assumed one
    /// letter per BOUNDARY, so the binding constraint was a QRS complex's own
    /// onset→offset width (~90 ms). At a 3 s window over 800 pt that is 24 pt,
    /// and a 13 pt "QRS" tag is about 26 pt wide — so letters could not be
    /// drawn at the very zoom they exist for.
    ///
    /// One letter per LAYER per beat, centred between that layer's two ticks,
    /// fixes it: the ticks still mark the edges precisely and the letter names
    /// the wave once. But the spacing that then matters is between DIFFERENT
    /// letters — P to QRS within a beat (~120 ms), or QRS to the next beat's
    /// QRS when only QRS draws (~1 s) — and those depend on the record's own
    /// rhythm, not on a constant. So the positions are measured.
    ///
    /// Sorted internally: callers build positions per beat and per layer, which
    /// is not x-order.
    public static func lettersFit(
        positions: [CGFloat],
        minimumSpacing: CGFloat = FiducialPalette.letterMinimumSpacing
    ) -> Bool {
        guard positions.count > 1 else { return !positions.isEmpty }
        let sorted = positions.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            if b - a < minimumSpacing { return false }
        }
        return true
    }

    /// Midpoint of a layer's two boundaries, where its letter goes.
    ///
    /// Nil when either edge is off-viewport: half a span gives a midpoint that
    /// is not the middle of anything, and a letter drifting away from the wave
    /// it names is worse than an absent one.
    public static func letterPosition(onsetX: CGFloat?, offsetX: CGFloat?) -> CGFloat? {
        guard let onsetX, let offsetX else { return nil }
        return (onsetX + offsetX) / 2
    }
}
