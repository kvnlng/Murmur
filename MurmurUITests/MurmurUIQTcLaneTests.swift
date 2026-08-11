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

    /// X111 (§2.1): the R–R CV instability bound ships exposed at the
    /// review's 15% default — the chip is on the QTc lane, adjustable, and
    /// the steady-sinus fixture (CV ≈ 5%) flags nothing, so no instability
    /// note renders on clean ground.
    @MainActor
    func testCVFlagChipShipsAtTheCitedDefault() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-inject-qtc-lane=455"]
        app.launch()

        let chip = app.descendants(matching: .any)
            .matching(identifier: "interval-trend-lane-cv-flag-picker").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15),
                      "The CV-bound chip should sit on the QTc lane's caption row")
        XCTAssertTrue(spokenName(of: chip).contains("15"),
                      "The exposed bound must default to the review's 15%, got: \(spokenName(of: chip))")

        let note = app.descendants(matching: .any)
            .matching(identifier: "interval-trend-lane-cv-instability-note").firstMatch
        XCTAssertFalse(note.exists,
                       "Steady sinus must not carry an instability note — no vacuous flags")
    }

    /// X58: the analyst's T-offset gate chip ships at the derived default
    /// (exclude, score ≥ 1) and the citation caption states the gate and the
    /// per-reason exclusion split from the injected template.
    @MainActor
    func testTOffsetGateChipAndExclusionCaption() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-inject-qtc-lane=455"]
        app.launch()

        let chip = app.descendants(matching: .any)
            .matching(identifier: "interval-trend-lane-toffset-gate").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15),
                      "The QTc lane should carry the T-offset gate chip")
        XCTAssertTrue(spokenName(of: chip).contains("T-gate ≥1"),
                      "The chip ships at the derived default; got \"\(spokenName(of: chip))\"")

        let caption = app.descendants(matching: .any)
            .matching(identifier: "interval-trend-lane-repro-caption").firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        let captionText = spokenName(of: caption)
        XCTAssertTrue(captionText.contains("5 excluded: 2 physically impossible · 3 unreliable T-offset"),
                      "Exclude-and-count must name both causes; got \"\(captionText)\"")
        XCTAssertTrue(captionText.contains("T-offset gate: exclude score ≥ 1"),
                      "The gate setting is a methods fact the citation must echo; got \"\(captionText)\"")
    }

    /// macOS surfaces an element's text in different attributes by role —
    /// `label` (buttons, explicit accessibility labels), `value` (static
    /// text), or `title` (MenuButtons, which is what a SwiftUI Menu chip
    /// becomes). Read all three; asserting on just one is how the first
    /// version of this test failed against a chip that WAS correctly named.
    private func spokenName(of element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.title
    }
}
