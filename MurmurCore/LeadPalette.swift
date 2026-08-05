//
//  LeadPalette.swift
//  MurmurCore
//
//  Trace inks for the focus-stage lead overlay (X64-C).
//
//  ## The rule this file exists to enforce
//
//  The colour budget on the trace surface was already spent before X64 arrived.
//  `CategoryPalette` holds reds/magentas (ventricular), purples (atrial), blues
//  (conduction) and grey-teals (noise/paced); amber is reserved for
//  analyst-marked findings; `FiducialOverlay` colours marks by P/QRS/T. Adding
//  lead colours on top of that is exactly how the amber overload happened — one
//  ink, four meanings — so lead colour is admitted under a rule:
//
//      Anything drawn AS the signal is low-chroma.
//      Anything drawn BECAUSE it means something is high-chroma.
//
//  Inks are therefore declared in HSV rather than as RGB literals, so the
//  ceiling the rule imposes (`maxSaturation` / `maxValue`) is a property the
//  source states and a test can read back. An RGB literal would let a later
//  hand-tweak drift over the line invisibly.
//
//  ## Why the ceiling beats a distance check
//
//  `CategoryPalette.color(for:)` falls back to a hash-derived hue at s = 0.65,
//  v = 0.70 for any category it doesn't recognise — so a mark can be ANY hue.
//  Checking distance from the named entries alone would miss that entirely. The
//  chroma/value ceiling separates every lead ink from that whole family at once,
//  whatever hue the hash lands on. The per-entry distances are checked too, but
//  the ceiling is the guarantee.
//

import Foundation
import simd
import SwiftUI

/// One trace ink: an HSV declaration plus the forms the renderer and SwiftUI
/// need. The colour name is carried for VoiceOver — an analyst who can't
/// separate the inks by eye still gets told which is which.
struct LeadInk: Equatable, Sendable {
    /// Human-readable ink name, e.g. "dark olive". Spoken, not drawn.
    let name: String
    /// Hue in degrees, 0..<360.
    let hue: Double
    let saturation: Double
    let value: Double

    var rgb: (r: Double, g: Double, b: Double) {
        LeadPalette.hsvToRGB(hue: hue, saturation: saturation, value: value)
    }

    var simd: SIMD4<Float> {
        let (r, g, b) = rgb
        return SIMD4(Float(r), Float(g), Float(b), 1.0)
    }

    var color: Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

enum LeadPalette {

    /// Chroma ceiling for anything drawn as signal. `CategoryPalette`'s
    /// hash fallback sits at s = 0.65; marks live above this line, traces below.
    static let maxSaturation: Double = 0.35

    /// Value ceiling — and the reason it is this low is worth stating, because
    /// the ratified spec got it wrong.
    ///
    /// §3 of `project_lead_overlay_focus_spec.md` says the mark palette is
    /// uniformly high-chroma, so keeping traces low-chroma would be enough on
    /// its own. It isn't. `CategoryPalette`'s noise/paced/unknown entries are
    /// ALREADY low-chroma greys — `"/"` (paced) is s = 0.33, `"Q"`/`"?"`
    /// (unknown) are pure grey at v = 0.55. A low-chroma lead ink is therefore
    /// separated from the reds, purples and blues but sits right on top of the
    /// greys. Measured: a v = 0.55 ink landed ΔE 15.4 from paced.
    ///
    /// So chroma is not the only axis doing the work — LIGHTNESS carries it
    /// too. Every trace ink is darker than the darkest mark colour (v = 0.55),
    /// with room to spare. Traces are dark ink on paper; marks are lighter and
    /// more saturated. Two axes, both asserted.
    static let maxValue: Double = 0.34

    /// The darkest colour `CategoryPalette` can produce — pure grey `"Q"`/`"?"`.
    /// `maxValue` sits below this by design; the test pins the relationship.
    static let darkestMarkValue: Double = 0.55

    /// The primary lead is pure black — `WaveformStyle.trace` unchanged, so the
    /// single-lead stage renders exactly as it did before X64 existed.
    static let primaryInk = LeadInk(name: "black", hue: 0, saturation: 0, value: 0)

    /// Inks for overlaid leads, handed out by SELECTION ORDER (never by lead
    /// name — WFDB sources don't agree on a closed set of lead names, so a
    /// name-keyed palette would have no entry for the first unfamiliar record
    /// anyone opens).
    ///
    /// Hues are spread around the wheel and the values are staggered, because
    /// four inks all sitting at the same lightness would be separable from the
    /// marks but not from each other.
    static let secondaryInks: [LeadInk] = [
        LeadInk(name: "dark olive",  hue: 62,  saturation: 0.34, value: 0.32),
        LeadInk(name: "dark indigo", hue: 248, saturation: 0.35, value: 0.34),
        LeadInk(name: "dark maroon", hue: 352, saturation: 0.33, value: 0.31),
        LeadInk(name: "dark teal",   hue: 186, saturation: 0.32, value: 0.29),
    ]

    /// Ink for a lead at `rank` in the selection (0 = primary).
    ///
    /// Cycles once the selection outruns the palette. Repeating an ink is worse
    /// than the alternatives only if colour were the sole discriminator — it
    /// isn't: every trace carries an edge label and a legend row. Refusing to
    /// draw the 6th lead would be worse.
    static func ink(rank: Int) -> LeadInk {
        guard rank > 0 else { return primaryInk }
        return secondaryInks[(rank - 1) % secondaryInks.count]
    }

    // MARK: - Reserved meaning colours

    /// Analyst-marked findings. Mirrors the `Color.orange` used by
    /// `IntervalTrendLane`; pinned here as sRGB so the separation test has a
    /// concrete value to measure against rather than a system colour that can
    /// shift under it.
    static let analystAmber = SIMD4<Float>(1.00, 0.58, 0.00, 1.0)

    /// Saturation and value of `CategoryPalette`'s hash fallback. Any
    /// unrecognised category lands somewhere on this ring, at an unknown hue.
    static let markChromaRing = (saturation: 0.65, value: 0.70)

    // MARK: - Colour maths

    static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> (r: Double, g: Double, b: Double) {
        let h = hue.truncatingRemainder(dividingBy: 360) / 60
        let c = value * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(h) % 6 {
        case 0:  (r1, g1, b1) = (c, x, 0)
        case 1:  (r1, g1, b1) = (x, c, 0)
        case 2:  (r1, g1, b1) = (0, c, x)
        case 3:  (r1, g1, b1) = (0, x, c)
        case 4:  (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }

    /// CIE76 ΔE between two sRGB colours.
    ///
    /// Plain RGB distance would be the easy option and it would lie: it treats
    /// a step in blue as the same size as a step in green, which is not how
    /// anyone sees. The claim being made here is "these cannot be confused by
    /// the eye", so the metric has to be a perceptual one.
    static func deltaE(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Double {
        let la = lab(a), lb = lab(b)
        let dL = la.l - lb.l, dA = la.a - lb.a, dB = la.b - lb.b
        return (dL * dL + dA * dA + dB * dB).squareRoot()
    }

    private static func lab(_ c: SIMD4<Float>) -> (l: Double, a: Double, b: Double) {
        func linear(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(Double(c.x)), g = linear(Double(c.y)), bl = linear(Double(c.z))
        // sRGB → CIE XYZ (D65), then normalised by the D65 white point.
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y = (0.2126 * r + 0.7152 * g + 0.0722 * bl) / 1.00000
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t) + (16.0 / 116.0)
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Minimum ΔE a lead ink must keep from every reserved meaning colour.
    ///
    /// CIE76 calls ~2.3 a just-noticeable difference, so this is roughly an
    /// order of magnitude past "tells them apart" and into "could not mistake
    /// one for the other". Chosen below the measured minimum with margin, so
    /// the test fails on drift rather than on the value being tight.
    /// Measured minimum at the time of writing: ΔE 27.1 (dark teal vs the
    /// noise grey) and ΔE 31.5 against the hash ring. 22 leaves real headroom
    /// so this fails on drift rather than on being tight to the current values.
    static let minimumSeparation: Double = 22
}
