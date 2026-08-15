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

    /// #246: the card's height is a constant across every per-beat state.
    /// The TestFlight complaint was the card popping and resizing under the
    /// analyst's eye; the fix routes every per-beat difference through a
    /// reserved line or a "—" row. This pins that property the way #205
    /// pinned the width: measure what the view INSISTS on, state by state,
    /// and demand one answer. Record-stable inputs (template, withheld
    /// reason, modes) are held fixed — those MAY move the height, once per
    /// record; the beat must not.
    @Test("The caliper card's height does not depend on the beat")
    func caliperCardHeightIsBeatInvariant() {
        let proposal = CGSize(width: BedsideGeometry.dockedColumnWidth, height: 4000)
        func height(of beat: MarkingsBeat?, kind: BeatCaliperKind = .unknown) -> CGFloat {
            demandedSize(
                BeatCalipers(beat: beat, sampleRate: 360, template: template(),
                             qtcFormula: .fridericia, kind: kind),
                proposal: proposal
            ).height
        }
        let normal = height(of: beat())
        let states: [(String, CGFloat)] = [
            ("no beat focused", height(of: nil)),
            ("ectopic", height(of: beat(), kind: .ectopic)),
            ("wide QRS with JT", height(of: MarkingsBeat(
                rPeakSampleIndex: 12500, prMs: 155.0, qrsMs: 148.0,
                qtMs: 470.0, qtcMs: 465.0, precedingRRMs: 820.0,
                jtMs: 322.0, jtcMs: 317.0))),
            ("implausible", height(of: MarkingsBeat(
                rPeakSampleIndex: 12500, prMs: 155.0, qrsMs: 92.0,
                qtMs: 410.0, qtcMs: 445.0, precedingRRMs: 820.0,
                isImplausible: true))),
            ("unreliable T-offset", height(of: MarkingsBeat(
                rPeakSampleIndex: 12500, prMs: 155.0, qrsMs: 92.0,
                qtMs: 410.0, qtcMs: 445.0, precedingRRMs: 820.0,
                isUnreliable: true))),
            ("censored with CI", height(of: MarkingsBeat(
                rPeakSampleIndex: 12500, prMs: 155.0, qrsMs: 92.0,
                qtMs: 410.0, qtcMs: 445.0, precedingRRMs: 820.0,
                tOffsetCensored: true, qtCalibratedHalfWidthMs: 22.0))),
        ]
        for (name, h) in states {
            #expect(abs(h - normal) < 0.5,
                    "State '\(name)' demands \(h) pt against the normal beat's \(normal) pt — the card changed size (#246)")
        }
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

    // MARK: - #207 · the width-0 probe

    /// A summary with enough rows that the single-column collapse is a tower —
    /// three sections, nine rows, which is an ordinary record, not a stress test.
    private func realisticSummary() -> VariabilityMetricsSummary {
        func row(_ i: Int, _ label: String, _ value: String, _ unit: String) -> VariabilityMetricsSummary.Row {
            .init(id: "r\(i)", label: label, value: value, unit: unit)
        }
        return VariabilityMetricsSummary(
            sections: [
                .init(id: "hrv", title: "Heart rate variability", rows: [
                    row(1, "Mean RR", "798.9", "ms"), row(2, "SDNN", "191.1", "ms"),
                    row(3, "RMSSD", "133.0", "ms"), row(4, "pNN50", "18.5", "%")
                ]),
                .init(id: "freq", title: "Frequency-domain HRV", rows: [
                    row(5, "VLF", "16999", "ms²"), row(6, "LF", "8334", "ms²"),
                    row(7, "HF", "3766", "ms²"), row(8, "LF/HF", "2.21", ""),
                    row(9, "LF / HF n.u.", "69 / 31", "")
                ]),
                .init(id: "qtv", title: "QT variability index", rows: [],
                      captions: ["No qualifying 5-min segments (needs ≥ 5 min of stable, artifact-free rate)."])
            ],
            provenance: "16265 · whole record · 100215 beats · 22.2 h",
            exportText: "x")
    }

    private func populatedStrip() -> some View {
        let context = VariabilityMetricsContext()
        context.set(summary: realisticSummary())
        return VariabilityMetricsStrip(context: context)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    @Test("A width-0 probe is answered at the floor, not with the collapsed tower")
    func widthZeroProbeIsNotATower() {
        let strip = populatedStrip()
        let bare = demandedHeightGivenRoom(strip, width: 0)
        #expect(bare > MetricsStripInsetHeight.cap,
                "fixture collapses to \(bare) pt — it must exceed the cap, or this proves nothing")
        let probed = demandedHeightGivenRoom(cappedInset(strip), width: 0)
        let atFloor = demandedHeightGivenRoom(strip, width: MetricsStripInsetHeight.measurementWidthFloor)
        // The whole point: the strip's MINIMUM height is what it would be in a
        // real column, not the cap. Before the floor this was 260 — the cap —
        // and the split view carried all 260 into its own minimum (#207).
        #expect(probed == atFloor,
                "Probe answers \(probed) pt, floor width answers \(atFloor) pt")
        #expect(probed < MetricsStripInsetHeight.cap,
                "The cap is still load-bearing at \(probed) pt")
    }

    @Test("The floor reports the width it was given, so it can widen nothing")
    func widthFloorDoesNotWiden() {
        // #207 is a minimum-WIDTH problem too (1537 pt). A floor that reported
        // 600 pt back would add itself to that, trading one spill for another.
        let probed = demandedSize(cappedInset(populatedStrip()),
                                  proposal: CGSize(width: 0, height: 4000))
        #expect(probed.width == 0, "The inset demands \(probed.width) pt of width at a width-0 probe")
    }

    @Test("At real column widths the floor changes nothing")
    func widthFloorIsInertAtRealWidths() {
        // The narrowest the detail column can structurally become is the split
        // view's minimum width less the sidebar and inspector at their maximums
        // — around 717 pt, comfortably above the floor. Below it the reported
        // height would understate the content, so the floor must stay below any
        // width the app can actually produce.
        let strip = populatedStrip()
        for width in [MetricsStripInsetHeight.measurementWidthFloor, 800, 1200] as [CGFloat] {
            #expect(demandedHeightGivenRoom(cappedInset(strip), width: width)
                    == demandedHeightGivenRoom(strip, width: width),
                    "The inset diverges from its content at \(width) pt")
        }
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
