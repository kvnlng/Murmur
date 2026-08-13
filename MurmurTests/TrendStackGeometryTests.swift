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
}
