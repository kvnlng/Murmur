//
//  SnapshotTests.swift
//  MurmurTests
//
//  Reference-image regression suite for the SwiftUI overlays that surround
//  the Metal waveform canvas. The canvas itself is intentionally skipped —
//  GPU pixel diffs across MSAA settings and OS versions are unreliable. The
//  overlays underneath (axes, tooltip, density timeline, summary header) are
//  where layout regressions actually bite the analyst.
//
//  Baselines live in `__Snapshots__/SnapshotTests/` next to this file.
//  To re-record after an intentional UI change: wrap the suite in
//  `withSnapshotTesting(record: .all)` via an `invokeTest` override
//  (or set env var `SNAPSHOT_TESTING_RECORD=all` on the MurmurTests
//  scheme), run once, commit the new images, revert the wrap.
//
//  Pin the suite to "Latest Release" only in Xcode Cloud — SwiftUI
//  metrics drift across macOS versions, so matrix runs would be flaky.
//

#if canImport(SnapshotTesting)

import XCTest
import SwiftUI
import SnapshotTesting
@testable import MurmurCore
#if canImport(MurmurMetrics)
import MurmurMetrics
#endif

@MainActor
final class SnapshotTests: XCTestCase {

    // To re-record baselines after an intentional UI change, uncomment:
    // override func invokeTest() {
    //     withSnapshotTesting(record: .all) {
    //         super.invokeTest()
    //     }
    // }

    override func setUpWithError() throws {
        // Skip on CI (Xcode Cloud sets CI=TRUE). SwiftUI font metrics and
        // material rasterization differ between the local dev machine
        // where baselines were recorded and the Cloud worker, so these
        // tests would flake on every run. Keep them as a local-only
        // safety net; re-record on the Cloud worker if/when we want to
        // promote them to a CI gate.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Snapshot tests skipped on CI — baselines are local-machine-specific")
        }
    }

    /// Renders a SwiftUI view to NSImage via `ImageRenderer` — SwiftUI's own
    /// layout-aware renderer. Avoids the NSHostingView/AppKit layout dance
    /// that left `GeometryReader`-rooted views (the axes) blank when
    /// snapshotted through cacheDisplay().
    private func render<V: View>(_ view: V, size: CGSize) -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 2.0
        return renderer.nsImage ?? NSImage(size: size)
    }

    // MARK: - AnnotationTooltip

    func testAnnotationTooltip_pointWithConfidenceAndNote() {
        let annotation = Annotation(
            kind: .point,
            sampleIndex: 1500,
            category: "PVC",
            confidence: 0.92,
            source: "demo-detector-v2",
            note: "Couplet, R-on-T morphology"
        )
        let size = CGSize(width: 280, height: 160)
        let view = AnnotationTooltip(annotation: annotation, sampleRate: 250)
            .frame(width: 240)
            .padding()
        assertSnapshot(of: render(view, size: size), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testAnnotationTooltip_rangeWithoutNote() {
        let annotation = Annotation(
            kind: .range,
            sampleIndex: 6000,
            endSampleIndex: 9500,
            category: "VT",
            source: "vt-detector-v1"
        )
        let size = CGSize(width: 280, height: 110)
        let view = AnnotationTooltip(annotation: annotation, sampleRate: 250)
            .frame(width: 240)
            .padding()
        assertSnapshot(of: render(view, size: size), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - WaveformTimeAxis

    func testTimeAxis_defaultTenSecondViewport() {
        let size = CGSize(width: 676, height: 32)
        let view = WaveformTimeAxis(startTime: 0, endTime: 10)
            .frame(width: 660, height: 16)
            .padding(.horizontal, 8)
            .background(Color.white)
        assertSnapshot(of: render(view, size: size), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testTimeAxis_zoomedSixtySecondViewport() {
        let size = CGSize(width: 676, height: 32)
        let view = WaveformTimeAxis(startTime: 120, endTime: 180)
            .frame(width: 660, height: 16)
            .padding(.horizontal, 8)
            .background(Color.white)
        assertSnapshot(of: render(view, size: size), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - WaveformVoltageAxis

    func testVoltageAxis_defaultRange() {
        let size = CGSize(width: 56, height: 188)
        let view = WaveformVoltageAxis(yMin: -1.5, yMax: 1.5, durationSeconds: 10)
            .frame(width: 56, height: 180)
            .padding(.vertical, 4)
            .background(Color.white)
        assertSnapshot(of: render(view, size: size), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - OverviewMap

    func testOverviewMap_mixedCategories() {
        let totalSamples: Int64 = 30_000
        let annotations: [Annotation] = [
            Annotation(kind: .point, sampleIndex: 1_000,  category: "PVC",  source: "demo"),
            Annotation(kind: .point, sampleIndex: 2_500,  category: "PVC",  source: "demo"),
            Annotation(kind: .point, sampleIndex: 5_500,  category: "PVC",  source: "demo"),
            Annotation(kind: .range, sampleIndex: 10_000, endSampleIndex: 17_500,
                       category: "AFib", source: "demo"),
            Annotation(kind: .range, sampleIndex: 20_000, endSampleIndex: 21_200,
                       category: "VT",   source: "demo"),
            Annotation(kind: .point, sampleIndex: 25_000, category: "noise", source: "demo")
        ]
        let viewport = RecordingViewport(
            totalSamples: totalSamples,
            sampleRate: 250,
            initialDurationSeconds: 10
        )
        let view = OverviewMap(
            annotations: annotations,
            totalSamples: totalSamples,
            sampleRate: 250,
            viewport: viewport,
            channelName: "I"
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 120)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - FindingsSummaryHeader

    // testFindingsSummaryHeader_mixedFindings: dropped from the snapshot suite.
    // The chip row lives inside a horizontal ScrollView; ImageRenderer measures
    // a ScrollView's natural size as zero and emits a blank image. The chip
    // visuals are exercised by the density-timeline snapshot above.
    // If this stops being an acceptable proxy we'd need a parallel non-Scroll
    // variant of the header for testing, which feels like SUT pollution.

    func testFindingsSummaryHeader_emptyState() {
        let summary = AnnotationSummary.empty
        let view = FindingsSummaryHeader(
            summary: summary,
            filter: .constant(FindingFilter())
        )
        .frame(width: 360)
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 360, height: 60)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - VariabilityLane

    func testVariabilityLane_empty() {
        // Empty sample list must render the "no metric samples" placeholder,
        // not a chart of zeros — proves the branch renders and the caption
        // still shows the metric header.
        let view = VariabilityLane(
            samples: [],
            timeRangeSeconds: 0...300,
            metricLabel: "RMSSD",
            unit: "ms",
            windowCaption: "5-min window"
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 120)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testVariabilityLane_allEligible() {
        // A monotonically-drifting RMSSD trajectory, all eligible, so it
        // renders as a single line. Time range 0-300s and 30 samples spaced
        // 10s apart cover the whole domain uniformly.
        let samples: [VariabilityLaneSample] = (0..<30).map { i in
            let t = Double(i) * 10.0
            let v = 40.0 + 30.0 * sin(Double(i) * 0.4)
            return VariabilityLaneSample(
                windowStartSeconds: t - 150,
                windowEndSeconds: t + 150,
                value: v,
                isEligible: true
            )
        }
        let view = VariabilityLane(
            samples: samples,
            timeRangeSeconds: 0...300,
            metricLabel: "RMSSD",
            unit: "ms",
            windowCaption: "5-min window"
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 120)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testVariabilityLane_withHoverHighlight() {
        // Same 30-sample sinusoid as the all-eligible case but with an
        // externalHoverTimeSeconds pinned in the middle. Baseline
        // captures the RuleMark + emphasized point + value readout in
        // the caption.
        let samples: [VariabilityLaneSample] = (0..<30).map { i in
            let t = Double(i) * 10.0
            let v = 40.0 + 30.0 * sin(Double(i) * 0.4)
            return VariabilityLaneSample(
                windowStartSeconds: t - 150,
                windowEndSeconds: t + 150,
                value: v,
                isEligible: true
            )
        }
        let view = VariabilityLane(
            samples: samples,
            timeRangeSeconds: 0...300,
            metricLabel: "RMSSD",
            unit: "ms",
            windowCaption: "5-min window · 30 s step",
            externalHoverTimeSeconds: 150,
            selectedPreset: .fiveMinute,
            onLaneHover: nil,
            onPickWindowPreset: { _ in }
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 120)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testVariabilityLane_mixedEligibleIneligible() {
        // Mixed sequence: two eligible runs separated by a bad-quality
        // window. The line must break at the ineligible sample and the
        // ineligible point renders dimmed.
        let samples: [VariabilityLaneSample] = [
            .init(windowStartSeconds:   0, windowEndSeconds:  60, value: 42, isEligible: true),
            .init(windowStartSeconds:  30, windowEndSeconds:  90, value: 48, isEligible: true),
            .init(windowStartSeconds:  60, windowEndSeconds: 120, value: 55, isEligible: true),
            .init(windowStartSeconds:  90, windowEndSeconds: 150, value: .nan, isEligible: false),
            .init(windowStartSeconds: 120, windowEndSeconds: 180, value: 62, isEligible: true),
            .init(windowStartSeconds: 150, windowEndSeconds: 210, value: 58, isEligible: true),
            .init(windowStartSeconds: 180, windowEndSeconds: 240, value: 51, isEligible: true),
        ]
        let view = VariabilityLane(
            samples: samples,
            timeRangeSeconds: 0...240,
            metricLabel: "RMSSD",
            unit: "ms",
            windowCaption: "1-min window · 30 s step"
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 120)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - BeatCalipers

    func testBeatCalipers_withTemplate() {
        // A beat with clear PR/QRS/QT/QTc and a template that has a
        // clear median. Delta column shows the beat is a bit prolonged
        // vs. the analyst's own normal template.
        let beat = MarkingsBeat(
            rPeakSampleIndex: 12500,
            rPeakConfidence: 1.0,
            pOnset:    MarkingsFiducial(kind: .pOnset,    sampleIndex: 12350, confidence: 0.85),
            pOffset:   MarkingsFiducial(kind: .pOffset,   sampleIndex: 12420, confidence: 0.85),
            qrsOnset:  MarkingsFiducial(kind: .qrsOnset,  sampleIndex: 12460, confidence: 0.95),
            qrsOffset: MarkingsFiducial(kind: .qrsOffset, sampleIndex: 12530, confidence: 0.90),
            tOnset:    MarkingsFiducial(kind: .tOnset,    sampleIndex: 12620, confidence: 0.75),
            tOffset:   MarkingsFiducial(kind: .tOffset,   sampleIndex: 12740, confidence: 0.55),
            prMs: 155.0,
            qrsMs: 92.0,
            qtMs: 410.0,
            qtcMs: 445.0,
            precedingRRMs: 820.0
        )
        let template = MarkingsTemplate(
            sampleCount: 200,
            medianPRMs: 148.0, iqrPRMs: 12.0,
            medianQRSMs: 88.0, iqrQRSMs: 6.0,
            medianQTMs: 395.0, iqrQTMs: 18.0,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 428.0, iqrQTcMs: 16.0
        )
        let view = BeatCalipers(beat: beat, sampleRate: 360, template: template, qtcFormula: .fridericia)
            .frame(width: 250)
            .padding()
            .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 300, height: 200)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testBeatCalipers_noTemplate() {
        // Delta columns should degrade gracefully to "—" when no
        // template exists yet (early after recording load).
        let beat = MarkingsBeat(
            rPeakSampleIndex: 12500,
            prMs: 155.0, qrsMs: 92.0, qtMs: 410.0, qtcMs: 445.0, precedingRRMs: 820.0
        )
        let view = BeatCalipers(beat: beat, sampleRate: 360, template: nil, qtcFormula: .fridericia)
            .frame(width: 250)
            .padding()
            .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 300, height: 200)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - IntervalTrendLane

    /// Builds a canonical trend fixture — 15 bins across one hour with
    /// a mid-recording low-confidence stretch — that the snapshot tests
    /// below reuse across show modes.
    private func makeCanonicalTrendData() -> IntervalTrendData {
        let bins: [IntervalTrendBin] = (0..<15).map { i in
            let start = Double(i) * 120  // 2-min bins
            let rise = 40 / (1 + exp(-(Double(i) - 6) / 1.5))
            let median = 420 + rise
            let eligible = !(i == 8 || i == 9)
            // Fill in ~40 per-beat values around the bin's median with
            // a bit of spread, so the scatter show-mode renders like a
            // real recording would look.
            let perBeat: [Double] = eligible
                ? (0..<40).map { j in
                    let jitter = sin(Double(j) * 0.7) * 4
                    return median + jitter
                }
                : []
            return IntervalTrendBin(
                startSeconds: start,
                endSeconds: start + 120,
                median: eligible ? median : median + 8,
                q1: eligible ? median - 6 : median,
                q3: eligible ? median + 6 : median,
                isEligible: eligible,
                beatCount: 60,
                perBeatValues: perBeat
            )
        }
        return IntervalTrendData(
            bins: bins,
            baselineBand: 412...428,
            baselineMedian: 420,
            reproCaption: "QTc · Fridericia · 2-min bins · normal template = 214 beats"
        )
    }

    func testIntervalTrendLane_medianAndIQRWithBaseline() {
        let view = IntervalTrendLane(
            timeRangeSeconds: 0...1800,
            data: makeCanonicalTrendData(),
            metric: .qtc,
            showMode: .medianAndIQR,
            selectedBinPreset: .twoMinute
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 160)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testIntervalTrendLane_perBeatScatter() {
        // Scatter show-mode renders every eligible per-beat value as a
        // faint point. Guards against the "scatter mode is wired but
        // the data path never populated perBeatValues" regression.
        let view = IntervalTrendLane(
            timeRangeSeconds: 0...1800,
            data: makeCanonicalTrendData(),
            metric: .qtc,
            showMode: .perBeatScatter,
            selectedBinPreset: .twoMinute
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 160)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testIntervalTrendLane_withGuidesAndEvents() {
        // The overlay layer: analyst-set threshold guides (dashed
        // horizontal lines) + analyst-authored events (vertical
        // markers). Exercises the "(user-set)" tagging and the
        // event-label rendering.
        let guides = [
            IntervalTrendGuide(metric: .qtc, valueMs: 500, label: "500 ms (user-set)")
        ]
        let events = [
            IntervalTrendEvent(timeSeconds: 480, label: "Sotalol started")
        ]
        let view = IntervalTrendLane(
            timeRangeSeconds: 0...1800,
            data: makeCanonicalTrendData(),
            metric: .qtc,
            showMode: .medianAndIQR,
            selectedBinPreset: .twoMinute,
            guides: guides,
            events: events
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 180)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testIntervalTrendLane_emptyState() {
        let data = IntervalTrendData(
            bins: [],
            baselineBand: nil,
            baselineMedian: nil,
            reproCaption: "QTc · Fridericia · 2-min bins · no template"
        )
        let view = IntervalTrendLane(
            timeRangeSeconds: 0...300,
            data: data,
            metric: .qtc,
            showMode: .medianAndIQR,
            selectedBinPreset: .twoMinute
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 140)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - ECGMetricsView / ECGMetricsLockedView
    //
    // Gated on `canImport(MurmurMetrics)` so the file still compiles
    // for anyone who hasn't linked the private framework into this
    // test target. Local-only per the CI skip in setUpWithError.

    #if canImport(MurmurMetrics)

    func testECGMetricsView_populated() {
        // Alternating 800 / 850 ms intervals produce a stable, easily
        // hand-checkable report. Only 10 beats — below the Task Force
        // 256-beat minimum, so the "interpret variability with
        // caution" advisory row renders and is part of this baseline.
        let intervals: [Double] = [800, 850, 800, 850, 800, 850, 800, 850, 800, 850]
        let report = ECGMetricsService.compute(fromRRIntervalsMs: intervals)
        let view = ECGMetricsView(report: report)
            .frame(width: 300)
            .padding()
            .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 340, height: 320)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testECGMetricsView_populated_adequate() {
        // 300 alternating intervals — comfortably above the Task Force
        // 256-beat minimum, so the advisory row is SUPPRESSED. Guards
        // the boundary in the opposite direction from
        // `testECGMetricsView_populated` (which is intentionally
        // below the minimum).
        var intervals = [Double]()
        for i in 0..<300 { intervals.append(i.isMultiple(of: 2) ? 800 : 850) }
        let report = ECGMetricsService.compute(fromRRIntervalsMs: intervals)
        let view = ECGMetricsView(report: report)
            .frame(width: 300)
            .padding()
            .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 340, height: 260)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testECGMetricsView_empty() {
        // `nil` report renders the "no beat data available" empty state
        // rather than a card of zeros — proves the branch renders.
        let view = ECGMetricsView(report: nil)
            .frame(width: 300)
            .padding()
            .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 340, height: 140)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testECGMetricsLockedView() {
        // Locked/marketing variant with a stable price string. The Buy
        // and Restore closures do nothing — this is a layout snapshot,
        // not an interaction test.
        let view = ECGMetricsLockedView(
            displayPrice: "$9.99",
            onBuy: {},
            onRestore: {}
        )
        .frame(width: 340)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 380, height: 260)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    #endif // canImport(MurmurMetrics)
}

#endif // canImport(SnapshotTesting)
