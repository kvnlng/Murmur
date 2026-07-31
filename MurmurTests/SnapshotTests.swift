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

// swiftlint:disable type_body_length file_length
// One snapshot per rendered surface — the suite grows with the UI it guards,
// and splitting it by view would scatter the shared render/assert helpers.
@MainActor
final class SnapshotTests: XCTestCase {

    // To re-record baselines after an intentional UI change, uncomment:
    // override func invokeTest() {
    //     withSnapshotTesting(record: .missing) {
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
    /// Internal so extensions in this file can use it.
    func render<V: View>(_ view: V, size: CGSize) -> NSImage {
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

    // MARK: - WaveformAnnotationOverlay (cluster hit-counter badges)

    func testWaveformAnnotationOverlay_lowZoomClusterBadge() {
        // 12 PVCs bunched at the start of a 60-second viewport at 250 Hz
        // (0.5 to 2.9 s in 0.2 s steps) — at ~11 pixels-per-second the
        // labels collide and the cluster collapses to one hit-counter
        // badge. A lone VT tag stays as unbadged text.
        var annotations: [Annotation] = []
        for i in 0..<12 {
            annotations.append(
                Annotation(
                    kind: .point,
                    sampleIndex: Int64(125 + i * 50),
                    category: "PVC",
                    source: "demo"
                )
            )
        }
        annotations.append(
            Annotation(
                kind: .point,
                sampleIndex: 12_000,
                category: "VT",
                source: "demo"
            )
        )
        let view = WaveformAnnotationOverlay(
            annotations: annotations,
            startSample: 0,
            endSample: 15_000
        )
        .frame(width: 660, height: 40)
        .background(Color.white)
        assertSnapshot(
            of: render(view, size: CGSize(width: 660, height: 40)),
            as: .image(precision: 0.98, perceptualPrecision: 0.96)
        )
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

    /// Ectopic-beat variant (mockup-review Correction A, ratified
    /// 2026-07-05): PR / QT / QTc render as "—" with muted-italic
    /// styling. QRS remains a valid measurement (ectopic beats have a
    /// measurable QRS width). Also renders the "Ectopic — PR / QT
    /// undefined" subtitle beneath the header.
    func testBeatCalipers_ectopicBeat() {
        // Beat with plausibly-computed PR/QT/QTc that the delineator
        // would emit even for a PVC — the caliper's job is to REFUSE
        // to render them as confident numbers.
        let beat = MarkingsBeat(
            rPeakSampleIndex: 12500,
            rPeakConfidence: 1.0,
            qrsOnset:  MarkingsFiducial(kind: .qrsOnset,  sampleIndex: 12440, confidence: 0.95),
            qrsOffset: MarkingsFiducial(kind: .qrsOffset, sampleIndex: 12560, confidence: 0.90),
            prMs: 119.0, qrsMs: 138.0, qtMs: 380.0, qtcMs: 418.0, precedingRRMs: 620.0
        )
        let template = MarkingsTemplate(
            sampleCount: 200,
            medianPRMs: 148.0, iqrPRMs: 12.0,
            medianQRSMs: 88.0, iqrQRSMs: 6.0,
            medianQTMs: 395.0, iqrQTMs: 18.0,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 428.0, iqrQTcMs: 16.0
        )
        let view = BeatCalipers(
            beat: beat,
            sampleRate: 360,
            template: template,
            qtcFormula: .fridericia,
            kind: .ectopic
        )
        .frame(width: 250)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 300, height: 220)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// Physically impossible beat (X53) — QT would occupy an absurd fraction of
    /// the cycle. The caliper states "Excluded — QT physically impossible" and
    /// refuses to render PR / QRS / QT / QTc as numbers, since the beat was
    /// withheld from the aggregates.
    func testBeatCalipers_excludedBeat() {
        let beat = MarkingsBeat(
            rPeakSampleIndex: 12500,
            rPeakConfidence: 1.0,
            qrsOnset:  MarkingsFiducial(kind: .qrsOnset,  sampleIndex: 12440, confidence: 0.95),
            qrsOffset: MarkingsFiducial(kind: .qrsOffset, sampleIndex: 12560, confidence: 0.90),
            prMs: 150.0, qrsMs: 96.0, qtMs: 540.0, qtcMs: 664.0, precedingRRMs: 654.0,
            isImplausible: true
        )
        let template = MarkingsTemplate(
            sampleCount: 200,
            medianPRMs: 148.0, iqrPRMs: 12.0,
            medianQRSMs: 88.0, iqrQRSMs: 6.0,
            medianQTMs: 395.0, iqrQTMs: 18.0,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 428.0, iqrQTcMs: 16.0
        )
        let view = BeatCalipers(
            beat: beat,
            sampleRate: 360,
            template: template,
            qtcFormula: .fridericia,
            kind: .unknown
        )
        .frame(width: 250)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 300, height: 220)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// Wide-QRS beat (X54) — QRS ≥ 120 ms, so JT (QT − QRS) and JTc are
    /// surfaced beneath QTc. Transcription of already-measured intervals; no
    /// BBB adjustment is applied.
    func testBeatCalipers_wideQRSWithJT() {
        let beat = MarkingsBeat(
            rPeakSampleIndex: 12500,
            rPeakConfidence: 1.0,
            qrsOnset:  MarkingsFiducial(kind: .qrsOnset,  sampleIndex: 12435, confidence: 0.95),
            qrsOffset: MarkingsFiducial(kind: .qrsOffset, sampleIndex: 12565, confidence: 0.92),
            prMs: 158.0, qrsMs: 130.0, qtMs: 440.0, qtcMs: 452.0, precedingRRMs: 900.0,
            jtMs: 310.0, jtcMs: 322.0
        )
        let template = MarkingsTemplate(
            sampleCount: 200,
            medianPRMs: 150.0, iqrPRMs: 12.0,
            medianQRSMs: 126.0, iqrQRSMs: 8.0,
            medianQTMs: 438.0, iqrQTMs: 18.0,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 450.0, iqrQTcMs: 16.0
        )
        let view = BeatCalipers(
            beat: beat,
            sampleRate: 360,
            template: template,
            qtcFormula: .fridericia,
            kind: .unknown
        )
        .frame(width: 250)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 300, height: 260)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// Censored beat — T-offset walk clipped at ceiling. QT / QTc render
    /// as "≥ X ms" (lower bound, not a point estimate) with the
    /// calibrated ± half-width surfaced in the delta column per
    /// project_qtc_trend_uncertainty_wireup_spec.md.
    func testBeatCalipers_censoredWithCalibratedCI() {
        let beat = MarkingsBeat(rPeakSampleIndex: 12500, rPeakConfidence: 1.0,
            qrsOnset: MarkingsFiducial(kind: .qrsOnset, sampleIndex: 12460, confidence: 0.95),
            qrsOffset: MarkingsFiducial(kind: .qrsOffset, sampleIndex: 12530, confidence: 0.90),
            tOffset: MarkingsFiducial(kind: .tOffset, sampleIndex: 12960, confidence: 0.30),
            prMs: 155, qrsMs: 92, qtMs: 500, qtcMs: 545, precedingRRMs: 820,
            tOffsetCensored: true, qtCalibratedHalfWidthMs: 22)
        let template = MarkingsTemplate(sampleCount: 200,
            medianPRMs: 148, iqrPRMs: 12, medianQRSMs: 88, iqrQRSMs: 6,
            medianQTMs: 395, iqrQTMs: 18,
            qtcFormulaName: "Fridericia", medianQTcMs: 428, iqrQTcMs: 16)
        let view = BeatCalipers(beat: beat, sampleRate: 360, template: template, qtcFormula: .fridericia)
            .frame(width: 260).padding().background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 310, height: 200)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    // MARK: - IntervalTrendLane

    /// Builds a canonical trend fixture — 15 bins across one hour with
    /// a mid-recording low-confidence stretch — that the snapshot tests
    /// below reuse across show modes.
    /// Internal so extensions can share the fixture.
    func makeCanonicalTrendData() -> IntervalTrendData {
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
            let m = eligible ? median : median + 8
            let q1 = eligible ? median - 6 : median
            let q3 = eligible ? median + 6 : median
            // Measurement band: bootstrap CI on the median is a tight
            // ~2-3 ms window around the point estimate at ~40 beats/bin.
            let bandHalf: Double = eligible ? 2.5 : 0
            return IntervalTrendBin(
                startSeconds: start,
                endSeconds: start + 120,
                median: m,
                q1: q1,
                q3: q3,
                bandLowerMs: m - bandHalf,
                bandUpperMs: m + bandHalf,
                hasCensoredBeats: false,
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
            band: .window,          // X41: scatter renders only at window scale
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

    /// Renders a censored zone in the middle of the recording — bins
    /// containing a T-offset-clipped beat get the open-top band +
    /// up-chevron + "QT ≥" treatment per
    /// project_qtc_trend_uncertainty_wireup_spec.md. Distinct from the
    /// low-confidence hatch: censored means "at least this prolonged,"
    /// low-confidence means "measured but noisy."
    func testIntervalTrendLane_censoredLowerBound() {
        let bins: [IntervalTrendBin] = (0..<15).map { i in
            let start = Double(i) * 120
            let rise = 40 / (1 + exp(-(Double(i) - 6) / 1.5))
            let median = 420 + rise
            // Bins 10-12: T-offset walk clipped at ceiling → true QT
            // is ≥ the reported bandLower.
            let censored = (10...12).contains(i)
            let m = median
            let q1 = median - 6
            let q3 = median + 6
            let perBeat: [Double] = (0..<40).map { j in
                let jitter = sin(Double(j) * 0.7) * 4
                return m + jitter
            }
            return IntervalTrendBin(
                startSeconds: start,
                endSeconds: start + 120,
                median: m,
                q1: q1,
                q3: q3,
                bandLowerMs: m - 2.5,
                bandUpperMs: m + 2.5,
                hasCensoredBeats: censored,
                isEligible: true,
                beatCount: 60,
                perBeatValues: perBeat
            )
        }
        let data = IntervalTrendData(
            bins: bins,
            baselineBand: 412...428,
            baselineMedian: 420,
            reproCaption: "QTc · Fridericia · 2-min bins · normal template = 214 beats"
        )
        let view = IntervalTrendLane(
            timeRangeSeconds: 0...1800,
            data: data,
            metric: .qtc,
            showMode: .medianAndIQR,
            selectedBinPreset: .twoMinute
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 180)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// Range finding — analyst-authored amber overlay + chip. Amber is
    /// the ONLY layer on the lane that carries the caution accent.
    func testIntervalTrendLane_rangeFinding() {
        let findings = [IntervalTrendRangeFinding(startSeconds: 600, endSeconds: 1400, label: "Prolonged QTc")]
        let view = IntervalTrendLane(timeRangeSeconds: 0...1800, data: makeCanonicalTrendData(),
                                     metric: .qtc, showMode: .medianAndIQR,
                                     selectedBinPreset: .twoMinute, rangeFindings: findings)
            .frame(width: 520).padding().background(Color.white)
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

// MARK: - FiducialOverlay snapshots
//
// Extension so SwiftLint's `type_body_length` rule stays under the
// 500-line threshold on the primary class body (extensions are
// counted separately).

@MainActor
extension SnapshotTests {

    /// Authoring marquee mid-drag — amber semi-transparent rectangle
    /// spanning the snapped bin range + live readout chip
    /// (project_drag_to_author_range_finding_spec.md). Seeded via
    /// `debugAuthoringMarquee` since SwiftUI ImageRenderer can't fire
    /// the real DragGesture in a headless snapshot pass.
    func testIntervalTrendLane_authoringMarquee() {
        // Uses the same fixture as the other lane tests. The marquee
        // covers t=600..1200 = bins 5..9 = 3 min of QTc rising
        // through the drug region.
        let data = makeCanonicalTrendData()
        let view = IntervalTrendLane(timeRangeSeconds: 0...1800, data: data,
            metric: .qtc, showMode: .medianAndIQR, selectedBinPreset: .twoMinute,
            onAuthorRange: { _, _, _, _ in },
            debugAuthoringMarquee: 600...1200)
            .frame(width: 520).padding().background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 180)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// Tangent↔isoelectric bracket render at full-zoom LOD (Phase 6 of
    /// project_qtc_trend_uncertainty_wireup_spec.md). Visible span
    /// between the T-offset point mark (tangent, LOWER edge) and the
    /// isoelectric endpoint (UPPER edge) = per-beat T-offset
    /// uncertainty bounded by two independent algorithms.
    func testFiducialOverlay_tOffsetBracket() {
        let beat = MarkingsBeat(rPeakSampleIndex: 500, rPeakConfidence: 1.0,
            pOnset: MarkingsFiducial(kind: .pOnset, sampleIndex: 380, confidence: 0.85),
            pOffset: MarkingsFiducial(kind: .pOffset, sampleIndex: 430, confidence: 0.85),
            qrsOnset: MarkingsFiducial(kind: .qrsOnset, sampleIndex: 470, confidence: 0.95),
            qrsOffset: MarkingsFiducial(kind: .qrsOffset, sampleIndex: 540, confidence: 0.90),
            tOnset: MarkingsFiducial(kind: .tOnset, sampleIndex: 620, confidence: 0.75),
            tOffset: MarkingsFiducial(kind: .tOffset, sampleIndex: 700, confidence: 0.70),
            tOffsetIsoelectricSampleIndex: 740)
        let view = FiducialOverlay(beats: [beat], viewportSampleRange: 300..<900,
            sampleRate: 250, detailLevel: .fullFiducials, focusedRPeakSampleIndex: 500,
            enabledLayers: [.p, .qrs, .t], canvasSize: CGSize(width: 520, height: 120))
            .frame(width: 520, height: 120).padding().background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 160)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// Same annotation set as `_lowZoomClusterBadge`, but at the Scan
    /// tier the rail collapses chips into short colored ticks and drops
    /// normal ("N") beats entirely. Locks in the
    /// project_waveform_zoom_lod_spec.md rail treatment for Scan.
    func testWaveformAnnotationOverlay_scanTierFlaggedTicks() {
        var annotations: [Annotation] = []
        for i in 0..<12 {
            annotations.append(Annotation(kind: .point, sampleIndex: Int64(125 + i * 50),
                                          category: "PVC", source: "demo"))
        }
        for i in 0..<8 {
            annotations.append(Annotation(kind: .point, sampleIndex: Int64(4_000 + i * 250),
                                          category: "N", source: "demo"))
        }
        annotations.append(Annotation(kind: .point, sampleIndex: 12_000,
                                      category: "VT", source: "demo"))
        let view = WaveformAnnotationOverlay(annotations: annotations,
            startSample: 0, endSample: 15_000, tier: .scan)
            .frame(width: 660, height: 40).background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 660, height: 40)),
                       as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// At Context the overlay's rail carries only INDIVIDUALLY
    /// LOCATABLE landmarks — SF Symbol glyphs for rare flagged
    /// categories. Categories whose count would blow past
    /// count * minMarkSpacing collapse into the density lane below the
    /// trace (rendered by AnnotationDensityLane), not this overlay.
    func testWaveformAnnotationOverlay_contextTierLandmarks() {
        // A rare rhythm event + a rare fusion event, plus a wall of
        // ventricular ectopy that would blow past the landmark budget.
        var annotations: [Annotation] = []
        annotations.append(Annotation(kind: .point, sampleIndex: 2_000,
                                      category: "rhythm", source: "demo"))
        annotations.append(Annotation(kind: .point, sampleIndex: 9_000,
                                      category: "F", source: "demo"))
        for i in 0..<60 {
            annotations.append(Annotation(kind: .point, sampleIndex: Int64(500 + i * 200),
                                          category: "PVC", source: "demo"))
        }
        let view = WaveformAnnotationOverlay(annotations: annotations,
            startSample: 0, endSample: 15_000, tier: .context)
            .frame(width: 660, height: 40).background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 660, height: 40)),
                       as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// AnnotationDensityLane: bulk ventricular ectopy collapses into a
    /// per-bucket density strip below the trace. Neutral ink (never
    /// category-hued — RUO consistency).
    func testAnnotationDensityLane_bulkVentricular() {
        // Bimodal density: a dense burst 20–40% of the window, a lighter
        // burst 60–80%. Reads as two visible clumps in the strip.
        var annotations: [Annotation] = []
        for i in 0..<80 {
            annotations.append(Annotation(kind: .point, sampleIndex: Int64(3_000 + i * 25),
                                          category: "PVC", source: "demo"))
        }
        for i in 0..<40 {
            annotations.append(Annotation(kind: .point, sampleIndex: Int64(9_000 + i * 75),
                                          category: "PVC", source: "demo"))
        }
        let view = AnnotationDensityLane(
            bulkAnnotations: annotations,
            startSample: 0,
            endSample: 15_000,
            categoryLabel: "PVC"
        )
        .frame(width: 660).background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 660, height: 44)),
                       as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }
}

// Kept in an extension so the main class body stays under SwiftLint's
// type_body_length cap.
extension SnapshotTests {

    func testOverviewMap_withVTVFCandidates() {
        let totalSamples: Int64 = 60_000
        let annotations: [Annotation] = [
            Annotation(kind: .point, sampleIndex: 2_000, category: "N", source: "demo"),
            Annotation(kind: .point, sampleIndex: 8_000, category: "N", source: "demo")
        ]
        // Two neutral candidate bands at different positions / lengths.
        let candidates: [Annotation] = [
            VTVFCandidateSource.makeAnnotation(startSample: 30_000, endSample: 34_000, score: 0.93),
            VTVFCandidateSource.makeAnnotation(startSample: 48_000, endSample: 49_000, score: 0.81)
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
            channelName: "I",
            candidates: candidates
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 120)), as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }
}

// MARK: - CalibrationReadout (X40)
// In an extension so the main class body stays under the type-body-length cap.
@MainActor
extension SnapshotTests {

    // Rendered at the real 220 pt inspector-column width so wrapping of the
    // "· non-standard" / fallback text is exercised, not just the happy line.
    func testCalibrationReadout_standard() {
        let reading = CalibrationReading.make(
            windowSeconds: 10, canvasWidthPoints: 1250, canvasHeightPoints: 500,
            visibleMillivoltSpan: 10, millimetersPerPoint: 0.2
        )
        let view = CalibrationReadout(reading: reading)
            .frame(width: 220)
            .padding(8)
            .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 236, height: 44)),
                       as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testCalibrationReadout_nonStandard() {
        let reading = CalibrationReading.make(
            windowSeconds: 10, canvasWidthPoints: 2500, canvasHeightPoints: 500,
            visibleMillivoltSpan: 5, millimetersPerPoint: 0.2
        )
        let view = CalibrationReadout(reading: reading)
            .frame(width: 220)
            .padding(8)
            .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 236, height: 64)),
                       as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    func testCalibrationReadout_pointFallback() {
        let reading = CalibrationReading.make(
            windowSeconds: 10, canvasWidthPoints: 1250, canvasHeightPoints: 500,
            visibleMillivoltSpan: 10, millimetersPerPoint: nil
        )
        let view = CalibrationReadout(reading: reading)
            .frame(width: 220)
            .padding(8)
            .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 236, height: 84)),
                       as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }
}

// MARK: - Interval trend lane LOD coercion (X41)
@MainActor
extension SnapshotTests {

    /// At map scale a per-beat-scatter PREFERENCE is coerced to median + IQR
    /// (no whole-recording point wall) and the "zoom in for per-beat" hint
    /// appears. Pickers are omitted (a live Menu renders as a placeholder in
    /// the headless ImageRenderer); the hint renders independently of them.
    func testIntervalTrendLane_scatterCoercedAtMapScale() {
        let view = IntervalTrendLane(
            timeRangeSeconds: 0...1800,
            data: makeCanonicalTrendData(),
            metric: .qtc,
            showMode: .perBeatScatter,
            band: .map,
            selectedBinPreset: .twoMinute
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 160)),
                       as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }

    /// X43: bins whose preceding-2-min rate was unstable carry a thin neutral
    /// band along the BOTTOM edge — distinct in position + ink from the
    /// full-height low-confidence fill and the open-top censored treatment.
    func testIntervalTrendLane_rateStabilityMarker() {
        let bins: [IntervalTrendBin] = (0..<12).map { i in
            let start = Double(i) * 120
            let median = 440.0 + (i >= 5 ? 20 : 0)
            // Bins 5–7 sit just after a rate change → rate-unstable.
            let unstable = (5...7).contains(i)
            return IntervalTrendBin(
                startSeconds: start, endSeconds: start + 120,
                median: median, q1: median - 5, q3: median + 5,
                bandLowerMs: median - 2.5, bandUpperMs: median + 2.5,
                hasCensoredBeats: false, isEligible: true, beatCount: 60,
                perBeatValues: [median],
                rateMaxDeviationBpm: unstable ? 7 : 0.5,
                rateStable: !unstable
            )
        }
        let data = IntervalTrendData(
            bins: bins, baselineBand: 432...448, baselineMedian: 440,
            reproCaption: "QTc · Fridericia · 2-min bins · normal template = 214 beats"
        )
        let view = IntervalTrendLane(
            timeRangeSeconds: 0...1440,
            data: data,
            metric: .qtc,
            showMode: .medianAndIQR,
            selectedBinPreset: .twoMinute
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 160)),
                       as: .image(precision: 0.98, perceptualPrecision: 0.96))
    }
}

#endif // canImport(SnapshotTesting)
