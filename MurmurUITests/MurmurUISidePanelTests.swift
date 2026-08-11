//
//  MurmurUISidePanelTests.swift
//  MurmurUITests
//
//  X82 — side panels render whole or not at all.
//
//  The reported bug: resizing the window left the record navigator and the
//  review-queue inspector partially clipped at the window edges. The rule
//  under test: below the coexistence width the two panels never coexist —
//  the last-requested one shows WHOLE (asserted by frame containment), the
//  other yields entirely.
//

import XCTest

final class MurmurUISidePanelTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Click a toolbar item that may be clipped into the toolbar's
    /// overflow ("more toolbar items") popup at narrow widths.
    @MainActor
    private func clickPossiblyClippedToolbarItem(
        identifier: String, menuLabel: String, in app: XCUIApplication
    ) {
        let direct = app.descendants(matching: .any)
            .matching(identifier: identifier).firstMatch
        if direct.waitForExistence(timeout: 2), direct.isHittable {
            direct.click()
            return
        }
        let overflow = app.popUpButtons["more toolbar items"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 5),
                      "Neither \(identifier) nor the toolbar overflow is on screen")
        overflow.click()
        let item = app.menuItems[menuLabel]
        XCTAssertTrue(item.waitForExistence(timeout: 3),
                      "The overflow menu should carry \(menuLabel)")
        item.click()
    }

    /// Whole-or-nothing at a width that cannot hold both panels.
    @MainActor
    func testNarrowWindowShowsOneWholePanelAtATime() throws {
        let app = XCUIApplication()
        // 1100 content — the production minimum, below the 1160 coexistence
        // width. The session path has a navigator; the inspector opens by
        // default and holds the win.
        app.launchArguments += ["--ui-test-open-sample-session", "--ui-test-window=1100x740"]
        app.launch()

        let window = app.windows.firstMatch
        let findings = app.descendants(matching: .any)
            .matching(identifier: "findings-panel").firstMatch
        let search = app.descendants(matching: .any)
            .matching(identifier: "record-search-field").firstMatch

        // Inspector holds the win; the navigator yields entirely.
        XCTAssertTrue(findings.waitForExistence(timeout: 15),
                      "The review queue should be open by default")
        XCTAssertFalse(search.exists,
                       "Below the coexistence width the navigator must yield entirely, not clip")
        XCTAssertTrue(window.frame.contains(findings.frame),
                      "The panel that shows must show WHOLE — clipped was the X82 bug (window \(window.frame), panel \(findings.frame))")

        // Request the navigator: it wins, the inspector yields.
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "toolbar-sidebar-toggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(search.waitForExistence(timeout: 5),
                      "Requesting the navigator at a narrow width should show it")
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(findings, timeout: 5),
                      "…and the inspector must yield entirely")
        XCTAssertTrue(window.frame.contains(search.frame),
                      "The navigator must render whole (window \(window.frame), search \(search.frame))")

        // Request the queue back: the win moves again. With the navigator
        // open at 1100 pt the full toolbar clips its trailing items into
        // the overflow popup — standard AppKit behaviour once the fresh
        // `.mur` open publishes the recording context (X96), so the
        // Review-queue toggle is followed to wherever AppKit put it.
        clickPossiblyClippedToolbarItem(identifier: "findings-toggle",
                                        menuLabel: "Review queue", in: app)
        XCTAssertTrue(findings.waitForExistence(timeout: 5))
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(search, timeout: 5),
                      "The navigator yields when the queue takes the win back")
    }
}
