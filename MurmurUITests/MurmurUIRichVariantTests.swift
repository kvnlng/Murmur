//
//  MurmurUIRichVariantTests.swift
//  MurmurUITests
//
//  X105 (#176) — the edge-state fixtures reach the UI through the real
//  import path. These are smokes, deliberately: they pin that each state is
//  a record the app OPENS and renders (no crash, no hang, channel panels
//  mount), which is what the fixture infrastructure owes. What each state
//  should LOOK like (the flat-line lane plot, primary-fallback policy) is
//  its own future ticket's subject — those tests will start from these
//  launches. No window flag: X100's 1400×900 default policy applies.
//

import XCTest

final class MurmurUIRichVariantTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchVariant(_ value: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample-rich=\(value)", "--ui-test-grant-studio"]
        app.launch()
        return app
    }

    @MainActor
    private func assertChannelPanelMounts(_ app: XCUIApplication, lead: String,
                                          message: String) {
        let panel = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-\(lead)").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 45), message)
    }

    @MainActor
    func testFlatlineVariantOpensAndRenders() throws {
        let app = launchVariant("flatline")
        // The record opens on the default primary despite a 15 s full
        // disconnect mid-record; the quality lane carries the elevated span.
        assertChannelPanelMounts(app, lead: "I",
            message: "The flat-line record must open like any record")
        let bar = app.descendants(matching: .any)
            .matching(identifier: "trend-stack-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20),
                      "Trend channels (incl. the elevated artifact lane) must import")
    }

    @MainActor
    func testDropoutVariantOpensAndRenders() throws {
        let app = launchVariant("dropout")
        // Lead I — the default primary — is the dead one, deliberately. The
        // record must still open with the flat trace as a first-class
        // channel; what the app SHOULD do about a flat primary is future
        // policy, but "opens and renders" is owed today.
        assertChannelPanelMounts(app, lead: "I",
            message: "A record whose primary lead is flat must still open and mount its panel")
    }

    @MainActor
    func testShortRecordOpensAndRenders() throws {
        // 8 s — shorter than the 10 s zoom window. Numeric values were
        // always accepted; this pins that a shorter-than-one-window record
        // is a state the app survives.
        let app = launchVariant("8")
        assertChannelPanelMounts(app, lead: "I",
            message: "A record shorter than one zoom window must open and render")
    }
}
