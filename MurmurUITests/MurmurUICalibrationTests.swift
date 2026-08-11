//
//  MurmurUICalibrationTests.swift
//  MurmurUITests
//
//  X50 wire-up guard: a raw record must OPEN on standard ECG paper, not at
//  whatever calibration falls out of the initial time window. The defect this
//  fixes is that the app opened reporting its own ruler as "non-standard" —
//  an own-goal in front of exactly the measurement-minded audience it courts.
//
//  The open-state snap is display-size dependent, so under XCUI it's off by
//  default (bare `--ui-test-sample` tests keep stable open geometry); this test
//  opts in with `--ui-test-standard-open`. Asserts the persistent
//  `calibration-readout` never says "non-standard" on open, and — when the
//  runner has a trustworthy physical display size — reads standard paper
//  exactly, without hover and without invoking the Standard View command.
//

import XCTest

final class MurmurUICalibrationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRawRecordOpensOnStandardPaper() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-standard-open"]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 10),
                      "Sample record should open and present the bedside view")

        let readout = app.descendants(matching: .any)
            .matching(identifier: "calibration-readout").firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 10),
                      "The persistent calibration readout should be visible on open, without hover")

        // The combined element exposes its text through VALUE, not label, on
        // macOS (probed under X16) — an empty read would pass every check
        // below vacuously, so insist on real text first.
        let text = (readout.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? readout.label
        XCTAssertFalse(text.isEmpty,
                       "The calibration readout should expose its text via value (or label) — got neither")
        // The core of X50: the open state must never self-report as off paper.
        XCTAssertFalse(text.contains("non-standard"),
                       "A freshly opened raw record must not report a non-standard ruler — got \"\(text)\"")
        // On a trustworthy display the readout is in mm and must read standard
        // paper exactly. On a degenerate display (X40 §7) it honestly falls back
        // to points and asserts no mm scale — which the check above already
        // covers — so only tighten to the exact string when mm are shown.
        if text.contains("mm/mV") {
            XCTAssertTrue(text.contains("25 mm/s · 10 mm/mV"),
                          "Open state should be standard 25 mm/s · 10 mm/mV — got \"\(text)\"")
        }
    }
}
