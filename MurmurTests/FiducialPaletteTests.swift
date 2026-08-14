//
//  FiducialPaletteTests.swift
//  MurmurTests
//
//  A mark drawn in the paper's own colour is not a mark (#226).
//
//  The fiducial overlay draws on calibrated ECG paper: `WaveformStyle.paper`
//  is (1.00, 0.93, 0.93) under a red grid ladder — the whole surface lives at
//  hue 0. QRS boundaries shipped at hue 0.02, one point wide, at the bottom of
//  an alpha band starting at 0.10. The result was invisible in the ordinary
//  sense: the analyst reading the trace did not know the overlay was on the
//  screen at all, while the Layers chip correctly reported `all`.
//
//  Nothing could catch that. The chip's honesty is unit-tested (X61), the
//  render policy is unit-tested, the geometry is snapshot-tested — and every
//  one of those passes just as well when the ink is the same colour as the
//  page. So this pins the property none of them cover: what is drawn on the
//  paper has to be distinguishable FROM the paper.
//

import SwiftUI
import Testing
@testable import MurmurCore

@Suite("Fiducial palette (#226)")
struct FiducialPaletteTests {

    /// Distance between two hues on the colour wheel, where 0.5 is opposite.
    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    /// Below this the ink reads as a shade of the paper rather than as ink
    /// on it. 0.15 is 54° — the old QRS was 7°, and the new one is 130°.
    private let minimumSeparationFromPaper = 0.15

    @Test("No boundary colour sits in the graph paper's hue")
    func coloursAreOffThePaperHue() {
        for layer in FiducialOverlay.FiducialColor.allCases {
            let distance = hueDistance(layer.hue, FiducialOverlay.FiducialColor.paperHue)
            #expect(distance >= minimumSeparationFromPaper,
                    "\(layer) is at hue \(layer.hue), \(distance) from the paper's \(FiducialOverlay.FiducialColor.paperHue) — a mark in the paper's own hue is grid")
        }
    }

    @Test("The three layers stay distinguishable from each other")
    func coloursAreDistinctFromEachOther() {
        // Colour is currently the ONLY channel separating P from QRS from T —
        // same tick, same dot, same hairline. Until the dots carry distinct
        // shapes, moving one layer's hue toward another silently merges two
        // measurements that mean different things.
        let layers = FiducialOverlay.FiducialColor.allCases
        for (index, layer) in layers.enumerated() {
            for other in layers[(index + 1)...] {
                #expect(hueDistance(layer.hue, other.hue) >= 0.12,
                        "\(layer) (\(layer.hue)) and \(other) (\(other.hue)) are too close to tell apart")
            }
        }
    }
}
