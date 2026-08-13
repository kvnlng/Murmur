//
//  LayoutFitTests.swift
//  MurmurTests
//
//  Does the content fit the box it was given?
//
//  The bug class these exist for (#205, #208, #209 and their siblings) is
//  always the same: a view asserts a size that was measured correctly once,
//  against a container that later changed, and nothing reconciles the two.
//  The snapshot suite cannot see it — it forces `.frame(width:height:)` before
//  rendering, so an overflowing view is simply told its size and drawn — and
//  it skips on CI besides. These ask the other question, via
//  `demandedSize`: given this proposal, how big does the view INSIST on being?
//

import AppKit
import SwiftUI
import Testing
@testable import MurmurCore

@Suite("Layout fit — demanded vs granted")
@MainActor
struct LayoutFitTests {

    // MARK: - #205 · the docked beat card and its column

    private func beat() -> MarkingsBeat {
        MarkingsBeat(
            rPeakSampleIndex: 12500, rPeakConfidence: 1.0,
            prMs: 155.0, qrsMs: 92.0, qtMs: 410.0, qtcMs: 445.0,
            precedingRRMs: 820.0)
    }

    /// A template whose medians differ from the beat, so the delta column
    /// renders its widest content rather than an em dash.
    private func template() -> MarkingsTemplate {
        MarkingsTemplate(
            sampleCount: 200,
            medianPRMs: 38.0, iqrPRMs: 22.0,
            medianQRSMs: 25.0, iqrQRSMs: 22.0,
            medianQTMs: 293.0, iqrQTMs: 22.0,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 328.0, iqrQTcMs: 22.0)
    }

    @Test("The caliper card fits the docked column it is rendered into")
    func caliperCardFitsItsColumn() {
        let card = BeatCalipers(beat: beat(), sampleRate: 360,
                                template: template(), qtcFormula: .fridericia)
        let demanded = demandedSize(
            card,
            proposal: CGSize(width: BedsideGeometry.dockedColumnWidth, height: 4000))
        // The failure this pins drew 218 pt into a 186 pt column, spilling the
        // delta cell under the review queue.
        #expect(demanded.width <= BedsideGeometry.dockedColumnWidth,
                "The beat card demands \(demanded.width) pt inside a \(BedsideGeometry.dockedColumnWidth) pt column")
    }

    @Test("The column arithmetic agrees with the column, with slack to spare")
    func caliperColumnBudget() {
        #expect(BeatCalipers.Columns.totalWidth <= BedsideGeometry.dockedColumnWidth)
        // Widest strings measured at .caption.monospacedDigit(): "QRS" 21,
        // "≥ 545.0 ms" 56, "+117.0 ±22 ms" 75. Each column keeps a little
        // over its worst case so a font-metric nudge doesn't clip a digit.
        #expect(BeatCalipers.Columns.label >= 21)
        #expect(BeatCalipers.Columns.value >= 56)
        #expect(BeatCalipers.Columns.delta >= 75)
    }

    // MARK: - #208 · a ceiling that stopped claiming

    /// THE construction the app renders — not a copy of it. A copied idiom
    /// keeps passing after someone edits the original, which is how this
    /// bug class survives its own tests.
    private func cappedInset<V: View>(_ content: V) -> some View {
        content.modifier(MetricsStripInsetHeight())
    }

    @Test("A capped inset takes its CONTENT's height, not the cap")
    func cappedInsetIsNotGreedy() {
        let content = VStack { Text("one line"); Text("two lines") }
        let bare = demandedHeightGivenRoom(content, width: 800)
        let capped = demandedHeightGivenRoom(cappedInset(content), width: 800)
        // Before #208 this construction answered 260 for ~30 pt of content —
        // `maxHeight` offered more than its max takes the whole max.
        #expect(capped == bare,
                "Inset demands \(capped) pt for \(bare) pt of content — the cap is claiming, not clamping")
        #expect(capped < MetricsStripInsetHeight.cap)
    }

    @Test("The real strip in its real inset is as tall as the strip")
    func realStripInsetMatchesItsContent() {
        // The locked variant is the one a test can build without reaching
        // into MurmurMetrics, and it exercises the same inset.
        let context = VariabilityMetricsContext()
        context.setLocked()
        let strip = VariabilityMetricsStrip(context: context)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        let bare = demandedHeightGivenRoom(strip, width: 1200)
        let inset = demandedHeightGivenRoom(cappedInset(strip), width: 1200)
        #expect(bare > 0, "fixture should render something, or it proves nothing")
        #expect(inset == bare,
                "The strip's inset demands \(inset) pt for \(bare) pt of strip — \(inset - bare) pt of dead space")
    }

    @Test("The cap still bounds a pathological measurement")
    func cappedInsetStillClamps() {
        // Stands in for the strip's LazyVGrid collapsing to one column at
        // width 0, where its ideal height runs to ~1800 pt. Bounding that is
        // the cap's whole reason to exist; the fix must not cost it.
        let tower = VStack {
            ForEach(0..<120, id: \.self) { _ in Text("row") }
        }
        let capped = demandedHeightGivenRoom(cappedInset(tower), width: 800)
        #expect(demandedHeightGivenRoom(tower, width: 800) > MetricsStripInsetHeight.cap,
                "fixture should be taller than the cap, or it proves nothing")
        #expect(capped <= MetricsStripInsetHeight.cap)
    }

    // MARK: - #209 · the lane says its name once

    @Test("An embedded lane omits the name its host already prints")
    func embeddedLaneDropsItsLabel() {
        let samples = (0..<20).map {
            VariabilityLaneSample(windowStartSeconds: Double($0) * 30,
                                  windowEndSeconds: Double($0) * 30 + 300,
                                  value: 40 + Double($0),
                                  isEligible: true)
        }
        func lane(showsLabel: Bool) -> some View {
            VariabilityLane(
                samples: samples, timeRangeSeconds: 0...600,
                metricLabel: "RMSSD", unit: "ms",
                windowCaption: "5-min window · 30 s step",
                showsMetricLabel: showsLabel)
        }
        // The label + caption occupy real width in the caption row; dropping
        // them is observable without reaching into the view's internals.
        let labelled = demandedSize(lane(showsLabel: true),
                                    proposal: CGSize(width: 0, height: 200)).width
        let embedded = demandedSize(lane(showsLabel: false),
                                    proposal: CGSize(width: 0, height: 200)).width
        #expect(embedded < labelled,
                "Embedded lane still demands \(embedded) pt — the duplicated name is still being drawn")
    }
}
