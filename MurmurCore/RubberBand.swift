//
//  RubberBand.swift
//  MurmurCore
//
//  Apple's UIKit scroll-view rubber-band damping curve, extracted so the
//  pan gesture's overscroll math has a testable home outside the
//  SwiftUI view that consumes it.
//
//  Used by `BedsideView`'s drag handler: when the user pulls past a
//  viewport boundary, the excess pixel distance is fed through this
//  curve and applied as a translation on the chart content. The chart
//  visibly trails the cursor with diminishing return — the iOS elastic
//  edge feel — and springs back when the gesture ends.
//

import CoreGraphics
import Foundation

enum RubberBand {

    /// Damping coefficient. `0.55` matches UIKit's scroll-view rubber-band
    /// feel; smaller values produce more resistance, larger values more
    /// "stretch" per pixel of pull.
    static let dampingCoefficient: CGFloat = 0.55

    /// Apple's documented rubber-band damping curve. Input is the raw
    /// pixel distance pulled past the boundary (signed); output is the
    /// visible translation that the chart should apply. Asymptotically
    /// approaches `canvasWidth`, so the chart never fully leaves the
    /// visible area no matter how hard the analyst pulls.
    ///
    /// Formula: `y = (1 - 1 / (|x| * c / d + 1)) * d`, with the sign of
    /// the input preserved.
    ///
    /// - Parameters:
    ///   - overshoot: signed pixel distance pulled past the boundary.
    ///     Positive means pulling past the left edge (chart should
    ///     shift right); negative means pulling past the right edge.
    ///   - canvasWidth: width of the chart canvas in points. The curve
    ///     saturates at this value so the chart never fully scrolls
    ///     off-screen.
    /// - Returns: the damped translation to apply, in points, with the
    ///   sign of `overshoot` preserved. Returns 0 if `canvasWidth` is
    ///   non-positive (no canvas to damp against).
    static func damp(overshoot: CGFloat, canvasWidth: CGFloat) -> CGFloat {
        guard canvasWidth > 0 else { return 0 }
        let absOvershoot = abs(overshoot)
        let sign: CGFloat = overshoot >= 0 ? 1 : -1
        let damped = (1 - 1 / (absOvershoot * dampingCoefficient / canvasWidth + 1)) * canvasWidth
        return damped * sign
    }
}
