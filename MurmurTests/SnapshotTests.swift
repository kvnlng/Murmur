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

@MainActor
final class SnapshotTests: XCTestCase {

    // To re-record baselines after an intentional UI change, uncomment:
    // override func invokeTest() {
    //     withSnapshotTesting(record: .all) {
    //         super.invokeTest()
    //     }
    // }

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
            severity: .warning,
            source: "demo-detector-v2",
            note: "Couplet, R-on-T morphology"
        )
        let size = CGSize(width: 280, height: 160)
        let view = AnnotationTooltip(annotation: annotation, sampleRate: 250)
            .frame(width: 240)
            .padding()
        assertSnapshot(of: render(view, size: size), as: .image)
    }

    func testAnnotationTooltip_rangeWithoutNote() {
        let annotation = Annotation(
            kind: .range,
            sampleIndex: 6000,
            endSampleIndex: 9500,
            category: "VT",
            severity: .critical,
            source: "vt-detector-v1"
        )
        let size = CGSize(width: 280, height: 110)
        let view = AnnotationTooltip(annotation: annotation, sampleRate: 250)
            .frame(width: 240)
            .padding()
        assertSnapshot(of: render(view, size: size), as: .image)
    }

    // MARK: - WaveformTimeAxis

    func testTimeAxis_defaultTenSecondViewport() {
        let size = CGSize(width: 676, height: 32)
        let view = WaveformTimeAxis(startTime: 0, endTime: 10)
            .frame(width: 660, height: 16)
            .padding(.horizontal, 8)
            .background(Color.white)
        assertSnapshot(of: render(view, size: size), as: .image)
    }

    func testTimeAxis_zoomedSixtySecondViewport() {
        let size = CGSize(width: 676, height: 32)
        let view = WaveformTimeAxis(startTime: 120, endTime: 180)
            .frame(width: 660, height: 16)
            .padding(.horizontal, 8)
            .background(Color.white)
        assertSnapshot(of: render(view, size: size), as: .image)
    }

    // MARK: - WaveformVoltageAxis

    func testVoltageAxis_defaultRange() {
        let size = CGSize(width: 56, height: 188)
        let view = WaveformVoltageAxis(yMin: -1.5, yMax: 1.5, durationSeconds: 10)
            .frame(width: 56, height: 180)
            .padding(.vertical, 4)
            .background(Color.white)
        assertSnapshot(of: render(view, size: size), as: .image)
    }

    // MARK: - FindingDensityTimeline

    func testFindingDensityTimeline_mixedCategories() {
        let totalSamples: Int64 = 30_000
        let annotations: [Annotation] = [
            Annotation(kind: .point, sampleIndex: 1_000,  category: "PVC",  severity: .warning,  source: "demo"),
            Annotation(kind: .point, sampleIndex: 2_500,  category: "PVC",  severity: .critical, source: "demo"),
            Annotation(kind: .point, sampleIndex: 5_500,  category: "PVC",  severity: .info,     source: "demo"),
            Annotation(kind: .range, sampleIndex: 10_000, endSampleIndex: 17_500,
                       category: "AFib", severity: .warning,  source: "demo"),
            Annotation(kind: .range, sampleIndex: 20_000, endSampleIndex: 21_200,
                       category: "VT",   severity: .critical, source: "demo"),
            Annotation(kind: .point, sampleIndex: 25_000, category: "noise", severity: .info, source: "demo")
        ]
        let viewport = RecordingViewport(
            totalSamples: totalSamples,
            sampleRate: 250,
            initialDurationSeconds: 10
        )
        let view = FindingDensityTimeline(
            annotations: annotations,
            totalSamples: totalSamples,
            sampleRate: 250,
            viewport: viewport,
            onJump: { _ in }
        )
        .frame(width: 520)
        .padding()
        .background(Color.white)
        assertSnapshot(of: render(view, size: CGSize(width: 552, height: 160)), as: .image)
    }

    // MARK: - FindingsSummaryHeader

    // testFindingsSummaryHeader_mixedFindings: dropped from the snapshot suite.
    // The chip row lives inside a horizontal ScrollView; ImageRenderer measures
    // a ScrollView's natural size as zero and emits a blank image. The chip
    // visuals (color + severity badge) are exercised by the density-timeline
    // snapshot above; severity-alpha logic is covered by CategoryPaletteTests.
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
        assertSnapshot(of: render(view, size: CGSize(width: 360, height: 60)), as: .image)
    }
}

#endif // canImport(SnapshotTesting)
