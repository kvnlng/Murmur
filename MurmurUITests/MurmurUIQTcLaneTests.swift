//
//  MurmurUIQTcLaneTests.swift
//  MurmurUITests
//
//  X52 §5 — rendered-equals-computed. Delineator validation (CSE, QTDB) and
//  render correctness are different claims, and the gap between them is exactly
//  where a units/binding slip survives a green unit suite. This drives the REAL
//  paid QTc trend lane with a deterministic fiducial store whose every beat
//  carries a known QTc, then asserts the value the lane RENDERS equals it.
//
//  `--ui-test-inject-qtc-lane=<qtcMs>` grants ECG Metrics in PurchaseStore.init,
//  has BedsideView publish the known store, and makes the markings orchestrator
//  skip its recompute so real delineation can't overwrite it.
//

import XCTest

final class MurmurUIQTcLaneTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testQTcLaneRendersTheComputedValue() throws {
        let knownQTc = 455
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-inject-qtc-lane=\(knownQTc)"]
        app.launch()

        let summary = app.descendants(matching: .any)
            .matching(identifier: "interval-trend-lane-summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15),
                      "The paid QTc trend lane should render once ECG Metrics is granted and a fiducial store is injected")

        // The rendered reading is folded into the summary's label.
        let label = summary.label
        let value = (summary.value as? String) ?? ""
        XCTAssertTrue(label.contains(String(knownQTc)) || value.contains(String(knownQTc)),
                      "The lane should render the computed median (\(knownQTc)); label=\"\(label)\" value=\"\(value)\"")
    }
}
