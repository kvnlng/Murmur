//
//  MurmurUISessionTests.swift
//  MurmurUITests
//
//  End-to-end coverage for opening a native `.mur` session. The NSOpenPanel is
//  system-modal (XCUI-hostile, like the folder picker), so `--ui-test-open-
//  sample-session` packages a synthetic fixture into a `.mur` and drives the
//  real loader (MurSessionPackage.read → RecordingStore.loadManifest →
//  present). This asserts the package actually reconstitutes into a viewable
//  recording — the read/present chain the unit tests can't reach.
//

import XCTest

final class MurmurUISessionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOpenMurSessionPresentsRecording() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-sample-session"]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 10),
                      "Opening a .mur package should reconstitute and present its recording")
    }

    @MainActor
    func testImportHeaderBlockCSVPresentsRecording() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-sample-csv"]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 10),
                      "Importing a header-block CSV should convert + present the recording")
    }
}
