//
//  MurmurUIGainTests.swift
//  MurmurUITests
//
//  X16 (#19) — the analyst gain reinterpretation end to end: the context
//  menu item honours the Editing + Studio latch, the sheet records a
//  factor, and every standing amplitude surface discloses it — the header
//  badge and the calibration readout.
//

import XCTest

final class MurmurUIGainTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInterpretGainFlow() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-grant-studio",
                                "--ui-test-window=1600x1100"]
        app.launch()

        let panel = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 30),
                      "The sample fixture should open with lead I focused")

        // 1. Behind the latch, like every analyst assertion about the data.
        panel.rightClick()
        let item = app.menuItems["bedside-context-interpret-gain"]
        XCTAssertTrue(item.waitForExistence(timeout: 3),
                      "Right-click should offer gain interpretation")
        XCTAssertFalse(item.isEnabled,
                       "Gain interpretation must stay behind the Editing latch")
        app.typeKey(.escape, modifierFlags: [])

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        // 2. Enter a ×2 reinterpretation.
        panel.rightClick()
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        let sheet = app.descendants(matching: .any)
            .matching(identifier: "gain-interpretation-sheet").firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5),
                      "The interpretation sheet should present")
        let field = app.descendants(matching: .any)
            .matching(identifier: "gain-sheet-factor").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText("2")
        app.descendants(matching: .any)
            .matching(identifier: "gain-sheet-apply").firstMatch.click()

        // 3. The standing disclosures: the header badge wears the factor…
        let badge = app.descendants(matching: .any)
            .matching(identifier: "channel-gain-factor-I").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10),
                      "A reinterpreted channel must wear its factor in the header")
        XCTAssertTrue(badge.label.contains("×2") || ((badge.value as? String) ?? "").contains("×2"),
                      "The badge should state ×2, got label \"\(badge.label)\"")

        // …and the calibration readout carries the provenance with every
        // mm/mV claim. The combined element exposes its text through VALUE,
        // not label, on macOS (probed) — match on value.
        let annotatedReadout = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND value CONTAINS %@",
                        "calibration-readout", "gain ×2 — analyst")).firstMatch
        XCTAssertTrue(annotatedReadout.waitForExistence(timeout: 15),
                      "The readout should disclose the correction")

        // 4. The menu reads back the standing interpretation.
        panel.rightClick()
        let updated = app.menuItems.matching(
            NSPredicate(format: "identifier == %@ AND title CONTAINS %@",
                        "bedside-context-interpret-gain", "×2")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 3),
                      "The menu item should read back the ×2 interpretation")
        app.typeKey(.escape, modifierFlags: [])
    }
}
