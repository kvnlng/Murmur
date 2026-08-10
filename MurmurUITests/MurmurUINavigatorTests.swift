//
//  MurmurUINavigatorTests.swift
//  MurmurUITests
//
//  X68 — the record navigator's search field and section header, and the
//  toolbar's side-panel toggles.
//
//  The navigator needs a real folder of records to be worth testing, so these
//  drive the `--ui-test-open-folder` path rather than the single-record sample
//  fixture. A test that can only ever see one row proves nothing about
//  filtering.
//

import XCTest

final class MurmurUINavigatorTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Close the review-queue inspector so the navigator can show at ANY
    /// window width (X82: below the coexistence width the two panels never
    /// coexist, and the queue holds the default win).
    @MainActor
    private func closeReviewQueue(_ app: XCUIApplication) {
        let findings = app.descendants(matching: .any)
            .matching(identifier: "findings-panel").firstMatch
        guard findings.waitForExistence(timeout: 5) else { return }
        let queueToggle = app.descendants(matching: .any)
            .matching(identifier: "findings-toggle").firstMatch
        XCTAssertTrue(queueToggle.waitForExistence(timeout: 5))
        queueToggle.click()
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(findings, timeout: 5),
                      "Closing the review queue should dismiss the inspector")
    }

    /// The review-queue toggle. Guards the X68 glyph swap: it was
    /// `stethoscope.circle`, which named a clinical role rather than the thing
    /// the button does.
    @MainActor
    func testReviewQueueToggleIsPresent() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let queueToggle = app.descendants(matching: .any)
            .matching(identifier: "findings-toggle").firstMatch
        XCTAssertTrue(queueToggle.waitForExistence(timeout: 10),
                      "The review-queue toggle should be in the toolbar")
    }

    /// The navigator toggle and the navigator's own header furniture.
    ///
    /// Launched through the SESSION path, not `--ui-test-sample`. That matters
    /// and is easy to get wrong: the sample fixture lands in `.directView`,
    /// which has no `NavigationSplitView` and therefore — correctly — no
    /// navigator and no toggle for one. Only the browse shell has a record
    /// list to show or hide.
    @MainActor
    func testNavigatorCarriesItsSearchFieldAndSectionHeader() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-sample-session"]
        app.launch()

        let navigatorToggle = app.descendants(matching: .any)
            .matching(identifier: "toolbar-sidebar-toggle").firstMatch
        XCTAssertTrue(navigatorToggle.waitForExistence(timeout: 15),
                      "The browse shell should carry a navigator toggle")

        // X82: on a window below the coexistence width (Cloud's VMs — or a
        // persisted narrow frame anywhere) the navigator and the review
        // queue cannot both be open, and the queue holds the default win.
        // Close the queue so the navigator shows unconditionally; this test
        // is about the navigator's furniture, not the arbitration.
        closeReviewQueue(app)

        let search = app.descendants(matching: .any)
            .matching(identifier: "record-search-field").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5),
                      "The navigator should carry a search field")

        let header = app.descendants(matching: .any)
            .matching(identifier: "records-section-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5),
                      "The navigator should carry a RECORDS section header")
    }

    /// X81: the toolbar carries ONE sidebar toggle — ours. The split view's
    /// injected "Hide Sidebar" button is suppressed: it lives in the sidebar's
    /// own toolbar region and vanishes with the collapsed column (the X63-B
    /// trap, still real on macOS 26), and beside the persistent toggle it
    /// read as two adjacent buttons doing the same thing.
    @MainActor
    func testToolbarCarriesExactlyOneSidebarToggle() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-sample-session"]
        app.launch()

        let ourToggle = app.descendants(matching: .any)
            .matching(identifier: "toolbar-sidebar-toggle").firstMatch
        XCTAssertTrue(ourToggle.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Hide Sidebar"].exists,
                       "The system sidebar toggle must be suppressed — two adjacent toggles was X81")

        // X82: below the coexistence width the review queue holds the win
        // and the navigator yields. Close the queue so the round trip below
        // exercises the toggle, not the arbitration (which has its own test).
        closeReviewQueue(app)

        // And the one toggle is sufficient: collapse, then bring the
        // navigator back — the round trip the system button can't make.
        let search = app.descendants(matching: .any)
            .matching(identifier: "record-search-field").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        ourToggle.click()
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(search, timeout: 3),
                      "Toggling should collapse the navigator")
        ourToggle.click()
        XCTAssertTrue(search.waitForExistence(timeout: 3),
                      "Toggling again should bring the navigator back")
    }

    /// The overflow menu carries Customize Toolbar…, which is the only route
    /// to visible labels while `.help()` renders nothing — so it is load-
    /// bearing, not a convenience.
    @MainActor
    func testOverflowMenuOffersToolbarCustomisation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let more = app.descendants(matching: .any)
            .matching(identifier: "toolbar-more").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.click()

        let customise = app.menuItems["toolbar-customize-item"]
        XCTAssertTrue(customise.waitForExistence(timeout: 3),
                      "The overflow menu should offer Customize Toolbar…")
        app.typeKey(.escape, modifierFlags: [])
    }
}
