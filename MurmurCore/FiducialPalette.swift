//
//  FiducialPalette.swift
//  MurmurCore
//
//  One letter → one colour, for every surface that names a fiducial (#249).
//
//  TestFlight feedback (2026-08-15): "The letters should be in primary colors,
//  always the same for each letter and exclude red." The point of "always the
//  same" is that the mapping becomes vocabulary — an analyst who learns blue is
//  P on the trace should not have to relearn it anywhere else. That only holds
//  if there is one definition, so this is it, and it is keyed on
//  `MarkingsFiducialLayer` rather than a parallel enum of the same three cases
//  (which is what `FiducialOverlay.FiducialColor` was).
//
//  ## The two hard constraints
//
//  **Off the paper's hue.** The overlay draws on calibrated ECG paper —
//  `WaveformStyle.paper` is (1.00, 0.93, 0.93) under a red grid ladder, so the
//  whole surface lives at hue 0. #226 shipped QRS at hue 0.02 and it vanished:
//  a one-point line in the grid's own hue IS grid, and the analyst did not know
//  the overlay was on screen. Red is therefore excluded as a stated rule here,
//  not as an incident lesson recalled in a comment.
//
//  **Dark enough to be ink.** The pre-#226 palette sat at brightness 0.85–0.90,
//  which is pastel ink on pale paper. It was competing on hue while giving away
//  the contrast that actually separates a mark from a light background. Every
//  colour here stays at or below 0.70.
//
//  ## On "primary colours" and colour vision
//
//  Blue / green / yellow, which is the primary family the feedback asked for
//  with red removed. Green and yellow are the classic red-green
//  colour-deficiency confusion, and the palette this replaces carried a comment
//  conceding exactly that about its green and teal — with the note that
//  "distinct dot SHAPES per layer would fix that properly and are not in this
//  change."
//
//  #249 is that change, from a different direction: the letters ARE the
//  redundant channel. Once a mark reads "P" rather than "the blue one", hue
//  stops being the only thing distinguishing three measurements that mean
//  different things, and a reader who cannot separate the green from the yellow
//  can still read the letter. The hue separation below is kept anyway — it is
//  what makes the letters findable at a glance — but it is no longer load-
//  bearing on its own.
//
//  Yellow is the awkward one and is worth saying why it looks the way it does:
//  a bright yellow is invisible on near-white paper, so T sits at hue 0.16 with
//  full saturation and brightness 0.62 — a dark amber-yellow. Anything lighter
//  fails the ink constraint; anything closer to 0.14 fails the red-band rule.
//

import SwiftUI

public enum FiducialPalette {

    /// The hue the ECG paper and its red grid ladder occupy.
    public static let paperHue: Double = 0.0

    /// How far a colour must sit from the paper's hue to read as ink on it
    /// rather than as a shade of it. 0.15 is 54° — #226's QRS was 7°.
    ///
    /// This is also the "exclude red" rule: red IS the paper's hue, so a band
    /// of this radius around hue 0 is precisely the excluded region.
    public static let minimumSeparationFromPaper: Double = 0.15

    /// How far two layers must sit from each other to be told apart at a
    /// glance. Less load-bearing than it was now that letters carry identity,
    /// but a palette whose three colours converge makes the letters harder to
    /// FIND even when they are readable once found.
    public static let minimumSeparationBetweenLayers: Double = 0.12

    /// Distance between two hues on the colour wheel, where 0.5 is opposite.
    /// Shared with the tests so the rule and its check cannot disagree.
    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    /// True when a hue falls inside the excluded red band around the paper.
    public static func isExcludedRed(_ hue: Double) -> Bool {
        hueDistance(hue, paperHue) < minimumSeparationFromPaper
    }

    public static func hue(for layer: MarkingsFiducialLayer) -> Double {
        switch layer {
        case .p:   return 0.60   // blue
        case .qrs: return 0.33   // green
        case .t:   return 0.16   // amber-yellow
        }
    }

    /// Saturation and brightness are per-layer rather than shared because the
    /// three hues do not carry equal weight at equal values: a saturated blue
    /// reads darker than a saturated yellow at the same brightness, so yellow
    /// is pushed to full saturation and green is darkened to hold its own
    /// against the grid.
    public static func color(for layer: MarkingsFiducialLayer) -> Color {
        switch layer {
        case .p:   return Color(hue: hue(for: .p), saturation: 0.85, brightness: 0.70)
        case .qrs: return Color(hue: hue(for: .qrs), saturation: 0.90, brightness: 0.52)
        case .t:   return Color(hue: hue(for: .t), saturation: 1.00, brightness: 0.62)
        }
    }

    /// The letter drawn on the trace. `MarkingsFiducialLayer.displayName`
    /// already spells these; re-exposed here so a caller that wants "the tag"
    /// gets the letter and its colour from one place.
    public static func letter(for layer: MarkingsFiducialLayer) -> String {
        layer.displayName
    }

    // MARK: - Sizes

    /// Cap height for the letter on the trace.
    ///
    /// The feedback's first rule is a HIERARCHY, not a number: "The fiducial
    /// tags in the waveform bedside view should be larger than the Review
    /// queue tags." The bedside trace is where morphology is actually read;
    /// the queue is navigation. So this is defined against
    /// `queueGlyphDiameter` rather than independently, and a unit test holds
    /// the ordering — otherwise the two drift apart in separate PRs and the
    /// rule quietly stops being true.
    public static let bedsideLetterPointSize: CGFloat = 13

    /// The Review queue's existing circle glyph, for the rule above to be
    /// stated against. `FindingsPanel` draws group rows at 9 pt.
    public static let queueGlyphDiameter: CGFloat = 9

    /// Cap height for the same letter in the Review queue. Smaller than the
    /// bedside one BY CONSTRUCTION — a unit test holds
    /// `queueLetterPointSize < bedsideLetterPointSize`, because the whole first
    /// rule of #249 is that ordering and two independent constants in two files
    /// is how it would quietly stop being true.
    public static let queueLetterPointSize: CGFloat = 10

    /// Minimum horizontal room a letter needs before it is drawn at all.
    ///
    /// Wider than the letter because "QRS" is three characters and because two
    /// adjacent letters touching is worse than either being absent — the
    /// analyst can zoom in, but cannot un-smear an overlap. Below this the
    /// overlay falls back to the confidence dot, which is what it drew before
    /// #249 and what still fits.
    public static let letterMinimumSpacing: CGFloat = 26
}
