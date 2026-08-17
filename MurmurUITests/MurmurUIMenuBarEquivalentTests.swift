//
//  MurmurUIMenuBarEquivalentTests.swift
//  MurmurUITests
//
//  #253 — every toolbar action is reachable from the menu bar.
//
//  This is a PRECONDITION test, not a feature test. The design's icon-only
//  toolbar drops the labels under the glyphs, and justifies it with "every
//  action keeps its menu-bar equivalent, so discoverability lives there". That
//  sentence is only true if something keeps it true: `.help()` renders no
//  tooltip anywhere in this app on macOS 26 (X60), so an icon-only button with
//  no menu row has NO way to say what it is. When the display-mode seed flips,
//  this suite is what stands between that and eight unlabelled glyphs.
//
//  Matched on TITLE rather than identifier, deliberately: accessibility
//  identifiers do not reach a menu-bar `NSMenuItem`. Measured during #236 —
//  with one set, `app.menuItems["trend-lane-toggle-hr"]` did not exist and the
//  item's `identifier` came back empty while its `title` was exactly the
//  label. Every menu-bar assertion in this suite matches on title for that
//  reason; the in-window `Menu`s that DO carry identifiers are a different
//  surface.
//
//  Titles are therefore load-bearing. Renaming a menu item is a test-visible
//  change, which is the correct amount of friction for a string that is the
//  analyst's only name for an action.
//

import XCTest

final class MurmurUIMenuBarEquivalentTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Open a menu-bar menu and return the titles it offers.
    ///
    /// Clicking is required rather than reading `app.menuItems` cold: AppKit
    /// populates a menu's items when it is about to open, so a menu never
    /// opened this launch can report empty.
    @MainActor
    private func titles(ofMenu name: String, in app: XCUIApplication) -> [String] {
        let menu = app.menuBarItems[name]
        XCTAssertTrue(menu.waitForExistence(timeout: 10),
                      "The menu bar should carry a \(name) menu")
        menu.click()
        // Let the menu populate before reading; `menuItems` on a menu that is
        // still opening returns a partial set.
        let items = menu.menuItems
        _ = items.firstMatch.waitForExistence(timeout: 3)
        let found = items.allElementsBoundByIndex.map(\.title)
        // Close it again so the next menu can open — a menu left open
        // swallows the following click.
        app.typeKey(.escape, modifierFlags: [])
        return found
    }

    @MainActor
    private func assertMenu(
        _ name: String,
        offers required: [String],
        in app: XCUIApplication,
        line: UInt = #line
    ) {
        let found = titles(ofMenu: name, in: app)
        for title in required {
            XCTAssertTrue(found.contains(title),
                          "\(name) should offer '\(title)'. It offers: \(found)",
                          line: line)
        }
    }

    /// The four File-menu actions that were toolbar-only.
    ///
    /// `Export WFDB Annotations…` is asserted to EXIST, not to be enabled: it
    /// gates on a confirmed finding, and the sample record has none. A
    /// disabled row is the X32 state — the analyst can see the capability
    /// exists and that this record has not earned it — so presence is exactly
    /// the right assertion and enablement would be the wrong one.
    @MainActor
    func testFileMenuOffersAttachAndTheThreeExports() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        assertMenu("File", offers: [
            "Attach Findings…",
            "Export Report…",
            "Export Snapshot…",
            "Export WFDB Annotations…",
        ], in: app)
    }

    /// The two View-menu actions that were toolbar-only.
    ///
    /// Both are titled by what they will DO, so the expected title depends on
    /// current state. At launch the review queue is open and the window is not
    /// held, which is what these titles assume.
    @MainActor
    func testViewMenuOffersTheReviewQueueAndWindowHold() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let found = titles(ofMenu: "View", in: app)
        XCTAssertTrue(found.contains("Hide Review Queue") || found.contains("Show Review Queue"),
                      "View should offer the review-queue toggle. It offers: \(found)")
        XCTAssertTrue(found.contains("Hold to 10-Second Window")
                      || found.contains("Release 10-Second Window"),
                      "View should offer the 10 s window hold. It offers: \(found)")
    }

    /// The Editing latch, in the Edit menu.
    @MainActor
    func testEditMenuOffersTheEditingLatch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let found = titles(ofMenu: "Edit", in: app)
        XCTAssertTrue(found.contains("Unlock for Editing") || found.contains("Lock Editing"),
                      "Edit should offer the Editing latch. It offers: \(found)")
    }

    /// The latch names the direction it will move, and follows the state.
    ///
    /// The half that matters: a toggle titled by its own state instead of its
    /// action reads as a label, and an analyst cannot tell whether clicking it
    /// turns editing on or off. Asserting the title CHANGES also proves the
    /// menu is reading live state rather than a constant.
    @MainActor
    func testTheEditingLatchTitleFollowsTheLatch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let before = titles(ofMenu: "Edit", in: app)
        XCTAssertTrue(before.contains("Unlock for Editing"),
                      "A record opens locked, so the latch should offer to unlock. Got: \(before)")

        let latch = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(latch.waitForExistence(timeout: 10), "No editing latch in the toolbar")
        latch.click()

        let after = titles(ofMenu: "Edit", in: app)
        XCTAssertTrue(after.contains("Lock Editing"),
                      "With editing unlocked the latch should offer to lock. Got: \(after)")
    }

    /// A menu row that does nothing is worse than no menu row.
    ///
    /// Every other test here asserts a TITLE, and a title is satisfied by an
    /// item wired to a closure that never fires — `@FocusedValue` yields nil
    /// whenever the scene value is not published, and `commands?.action()` is
    /// silent about it. This drives one of the new items end to end so the
    /// bridge itself is covered: click the menu, watch the pane move.
    ///
    /// The review queue is the one to use because its state is directly
    /// observable (`findings-panel` mounts and unmounts) rather than inferred
    /// from a title this suite also controls.
    @MainActor
    func testTheReviewQueueMenuItemActuallyMovesThePane() throws {
        let app = XCUIApplication()
        // Wide enough for panel coexistence, so the toggle is the only thing
        // that can close the pane — below 1160 pt the panels evict each other
        // and a closed queue would prove nothing.
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=1400x900"]
        app.launch()

        let queue = app.descendants(matching: .any)
            .matching(identifier: "findings-panel").firstMatch
        XCTAssertTrue(queue.waitForExistence(timeout: 15),
                      "The review queue should be open at launch")

        let view = app.menuBarItems["View"]
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        view.click()
        let hide = app.menuItems["Hide Review Queue"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3),
                      "With the queue open the item should offer to hide it")
        hide.click()

        XCTAssertTrue(queue.waitForNonExistence(timeout: 5),
                      "View ▸ Hide Review Queue left the pane on screen — the menu item "
                      + "renders but its action never reaches the bedside")

        // And back, so this covers the toggle rather than a one-way switch.
        view.click()
        let show = app.menuItems["Show Review Queue"]
        XCTAssertTrue(show.waitForExistence(timeout: 3),
                      "With the queue hidden the item should offer to show it")
        show.click()
        XCTAssertTrue(queue.waitForExistence(timeout: 5),
                      "View ▸ Show Review Queue did not bring the pane back")
    }

    /// The Analyze menu exists only when the VT/VF scan does.
    ///
    /// Not the X32 "disabled, not hidden" case: X32 is about a capability THIS
    /// RECORD cannot support, where the analyst should still see the app can
    /// do it. Here the app genuinely cannot until the entitlement is bought,
    /// and a top-level menu holding one permanently dead row reads as a broken
    /// app rather than a locked feature.
    @MainActor
    func testAnalyzeMenuIsAbsentWithoutTheScanEntitlement() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-no-entitlements"]
        app.launch()

        // Anchor on a menu that always exists, so this cannot pass because the
        // menu bar had not mounted yet.
        XCTAssertTrue(app.menuBarItems["File"].waitForExistence(timeout: 10),
                      "The menu bar should have mounted")
        XCTAssertFalse(app.menuBarItems["Analyze"].exists,
                       "Analyze should be absent for the free viewer — an empty or "
                       + "permanently-disabled menu advertises a locked feature")
    }

    @MainActor
    func testAnalyzeMenuOffersTheScanWhenAvailable() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-vtvf-candidates"]
        app.launch()

        assertMenu("Analyze", offers: ["Scan for VT/VF Candidates…"], in: app)
    }
}
