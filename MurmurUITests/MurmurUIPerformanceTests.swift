//
//  MurmurUIPerformanceTests.swift
//  MurmurUITests
//
//  Performance & smoothness metrics. These tests run each scenario multiple
//  iterations under an `XCTMetric` so regressions show up as drift in the
//  Xcode test report's baseline. They're not pass/fail correctness tests;
//  they're trend lines.
//
//  How to read the results: each metric reports an average + standard
//  deviation across the iterations. Xcode lets you set a baseline; future
//  runs that exceed the baseline by a configurable threshold fail.
//
//  What's measured (and what isn't):
//    • Cold launch, fixture load, and the key viewport-mutating interactions —
//      these are the "feel" of the app for an analyst, so we want to know
//      when a feature degrades them.
//    • We do NOT measure native gesture recognition. Drag-pan and pinch-zoom
//      gestures aren't synthesisable under XCUI on macOS, so the latency
//      tests use the same `--ui-test-pan-by` / `--ui-test-zoom-to` bypasses
//      the bypass tests use. The number reported reflects the viewport
//      mutation cost, not the gesture-recognition cost.
//    • Renderer frame time / animation hitch metrics are iOS-only. On macOS
//      the closest proxy is the clock metric on the find-row jump, which
//      includes the 250 ms animateJump.
//
//  Cost: each test does 3 measure iterations. At ~5 s per launch that's
//  ~15 s/test; the suite runs in roughly 2 minutes. If CI gets squeezed,
//  consider splitting into a separate xctestplan that runs nightly.
//

import XCTest

final class MurmurUIPerformanceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The `XCTOSSignpostMetric` tests below read custom-subsystem signposts
    /// emitted from the launched app process. On the Xcode Cloud macOS runner
    /// those cross-process signposts don't surface in the runner's metric
    /// collection, and the `measure` block stalls waiting for trace data that
    /// never arrives — the test runs to the 10-minute execution-time limit and
    /// is killed. These are diagnostic trend-line tests (not pass/fail
    /// correctness), meant to be read with Instruments attached on a developer
    /// machine, so we skip them on CI rather than burn the runner budget.
    private func skipSignpostMetricsOnCI() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Signpost perf metrics skipped on CI — signposts don't surface cross-process on the Cloud runner and stall the measure block; run locally with Instruments.")
        }
    }

    // MARK: - Launch & load

    @MainActor
    func testColdLaunchTime() throws {
        // Pure cold launch — no synthetic fixture, no recents seed. Measures
        // the time from "click launch" to first-paint of the welcome view.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launch()
        }
    }

    @MainActor
    func testSyntheticFixtureLoadTime() throws {
        // End-to-end clock for the "Try a sample recording" path: launch +
        // synthetic record generation + WFDB import + bedside render. This
        // is the path the welcome demo and every UI test uses, so its cost
        // gates the rest of the suite.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-sample"]
            app.launch()
            let bedside = app.descendants(matching: .any)
                .matching(identifier: "bedside-view").firstMatch
            XCTAssertTrue(bedside.waitForExistence(timeout: 10))
        }
    }

    // MARK: - Viewport interaction latency

    @MainActor
    func testFindingRowJumpLatency() throws {
        // Measures the click → animateJump → viewport-state-label-changed
        // round-trip. Includes the 250 ms SwiftUI animation by design — that
        // animation IS the felt latency for the analyst.
        //
        // Launch happens outside the measure block so we're timing the
        // interaction, not the launch (covered by testSyntheticFixtureLoadTime).
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 10))

        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            // Each iteration clicks a different row (VF then VT then VF…) so
            // the viewport actually has to move every time — if we kept
            // clicking the same row, the second-onwards iterations would
            // measure ~0ms because the viewport is already there.
            let initialLabel = viewportState.label
            let row = app.buttons.matching(identifier: "finding-row-VF").firstMatch
            XCTAssertTrue(row.exists)
            row.click()
            let changed = NSPredicate(format: "label != %@", initialLabel)
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: changed, object: viewportState)],
                timeout: 3
            )
            // Move it back so the next iteration has somewhere to jump to.
            let resetLabel = viewportState.label
            let other = app.buttons.matching(identifier: "finding-row-VT").firstMatch
            XCTAssertTrue(other.exists)
            other.click()
            let changedAgain = NSPredicate(format: "label != %@", resetLabel)
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: changedAgain, object: viewportState)],
                timeout: 3
            )
        }
    }

    @MainActor
    func testViewportPanLatency() throws {
        // Time from app launch with --ui-test-pan-by=200 to the viewport
        // landing at start=200. Captures the cost of viewport.setStart plus
        // the SwiftUI re-render that updates the accessibility label.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-test-sample",
                "--ui-test-initial-duration=2",
                "--ui-test-pan-by=200"
            ]
            app.launch()
            let viewportState = app.descendants(matching: .any)
                .matching(identifier: "ui-test-viewport-state").firstMatch
            let expected = NSPredicate(format: "label == 'start=200 end=700'")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: expected, object: viewportState)],
                timeout: 10
            )
        }
    }

    @MainActor
    func testWarmPanBurstSignpostLatency() throws {
        // Paired with `testColdPanFrameSignpostLatency` to decompose
        // start-of-pan hesitation into (a) cold-start premium and
        // (b) steady-state per-tick cost.
        //
        // After app launch the bedside view sleeps 500 ms (so MTKView's
        // display link auto-suspends and the renderer goes cold), then
        // fires 10 viewport mutations at ~16 ms cadence — the tick rate of
        // a 60 Hz drag. The signpost intervals captured during the burst
        // include 1 cold tick + 9 warm ticks; the metric reports the
        // average across all 10.
        //
        // Comparison protocol:
        //   • cold_test_avg ≈ cold-tick latency (single tick, always cold)
        //   • burst_test_avg ≈ (cold + 9 × warm) / 10
        //   • warm_per_tick ≈ (10 × burst_test_avg − cold_test_avg) / 9
        //   • cold_premium ≈ cold_test_avg − warm_per_tick
        //
        // If burst_test_avg ≈ cold_test_avg, every tick is paying cold
        // cost — the display link isn't staying spun up between ticks and
        // the warm-on-hover wiring isn't keeping the canvas warm.
        try skipSignpostMetricsOnCI()
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 5
        measure(
            metrics: [
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "UpdateNSView"
                ),
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "Sync"
                ),
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "RendererDraw"
                ),
            ],
            options: measureOptions
        ) {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-test-sample",
                "--ui-test-initial-duration=2",
                "--ui-test-pan-burst=10"
            ]
            app.launch()
            let viewportState = app.descendants(matching: .any)
                .matching(identifier: "ui-test-viewport-state").firstMatch
            // 10 ticks × 40 samples = 400. Initial range is 0..500 (2 s
            // window at the synthetic 250 Hz). Final state = start=400 end=900,
            // both 3-digit so macOS's accessibility post-processor doesn't
            // commafy them and break the equality predicate.
            let expected = NSPredicate(format: "label == 'start=400 end=900'")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: expected, object: viewportState)],
                timeout: 10
            )
        }
    }

    @MainActor
    func testWarmPanBurstSignpostLatency_longRecording() throws {
        // Long-recording variant of `testWarmPanBurstSignpostLatency`.
        // Kevin surfaced (2026-07-06) a pan stutter that scales with
        // TOTAL beat count in the recording: ~163 beats smooth, 1600
        // beats near-standstill. The default burst test uses a 2-sec
        // synthetic fixture (~2 beats) which doesn't exercise the
        // scaling. This variant runs the same burst against a
        // 1000-second synthetic (~1000 beats) so the signpost
        // averages reveal per-tick cost as a function of N_beats.
        //
        // If UpdateNSView / Sync / RendererDraw stay flat vs the
        // short-fixture baseline (~87-105 µs), the render path is
        // NOT the bottleneck — the sluggishness is elsewhere (e.g.,
        // SwiftUI view-diff cost or MarkingsBeat filter allocation).
        // If they scale with N, the render path itself is O(N total
        // beats) somewhere.
        try skipSignpostMetricsOnCI()
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(
            metrics: [
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "UpdateNSView"
                ),
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "Sync"
                ),
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "RendererDraw"
                ),
            ],
            options: measureOptions
        ) {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-test-sample",
                "--ui-test-initial-duration=1000",
                "--ui-test-pan-burst=10"
            ]
            app.launch()
            let viewportState = app.descendants(matching: .any)
                .matching(identifier: "ui-test-viewport-state").firstMatch
            // Wait for the pan burst to land; the exact end range depends
            // on the initial-viewport-duration constant in BedsideView but
            // the burst always advances by 10×40=400 samples.
            let expected = NSPredicate(format: "label CONTAINS 'end='")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: expected, object: viewportState)],
                timeout: 30
            )
        }
    }

    @MainActor
    func testColdPanFrameSignpostLatency() throws {
        // Diagnostic for the start-of-pan hesitation: reads OSSignposter
        // intervals emitted from WaveformCanvas.updateNSView, the inner
        // sync() that rebuilds grid + annotation buffers, and the renderer's
        // draw(in:). Each iteration cold-starts the app and triggers exactly
        // one viewport mutation, so every captured interval is a "first
        // frame after idle" measurement — the exact case the analyst feels
        // when grabbing the chart for a drag.
        //
        // Compare the three intervals: if Sync dominates the
        // UpdateNSView envelope, the per-tick MTLBuffer rebuilds are the
        // culprit. If RendererDraw dominates, the GPU command commit or the
        // display-link wakeup is the culprit. If neither, look upstream at
        // SwiftUI body re-evaluation cost.
        try skipSignpostMetricsOnCI()
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 5
        measure(
            metrics: [
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "UpdateNSView"
                ),
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "Sync"
                ),
                XCTOSSignpostMetric(
                    subsystem: "com.kevinlong.murmur",
                    category: "PointsOfInterest",
                    name: "RendererDraw"
                ),
            ],
            options: measureOptions
        ) {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-test-sample",
                "--ui-test-initial-duration=2",
                "--ui-test-pan-by=200"
            ]
            app.launch()
            let viewportState = app.descendants(matching: .any)
                .matching(identifier: "ui-test-viewport-state").firstMatch
            let expected = NSPredicate(format: "label == 'start=200 end=700'")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: expected, object: viewportState)],
                timeout: 10
            )
        }
    }

    @MainActor
    func testViewportZoomLatency() throws {
        // Time to reach the expected post-zoom viewport state. Captures the
        // cost of viewport.setWidth plus the re-render. Test values stay
        // under 1000 because macOS's accessibility post-processor injects
        // thousands separators into 4+ digit numbers.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-test-sample",
                "--ui-test-initial-duration=2",
                "--ui-test-zoom-to=0.4"
            ]
            app.launch()
            let viewportState = app.descendants(matching: .any)
                .matching(identifier: "ui-test-viewport-state").firstMatch
            let expected = NSPredicate(format: "label == 'start=200 end=300'")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: expected, object: viewportState)],
                timeout: 10
            )
        }
    }

    // MARK: - UI mutation latency

    @MainActor
    func testFindingsPanelToggleLatency() throws {
        // Measures the toolbar-click → panel-content-disappears round-trip.
        // Catches regressions in the inspector animation cost as the
        // findings panel grows feature-wise (chips, badges, etc.).
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-sample"]
        app.launch()

        let toggle = app.buttons.matching(identifier: "findings-toggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 5))

        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            toggle.click()
            let gone = NSPredicate(format: "exists == false")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: gone, object: vfRow)],
                timeout: 3
            )
            // Toggle back so the next iteration has something to hide.
            toggle.click()
            let back = NSPredicate(format: "exists == true")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: back, object: vfRow)],
                timeout: 3
            )
        }
    }

    // MARK: - Memory

    @MainActor
    func testMemoryAfterFixtureLoad() throws {
        // Snapshot the process memory after loading the synthetic fixture.
        // Drift here points at leaked retain cycles, growing per-recording
        // caches, or pyramid/annotation data not being released between
        // bedside views.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTMemoryMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-sample"]
            app.launch()
            let bedside = app.descendants(matching: .any)
                .matching(identifier: "bedside-view").firstMatch
            XCTAssertTrue(bedside.waitForExistence(timeout: 10))
        }
    }
}
