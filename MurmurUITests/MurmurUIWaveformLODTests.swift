//
//  MurmurUIWaveformLODTests.swift
//  MurmurUITests
//
//  End-to-end tier-transition tests for the semantic-zoom LOD wired
//  up in `project_waveform_zoom_lod_spec.md`. These sit alongside the
//  component-level snapshot tests + unit tests to catch WIRE-UP bugs
//  the other layers miss:
//    - Snapshot tests pin the render for each tier in isolation, but
//      not the tier COMPUTATION inside ChannelPanel.
//    - Unit tests pin the selector math + thresholds, but not the
//      viewport → plotWidth → beatsInWindow → tier path.
//    - The bugs Kevin found in TestFlight (tier stuck at .inspect
//      because delineator hadn't run; thresholds calibrated for a
//      too-narrow canvas) were exactly this wire-up layer.
//
//  Reads the tier via the `ui-test-waveform-tier` accessibility
//  overlay (BedsideView), which prints "tier=<name> beats=<count>"
//  so tests can assert both the resolved tier + the beats-in-window
//  input that drove the selector.
//
//  Seeds beats via `--ui-test-seed-beat-annotations=<N>` so the
//  default 10 s / 3-finding synthetic fixture has enough beats in
//  view to cross tier thresholds.
//

import XCTest

@MainActor
final class MurmurUIWaveformLODTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private static func tierElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "ui-test-waveform-tier").firstMatch
    }

    private static func waitForTier(
        _ tier: String,
        in element: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        // Accessibility label format: "tier=<name> beats=<count>".
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "tier=\(tier)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Sanity: at the default narrow zoom (2 s window) with the default
    /// fixture (very few beat annotations), the tier resolves to
    /// `.inspect`. Pin this so a future refactor that accidentally
    /// bumps the initial-tier default doesn't silently ship as Scan.
    func testTierIsInspectAtNarrowZoomWithFewBeats() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let element = Self.tierElement(in: app)
        XCTAssertTrue(
            Self.waitForTier("inspect", in: element),
            "Narrow-zoom + few-beat viewport must resolve to Inspect; " +
            "label was \(element.label)"
        )
    }

    /// Seed a modest 20 beat annotations, keep the initial narrow zoom
    /// (2 s), then confirm the tier is STILL Inspect — 20 beats spread
    /// over 10 s of fixture means only ~4 beats fall in the 2 s window,
    /// well inside Inspect at any canvas width. Guards against a
    /// regression where seed annotations flip the tier prematurely
    /// because the whole-fixture count grew even though the in-viewport
    /// count is still low.
    func testTierStaysInspectAtNarrowZoomEvenWithManyBeats() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-sample",
            "--ui-test-initial-duration=2",
            "--ui-test-seed-beat-annotations=20"
        ]
        app.launch()

        let element = Self.tierElement(in: app)
        XCTAssertTrue(
            Self.waitForTier("inspect", in: element),
            "Narrow zoom with few in-viewport beats must stay Inspect; " +
            "label was \(element.label)"
        )
    }

    /// Seed 200 beat annotations across the fixture and zoom out to a
    /// 6 s window so ~120 beats are in view. On a normal Mac canvas
    /// that's ≲ 12 pt/beat, well below the Inspect exit boundary (60);
    /// the tier must transition to Scan (or Context if the canvas is
    /// wider). The test tolerates either — the "still Inspect" branch
    /// is the regression case worth catching.
    func testTierLeavesInspectWhenZoomedOutWithSeededBeats() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-sample",
            "--ui-test-initial-duration=2",
            "--ui-test-seed-beat-annotations=200",
            "--ui-test-zoom-to=6"
        ]
        app.launch()

        let element = Self.tierElement(in: app)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format:
                "label BEGINSWITH 'tier=scan' OR label BEGINSWITH 'tier=context'"),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(
            result, .completed,
            "Zooming out with 200 seeded beats must leave Inspect; " +
            "label was \(element.label)"
        )
    }

    /// Seed 500 beat annotations and zoom to the full 10 s fixture.
    /// All 500 beats fall in view, so on any reasonable canvas the
    /// tier must resolve to Context (≤ 8 pt/beat). Guards the
    /// bulk-density-hand-off contract: once we cross into Context,
    /// the trace area's rail simplifies to landmarks + focus and the
    /// pinned Overview strip takes over as the far-out navigator.
    func testTierReachesContextAtWholeRecordZoom() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-sample",
            "--ui-test-initial-duration=10",
            "--ui-test-seed-beat-annotations=500",
            "--ui-test-zoom-to=10"
        ]
        app.launch()

        let element = Self.tierElement(in: app)
        XCTAssertTrue(
            Self.waitForTier("context", in: element, timeout: 15),
            "500 beats in view must reach Context; label was \(element.label)"
        )
    }
}
