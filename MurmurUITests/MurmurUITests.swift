//
//  MurmurUITests.swift
//  MurmurUITests
//
//  Created by Kevin Long on 6/14/26.
//

import XCTest

final class MurmurUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tier 1: smoke tests

    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    @MainActor
    func testEmptyStateIsVisible() throws {
        let app = XCUIApplication()
        app.launch()

        let prompt = app.staticTexts["empty-state-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3), "Empty-state prompt should appear on cold launch")

        let openButton = app.buttons["empty-state-open-button"]
        XCTAssertTrue(openButton.exists, "Empty-state Open CSV button should be present")
        XCTAssertTrue(openButton.isHittable, "Empty-state Open CSV button should be hittable")
    }

    @MainActor
    func testToolbarOpenButtonExists() throws {
        let app = XCUIApplication()
        app.launch()

        let toolbarButton = app.buttons["toolbar-open-button"]
        XCTAssertTrue(toolbarButton.waitForExistence(timeout: 3),
                      "Toolbar Open CSV button should be present")
    }

    // MARK: - Tier 3: synthetic Recording fixture loaded via launch argument

    @MainActor
    func testSyntheticFixtureRendersBedsideView() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bedside = app.descendants(matching: .any).matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5),
                      "BedsideView should appear once the synthetic fixture loads")

        // The lead chip bar should be present with chips for every synthetic
        // lead — Focus mode default still renders the chip bar even though
        // only one channel panel is visible at a time.
        let chipBar = app.descendants(matching: .any).matching(identifier: "lead-chip-bar").firstMatch
        XCTAssertTrue(chipBar.waitForExistence(timeout: 3),
                      "Lead chip bar should be present so the user can pick a lead")
        let chipForV1 = app.descendants(matching: .any).matching(identifier: "lead-chip-V1").firstMatch
        XCTAssertTrue(chipForV1.exists, "Chip for V1 should be present in the lead bar")

        // First synthetic lead is "I" — focus mode defaults to it.
        let focusedPanel = app.descendants(matching: .any).matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(focusedPanel.waitForExistence(timeout: 5),
                      "Channel panel for the default-focused lead (I) should render")

        // Empty state is gone.
        let prompt = app.staticTexts["empty-state-prompt"]
        XCTAssertFalse(prompt.exists, "Empty-state prompt should not be visible once a recording is loaded")
    }

    // MARK: - Tier 4: canvas interaction regression guards
    //
    // The bugs these catch were all silent — events fired, no crash, but
    // the canvas didn't behave. Worth $10 of slow UI-test setup to make
    // sure they don't sneak back in.

    // The next four tests use UI-test-only launch arg hooks
    // (`--ui-test-initial-duration=<seconds>`, `--ui-test-hover-at=X,Y`)
    // and a hidden accessibility element (`ui-test-viewport-state`,
    // whose label encodes `<startSample>-<endSample>`). See
    // UITestSupport.swift for why those exist — they side-step macOS
    // XCUI quirks (hover synthesis, nested SwiftUI Text invisibility)
    // we hit when first attempting these tests.

    // Note: a `testDragOnCanvasPansViewport` was drafted using
    // `XCUICoordinate.press(forDuration: 0.5, thenDragTo:)` on the
    // channel-panel-I region, with `--ui-test-initial-duration=2`
    // arranging plenty of pan room. The synthesised press doesn't
    // generate the NSEvent.mouseDragged sequence SwiftUI's DragGesture
    // listens for, so the gesture never fires and the viewport-state
    // label stays put. Hand-testing confirms drag works in production.
    // The viewport math is also covered by RecordingViewportTests
    // (pan clamps, setWidth, jump), so this gap is informational
    // rather than substantive.

    // Note: a `testHoverInjectionRendersCrosshair` was drafted using
    // a `--ui-test-hover-at=X,Y` launch arg that pipes through the same
    // applyHover() path HoverTrackingView would. The injection runs
    // and the crosshair body renders (verified by hand), but it
    // doesn't appear in the macOS XCUI accessibility tree even with
    // `.accessibilityElement(children: .ignore)` + identifier —
    // SwiftUI's tree-pruning for non-hit-testable views in nested
    // GeometryReader contexts is unforgiving. The hover state +
    // hit-test math are unit-tested; the visual is verified during
    // the RELEASE.md smoke-test pass.

    @MainActor
    func testClickingFindingRowChangesViewport() throws {
        // Guards: animateJump path + viewport observability. Click the
        // synthetic fixture's VF finding (mid-record) and assert the
        // hidden viewport-state label changes within the 250 ms
        // animation window.
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

        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 3))
        vfRow.click()

        let predicate = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport state should change after a finding row click (was '\(initial)')")
    }

    @MainActor
    func testWindowHonorsMinimumSize() throws {
        // Guards: the min-window-size fix that resolved the App Store
        // Guideline 4 rejection. If `MurmurApp` ever drops
        // `.frame(minWidth: 1100, minHeight: 720)`, this test fails.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        guard let window = app.windows.allElementsBoundByIndex.first else {
            XCTFail("Expected at least one application window")
            return
        }
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        // The frame call returns a CGRect; both dimensions should be at
        // or above the minimum we set in MurmurApp.
        XCTAssertGreaterThanOrEqual(window.frame.width, 1100,
                                    "Window width should be at least the 1100pt minimum")
        XCTAssertGreaterThanOrEqual(window.frame.height, 720,
                                    "Window height should be at least the 720pt minimum")
    }

    @MainActor
    func testFindingsPanelTogglesViaToolbar() throws {
        // Guards: toolbar button wiring, inspector show/hide, panel
        // render path. A regression here would silently strand findings
        // behind a panel the analyst can't reopen.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let toggle = app.buttons.matching(identifier: "findings-toggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // The synthetic fixture's VF finding is in the panel by default.
        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 3),
                      "VF finding row should be visible by default in the findings panel")

        toggle.click()
        XCTAssertTrue(waitForElementToDisappear(vfRow, timeout: 2),
                      "Finding row should disappear after the toggle hides the panel")

        toggle.click()
        XCTAssertTrue(vfRow.waitForExistence(timeout: 2),
                      "Finding row should reappear after toggling the panel back on")
    }

    /// XCUIElement.waitForNonExistence isn't on macOS; spin our own.
    @MainActor
    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
