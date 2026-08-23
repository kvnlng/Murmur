//
//  MurmurUIDispositionTests.swift
//  MurmurUITests
//
//  #331 — confirming a finding AS something. The generic confirm menu used
//  to offer "Confirm as VT / VF", two words that were wrong for every
//  producer except the arrhythmia scan. It now offers the finding's own
//  category, the other categories on the record, and a free-form
//  "Confirm as…". Agreeing with the label is silent; disagreeing draws a
//  "→ <category>" chip beside the producer's word.
//
//  (The pre-#331 "Confirm (unsure)" item is the fixture-independent one and
//  stays covered by MurmurUITests.testConfirmFindingViaMenuExposesResetButton.)
//

import XCTest

final class MurmurUIDispositionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches the sample, unlocks editing, and opens the first finding's
    /// confirm menu. Returns the app with the menu showing.
    @MainActor
    private func launchWithConfirmMenuOpen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 10))
        editToggle.click()

        let confirms = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'disposition-confirm-'"))
        let appeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"), object: confirms
        )
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 5), .completed,
                       "Confirm controls should appear once editing is on")
        confirms.element(boundBy: 0).click()
        return app
    }

    /// "Confirm as <the finding's own category>" is agreement. It confirms the
    /// row and draws NO override chip — agreement stays silent so that only
    /// disagreement draws the eye.
    @MainActor
    func testConfirmAsOwnCategoryIsSilentAgreement() throws {
        let app = launchWithConfirmMenuOpen()

        // The first item is "Confirm as <category>" — whatever this row's
        // category is. Exclude the submenu ("Confirm as another…") and the
        // free-form item ("Confirm as…", no space after "as").
        let ownCategory = app.menuItems.matching(
            NSPredicate(format: "title BEGINSWITH 'Confirm as ' AND NOT title BEGINSWITH 'Confirm as another'")
        ).firstMatch
        XCTAssertTrue(ownCategory.waitForExistence(timeout: 3),
                      "The menu should lead with the row's own category")
        // On the sample the first row IS a VT, so this reads "Confirm as VT"
        // — same words as the old hard-coded item, now for the right reason.
        // What proves it is record-driven is the clicked row's category,
        // captured here and compared below.
        let category = String(ownCategory.title.dropFirst("Confirm as ".count))
        ownCategory.click()

        let reset = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'disposition-reset-'"))
        let confirmed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"), object: reset
        )
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 5), .completed,
                       "The finding should be confirmed")

        // The chip is a Text inside the row Button's label, so XCUI sees it
        // only as part of the row's label (the rename test reads its row the
        // same way). No row may carry the override arrow.
        let row = app.descendants(matching: .any)
            .matching(identifier: "finding-row-\(category)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The confirmed row should be the one whose category was offered")
        let overridden = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'finding-row-' AND label CONTAINS '→ '")
        )
        XCTAssertEqual(overridden.count, 0,
                       "Agreeing with the producer's label must not draw an override chip")
    }

    /// "Confirm as…" records what the ANALYST says the finding is. The row
    /// then shows that word beside the producer's, verbatim.
    @MainActor
    func testConfirmAsAnotherCategoryShowsTheOverride() throws {
        let app = launchWithConfirmMenuOpen()

        let freeForm = app.menuItems["Confirm as…"].firstMatch
        XCTAssertTrue(freeForm.waitForExistence(timeout: 3),
                      "The menu should offer a free-form Confirm as…")
        freeForm.click()

        // Same container dance as the rename test: .alert reaches XCUI as a
        // dialog or a sheet depending on the macOS release.
        let container: XCUIElement = {
            if app.dialogs.firstMatch.waitForExistence(timeout: 2) { return app.dialogs.firstMatch }
            if app.sheets.firstMatch.waitForExistence(timeout: 2) { return app.sheets.firstMatch }
            return app.windows.firstMatch
        }()
        let field = container.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "Confirm as… should present a category field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("AFlutter")

        let confirm = container.buttons["Confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.click()

        // First: was the disposition written at all? Separates "the dialog
        // didn't commit" from "the chip isn't exposed".
        let reset = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'disposition-reset-'"))
        let confirmed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"), object: reset
        )
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 5), .completed,
                       "Confirm as… should confirm the finding")

        // The chip is a Text inside the row Button's label — XCUI sees it as
        // part of the row's label, not as its own element (the rename test
        // reads its renamed row the same way). VERBATIM: a dropped letter
        // would mean a bedside shortcut swallowed a keystroke.
        let overridden = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'finding-row-' AND label CONTAINS '→ AFlutter'")
        ).firstMatch
        XCTAssertTrue(overridden.waitForExistence(timeout: 5),
                      "Disagreeing with the label should draw \"→ AFlutter\" on the row")
    }
}
