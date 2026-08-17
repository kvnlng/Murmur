//
//  MurmurUIFindingRenameTests.swift
//  MurmurUITests
//
//  #250 — the analyst names their own finding in the Review Queue.
//
//  The X52 §5 half of the coverage: the RENDERED row shows the typed name,
//  not just the model field. (The save/reopen half round-trips through the
//  real sidecar code in `FindingRenameTests` — the synthetic fixture is
//  regenerated per launch, so a relaunch here would erase the bundle the
//  rename was saved into and prove nothing.)
//
//  The typed name deliberately contains J, K and V — bedside plain-key
//  shortcuts. If the rename field fails to raise `textEntryActive`, those
//  keystrokes pan the viewport and act dispositions instead of landing in
//  the field, and the final row-label assertion fails on the mangled name.
//

import XCTest

final class MurmurUIFindingRenameTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithSeededFinding() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-seed-analyst-finding"]
        app.launch()
        return app
    }

    @MainActor
    func testRenameUpdatesTheRenderedRow() throws {
        let app = launchWithSeededFinding()

        // The header renders human copy, not the internal constant.
        let group = app.buttons["finding-group-ANALYST_FINDING"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 30))
        XCTAssertTrue(group.label.contains("Analyst findings"),
                      "Group header should read \"Analyst findings\"; it reads: \(group.label)")

        // Renaming is an authoring act — unlock Editing first.
        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        // Groups are expanded by default under XCUI (X65).
        let row = app.descendants(matching: .any)
            .matching(identifier: "finding-row-ANALYST_FINDING").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        let renameItem = app.menuItems["Rename…"].firstMatch
        XCTAssertTrue(renameItem.waitForExistence(timeout: 3),
                      "An analyst-authored row must offer Rename… under Editing")
        renameItem.click()

        // The rename dialog. SwiftUI's .alert reaches XCUI as a sheet on
        // some macOS releases and a dialog on others, and NSAlert's
        // accessory plumbing may drop the field's identifier — so find the
        // container first, then its only text field.
        let container: XCUIElement = {
            if app.dialogs.firstMatch.waitForExistence(timeout: 2) { return app.dialogs.firstMatch }
            if app.sheets.firstMatch.waitForExistence(timeout: 2) { return app.sheets.firstMatch }
            return app.windows.firstMatch
        }()
        let field = container.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "The rename dialog should present a text field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Junctional escape JKV")

        let save = container.buttons["Rename"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.click()

        // The rendered row carries the typed name — VERBATIM, which is what
        // proves the textEntryActive gate: a dropped J, K or V here means a
        // bedside shortcut swallowed the keystroke.
        let renamed = app.descendants(matching: .any)
            .matching(identifier: "finding-row-ANALYST_FINDING").firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        while !renamed.label.contains("Junctional escape JKV"), Date() < deadline {
            usleep(300_000)
        }
        XCTAssertTrue(renamed.label.contains("Junctional escape JKV"),
                      "Row should render the typed name; it renders: \(renamed.label)")
    }

    /// Provenance stays unforgeable: a producer-sourced row offers no
    /// Rename even under Editing.
    @MainActor
    func testProducerRowsOfferNoRename() throws {
        let app = launchWithSeededFinding()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 30))
        editToggle.click()

        // The default fixture's VT row comes from the synthetic producer.
        let vtRow = app.descendants(matching: .any)
            .matching(identifier: "finding-row-VT").firstMatch
        XCTAssertTrue(vtRow.waitForExistence(timeout: 5))
        vtRow.rightClick()

        let renameItem = app.menuItems["Rename…"].firstMatch
        XCTAssertFalse(renameItem.waitForExistence(timeout: 2),
                       "A producer-sourced row must not offer Rename — renaming "
                       + "someone else's annotation would falsify provenance")
        // Dismiss any open context menu so teardown is clean.
        app.typeKey(.escape, modifierFlags: [])
    }
}
