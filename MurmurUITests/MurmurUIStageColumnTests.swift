//
//  MurmurUIStageColumnTests.swift
//  MurmurUITests
//
//  X71 — the stage's right column.
//
//  The change worth guarding is a REMOVAL: the focus-beat readout no longer
//  keeps a placeholder card on screen when nothing is focused. An absence is
//  easy to break silently — a merge that restores the empty state would pass
//  every existing test, because they only ever asserted presence.
//

import XCTest

final class MurmurUIStageColumnTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    @MainActor
    func testNoBeatFocusedMeansNoBeatCard() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        // Anchor on the column so this cannot pass because the stage failed
        // to render at all.
        let controls = app.descendants(matching: .any)
            .matching(identifier: "calibration-controls").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 10),
                      "The stage's right column should render")

        for identifier in ["docked-beat-inspector-empty", "docked-beat-inspector"] {
            let card = app.descendants(matching: .any)
                .matching(identifier: identifier).firstMatch
            XCTAssertFalse(card.exists,
                           "\(identifier) should be absent with no beat focused")
        }
    }

    /// The keyboard hint moved here from the retired `summaryHeader`. Without
    /// it the shortcuts would exist only in the menu bar, and the retirement
    /// would have quietly cost the stage its only on-screen mention of them.
    @MainActor
    func testColumnCarriesTheKeyboardHint() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let hint = app.descendants(matching: .any)
            .matching(identifier: "stage-keyboard-hint").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10),
                      "The right column should carry a keyboard hint")
        let spoken = spokenName(hint)
        XCTAssertTrue(spoken.contains("J") && spoken.contains("K"),
                      "The hint should name the finding-jump keys, got '\(spoken)'")
    }

    /// X28's elapsed / wall-clock switch was honoured by exactly one surface,
    /// `viewportIndicator`, which X71 deleted after X69 moved the window range
    /// to the info bar. This guards that the info bar carries the switch
    /// rather than having silently dropped wall-clock from the app.
    @MainActor
    func testInfoBarWindowRangeStatesTheRecordTotal() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))

        let spoken = spokenName(bar)
        XCTAssertTrue(spoken.contains("window"),
                      "Info bar should name the window, got '\(spoken)'")
        // "of <total>" came across with the retired indicator. Without it the
        // window range says where you are but not what it is out of.
        XCTAssertTrue(spoken.contains(" of "),
                      "Info bar should state the window against the record total, got '\(spoken)'")
    }
}
