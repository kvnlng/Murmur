//
//  TrendStackGeometryTests.swift
//  MurmurTests
//
//  Do the trend lanes actually share the axis they claim to share?
//
//  #210: they did not. Every lane got an identical plot cell, and then each
//  decided for itself where to draw inside it — the Swift Charts lanes let
//  Charts reserve a data-dependent leading gutter, the `Canvas` lanes drew
//  from the cell's edge, and the RMSSD lane's card padding inset both of its
//  edges. Four lanes on "one axis", three different x-mappings, and a shared
//  window box that landed on the RMSSD lane's y-labels instead of its data.
//
//  Nothing in the type system can catch that: every lane satisfies `View`.
//  So these tests render each lane and look at where the ink lands, which is
//  the only place the contract is actually observable.
//

import AppKit
import Charts
import SwiftUI
import Testing
@testable import MurmurCore

@Suite("Trend stack — one axis, one mapping")
@MainActor
struct TrendStackGeometryTests {

    /// Columns of `view` that contain accent-coloured ink, as `(first, last)`.
    ///
    /// Accent-coloured specifically: the axis LABELS are grey, and counting
    /// those would measure the gutter's ink rather than the plot's, which is
    /// the exact confusion the bug was made of.
    private func dataColumns<V: View>(_ view: V, size: CGSize) -> (first: Int, last: Int)? {
        let renderer = ImageRenderer(
            content: view.frame(width: size.width, height: size.height).background(Color.white))
        renderer.scale = 1.0
        guard let cg = renderer.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func isData(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return Int(raw[i + 2]) - Int(raw[i]) > 40
        }
        guard let first = (0..<w).first(where: { x in (0..<h).contains { isData(x, $0) } }),
              let last = (0..<w).reversed().first(where: { x in (0..<h).contains { isData(x, $0) } })
        else { return nil }
        return (first, last)
    }

    private let range = 0.0...6000.0
    private let cell = CGSize(width: 700, height: 46)

    private func hrSamples() -> [Float] {
        (0..<1500).map { 60 + 12 * Float(sin(Double($0) / 40)) }
    }

    private func laneSamples() -> [VariabilityLaneSample] {
        (0..<200).map {
            VariabilityLaneSample(windowStartSeconds: Double($0) * 30,
                                  windowEndSeconds: Double($0) * 30 + 300,
                                  value: 40 + 30 * sin(Double($0) / 9),
                                  isEligible: true)
        }
    }

    private func rmssdLane() -> some View {
        VariabilityLane(samples: laneSamples(), timeRangeSeconds: range,
                        metricLabel: "RMSSD", unit: "ms",
                        windowCaption: "5-min window · 30 s step",
                        showsMetricLabel: false)
    }

    /// Antialiasing and per-lane line widths move the first inked column by a
    /// point or so. 4 pt of slack keeps that from being a failure while still
    /// catching the ~30 pt regression this suite exists for.
    private let slack = 4

    @Test("Every lane's data starts at the stack's plot origin")
    func lanesShareALeadingEdge() {
        let hr = dataColumns(HeartRateLanePlot(samples: hrSamples(), sampleRate: 0.25,
                                               recordingRange: range), size: cell)
        let lfhf = dataColumns(LFHFLanePlot(samples: laneSamples(), recordingRange: range,
                                            stepSeconds: 30), size: cell)
        let rmssd = dataColumns(rmssdLane(), size: CGSize(width: 700, height: 90))

        for (name, measured) in [("HR", hr), ("LF/HF", lfhf), ("RMSSD", rmssd)] {
            guard let measured else {
                Issue.record("\(name) drew no data — the fixture proves nothing")
                continue
            }
            #expect(abs(CGFloat(measured.first) - TrendStack.axisGutter) <= CGFloat(slack),
                    "\(name) starts drawing at \(measured.first) pt, gutter is \(TrendStack.axisGutter)")
        }
    }

    @Test("Every lane's data ends at the same trailing edge")
    func lanesShareATrailingEdge() {
        // The leading edge alone is not the contract: the RMSSD lane's card
        // padding also inset its RIGHT edge by 12 pt, compressing its time
        // mapping — the same feature drawn at two different times.
        let hr = dataColumns(HeartRateLanePlot(samples: hrSamples(), sampleRate: 0.25,
                                               recordingRange: range), size: cell)
        let rmssd = dataColumns(rmssdLane(), size: CGSize(width: 700, height: 90))
        guard let hr, let rmssd else {
            Issue.record("a lane drew no data — the fixture proves nothing")
            return
        }
        #expect(abs(hr.last - rmssd.last) <= slack,
                "HR ends at \(hr.last) pt, RMSSD at \(rmssd.last) pt")
    }

    @Test("The scale-less lane still reserves the gutter")
    func gutterlessLaneStillReservesIt() {
        // The quality band draws in grey, so `dataColumns` cannot see it —
        // its own background fill marks the plot area instead, and that is
        // what has to start at the gutter.
        let plot = QualityLanePlot(samples: (0..<200).map { _ in 0.5 },
                                   sampleRate: 0.03, recordingRange: range)
        let renderer = ImageRenderer(
            content: plot.frame(width: 700, height: 22).background(Color.white))
        renderer.scale = 1.0
        guard let cg = renderer.cgImage else {
            Issue.record("nothing rendered")
            return
        }
        var raw = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &raw, width: cg.width, height: cg.height, bitsPerComponent: 8,
                            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        // A near-white threshold, not a generous one: this band renders as
        // `secondary` at low opacity — 247 grey on white — so anything coarser
        // finds no lane at all and passes for the wrong reason.
        let first = (0..<cg.width).first { x in
            (0..<cg.height).contains { y in raw[(y * cg.width + x) * 4] < 252 }
        }
        #expect(first.map { abs(CGFloat($0) - TrendStack.axisGutter) <= CGFloat(slack) } == true,
                "The quality band starts at \(first.map(String.init) ?? "nothing") pt")
    }

    @Test("Charts still reserves label + spacing + 15")
    func chartsGutterArithmeticHolds() {
        // The one number here that Apple owns. Measured across four label-box
        // widths and two spacings; if a future Charts changes it, the gutter
        // constant is wrong and every lane drifts together — silently, because
        // they would all still agree with each other.
        let chart = Chart {
            ForEach(laneSamples()) { s in
                LineMark(x: .value("t", s.windowCenterSeconds), y: .value("v", s.value))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: range)
        .trendLaneYAxis()
        guard let measured = dataColumns(chart, size: cell) else {
            Issue.record("chart drew no data")
            return
        }
        let expected = TrendStack.axisLabelWidth + TrendStack.axisLabelSpacing
            + TrendStack.chartsAxisPadding
        #expect(expected == TrendStack.axisGutter,
                "The gutter constant (\(TrendStack.axisGutter)) no longer equals its parts (\(expected))")
        #expect(abs(CGFloat(measured.first) - expected) <= CGFloat(slack),
                "Charts put the data at \(measured.first) pt, the arithmetic says \(expected)")
    }

    // MARK: - Vertical geometry

    /// A lane's label column: title over subtitle, in `TrendStack.labelWidth`.
    private struct Rail {
        let id: String
        let title: String
        let subtitle: String
        /// The row height the lane declares in `BedsideTrendStack`.
        let height: CGFloat

        /// Rebuilt from `TrendStack.laneRowContent`'s rail. Duplicated rather
        /// than reached into because the rail is a private detail of a private
        /// method; the fonts and the 1 pt spacing are the part under test.
        var view: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: TrendStack.labelWidth, alignment: .leading)
        }
    }

    /// A five-lane stack at the heights `BedsideTrendStack` declares. Built
    /// here rather than through `BedsideTrendStack` so the measurement doesn't
    /// depend on entitlement or a loaded record.
    private func fiveLaneStack() -> TrendStack {
        func lane(_ id: String, _ subtitle: String, height: CGFloat?) -> TrendStackLane {
            TrendStackLane(id: id, title: "Lane", subtitle: subtitle,
                           value: "1.50", height: height) {
                LFHFLanePlot(samples: laneSamples(), recordingRange: range, stepSeconds: 30)
            }
        }
        return TrendStack(
            lanes: [
                lane("hr", "bpm · trend channel only", height: 46),
                lane("beat-hr", "bpm · median per 10 s · from R–R", height: 46),
                // The natural-height lane matters to the measurement: it is
                // the one whose height comes from its content rather than a
                // literal, so a greedy stack can hide behind it.
                TrendStackLane(id: "rmssd", title: "RMSSD", subtitle: "ms · 5-min window",
                               value: "42", height: nil) { rmssdLane() },
                lane(BedsideTrendStack.lfhfLaneID, RollingLFHFContext.provenanceCaption, height: 46),
                lane(BedsideTrendStack.qualityLaneID, "artifact ratio · outline over 10%", height: 22),
            ],
            recordingRange: range,
            viewportRange: 100.0...400.0,
            caption: "one axis · every lane"
        )
    }

    @Test("The stack takes the height of its lanes, not the height it is offered")
    func stackIsNotGreedyVertically() {
        // #215. TWO children voted for the full proposal, and either one alone
        // is enough to make the card claim everything — measured by putting
        // each back: with only the other fixed, a five-lane stack still
        // demanded 700 pt of 700 and 2000 of 2000.
        //
        //   1. `crossLaneOverlay` as a `ZStack` sibling of the lanes. It is a
        //      `GeometryReader`, which has no intrinsic size, so it accepted
        //      the whole proposal and the ZStack sized to the larger child.
        //   2. `axisRow`'s two `Color.clear` spacers. Given a width and no
        //      height they still take any height proposed, so the axis row
        //      sized to the container rather than to its 16 pt of axis.
        //
        // Same fault as #208's `maxHeight` claim, wearing two different views.
        // The stack now settles at ~299 pt for these five lanes.
        let stack = fiveLaneStack()
        let content = demandedHeightGivenRoom(stack, width: 700)
        #expect(content < 1000,
                "Offered 4000 pt the stack demanded \(content) pt — it is claiming, not needing")

        // The invariant, not the number: what it wants must not track what it
        // is offered. Equal answers to two proposals is an honest answer.
        let small = demandedSize(stack, proposal: CGSize(width: 700, height: 700)).height
        let large = demandedSize(stack, proposal: CGSize(width: 700, height: 2000)).height
        #expect(abs(small - large) < 1,
                "Demanded \(small) pt of 700 but \(large) pt of 2000 — the height follows the offer")
    }

    @Test("The LF/HF provenance line fits its label column on one line")
    func lfhfProvenanceFitsOneLine() {
        // #216, and the measurement corrects the report: the old subtitle did
        // not overflow its row — `Lomb–Scargle · 5-min window · 1 min step`
        // wrapped to two lines for a 40 pt rail in a 46 pt row. What it left
        // was SIX points between its last line and the Quality lane's title
        // beneath, and at .caption2 six points reads as one paragraph rather
        // than two lanes. Crowding, not overflow.
        //
        // So the guard is the property the fix actually establishes: the
        // longest subtitle in the stack fits on one line. Re-word it longer
        // and it wraps, the clearance drops back to ~6 pt, and this fails.
        let oneLine = Rail(id: "reference", title: "LF / HF", subtitle: "bpm", height: 46)
        let shipping = Rail(id: BedsideTrendStack.lfhfLaneID, title: "LF / HF",
                            subtitle: RollingLFHFContext.provenanceCaption, height: 46)
        let reference = demandedHeightGivenRoom(oneLine.view, width: TrendStack.labelWidth)
        let measured = demandedHeightGivenRoom(shipping.view, width: TrendStack.labelWidth)
        #expect(abs(measured - reference) < 1,
                "'\(RollingLFHFContext.provenanceCaption)' needs \(measured) pt against \(reference) pt for one line, so it wraps and crowds the lane beneath")
    }

    @Test("A lane's row is at least as tall as its own rail")
    func railsFitTheirRows() {
        // The general form of #216, so the next long subtitle is caught by a
        // test rather than by an eye.
        //
        // Quality is the case that made this a decision rather than a fix
        // (#218): its rail wants 40 pt in the 22 pt row a thin heat band was
        // designed for, and no wording closes that — even a one-line subtitle
        // needs 27. It was excluded here while the only remedies cost the
        // column space it did not have. A declared height is now a floor
        // rather than a claim, so it is in the list, and this is the
        // acceptance test #218 asked for.
        let rows: [Rail] = [
            Rail(id: "hr", title: "Trends · HR",
                 subtitle: "bpm · trend channel only", height: 46),
            Rail(id: "beat-hr", title: "HR · beat-derived",
                 subtitle: "bpm · median per \(Int(BeatHeartRateSeries.defaultBinSeconds)) s · from R–R",
                 height: 46),
            Rail(id: BedsideTrendStack.lfhfLaneID, title: "LF / HF",
                 subtitle: RollingLFHFContext.provenanceCaption, height: 46),
            Rail(id: BedsideTrendStack.qualityLaneID, title: "Quality",
                 subtitle: "artifact ratio · outline over 10%", height: 22),
        ]
        for row in rows {
            let rail = demandedHeightGivenRoom(row.view, width: TrendStack.labelWidth)
            let rendered = demandedHeightGivenRoom(
                laneRow(rail: row, plotHeight: row.height), width: 700)
            #expect(rendered >= rail - 1,
                    "\(row.id)'s row renders \(rendered) pt around a \(rail) pt rail, so the rail spills onto the lane beneath")
        }
    }

    /// A row built the way `TrendStack.laneRow` builds one, for measuring
    /// what the row does with a rail taller than the declared height.
    private func laneRow(rail: Rail, plotHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            rail.view.padding(.leading, 10)
            LFHFLanePlot(samples: laneSamples(), recordingRange: range, stepSeconds: 30)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .frame(height: plotHeight)
            Text("1.50").font(.caption.monospacedDigit())
                .frame(width: TrendStack.valueWidth, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(minHeight: plotHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
