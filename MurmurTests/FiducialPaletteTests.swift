//
//  FiducialPaletteTests.swift
//  MurmurTests
//
//  A mark drawn in the paper's own colour is not a mark (#226), and a rule
//  about the RELATIONSHIP between two surfaces does not survive being
//  implemented twice (#249).
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
//  page. So this pins the properties none of them cover: what is drawn on the
//  paper has to be distinguishable FROM the paper, and the bedside tag has to
//  stay larger than the queue's.
//

import SwiftUI
import Testing
@testable import MurmurCore

@Suite("Fiducial palette (#226, #249)")
struct FiducialPaletteTests {

    @Test("No layer colour sits in the graph paper's hue — the 'exclude red' rule")
    func coloursAreOffThePaperHue() {
        for layer in MarkingsFiducialLayer.allCases {
            let hue = FiducialPalette.hue(for: layer)
            let distance = FiducialPalette.hueDistance(hue, FiducialPalette.paperHue)
            #expect(!FiducialPalette.isExcludedRed(hue),
                    "\(layer) is at hue \(hue), \(distance) from the paper's \(FiducialPalette.paperHue) — a mark in the paper's own hue is grid")
        }
    }

    /// The rule stated the way #249 asks for it: as a palette rule, not as a
    /// recollection of #226's incident. Red is the paper's hue, so "exclude
    /// red" and "stay off the paper" are the same constraint — this asserts
    /// the band is actually enforced at its edges rather than trusting that
    /// today's three picks happen to clear it.
    @Test("The excluded red band is enforced at its edges",
          arguments: [0.0, 0.02, 0.05, 0.10, 0.149, 0.851, 0.98])
    func redBandRejectsHuesNearThePaper(hue: Double) {
        #expect(FiducialPalette.isExcludedRed(hue),
                "hue \(hue) is within the paper's band and must be rejected")
    }

    @Test("The three layers stay distinguishable from each other")
    func coloursAreDistinctFromEachOther() {
        let layers = MarkingsFiducialLayer.allCases
        for (index, layer) in layers.enumerated() {
            for other in layers[(index + 1)...] {
                let distance = FiducialPalette.hueDistance(
                    FiducialPalette.hue(for: layer), FiducialPalette.hue(for: other))
                #expect(distance >= FiducialPalette.minimumSeparationBetweenLayers,
                        "\(layer) (\(FiducialPalette.hue(for: layer))) and \(other) (\(FiducialPalette.hue(for: other))) are too close to tell apart")
            }
        }
    }

    /// #249's first rule, and the reason the two sizes live in one file.
    ///
    /// "The fiducial tags in the waveform bedside view should be larger than
    /// the Review queue tags" is a property of a relationship, so it cannot be
    /// checked by looking at either surface alone — which is exactly how it
    /// would decay, with one PR tuning a trace glyph and another tuning a row.
    @Test("The bedside tag outranks the queue's, and both outrank nothing")
    func bedsideTagIsLargerThanTheQueues() {
        let bedside = FiducialPalette.bedsideLetterPointSize
        let queue = FiducialPalette.queueLetterPointSize
        #expect(bedside > queue,
                "The bedside letter (\(bedside)) must read larger than the queue's (\(queue))")
        // Also against the glyph the queue drew BEFORE letters existed, since
        // that is the size the feedback was comparing to.
        #expect(FiducialPalette.bedsideLetterPointSize > FiducialPalette.queueGlyphDiameter)
    }

    /// Every letter has to be one, and they have to differ — a palette whose
    /// letters collide is no better than one whose colours do.
    @Test("Each layer has a distinct, non-empty letter")
    func lettersAreDistinct() {
        let letters = MarkingsFiducialLayer.allCases.map(FiducialPalette.letter(for:))
        #expect(letters.allSatisfy { !$0.isEmpty })
        #expect(Set(letters).count == letters.count, "Letters collide: \(letters)")
    }
}

@Suite("Fiducial letter density (#249)")
struct FiducialGeometryTests {

    private let spacing = FiducialPalette.letterMinimumSpacing

    /// The regime the letters exist for. At a 3 s window over 800 pt a beat is
    /// ~267 pt wide and its P / QRS / T letters land ~30 pt apart.
    @Test("Letters fit where P·QRS·T are drawn at full-fiducial zoom")
    func lettersFitAtFullFiducialZoom() {
        // One beat's three letters, then the next beat's.
        let positions: [CGFloat] = [100, 132, 196, 367, 399, 463]
        #expect(FiducialGeometry.lettersFit(positions: positions))
    }

    /// The regime that forced the fallback to exist: QRS draws up to a 30 s
    /// window, where consecutive beats are ~27 pt apart and a three-character
    /// tag is 26 pt wide. One tight pair anywhere yields the whole frame.
    @Test("A single tight pair yields the whole frame to dots")
    func oneTightPairYieldsEverything() {
        var positions: [CGFloat] = stride(from: 0, to: 800, by: 100).map(CGFloat.init)
        #expect(FiducialGeometry.lettersFit(positions: positions))
        // Insert one beat that arrived early — an ectopic couplet does exactly
        // this, and it is why the decision is all-or-nothing rather than
        // per-letter: a letter that vanishes for one beat reads as "no P wave
        // in that beat", which is a finding.
        positions.append(105)
        #expect(!FiducialGeometry.lettersFit(positions: positions))
    }

    /// Order is the caller's convenience, not a precondition — the overlay
    /// builds positions per beat and per layer, which is not x-order.
    @Test("Unsorted input is handled")
    func unsortedPositionsAreSorted() {
        #expect(FiducialGeometry.lettersFit(positions: [400, 100, 700]))
        #expect(!FiducialGeometry.lettersFit(positions: [400, 410, 100]))
    }

    @Test("Exactly the minimum spacing fits; a hair under does not")
    func thresholdIsInclusive() {
        #expect(FiducialGeometry.lettersFit(positions: [0, spacing]))
        #expect(!FiducialGeometry.lettersFit(positions: [0, spacing - 0.5]))
    }

    /// A single letter has nothing to collide with; no letters is not a reason
    /// to claim the zoom is too dense.
    @Test("Degenerate counts")
    func degenerateCounts() {
        #expect(FiducialGeometry.lettersFit(positions: [42]))
        #expect(!FiducialGeometry.lettersFit(positions: []))
    }

    /// A letter must sit at the middle of the wave it names, or not be drawn.
    /// Half a span off-viewport gives a midpoint that is not the middle of
    /// anything, and a letter drifting away from its wave is worse than none.
    @Test("A letter needs both edges on screen")
    func letterPositionNeedsBothEdges() {
        #expect(FiducialGeometry.letterPosition(onsetX: 100, offsetX: 140) == 120)
        #expect(FiducialGeometry.letterPosition(onsetX: nil, offsetX: 140) == nil)
        #expect(FiducialGeometry.letterPosition(onsetX: 100, offsetX: nil) == nil)
    }
}

@Suite("Fiducial glyph band (#249)")
struct FiducialBandTests {

    /// The letter has to stay inside the glyph band.
    ///
    /// Found by breaking it: the letter first went in at 13 pt over a band that
    /// ended at 31, so its bottom pixels landed in the trace's space and
    /// `SnapshotTests.belowGlyphBand` failed the no-hairlines-at-qrsOnly
    /// assertion — with a change that added no hairline. #226 hit the identical
    /// edge when it enlarged the confidence dot, and that test's own comment
    /// records it. Twice is a pattern, so this states the relationship
    /// arithmetically instead of leaving the next person to rediscover it
    /// through a confusing snapshot diff.
    @Test("The letter tag's footprint stays above the hairline inset")
    func letterFitsInsideTheGlyphBand() {
        let letterTop: CGFloat = 19
        let bottom = letterTop + FiducialOverlay.letterBandHeight
        #expect(bottom <= FiducialOverlay.hairlineTopInset,
                "A letter running to \(bottom) pt under a band ending at \(FiducialOverlay.hairlineTopInset) pt spills into the trace")
    }

    /// The band exists to hold the tag, so it must not be so tall that it eats
    /// the trace. 40 pt is about a third of the 120 pt test canvas — past that
    /// the annotation is competing with the signal it annotates.
    @Test("The band stays a band, not a header")
    func bandDoesNotEatTheTrace() {
        #expect(FiducialOverlay.hairlineTopInset <= 40)
    }
}

@Suite("Queue fiducial letters (#249)")
struct QueueFiducialLetterTests {

    /// The whitelist, and the reason it is one.
    ///
    /// A queue group is a WFDB annotation category describing a BEAT or a
    /// rhythm transition. Only `QT-MANUAL` — "analyst-placed Q-onset →
    /// T-offset spans" — is defined by fiducial boundaries, so only it earns
    /// letters. Giving `V` a letter would teach a vocabulary that is wrong,
    /// which is worse than a list that looks inconsistent.
    @Test("Only the QT span carries letters, and it carries its own two")
    func onlyQTManualHasLetters() {
        #expect(FindingsPanel.fiducialSpanLetters(for: "QT-MANUAL") == [.qrs, .t])
        #expect(FindingsPanel.fiducialSpanLetters(for: "qt-manual") == [.qrs, .t],
                "Category matching is case-insensitive elsewhere in this panel")
        for category in ["V", "PVC", "A", "APC", "E", "~", "+", "|", "\"", "NOISE", ""] {
            #expect(FindingsPanel.fiducialSpanLetters(for: category).isEmpty,
                    "\(category) describes a beat or a transition, not a wave boundary")
        }
    }
}
