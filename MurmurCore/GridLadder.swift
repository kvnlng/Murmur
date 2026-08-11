//
//  GridLadder.swift
//  MurmurCore
//
//  The grid "ruler" for the waveform stage (X37 /
//  project_grid_ladder_and_wheel_navigation.md). Computed per frame from the
//  viewport's OWN governing metrics — pointsPerSecond and pointsPerMillivolt —
//  and DELIBERATELY independent of the `WaveformZoomTier` (LOD).
//
//  Why decoupled from the LOD tier:
//    • The grid is a ruler over time and amplitude. Keying it on
//      `pointsPerBeat` (a heart-rate-dependent metric) means two records at
//      the same seconds-per-screen lose their grid at different zooms.
//    • A ruler should COARSEN, not vanish. Red ECG-paper hands off to a
//      neutral wall-clock scale, which is never off — so the "white flash"
//      when the LOD tier left Inspect disappears structurally rather than
//      by tuning.
//
//  Two ink families:
//    • Red — calibrated ECG paper: 0.04 s / 0.20 s horizontally, 0.1 mV /
//      0.5 mV vertically. Red means "you may measure against this." Once the
//      paper tiers are no longer legible red has nothing to assert and leaves.
//    • Neutral — wall-clock scale: 1 s → 10 s → 60 s → 10 min → 1 h. Never
//      off; the major tier is always drawn and carries the axis label.
//
//  Selection rule (mockup Planning/design/grid-ladder.html):
//    • A tier ramps opacity 0 → full across 3 pt → 7 pt of on-screen spacing;
//      below 3 pt it is culled. This is a continuous opacity ramp, NOT the
//      discrete LOD hysteresis band — hysteresis on continuous ink would
//      reproduce exactly the snap being fixed.
//    • The neutral major is the largest tier with ≥ 2 divisions on screen.
//    • The amplitude family fades on its OWN metric, so horizontal red rules
//      persist through a wide TIME zoom while the vertical ones go.
//

import Foundation

/// Per-frame description of every gridline family/tier that should be inked,
/// with the opacity each carries. Pure value type: no rendering, no view
/// geometry beyond the point measurements handed in — so it's unit-testable.
public struct GridLadder: Equatable, Sendable {
    public enum Family: Equatable, Sendable {
        /// Calibrated ECG-paper, vertical lines, spacing in seconds.
        case redTime
        /// Calibrated ECG-paper, horizontal lines, spacing in millivolts.
        case redAmplitude
        /// Wall-clock scale, vertical lines, spacing in seconds.
        case neutralTime
    }

    public struct Tier: Equatable, Sendable {
        public let family: Family
        /// Seconds (time families) or millivolts (amplitude family).
        public let spacing: Double
        /// On-screen spacing of this tier, in points.
        public let onScreenPoints: Double
        /// Final opacity 0...1 — the ramp, folded with the tier weight and
        /// (for a non-major neutral tier) the minor-ink dim.
        public let alpha: Double
        /// The neutral tier that carries the axis label. Always false for the
        /// red families and for minor neutral tiers.
        public let isMajor: Bool
    }

    /// Tiers with `alpha > 0` only. Callers ink them; nothing here is a
    /// "switch it off" decision — a tier is simply absent when its spacing
    /// fell below the cull threshold.
    public let tiers: [Tier]

    /// Largest neutral tier with ≥ 2 divisions on screen — the time axis
    /// places its elapsed-time labels on this tier so labels sit on the same
    /// gridlines the renderer draws as major.
    public let majorNeutralSeconds: Double

    /// 0...1: how present the calibrated red TIME grid is. The paper
    /// background crossfades pink → neutral by this, so the ECG-paper surface
    /// hands off to a plain one as the time ruler leaves (~60–75 s window)
    /// rather than the trace landing on a hard white flash. Keyed on the time
    /// family only: the amplitude red rules persist on their own metric and
    /// draw over a neutral surface once time is no longer calibrated.
    public let redPresence: Double

    /// X16 — the same ladder with amplitude-family spacings mapped into the
    /// renderer's STORED-unit data space (spacing ÷ factor). The renderer
    /// bakes red amplitude rules in the same coordinate space as its
    /// yMin/yMax uniforms; with a gain reinterpretation those uniforms are
    /// stored units while the ladder's tiers are TRUE millivolts, so the
    /// rules must be converted at the same boundary or a "0.5 mV square"
    /// would silently be 0.5 × factor mV tall. Alphas and on-screen spacings
    /// are geometry facts and stay put; time families are untouched.
    public func amplitudeSpacingScaled(dividedBy factor: Double) -> GridLadder {
        guard factor.isFinite, factor > 0, factor != 1 else { return self }
        return GridLadder(
            tiers: tiers.map { tier in
                guard tier.family == .redAmplitude else { return tier }
                return Tier(family: tier.family,
                            spacing: tier.spacing / factor,
                            onScreenPoints: tier.onScreenPoints,
                            alpha: tier.alpha,
                            isMajor: tier.isMajor)
            },
            majorNeutralSeconds: majorNeutralSeconds,
            redPresence: redPresence)
    }

    // MARK: - Ladder definition

    /// A tier is culled below this on-screen spacing (points)…
    public static let cullPoints: Double = 3
    /// …and reaches full ink at this spacing. Linear ramp in between.
    public static let fullPoints: Double = 7

    /// Calibrated ECG-paper time tiers: 0.04 s (one small square) and 0.20 s
    /// (one large square). The weight biases the coarse tier heavier so the
    /// fine grid reads as a subordinate hatch.
    static let redTimeTiers: [(seconds: Double, weight: Double)] =
        [(0.04, 0.55), (0.20, 1.0)]
    static let redAmplitudeTiers: [(millivolts: Double, weight: Double)] =
        [(0.1, 0.55), (0.5, 1.0)]
    /// Wall-clock neutral tiers, 1 s → 1 h.
    static let neutralTimeTiers: [Double] = [1, 10, 60, 600, 3600]
    /// Fraction of full ink a non-major neutral tier carries.
    static let neutralMinorInk: Double = 0.42

    /// Opacity a tier carries at a given on-screen spacing. 0 below the cull
    /// threshold, ramping linearly to 1 at the full-ink threshold.
    public static func ramp(spacingPoints s: Double) -> Double {
        guard s > cullPoints else { return 0 }
        return min(1, (s - cullPoints) / (fullPoints - cullPoints))
    }

    /// Largest neutral tier with ≥ 2 divisions across `windowSeconds`. Pure
    /// function of the window (not the pixel width) so the time axis can call
    /// it to align its labels without knowing the plot geometry. Defaults to
    /// the finest tier when even it has < 2 divisions (very tight zoom).
    public static func neutralMajorSeconds(windowSeconds: Double) -> Double {
        var major = neutralTimeTiers[0]
        for tier in neutralTimeTiers where windowSeconds / tier >= 2 { major = tier }
        return major
    }

    /// Coarsest calibrated amplitude tier with ≥ 2 divisions across
    /// `windowMillivolts`; the voltage axis labels this tier so its labels sit
    /// on the calibrated horizontal rules. Independent of the time zoom.
    public static func redAmplitudeMajorMillivolts(windowMillivolts: Double) -> Double {
        var major = redAmplitudeTiers[0].millivolts
        for tier in redAmplitudeTiers where windowMillivolts / tier.millivolts >= 2 {
            major = tier.millivolts
        }
        return major
    }

    /// Build the ladder for one frame.
    /// - Parameters:
    ///   - windowSeconds: visible time span.
    ///   - windowMillivolts: visible amplitude span (`displayMax - displayMin`).
    ///   - plotWidthPoints: chart width in points (NOT drawable pixels).
    ///   - plotHeightPoints: chart height in points.
    public static func compute(
        windowSeconds: Double,
        windowMillivolts: Double,
        plotWidthPoints: Double,
        plotHeightPoints: Double
    ) -> GridLadder {
        guard windowSeconds > 0, plotWidthPoints > 0 else {
            return GridLadder(
                tiers: [],
                majorNeutralSeconds: neutralTimeTiers[0],
                redPresence: 0
            )
        }

        let pointsPerSecond = plotWidthPoints / windowSeconds
        let pointsPerMillivolt = (windowMillivolts > 0 && plotHeightPoints > 0)
            ? plotHeightPoints / windowMillivolts
            : 0

        var tiers: [Tier] = []
        var redTimeAlpha = 0.0

        // Red — time (own metric: pointsPerSecond). Drives the paper crossfade.
        for tier in redTimeTiers {
            let spacing = tier.seconds * pointsPerSecond
            let alpha = ramp(spacingPoints: spacing) * tier.weight
            redTimeAlpha = max(redTimeAlpha, alpha)
            if alpha > 0 {
                tiers.append(Tier(family: .redTime, spacing: tier.seconds,
                                  onScreenPoints: spacing, alpha: alpha, isMajor: false))
            }
        }

        // Red — amplitude (own metric: pointsPerMillivolt). Persists through a
        // wide time zoom, so it does NOT hold the paper pink.
        for tier in redAmplitudeTiers {
            let spacing = tier.millivolts * pointsPerMillivolt
            let alpha = ramp(spacingPoints: spacing) * tier.weight
            if alpha > 0 {
                tiers.append(Tier(family: .redAmplitude, spacing: tier.millivolts,
                                  onScreenPoints: spacing, alpha: alpha, isMajor: false))
            }
        }

        // Neutral — time. The major tier is always eligible (so the ruler
        // never fully leaves); minor tiers appear only with ≥ 2 divisions.
        let major = neutralMajorSeconds(windowSeconds: windowSeconds)
        for tier in neutralTimeTiers {
            let divisions = windowSeconds / tier
            let isMajor = tier == major
            guard divisions >= 2 || isMajor else { continue }
            let spacing = tier * pointsPerSecond
            var alpha = ramp(spacingPoints: spacing)
            if !isMajor { alpha *= neutralMinorInk }
            if alpha > 0 {
                tiers.append(Tier(family: .neutralTime, spacing: tier,
                                  onScreenPoints: spacing, alpha: alpha, isMajor: isMajor))
            }
        }

        return GridLadder(
            tiers: tiers,
            majorNeutralSeconds: major,
            redPresence: min(1, max(0, redTimeAlpha))
        )
    }
}
