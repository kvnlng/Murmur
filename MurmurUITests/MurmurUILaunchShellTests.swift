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
        for id in ["notes-toggle", "edit-mode-toggle", "attach-findings"] {
            XCTAssertFalse(toolbarElement(app, id).isEnabled,
                           "\(id) must be disabled with no record open")
        }
        XCTAssertTrue(toolbarElement(app, "toolbar-more").isEnabled,
                      "The overflow menu stays enabled — it is how a record gets opened")
        // #303: the pane toggles are the OTHER exception — they act on
        // chrome, not on record data, and 12a wants the panes closed but
        // openable at launch.
        XCTAssertTrue(toolbarElement(app, "findings-toggle").isEnabled,
                      "The review-queue toggle stays enabled — the empty pane must open")

        // The scan item is present at launch like everything else…
        XCTAssertTrue(toolbarElement(app, "vtvf-scan-action").exists,
                      "vtvf-scan-action must exist at launch")

        // …and the info bar holds the frame with blank values.
        let bar = app.descendants(matching: .any).matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(bar.exists, "12a: the info bar exists at launch, values blank")
        XCTAssertTrue(bar.label.contains("—"),
                      "The idle bar's values are em-dashes; it reads: \(bar.label)")
    }

    /// 12a: "The trend stack renders all five lane rows with their accent
    /// rails, label columns, y-axis ticks and gridlines; plots are empty and
    /// values are em-dashes." The lane ids are the REAL lanes' ids, so a
    /// record opening changes values, never which rows exist.
    @MainActor
    func testAllFiveTrendLanesExistIdleAtLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let stack = app.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 15),
                      "12a: the trend stack exists at launch")
        for laneID in [
            "trend-lane-hr",
            "trend-lane-rmssd",
            "trend-lane-interval-trend",
            "trend-lane-lfhf",
            "trend-lane-quality",
        ] {
            let lane = app.descendants(matching: .any)
                .matching(identifier: laneID).firstMatch
            XCTAssertTrue(lane.exists,
                          "\(laneID) must exist at launch — all five lane rows, values blank")
            XCTAssertTrue(lane.staticTexts["—"].exists,
                          "\(laneID)'s value must render as an em-dash")
        }
    }

    /// #263 wired into the shell: with no record open, the import strip
    /// lives in the SAME idle info bar — the one piece of chrome 12a allows
    /// to change state between empty and loaded.
    @MainActor
    func testIdleInfoBarCarriesTheImportStrip() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-seed-import-progress"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 15),
                      "the idle info bar exists at launch")
        XCTAssertTrue(bar.label.contains("synth-02"),
                      "the idle bar carries the import summary; it reads: \(bar.label)")
        XCTAssertTrue(bar.label.contains("3 of 12"),
                      "the summary names N of M records; it reads: \(bar.label)")
    }

    /// #303 / 12a: "Both side panes are closed at launch; their toolbar
    /// toggles render in the off state." Closed, not absent — the design's
    /// launch window is the REAL split view, so the record navigator and the
    /// review queue open and close with no record, showing their working
    /// chrome with quiet empties.
    @MainActor
    func testLaunchPanesStartClosedAndToggleOpenEmpty() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.toolbars.firstMatch.waitForExistence(timeout: 15))
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "record-search-field").firstMatch
        let idleQueue = app.descendants(matching: .any)
            .matching(identifier: "findings-panel-idle").firstMatch
        XCTAssertFalse(searchField.exists, "the navigator starts CLOSED at launch")
        XCTAssertFalse(idleQueue.exists, "the review queue starts CLOSED at launch")

        // Navigator: open → the record list's working chrome, empty.
        let sidebarToggle = toolbarElement(app, "toolbar-sidebar-toggle")
        XCTAssertTrue(sidebarToggle.exists,
                      "the sidebar toggle exists at launch — the pane is closed, not absent")
        sidebarToggle.click()
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "the empty navigator keeps the search field")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "records-section-header").firstMatch.exists,
                      "the empty navigator keeps the RECORDS header")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "sidebar-empty-open-button").firstMatch.exists,
                      "the empty navigator offers Open Record Folder — the design's third home "
                      + "for the open action")
        sidebarToggle.click()
        XCTAssertTrue(waitForAbsence(searchField),
                      "the navigator closes again — the toggle round-trips")

        // Review queue: open → header and disposition filter, counts blank.
        let queueToggle = toolbarElement(app, "findings-toggle")
        queueToggle.click()
        XCTAssertTrue(idleQueue.waitForExistence(timeout: 5),
                      "the review-queue toggle opens the empty queue")
        XCTAssertTrue(idleQueue.staticTexts["Review queue"].exists,
                      "the empty queue keeps its header")
        for bucket in ["toReview", "confirmed", "dismissed"] {
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(identifier: "disposition-filter-\(bucket)").firstMatch.exists,
                          "the empty queue keeps the \(bucket) chip — working chrome, quiet empties")
        }
        queueToggle.click()
        XCTAssertTrue(waitForAbsence(idleQueue),
                      "the queue closes again — the toggle round-trips")
    }

    /// Absence has no waitFor — poll briefly.
    private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(200_000)
        }
        return !element.exists
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
        // The other half of "same items, different STATE": with a record
        // open the controls are live. Guards the wiring that turns the idle
        // set into the bedside's controls (#298 — the two must be one
        // registration, not two swapping ones).
        for id in ["notes-toggle", "edit-mode-toggle", "window-lock-toggle", "findings-toggle"] {
            XCTAssertTrue(toolbarElement(app, id).isEnabled,
                          "\(id) must be ENABLED with a record open")
        }
    }
}
