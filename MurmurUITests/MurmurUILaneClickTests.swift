//
//  MurmurUILaneClickTests.swift
//  MurmurUITests
//
//  Tap-to-jump coverage for the scrolling context lanes (density / alarm /
//  quality / state-backdrop). Split out of MurmurUITests to keep that file
//  under the file-length limit; each test is self-contained (launches its own
//  app). The bottom-of-scroll strips skip on Xcode Cloud, where the runner's
//  default window height keeps them off-screen and XCUI can't scroll them to a
//  hittable position; they're covered on taller local windows.
//

import XCTest

final class MurmurUILaneClickTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testClickingDensityLaneJumpsViewport() throws {
        // Guards: OverviewMap's expanded per-category lane tap-to-jump path.
        // The compact strip's scrub is covered by
        // testClickingOverviewRibbonScrubsViewport; this asserts the
        // per-category lane rows that appear once the map is expanded still
        // jump the viewport when clicked.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))

        let expandToggle = app.buttons
            .matching(identifier: "overview-map-expand-toggle").firstMatch
        XCTAssertTrue(expandToggle.waitForExistence(timeout: 3))
        expandToggle.click()

        let initial = viewportState.label
        let vtLane = app.descendants(matching: .any)
            .matching(identifier: "density-lane-VT").firstMatch
        XCTAssertTrue(vtLane.waitForExistence(timeout: 3))
        vtLane.click()

        let predicate = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport state should change after a density-lane click (was '\(initial)')")
    }

    @MainActor
    func testClickingAlarmLaneJumpsViewport() throws {
        // Guards: AlarmStrip's tap-to-jump path. The synthetic fixture's
        // had_high_priority_alarm channel fires at frames 3 and 7, so the
        // strip is visible (the lane hides itself if every channel is silent).
        //
        // Skipped on Xcode Cloud for the same reason as the quality-lane test
        // below: it's a bottom-of-scroll strip, and on the Cloud runner's
        // default window height XCUI can't scroll it to a hittable position
        // (frame ends at y≈763, off-screen). It sat just above that fold until
        // the X40 calibration controls grew the pinned stage and pushed it into
        // the same zone. The feature works on developer machines with taller
        // windows; covered by local runs.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("AlarmStrip lane-click test skipped on CI — Cloud runner's window height keeps the strip off-screen; feature is covered by local runs.")
        }
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        let initial = viewportState.label

        let alarmLane = app.descendants(matching: .any)
            .matching(identifier: "alarm-lane-had_high_priority_alarm").firstMatch
        XCTAssertTrue(alarmLane.waitForExistence(timeout: 3))
        alarmLane.click()

        let predicate = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport state should change after an alarm-lane click (was '\(initial)')")
    }

    @MainActor
    func testClickingQualityLaneJumpsViewport() throws {
        // Guards: QualityStrip's tap-to-jump path. The synthetic fixture's
        // ecg_artifact_ratio channel has visibly-noisy frames at 5 and 8.
        //
        // Skipped on Xcode Cloud: the strip renders at the bottom of the
        // scrollable content column, and on the Cloud runner's default
        // window / display size XCUI's "scroll to visible" cannot get
        // the element to a hittable position (frame consistently ends
        // at y≈763 across scroll retries — off-screen relative to the
        // Cloud VM viewport). The feature is exercised locally on
        // developer machines with taller windows and works correctly
        // there. See Builds 37/45/47 in the CI history for the full
        // debugging trail.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("QualityStrip lane-click test skipped on CI — Cloud runner's window height keeps the strip off-screen; feature is covered by local runs.")
        }
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        let initial = viewportState.label

        let qualityLane = app.descendants(matching: .any)
            .matching(identifier: "quality-lane-ecg_artifact_ratio").firstMatch
        XCTAssertTrue(qualityLane.waitForExistence(timeout: 3))
        qualityLane.click()

        let predicate = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport state should change after a quality-lane click (was '\(initial)')")
    }

    @MainActor
    func testClickingStateBackdropStripJumpsViewport() throws {
        // Guards: StateBackdropStrip's tap-to-jump path. Click the inner
        // cell-body lane (state-backdrop-lane) directly — same shape as
        // the other lane-click tests.
        // Skipped on CI — same off-screen-strip issue as the quality-lane test.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("StateBackdropStrip lane-click skipped on CI — strip off-screen on the Cloud runner; covered locally.")
        }
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        let initial = viewportState.label

        let lane = app.descendants(matching: .any)
            .matching(identifier: "state-backdrop-lane").firstMatch
        XCTAssertTrue(lane.waitForExistence(timeout: 3))
        lane.click()

        let predicate = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport state should change after a state-backdrop-lane click (was '\(initial)')")
    }
}
