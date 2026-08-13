//
//  MurmurUIWindowPolicyTests.swift
//  MurmurUITests
//
//  X100 (#165) — window size under XCUI is an explicit choice, never
//  inherited state.
//
//  The mechanism this guards: macOS state restoration re-applies the frame
//  the LAST launch persisted — including the 1000×600 frames short-display
//  tests deliberately force — so a test omitting `--ui-test-window` used to
//  open at whatever the previous test left behind. The first test here
//  reproduces that exact sequence (pin small, relaunch bare) and asserts the
//  bare launch gets the policy size, not the leftover.
//
//  Assertions measure the WINDOW frame; the policy sets CONTENT size, so
//  widths compare tightly while heights allow title-bar/toolbar chrome.
//

import XCTest

final class MurmurUIWindowPolicyTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// What the policy should resolve to on THIS runner — mirrors
    /// `WindowSizing.testWindowContentSize` (default 1400×900 clamped to the
    /// visible frame minus the 60 pt chrome allowance).
    @MainActor
    private func expectedDefaultContentWidth() -> CGFloat {
        guard let visible = NSScreen.main?.visibleFrame else { return 1400 }
        return min(1400, visible.width - 60)
    }

    @MainActor
    private func mainWindowFrame(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "The main window should exist")
        return window.frame
    }

    /// The regression test: a short-window run persists its frame; the next
    /// bare launch must get the generous policy size, not the leftover.
    @MainActor
    func testBareLaunchNeverInheritsThePersistedShortFrame() throws {
        // Persist a deliberately small frame, the way short-display tests do.
        let pinned = XCUIApplication()
        pinned.launchArguments += ["--ui-test-sample", "--ui-test-window=1000x600"]
        pinned.launch()
        let pinnedFrame = mainWindowFrame(pinned)
        XCTAssertEqual(pinnedFrame.width, 1000, accuracy: 2,
                       "The pinned short-display regime must keep reproducing exactly")
        pinned.terminate()

        // Relaunch with no window flag: the old behaviour inherited 1000×600.
        let bare = XCUIApplication()
        bare.launchArguments += ["--ui-test-sample"]
        bare.launch()
        let frame = mainWindowFrame(bare)
        let expected = expectedDefaultContentWidth()
        // Poll briefly: the policy applier re-asserts against async state
        // restoration, so the final size can land a beat after the window.
        let deadline = Date().addingTimeInterval(8)
        var width = frame.width
        while abs(width - expected) > 2 && Date() < deadline {
            usleep(300_000)
            width = bare.windows.firstMatch.frame.width
        }
        XCTAssertEqual(width, expected, accuracy: 2,
                       "A launch without --ui-test-window must get the policy default, not the persisted 1000 pt frame")
    }

    /// Each column scrolls its own content, so no column may publish a
    /// minimum the window has to honour (#202, #207).
    ///
    /// The window is pinned BELOW the content's old minimum. Before this, the
    /// split view answered with an oversized frame and macOS centred it, so
    /// the content spilled over the title bar at the top and past the window
    /// at the bottom — the bottom band unreachable at any window size, which
    /// is what made X112's drawer untestable on Cloud's short VMs.
    @MainActor
    func testColumnsScrollRatherThanOverflowTheWindow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample-rich=two-morphology",
                                "--ui-test-grant-studio",
                                "--ui-test-window=1500x786"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "The main window should exist")
        // The split view re-negotiates after the record's derived surfaces
        // land, so read once it has settled rather than on the first frame.
        Thread.sleep(forTimeInterval: 8)
        let windowFrame = window.frame
        let split = app.windows.firstMatch.descendants(matching: .splitGroup).firstMatch
        XCTAssertTrue(split.exists, "The split view should exist")
        let splitFrame = split.frame

        XCTAssertLessThanOrEqual(
            splitFrame.height, windowFrame.height + 2,
            "The split view is \(splitFrame.height) pt in a \(windowFrame.height) pt window — "
            + "a column is still publishing its content height as a minimum")
        XCTAssertGreaterThanOrEqual(
            splitFrame.minY, windowFrame.minY - 2,
            "The split view starts \(windowFrame.minY - splitFrame.minY) pt above the window — "
            + "oversized content is being centred and is spilling over the title bar")
        XCTAssertLessThanOrEqual(
            splitFrame.maxY, windowFrame.maxY + 2,
            "The split view ends \(splitFrame.maxY - windowFrame.maxY) pt below the window — "
            + "the bottom band is unreachable")
    }

    /// The whole-record summary reads ABOVE the trace at every window size.
    ///
    /// X83 made this conditional on an 800 pt column, so the strip dropped
    /// below the trace on a short window. That rule was never observed
    /// working — it measured the oversized layout it was handed rather than
    /// the window — and once the columns scrolled it started firing and moved
    /// the strip. The condition is gone: a scrolling column costs a short
    /// window a scroll, not a surface.
    ///
    /// Both sizes matter. The tall one alone passed throughout the period the
    /// rule was broken AND the period it was wrong.
    @MainActor
    func testMetricsSummaryReadsAboveTheTraceAtEveryWindowSize() throws {
        for size in ["1500x1400", "1500x786"] {
            let app = XCUIApplication()
            app.launchArguments += ["--ui-test-sample-rich=two-morphology",
                                    "--ui-test-grant-studio",
                                    "--ui-test-window=\(size)"]
            app.launch()
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 30), "no window at \(size)")
            Thread.sleep(forTimeInterval: 8)
            let strip = window.descendants(matching: .any)
                .matching(identifier: "variability-metrics-strip").firstMatch
            let stage = window.descendants(matching: .any)
                .matching(identifier: "pinned-stage").firstMatch
            XCTAssertTrue(strip.exists, "no metrics strip at \(size)")
            XCTAssertTrue(stage.exists, "no stage at \(size)")
            XCTAssertLessThan(
                strip.frame.minY, stage.frame.minY,
                "At \(size) the strip is at y=\(strip.frame.minY) and the trace at "
                + "y=\(stage.frame.minY) — the summary has dropped below the trace")
            app.terminate()
        }
    }

    /// No surface in the bedside column is wider than the column (#223).
    ///
    /// The width sibling of `testColumnsScrollRatherThanOverflowTheWindow`.
    /// The trend stack read 799 pt at every window under ~1180 while the strip
    /// above it tracked the column — 728 pt at the 1100 pt production minimum —
    /// because the interval lane's seven fixed-size control chips had a 633 pt
    /// floor and the lane's cell clipped rather than compressed. Clipped
    /// controls are still in the layout: they can neither be seen nor clicked.
    ///
    /// The strip is the yardstick rather than the window because it is the
    /// sibling that actually fills the column, so this measures the same
    /// question a reader would — is this card wider than the thing above it.
    @MainActor
    func testNoBedsideSurfaceIsWiderThanItsColumn() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample-rich=two-morphology",
                                "--ui-test-grant-studio",
                                "--ui-test-window=1100x900"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "The main window should exist")
        Thread.sleep(forTimeInterval: 8)
        let strip = window.descendants(matching: .any)
            .matching(identifier: "variability-metrics-strip").firstMatch
        let stack = window.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        XCTAssertTrue(strip.exists, "no metrics strip")
        XCTAssertTrue(stack.exists, "no trend stack")
        XCTAssertLessThanOrEqual(
            stack.frame.width, strip.frame.width + 2,
            "The trend stack is \(stack.frame.width) pt in a \(strip.frame.width) pt column — "
            + "a lane is still publishing a width floor its cell can only clip")
    }

    /// `max` fills the runner's visible frame (minus the chrome allowance).
    @MainActor
    func testMaxFillsTheVisibleFrame() throws {
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=max"]
        app.launch()
        let frame = mainWindowFrame(app)
        XCTAssertEqual(frame.width, visible.width - 60, accuracy: 2,
                       "--ui-test-window=max should fill the visible width minus the chrome allowance")
    }
}
