//
//  MurmurUILaneClickTests.swift
//  MurmurUITests
//
//  Tap-to-jump coverage for the scrolling context lanes (density, quality).
//  Split out of MurmurUITests to keep that file under the file-length limit;
//  each test is self-contained (launches its own app). The bottom-of-scroll
//  strips skip on Xcode Cloud, where the runner's default window height keeps
//  them off-screen and XCUI can't scroll them to a hittable position; they're
//  covered on taller local windows.
//
//  X66 retired the alarm and ventilation-state lanes; their two click tests
//  were replaced by `testRetiredLanesDoNotRender`, which asserts the absence
//  and needs no click, so it does not skip on CI.
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
    func testRetiredLanesDoNotRender() throws {
        // X66 retired the alarm and ventilation-state lanes. The synthetic
        // fixture still EMITS those channels — `had_high_priority_alarm`,
        // `prob_state_spontaneous`, `prob_state_assist_control` — because the
        // importer must keep reading every signal a producer supplies. So this
        // is the real assertion: a record that carries the channels renders no
        // lane for them.
        //
        // Written as an absence test deliberately. Deleting the two old
        // lane-click tests would have left nothing failing if a merge
        // resurrected the strips.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        // Anchor on a lane that DOES still render, so this can't pass simply
        // because the context column failed to load.
        //
        // This is also what makes the two `exists` checks below non-racy
        // despite having no wait of their own: the retired lanes rendered
        // ABOVE the quality lane in the old order (trends, alarm, state,
        // quality), so a tree containing the quality lane would have
        // contained them too. Keep the anchor last-in-order if the lane
        // order ever changes.
        let qualityLane = app.descendants(matching: .any)
            .matching(identifier: "quality-lane-ecg_artifact_ratio").firstMatch
        XCTAssertTrue(qualityLane.waitForExistence(timeout: 10),
                      "The quality lane should still render — without it this test proves nothing")

        let alarmLane = app.descendants(matching: .any)
            .matching(identifier: "alarm-lane-had_high_priority_alarm").firstMatch
        XCTAssertFalse(alarmLane.exists,
                       "The alarm lane was retired in X66, but the fixture's alarm channel still rendered one")

        let stateLane = app.descendants(matching: .any)
            .matching(identifier: "state-backdrop-lane").firstMatch
        XCTAssertFalse(stateLane.exists,
                       "The ventilation-state lane was retired in X66, but the fixture's prob_state_* channels still rendered one")
    }
}
