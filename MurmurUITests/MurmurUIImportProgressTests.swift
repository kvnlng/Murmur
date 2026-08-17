//
//  MurmurUIImportProgressTests.swift
//  MurmurUITests
//
//  #263 — the 12a import-progress strip in the info bar: record name, bar,
//  "N of M records · P%", one global surface. Seeded via
//  `--ui-test-seed-import-progress` because a real synthetic import
//  completes in well under a second — far too fast for XCUI to catch the
//  strip mounted.
//
//  The bar combines its children into one accessibility label (X51), so
//  the strip is asserted through the bar's label, the same way the
//  window-range assertions work.
//

import XCTest

final class MurmurUIImportProgressTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func infoBar(of app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "info-bar").firstMatch
    }

    @MainActor
    func testInfoBarCarriesTheImportStrip() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-seed-import-progress"]
        app.launch()

        let bar = infoBar(of: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 30))
        XCTAssertTrue(bar.label.contains("synth-02 · 3 of 12 records · 41%"),
                      "The bar should carry the 12a sentence verbatim; it reads: \(bar.label)")
    }

    /// The strip is chrome that exists ONLY while an import is in flight —
    /// an idle bar must not carry a stale or fabricated progress readout.
    @MainActor
    func testIdleBarCarriesNoImportStrip() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bar = infoBar(of: app)
        XCTAssertTrue(bar.waitForExistence(timeout: 30))
        XCTAssertFalse(bar.label.contains("of 12 records"),
                       "No import is running, so no import sentence belongs in the bar")
    }
}
