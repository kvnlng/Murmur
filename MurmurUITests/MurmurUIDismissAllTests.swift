//
//  MurmurUIDismissAllTests.swift
//  MurmurUITests
//
//  X90 (#139) — right-click on a review-queue group header offers
//  Dismiss All for that group's findings.
//
//  What XCUI must prove: the context menu is latch-gated exactly like the
//  per-row disposition buttons (no edit mode → no menu at all), and one
//  menu click dispositions every unreviewed finding in THAT group while
//  leaving the sibling group untouched. The unreviewed-only semantics —
//  a bulk gesture never overwrites an explicit confirm — are pinned by
//  `DispositionStoreTests.dismissAllSkipsReviewed`; here the visible proof
//  is the reset-button count, which appears once per dispositioned row.
//
//  The `--ui-test-sample` fixture carries 2 VT findings (both ranges), a VF finding, and a
//  fresh bundle every launch, so counts are deterministic.
//

import XCTest

final class MurmurUIDismissAllTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchOnSample() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()
        return app
    }

    @MainActor
    private func rightClickVTGroupHeader(in app: XCUIApplication) {
        let header = app.buttons.matching(identifier: "finding-group-VT").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10),
                      "The VT group header should render for the sample fixture")
        header.rightClick()
    }

    /// The latch gate: without edit mode the builder is empty, so
    /// right-clicking the header must offer no Dismiss All.
    @MainActor
    func testDismissAllIsAbsentOutsideEditMode() throws {
        let app = launchOnSample()
        rightClickVTGroupHeader(in: app)
        XCTAssertFalse(app.menuItems["group-dismiss-all-VT"].waitForExistence(timeout: 2),
                       "Dismiss All must respect the editing latch, like every disposition control")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// One right-click + one menu click dispositions the whole VT group (2 findings) —
    /// and only the VT group.
    @MainActor
    func testDismissAllDispositionsTheWholeGroup() throws {
        let app = launchOnSample()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        // Nothing dispositioned yet — no reset buttons anywhere.
        let resetPredicate = NSPredicate(format: "identifier BEGINSWITH 'disposition-reset-'")
        let resetButtons = app.descendants(matching: .any).matching(resetPredicate)
        XCTAssertEqual(resetButtons.count, 0,
                       "Reset buttons should not exist before any disposition")

        rightClickVTGroupHeader(in: app)
        let dismissAll = app.menuItems["group-dismiss-all-VT"]
        XCTAssertTrue(dismissAll.waitForExistence(timeout: 5),
                      "Edit mode on: the group header's context menu should offer Dismiss All")
        XCTAssertEqual(dismissAll.title, "Dismiss All (2)",
                       "With every VT finding unreviewed, the title carries the full group count")
        dismissAll.click()

        // Both VT rows — and nothing else — now carry a disposition.
        let bothReset = NSPredicate(format: "count == 2")
        let exp = XCTNSPredicateExpectation(predicate: bothReset, object: resetButtons)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed,
                       "Dismiss All should disposition exactly the 2 VT findings; the VF group stays unreviewed")
    }
}
