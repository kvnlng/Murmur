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

        let search = app.descendants(matching: .any)
            .matching(identifier: "record-search-field").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5),
                      "The navigator should carry a search field")

        let header = app.descendants(matching: .any)
            .matching(identifier: "records-section-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5),
                      "The navigator should carry a RECORDS section header")
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
