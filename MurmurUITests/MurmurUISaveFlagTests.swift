//
//  MurmurUISaveFlagTests.swift
//  MurmurUITests
//
//  X87 — the Save Session flag defaults ON when a record is selected for
//  review, so the analyst unflags to EXCLUDE rather than flags to include.
//  (The flag's existence and reachability are asserted by X63-B's
//  testOpenFolderShowsFlaggableRecordRows in MurmurUITests.swift.)
//

import XCTest

final class MurmurUISaveFlagTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// X87 (#136): selecting a record flags it by default, and the default
    /// never overrules the analyst — an explicit unflag survives switching
    /// away and back.
    @MainActor
    func testSelectingARecordFlagsItByDefault() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-folder=2"]
        app.launch()

        // The first record auto-selects and imports. Bring the navigator up
        // if X82's coexistence rule collapsed it (the inspector wins by
        // default in a window that can't hold both panels).
        let flag1 = app.descendants(matching: .any)
            .matching(identifier: "record-flag-synth.hea").firstMatch
        if !flag1.waitForExistence(timeout: 15) {
            let sidebarToggle = app.descendants(matching: .any)
                .matching(identifier: "toolbar-sidebar-toggle").firstMatch
            XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
            sidebarToggle.click()
        }
        XCTAssertTrue(flag1.waitForExistence(timeout: 15),
                      "The auto-selected record should be imported and flaggable")
        XCTAssertEqual(flag1.label, "Flagged",
                       "Selecting a record for review should flag it by default (X87)")

        // The second record hasn't been selected — click it; import + the
        // selection default should follow.
        let row2 = app.descendants(matching: .any)
            .matching(identifier: "record-row-synth2.hea").firstMatch
        XCTAssertTrue(row2.waitForExistence(timeout: 5))
        row2.click()
        let flag2 = app.descendants(matching: .any)
            .matching(identifier: "record-flag-synth2.hea").firstMatch
        XCTAssertTrue(flag2.waitForExistence(timeout: 15))
        let flagged2 = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Flagged'"), object: flag2
        )
        XCTAssertEqual(XCTWaiter.wait(for: [flagged2], timeout: 10), .completed,
                       "Selecting the second record should flag it by default")

        // The analyst excludes it — and that decision survives a revisit.
        flag2.click()
        let unflagged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Not flagged'"), object: flag2
        )
        XCTAssertEqual(XCTWaiter.wait(for: [unflagged], timeout: 5), .completed)

        let row1 = app.descendants(matching: .any)
            .matching(identifier: "record-row-synth.hea").firstMatch
        XCTAssertTrue(row1.waitForExistence(timeout: 5))
        row1.click()
        row2.click()
        XCTAssertEqual(flag2.label, "Not flagged",
                       "An explicit unflag must survive switching away and back — the default never overrules the analyst")
    }
}
