//
//  MurmurUILeadPresetTests.swift
//  MurmurUITests
//
//  #332 — the lead-presets menu, end to end. The unit suites prove that a
//  preset RESOLVES against a channel list and that the store ROUND-TRIPS;
//  neither proves that the menu row reaches the stage or that the save
//  dialog reaches the menu. These do.
//

import XCTest

final class MurmurUILeadPresetTests: XCTestCase {
    /// Built-in ids are fixed (`LeadPreset.builtInID`), so the Limb row has
    /// the same identifier in every build.
    private let limbRowID = "lead-preset-00000000-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// What VoiceOver would announce — see `MurmurUILeadOverlayTests`.
    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    /// A row of the presets menu once it is open. SwiftUI's `Menu` surfaces
    /// its rows as menu items.
    @MainActor
    private func presetRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.menuItems.matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func openPresetsMenu(_ app: XCUIApplication) {
        let menu = app.descendants(matching: .any)
            .matching(identifier: "lead-presets-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Chip bar should carry the presets menu")
        menu.click()
    }

    @MainActor
    func testApplyingLimbPresetStagesSixLeadsWithPrimaryI() throws {
        // The sample record carries I, II, III, aVR, aVL, aVF, V1, V2, so
        // `Limb` resolves in full. Applying it should put exactly the six
        // limb leads on the stage with I primary — and NOT V1/V2, which
        // were never in the preset.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let panelI = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panelI.waitForExistence(timeout: 5), "Default focus is lead I")

        openPresetsMenu(app)
        let limb = presetRow(app, limbRowID)
        XCTAssertTrue(limb.waitForExistence(timeout: 3), "Limb should be offered as a built-in row")
        XCTAssertEqual(limb.title, "Limb",
                       "Every Limb lead is in the sample, so the row carries no 'n of m' shortfall")
        limb.click()

        for lead in ["I", "II", "III", "aVR", "aVL", "aVF"] {
            let row = app.descendants(matching: .any)
                .matching(identifier: "lead-legend-\(lead)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3),
                          "Applying Limb should stage lead \(lead)")
        }
        for lead in ["V1", "V2"] {
            let row = app.descendants(matching: .any)
                .matching(identifier: "lead-legend-\(lead)").firstMatch
            XCTAssertFalse(row.exists, "Lead \(lead) is not in Limb and must not be staged")
        }
        XCTAssertTrue(panelI.exists, "The first lead of the preset is primary — the panel stays I's")
        let chipI = app.buttons.matching(identifier: "lead-chip-I").firstMatch
        XCTAssertTrue(spokenName(chipI).contains("primary lead"),
                      "Chip I should announce itself as primary, got '\(spokenName(chipI))'")
    }

    @MainActor
    func testSavingTheStagedLeadsAddsAPresetRow() throws {
        // Stage I + V1, save them under a name, and the name should appear
        // as a row of the menu in the same run. The suite is test-scoped
        // (`--ui-test-preset-suite`) so nothing lands in the analyst's
        // preferences and the menu starts with only the four built-ins.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-preset-suite=murmur.uitests.leadPresets"]
        app.launch()

        let chipV1 = app.buttons.matching(identifier: "lead-chip-V1").firstMatch
        XCTAssertTrue(chipV1.waitForExistence(timeout: 5))
        chipV1.click()
        let legendV1 = app.descendants(matching: .any)
            .matching(identifier: "lead-legend-V1").firstMatch
        XCTAssertTrue(legendV1.waitForExistence(timeout: 3), "V1 should join I on the stage")

        openPresetsMenu(app)
        XCTAssertFalse(app.menuItems["Reduced"].exists, "A fresh suite has no saved presets")
        let save = presetRow(app, "lead-preset-save")
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.click()

        // SwiftUI's `.alert` reaches XCUI as a dialog on some builds and a
        // sheet on others — find the container first, then its field.
        let dialog = app.dialogs.firstMatch
        let sheet = app.sheets.firstMatch
        let container: XCUIElement
        if dialog.waitForExistence(timeout: 3) {
            container = dialog
        } else {
            XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Save Lead Preset alert should appear")
            container = sheet
        }
        let field = container.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "Alert should carry the name field")
        field.click()
        field.typeText("Reduced")
        container.buttons["Save"].click()

        openPresetsMenu(app)
        let saved = app.menuItems["Reduced"]
        XCTAssertTrue(saved.waitForExistence(timeout: 3),
                      "The saved preset should be offered by name in the same run")
        XCTAssertTrue(saved.isEnabled, "I and V1 are both in the sample, so the row resolves")
    }
}
