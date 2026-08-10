//
//  MurmurUITrendStackTests.swift
//  MurmurUITests
//
//  X74 — the shared-axis trend stack.
//
//  What XCUI can reach: that the lanes exist, that the caption names its
//  populations, and that the Lanes menu removes a row. What it cannot reach is
//  the thing the ticket is actually about — whether every lane maps the same
//  instant to the same x — because a Swift Charts lane and a `Canvas` expose
//  nothing about what they painted. That was verified against pixels on the
//  synthetic fixture (HR + quality on one axis) and on NSRDB 16265 at 25.5 h.
//
//  So the assertion that earns its place here is the ABSENCE test: the stack
//  renders nothing at all if its loading task never runs, and that failure
//  looks exactly like "this record has no lanes".
//

import XCTest

final class MurmurUITrendStackTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    /// The Context drawer's expansion is `@AppStorage`, so whatever the last
    /// run (or a developer's manual session) left behind is what this test
    /// inherits — and an expanded drawer pushes the Lanes menu below the
    /// fold, where XCUI reports it "not hittable". Tests that CLICK stack
    /// chrome collapse the drawer first; existence-only tests don't care.
    @MainActor
    private func collapseContextDrawer(_ app: XCUIApplication) {
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        guard panel.exists else { return }
        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 5))
        contextBar.click()
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(panel, timeout: 3),
                      "Collapsing the Context bar should unmount the drawer")
    }

    /// The fixture carries `HR_bpm` and `ecg_artifact_ratio`, so both
    /// whole-record lanes must appear. This is the regression guard for the
    /// deadlock found during X74's pixel pass: the load task hung off a view
    /// that only existed once loading had succeeded, so no samples ever
    /// loaded, so the stack rendered empty — and every existence assertion
    /// simply found nothing, which reads as "no lanes in this record".
    @MainActor
    func testStackRendersItsWholeRecordLanes() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let stack = app.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 20),
                      "A record with trend and quality channels should carry a trend stack")

        for lane in ["hr", "quality"] {
            let row = app.descendants(matching: .any)
                .matching(identifier: "trend-lane-\(lane)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "The \(lane) lane should render — an empty stack is how the load deadlock presents")
        }
    }

    /// Provenance travels with the numbers. The lanes come from different
    /// channels at different rates, and a stack that looks like one chart
    /// invites the assumption that it is one.
    @MainActor
    func testCaptionNamesEachLanesSource() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let caption = app.descendants(matching: .any)
            .matching(identifier: "trend-stack-caption").firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 20),
                      "The stack should carry a provenance caption")

        let spoken = spokenName(caption)
        XCTAssertTrue(spoken.contains("HR_bpm"),
                      "Caption should name the HR channel, got '\(spoken)'")
        XCTAssertTrue(spoken.contains("ecg_artifact_ratio"),
                      "Caption should name the quality channel, got '\(spoken)'")
        XCTAssertTrue(spoken.contains("one axis"),
                      "Caption should state the shared span, got '\(spoken)'")
    }

    /// The Lanes menu removes a row. Asserted by disappearance rather than by
    /// the menu's checkmark: a menu that toggles its own state while the stack
    /// ignores it would pass any check on the menu alone.
    ///
    /// Runs in a FORCED SHORT WINDOW: this test failed "not hittable" on
    /// Xcode Cloud's 1024×768 VMs, where the production minimum window can't
    /// fit the screen and the stack's bottom chrome hangs off it. With
    /// WindowSizing capping the minimum under XCUI runs the window fits; the
    /// forced size reproduces that regime on every machine so the regression
    /// can't reach CI unseen.
    @MainActor
    func testLanesMenuRemovesALane() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=1000x600"]
        app.launch()

        let hrLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-hr").firstMatch
        XCTAssertTrue(hrLane.waitForExistence(timeout: 20))
        collapseContextDrawer(app)

        let menu = app.descendants(matching: .any)
            .matching(identifier: "trend-lanes-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // Short window: the trend stack sits past the fold of the scrolling
        // context — bring it into view the way an analyst would.
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(menu, in: app),
                      "The Lanes menu never became clickable, even after scrolling the stack into view")
        menu.click()

        let toggle = app.menuItems["trend-lane-toggle-hr"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "The Lanes menu should offer the HR lane")
        toggle.click()

        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(hrLane, timeout: 5),
                      "Switching a lane off should remove its row from the stack")
    }

    /// X76 wire-up: the injected series carries the exact value 1.50 in every
    /// window, so this asserts the RENDERED value column equals it — catching
    /// a binding slip between `RollingLFHFContext` and the screen that a
    /// green unit suite would miss (the X52 §5 pattern).
    @MainActor
    func testLFHFLaneRendersInjectedSeries() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-inject-lfhf-lane"]
        app.launch()

        let lane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-lfhf").firstMatch
        XCTAssertTrue(lane.waitForExistence(timeout: 20),
                      "The injected LF/HF series should render its lane")

        let value = lane.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == '1.50' OR value == '1.50'"))
            .firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5),
                      "The lane's value column should render the injected 1.50")

        // The Lanes menu offers the lane once the series exists.
        collapseContextDrawer(app)
        let menu = app.descendants(matching: .any)
            .matching(identifier: "trend-lanes-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        XCTAssertTrue(app.menuItems["trend-lane-toggle-lfhf"].waitForExistence(timeout: 5),
                      "The Lanes menu should offer LF / HF when the series exists")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The paid gate, from the free side: with no entitlements the series is
    /// never computed, so the lane must be absent. Anchored on the quality
    /// lane so this can't pass simply because the stack failed to load.
    @MainActor
    func testFreeViewerNeverShowsLFHFLane() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-no-entitlements"]
        app.launch()

        let qualityLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-quality").firstMatch
        XCTAssertTrue(qualityLane.waitForExistence(timeout: 20),
                      "The quality lane should render — without it this test proves nothing")

        let lfhfLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-lfhf").firstMatch
        XCTAssertFalse(lfhfLane.exists,
                       "The free viewer must never render the LF/HF measurement lane")
    }

    /// X85: the header bar folds the stack whole, like the Context drawer —
    /// and unfolds it again.
    @MainActor
    func testHeaderBarFoldsTheStackWhole() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=1000x600"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "trend-stack-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        collapseContextDrawer(app)

        let stack = app.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        // Drive to a known state first — the fold is @AppStorage, so this
        // test inherits whatever a previous run left behind (the X72
        // lesson: never blind-toggle persisted state).
        if !stack.exists {
            XCTAssertTrue(MurmurUITests.scrollUntilHittable(bar, in: app))
            bar.click()
            XCTAssertTrue(stack.waitForExistence(timeout: 3),
                          "Unfolding from a persisted-folded state should mount the stack")
        }

        XCTAssertTrue(MurmurUITests.scrollUntilHittable(bar, in: app),
                      "The trend-stack bar should scroll into view")
        bar.click()
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(stack, timeout: 3),
                      "Clicking the bar should fold the stack whole")
        bar.click()
        XCTAssertTrue(stack.waitForExistence(timeout: 3),
                      "Clicking the bar again should unfold the stack")
    }
}
