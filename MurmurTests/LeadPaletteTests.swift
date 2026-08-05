//
//  LeadPaletteTests.swift
//  MurmurTests
//
//  X64-C acceptance for the lead trace inks. The failure this pins against is
//  not "the colours look wrong" — it is the amber-overload failure repeating:
//  a hand-picked palette that drifts, one tweak at a time, into the colours
//  that already carry meaning on this surface, until an analyst can no longer
//  tell "that's lead V1" from "that's a flagged beat".
//

import Foundation
import simd
import Testing
@testable import MurmurCore

@Suite("LeadPalette — trace inks stay out of the meaning palette")
struct LeadPaletteTests {

    @Test("The primary lead is pure black — the single-lead stage is unchanged")
    func primaryIsBlack() {
        #expect(LeadPalette.primaryInk.simd == WaveformStyle().trace)
        #expect(LeadPalette.ink(rank: 0) == LeadPalette.primaryInk)
    }

    @Test("Every secondary ink sits under the chroma and value ceiling")
    func inksAreLowChroma() {
        // This is the guarantee, not a style preference. CategoryPalette's
        // fallback puts unrecognised categories at an ARBITRARY hue on the
        // s = 0.65 / v = 0.70 ring, so no per-colour distance check can cover
        // them. Staying under the ceiling separates the traces from that whole
        // family at once.
        for ink in LeadPalette.secondaryInks {
            #expect(ink.saturation <= LeadPalette.maxSaturation, "\(ink.name) saturation \(ink.saturation)")
            #expect(ink.value <= LeadPalette.maxValue, "\(ink.name) value \(ink.value)")
        }
    }

    @Test("Every secondary ink is darker than the darkest mark colour")
    func inksAreDarkerThanEveryMark() {
        // The second axis, and the one the ratified spec missed. CategoryPalette
        // is NOT uniformly high-chroma: paced, noise and unknown are low-chroma
        // greys, so the chroma ceiling alone leaves a lead ink sitting on top of
        // them. Lightness is what separates the traces from the greys.
        for ink in LeadPalette.secondaryInks {
            #expect(ink.value <= LeadPalette.maxValue)
        }
        #expect(LeadPalette.maxValue < LeadPalette.darkestMarkValue)

        // And the claim about the mark palette that the ceiling rests on: no
        // CategoryPalette entry is darker than `darkestMarkValue`. If someone
        // adds a darker mark colour later, this fails here rather than showing
        // up as two indistinguishable things on the trace.
        for (category, markColor) in CategoryPalette.fixed {
            let value = max(markColor.x, max(markColor.y, markColor.z))
            #expect(
                Double(value) >= LeadPalette.darkestMarkValue,
                "category \"\(category)\" is darker (v \(value)) than the stated floor"
            )
        }
    }

    @Test("Every secondary ink is distinguishable from the primary's black")
    func inksClearThePrimaryBlack() {
        // The confusion that matters most on this surface is not ink-vs-mark
        // but "which trace am I reading" — and the primary is the one the marks
        // and the inspector belong to.
        for ink in LeadPalette.secondaryInks {
            let delta = LeadPalette.deltaE(ink.simd, LeadPalette.primaryInk.simd)
            #expect(delta >= LeadPalette.minimumSeparation, "\(ink.name) is ΔE \(delta) from black")
        }
    }

    @Test("Every secondary ink clears the reserved mark colours by ΔE")
    func inksClearEveryFixedCategory() {
        var worst = (name: "", against: "", deltaE: Double.greatestFiniteMagnitude)
        for ink in LeadPalette.secondaryInks {
            for (category, markColor) in CategoryPalette.fixed {
                let delta = LeadPalette.deltaE(ink.simd, markColor)
                if delta < worst.deltaE { worst = (ink.name, category, delta) }
                #expect(
                    delta >= LeadPalette.minimumSeparation,
                    "\(ink.name) is ΔE \(delta) from category \"\(category)\""
                )
            }
        }
        // Surfaced so a future tightening of `minimumSeparation` is an informed
        // decision rather than a guess at how much headroom there was.
        print("closest lead ink to a fixed category: \(worst.name) vs \(worst.against) — ΔE \(worst.deltaE)")
    }

    @Test("Every secondary ink clears analyst amber")
    func inksClearAnalystAmber() {
        for ink in LeadPalette.secondaryInks {
            let delta = LeadPalette.deltaE(ink.simd, LeadPalette.analystAmber)
            #expect(delta >= LeadPalette.minimumSeparation, "\(ink.name) is ΔE \(delta) from analyst amber")
        }
    }

    @Test("Every secondary ink clears the whole hash-fallback ring, at every hue")
    func inksClearTheHashFallbackRing() {
        // The case a fixed-entry check cannot reach: a producer emits a
        // category nobody hard-coded, CategoryPalette hashes it to some hue,
        // and that mark lands on the trace. Sweep the ring a degree at a time.
        let ring = LeadPalette.markChromaRing
        var worst = (name: "", hue: 0, deltaE: Double.greatestFiniteMagnitude)
        for ink in LeadPalette.secondaryInks {
            for hue in 0..<360 {
                let (r, g, b) = LeadPalette.hsvToRGB(
                    hue: Double(hue), saturation: ring.saturation, value: ring.value
                )
                let markColor = SIMD4<Float>(Float(r), Float(g), Float(b), 1)
                let delta = LeadPalette.deltaE(ink.simd, markColor)
                if delta < worst.deltaE { worst = (ink.name, hue, delta) }
            }
        }
        print("closest lead ink to the hash-fallback ring: \(worst.name) at hue \(worst.hue)° — ΔE \(worst.deltaE)")
        #expect(
            worst.deltaE >= LeadPalette.minimumSeparation,
            "\(worst.name) is ΔE \(worst.deltaE) from a hash-fallback mark at hue \(worst.hue)°"
        )
    }

    @Test("Secondary inks are separable from each other, not just from the marks")
    func inksAreSeparableFromEachOther() {
        // Colour is never the sole discriminator here — edge labels and the
        // legend carry identification — but inks that are indistinguishable
        // from one another would make the colour channel pure noise.
        let inks = LeadPalette.secondaryInks
        for i in inks.indices {
            for j in inks.indices where j > i {
                let delta = LeadPalette.deltaE(inks[i].simd, inks[j].simd)
                #expect(delta >= 10, "\(inks[i].name) vs \(inks[j].name): ΔE \(delta)")
            }
        }
    }

    @Test("Inks are assigned by selection rank and cycle past the palette's end")
    func ranksCycleRatherThanRunOut() {
        let count = LeadPalette.secondaryInks.count
        #expect(LeadPalette.ink(rank: 1) == LeadPalette.secondaryInks[0])
        #expect(LeadPalette.ink(rank: count) == LeadPalette.secondaryInks[count - 1])
        // Overlaying more leads than the palette has inks must still draw them.
        #expect(LeadPalette.ink(rank: count + 1) == LeadPalette.secondaryInks[0])
    }

    @Test("HSV conversion round-trips the greys and primaries it is used for")
    func hsvConversionIsSane() {
        let black = LeadPalette.hsvToRGB(hue: 0, saturation: 0, value: 0)
        #expect(black.r == 0 && black.g == 0 && black.b == 0)
        let red = LeadPalette.hsvToRGB(hue: 0, saturation: 1, value: 1)
        #expect(abs(red.r - 1) < 1e-9 && red.g < 1e-9 && red.b < 1e-9)
        let cyan = LeadPalette.hsvToRGB(hue: 180, saturation: 1, value: 1)
        #expect(cyan.r < 1e-9 && abs(cyan.g - 1) < 1e-9 && abs(cyan.b - 1) < 1e-9)
    }
}
