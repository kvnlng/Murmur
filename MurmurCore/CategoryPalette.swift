//
//  CategoryPalette.swift
//  Murmur
//
//  Maps an annotation `category` string to a stable color. Common clinical
//  categories get hand-tuned colors that group sensibly when several findings
//  appear together (reds for ventricular, purples for atrial, blues for
//  conduction, slate for noise). Unknown categories fall back to a
//  deterministic hash-derived hue so each producer-side category keeps the
//  same color across runs.
//

import Foundation
import simd
import SwiftUI

enum CategoryPalette {

    /// Hand-tuned colors for the categories we expect from clinical analyses.
    static let fixed: [String: SIMD4<Float>] = [
        // Ventricular ectopy / arrhythmia — reds + magentas
        "V":          SIMD4(0.85, 0.20, 0.55, 1.0),
        "PVC":        SIMD4(0.85, 0.20, 0.55, 1.0),
        "VT":         SIMD4(0.95, 0.40, 0.20, 1.0),
        "VF":         SIMD4(0.85, 0.10, 0.10, 1.0),
        "VF_onset":   SIMD4(0.85, 0.10, 0.10, 1.0),
        "F":          SIMD4(0.90, 0.45, 0.25, 1.0),  // fusion
        "E":          SIMD4(0.80, 0.30, 0.40, 1.0),  // ventricular escape

        // Atrial — purples
        "A":          SIMD4(0.55, 0.25, 0.75, 1.0),
        "APC":        SIMD4(0.55, 0.25, 0.75, 1.0),
        "AFib":       SIMD4(0.50, 0.20, 0.85, 1.0),
        "S":          SIMD4(0.45, 0.30, 0.80, 1.0),  // supraventricular

        // Conduction — blues
        "L":          SIMD4(0.15, 0.40, 0.70, 1.0),  // LBBB
        "R":          SIMD4(0.20, 0.55, 0.80, 1.0),  // RBBB
        "N":          SIMD4(0.20, 0.45, 0.65, 1.0),  // normal beat
        "J":          SIMD4(0.30, 0.50, 0.65, 1.0),  // nodal

        // Pacing / artifact — greys + teals
        "/":          SIMD4(0.40, 0.55, 0.60, 1.0),  // paced
        "Noise":      SIMD4(0.40, 0.50, 0.60, 1.0),
        "NoiseGap":   SIMD4(0.40, 0.50, 0.60, 1.0),
        "~":          SIMD4(0.45, 0.55, 0.60, 1.0),

        // Unknown / learning
        "Q":          SIMD4(0.55, 0.55, 0.55, 1.0),
        "?":          SIMD4(0.55, 0.55, 0.55, 1.0)
    ]

    static func color(for category: String) -> SIMD4<Float> {
        if let known = fixed[category] { return known }
        return hashColor(category)
    }

    static func swiftUIColor(for category: String) -> Color {
        let c = color(for: category)
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: Double(c.w))
    }

    /// Severity tweaks alpha — more critical findings render slightly more
    /// opaque (and read as more saturated against the pink paper).
    static func alpha(for severity: Annotation.Severity, baseAlpha: Float) -> Float {
        switch severity {
        case .info:     return baseAlpha * 0.85
        case .notice:   return baseAlpha
        case .warning:  return min(1, baseAlpha * 1.15)
        case .critical: return min(1, baseAlpha * 1.30)
        }
    }

    // MARK: - Fallback

    private static func hashColor(_ category: String) -> SIMD4<Float> {
        // FNV-1a 32-bit so the value is stable across launches (Swift's hashValue isn't).
        var hash: UInt32 = 2_166_136_261
        for byte in category.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hue = Double(hash % 360) / 360.0
        let (r, g, b) = hsvToRgb(h: hue, s: 0.65, v: 0.70)
        return SIMD4(Float(r), Float(g), Float(b), 1.0)
    }

    private static func hsvToRgb(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let c = v * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let segment = Int(h * 6) % 6
        let (r1, g1, b1): (Double, Double, Double)
        switch segment {
        case 0:  (r1, g1, b1) = (c, x, 0)
        case 1:  (r1, g1, b1) = (x, c, 0)
        case 2:  (r1, g1, b1) = (0, c, x)
        case 3:  (r1, g1, b1) = (0, x, c)
        case 4:  (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }
}
