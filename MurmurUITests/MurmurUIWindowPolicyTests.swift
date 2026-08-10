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
