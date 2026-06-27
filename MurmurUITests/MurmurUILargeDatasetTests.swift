//
//  MurmurUILargeDatasetTests.swift
//  MurmurUITests
//
//  Performance & smoothness baselines on a *realistically-sized* recording.
//  The default `MurmurUIPerformanceTests` suite uses a 10-second synthetic
//  fixture, which is fast but tells us nothing about how the app scales when
//  an analyst opens an hour-long ICU recording. This suite generates one
//  hour of 8-lead ECG (~230 MB binary on disk, plus pyramid levels) and
//  measures the same kinds of interactions on that scale.
//
//  Strategy:
//    1. The first test in the run (alphabetical) — `testHourLongImportTime` —
//       is the prep step. It generates the fixture and runs the importer
//       end-to-end, measuring the full import path. The resulting bundle
//       stays on disk at a fixed location.
//    2. Every subsequent test launches with `--ui-test-load-prepped-bundle`
//       and reads the bundle from that fixed location — fast, lets us
//       measure post-import operations without the import dominating the
//       clock.
//    3. We also explicitly model the "first prep" as a test so a regression
//       in `WFDBImporter` shows up as a single, attributable failure.
//
//  Cost:
//    • Import test: 1 iteration, ~15-30 s on a fast Mac. Slower on Xcode
//      Cloud builders — give it a generous timeout.
//    • Navigation tests: 3 iterations × ~3-5 s each.
//    • Memory test: 3 iterations.
//
//  Total suite runtime: ~3-5 minutes added on top of MurmurUIPerformanceTests.
//  If CI gets squeezed, split into Murmur-Performance-Large.xctestplan and
//  trigger nightly.
//
//  Disk usage:
//    • Source WFDB: ~230 MB
//    • Imported bundle: ~300-500 MB (binaries + pyramid levels)
//  Both live under /private/var/folders/.../tmp/ and survive across tests
//  within the same run.
//

import XCTest

final class MurmurUILargeDatasetTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 1. Import time (fresh, one iteration)

    @MainActor
    func test01HourLongImportTime() throws {
        // Measures the full pipeline: generate 1 h of synthetic WFDB +
        // import to bundle + first bedside render. Single iteration because
        // each pass is expensive (multi-second) and we don't want to bloat
        // CI further.
        //
        // This test ALSO serves as the prep step for the rest of the suite.
        // The "01" prefix orders it first alphabetically so XCTest runs it
        // before its dependants. The downstream tests rely on the bundle
        // it leaves at the fixed `/tmp` location.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 1
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-prep-large-fixture"]
            app.launch()
            let bedside = app.descendants(matching: .any)
                .matching(identifier: "bedside-view").firstMatch
            XCTAssertTrue(bedside.waitForExistence(timeout: 180),
                          "1 h fixture generation + import + first paint should finish in under 3 minutes")
        }
    }

    // MARK: - 2. Open from pre-imported bundle

    @MainActor
    func test02HourLongOpenPreImportedBundle() throws {
        // Re-open a previously-imported 1-hour bundle. Skips the WFDB
        // generation and import — measures only the manifest load + memory
        // mapping + first bedside render. This is the "warm" path the
        // analyst experiences after the recording's been imported once.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-load-prepped-bundle"]
            app.launch()
            let bedside = app.descendants(matching: .any)
                .matching(identifier: "bedside-view").firstMatch
            XCTAssertTrue(bedside.waitForExistence(timeout: 30))
        }
    }

    // MARK: - 3. Pan latency on a 1-hour viewport

    @MainActor
    func test03HourLongPanLatency() throws {
        // Pan by 75 000 samples (5 minutes at 250 Hz). Captures the cost of
        // `viewport.setStart` plus the SwiftUI re-render + accessibility-tree
        // update at 1-hour-recording scale — should still be O(1) but a
        // regression that triggers a pyramid re-scan would show up here.
        //
        // The regex predicate tolerates the optional thousands separator
        // macOS injects into 4+ digit numbers in accessibility labels —
        // `start=75000` and `start=75,000` both match.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-test-load-prepped-bundle",
                "--ui-test-initial-duration=10",
                "--ui-test-pan-by=75000"
            ]
            app.launch()
            let viewportState = app.descendants(matching: .any)
                .matching(identifier: "ui-test-viewport-state").firstMatch
            let expected = NSPredicate(format: "label MATCHES 'start=75,?000 end=77,?500'")
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: expected, object: viewportState)],
                timeout: 30
            )
        }
    }

    // MARK: - 4. Zoom out to full extent

    @MainActor
    func test04HourLongZoomToFullExtent() throws {
        // Zoom out to ~3600 s — the entire recording at once. Stresses the
        // overview ribbon's envelope chart load + the canvas's pyramid
        // level selection (it should pick the deepest level fitting the
        // viewport). A regression here is felt as "the app freezes when I
        // hit Zoom Out".
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-test-load-prepped-bundle",
                "--ui-test-initial-duration=10",
                "--ui-test-zoom-to=3600"
            ]
            app.launch()
            // Initial range is 0-2500. After zoom to 3600s × 250Hz = 900000
            // samples anchored at 0.5, viewport becomes -448750 → 451250
            // which clamps to 0 → 900000. Just wait for the bedside to be
            // ready and the viewport label to settle.
            let viewportState = app.descendants(matching: .any)
                .matching(identifier: "ui-test-viewport-state").firstMatch
            XCTAssertTrue(viewportState.waitForExistence(timeout: 30))
        }
    }

    // MARK: - 5. Jump to a late-record finding

    @MainActor
    func test05HourLongJumpToLateFinding() throws {
        // Click a finding row near the end of the recording. Exercises the
        // animateJump path on a 1-hour viewport. The scaled annotation
        // generator places findings evenly through the recording, so the
        // last few finding-row-VT / -VF entries are >55 min in.
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-load-prepped-bundle"]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 30))

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))

        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: measureOptions) {
            let initial = viewportState.label
            // Cycle between two rows so each iteration has somewhere to jump.
            let vt = app.buttons.matching(identifier: "finding-row-VT").firstMatch
            XCTAssertTrue(vt.exists)
            vt.click()
            let changed = NSPredicate(format: "label != %@", initial)
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: changed, object: viewportState)],
                timeout: 5
            )
            let resetLabel = viewportState.label
            let vf = app.buttons.matching(identifier: "finding-row-VF").firstMatch
            XCTAssertTrue(vf.exists)
            vf.click()
            let changedAgain = NSPredicate(format: "label != %@", resetLabel)
            _ = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: changedAgain, object: viewportState)],
                timeout: 5
            )
        }
    }

    // MARK: - 6. Memory footprint on a 1-hour recording

    @MainActor
    func test06HourLongMemoryFootprint() throws {
        // Snapshot peak memory after loading the 1-hour bundle. Compare to
        // the 10-second baseline (testMemoryAfterFixtureLoad in
        // MurmurUIPerformanceTests) — the delta should scale roughly with
        // the resident channel/pyramid data, not faster. A regression that
        // grows non-linearly here would point at a per-sample retain leak
        // or a mis-mmap.
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 3
        measure(metrics: [XCTMemoryMetric()], options: measureOptions) {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-load-prepped-bundle"]
            app.launch()
            let bedside = app.descendants(matching: .any)
                .matching(identifier: "bedside-view").firstMatch
            XCTAssertTrue(bedside.waitForExistence(timeout: 30))
        }
    }
}
