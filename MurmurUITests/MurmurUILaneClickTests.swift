//
//  MurmurUILaneClickTests.swift
//  MurmurUITests
//
//  Tap-to-jump coverage for the scrolling context lanes (density, and the
//  X74 trend stack via its quality lane).
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
        // Guards: the trend stack's click-to-seek path (X74 — `TrendStack`'s
        // cross-lane overlay owns the gesture, so ONE test through any lane
        // covers every lane). The quality lane is clicked because it sits
        // last in the stack: if it is hittable the whole stack rendered.
        //
        // Skipped on Xcode Cloud for the same reason the old QualityStrip
        // test was: the stack renders at the bottom of the scrollable
        // context column, and on the Cloud runner's default window /
        // display size XCUI's "scroll to visible" cannot get the element
        // to a hittable position. The feature is exercised locally on
        // developer machines with taller windows. See Builds 37/45/47 in
        // the CI history for the original debugging trail.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Trend-stack lane-click test skipped on CI — Cloud runner's window height keeps the stack off-screen; feature is covered by local runs.")
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

        // A 2 s viewport starts at the record's left edge, so a click at the
        // lane's center — mid-record — must move it.
        let qualityLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-quality").firstMatch
        XCTAssertTrue(qualityLane.waitForExistence(timeout: 10))
        qualityLane.click()

        let predicate = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport state should change after a trend-stack lane click (was '\(initial)')")
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
        // because the context column failed to load. X74 moved the quality
        // lane into the trend stack, where it renders last — so a tree that
        // contains it contains the whole context column, which keeps the two
        // `exists` checks below non-racy despite having no wait of their
        // own. Keep the anchor last-in-order if the lane order ever changes.
        let qualityLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-quality").firstMatch
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
