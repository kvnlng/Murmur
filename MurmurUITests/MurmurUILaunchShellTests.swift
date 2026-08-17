//
//  MurmurUILaunchShellTests.swift
//  MurmurUITests
//
//  #285 — 12a's headline: "The frame never moves." The launch shell keeps
//  every toolbar item present (disabled, off state) and the info bar
//  mounted with blank values, so opening a record changes VALUES, never
//  the frame.
//
//  The one bullet 12a states as an invariant rather than an appearance is
//  "No item appears or disappears on load" — so the core assertion here is
//  set-shaped: the same item ids exist at launch and with a record open.
//
//  `vtvf-scan-action` is asserted at launch only: with a record open its
//  registration follows `scanContext.isScanAvailable`, which the bare
//  sample fixture does not guarantee.
//

import XCTest

final class MurmurUILaunchShellTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The customisable item set that must exist in BOTH states. Ids are
    /// the accessibility identifiers, as everywhere in this suite.
    private static let invariantItemIDs = [
        "notes-toggle",
        "edit-mode-toggle",
        "window-lock-toggle",
        "attach-findings",
        "export-report",
        "producers-toggle",   // DEBUG builds — which UI tests are
        "findings-toggle",
        "toolbar-more",
    ]

    private func toolbarElement(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.toolbars.firstMatch.descendants(matching: .any)
            .matching(identifier: id).firstMatch
    }

    @MainActor
    func testLaunchShellKeepsEveryToolbarItemPresentAndIdle() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.toolbars.firstMatch.waitForExistence(timeout: 15),
                      "The launch shell should have a toolbar at all")
        for id in Self.invariantItemIDs {
            let item = toolbarElement(app, id)
            XCTAssertTrue(item.waitForExistence(timeout: 5),
                          "\(id) must exist at launch — 12a: no item appears on load")
        }
        // Idle means idle: a control that acts with no record open would be
        // worse than an absent one. The overflow menu is the one exception
        // 12a names (Open Record Folder…, Customize Toolbar…).
        for id in ["notes-toggle", "edit-mode-toggle", "attach-findings", "findings-toggle"] {
            XCTAssertFalse(toolbarElement(app, id).isEnabled,
                           "\(id) must be disabled with no record open")
        }
        XCTAssertTrue(toolbarElement(app, "toolbar-more").isEnabled,
                      "The overflow menu stays enabled — it is how a record gets opened")

        // The scan item is present at launch like everything else…
        XCTAssertTrue(toolbarElement(app, "vtvf-scan-action").exists,
                      "vtvf-scan-action must exist at launch")

        // …and the info bar holds the frame with blank values.
        let bar = app.descendants(matching: .any).matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(bar.exists, "12a: the info bar exists at launch, values blank")
        XCTAssertTrue(bar.label.contains("—"),
                      "The idle bar's values are em-dashes; it reads: \(bar.label)")
    }

    @MainActor
    func testTheSameItemSetExistsWithARecordOpen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let infoBar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(infoBar.waitForExistence(timeout: 30),
                      "the bedside should render at all")
        for id in Self.invariantItemIDs {
            XCTAssertTrue(toolbarElement(app, id).waitForExistence(timeout: 5),
                          "\(id) must exist with a record open — the frame never moves")
        }
    }
}
