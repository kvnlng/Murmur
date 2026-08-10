//
//  MurmurUISyntheticFixtureTests.swift
//  MurmurUITests
//
//  X99 (#164) — the rich ECGSYN-style fixture, end to end through the app.
//
//  `--ui-test-sample-rich` generates a record whose R–R tachogram, beat
//  positions, and episode labels are constructed truth (MurmurCore.SyntheticECG)
//  and imports it like any WFDB record. The unit suites prove the numbers
//  (SyntheticECGOracleTests: metrics over the truth tachogram equal an
//  independent derivation); what only XCUI can prove is that the app's real
//  pipelines — trend-channel import, wavelet delineation over the synthetic
//  morphology, and the variability-metrics orchestrator — all light up on it
//  with NO inject flags. Every lane asserted here is computed, not planted.
//
//  The strip assertion is the sharp one: `variability-metrics-strip` exists
//  only in the POPULATED state (locked and insufficient states render other
//  views), so its presence means Studio gating passed, the delineator found
//  beats, and ECGMetricsService produced a real report from them.
//

import XCTest

final class MurmurUISyntheticFixtureTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Same X85 lesson as MurmurUITrendStackTests: the stack's fold state is
    /// `@AppStorage`, so drive to expanded before asserting lane content.
    @MainActor
    private func ensureTrendStackExpanded(_ app: XCUIApplication, timeout: TimeInterval = 20) {
        let bar = app.descendants(matching: .any)
            .matching(identifier: "trend-stack-bar").firstMatch
        guard bar.waitForExistence(timeout: timeout) else { return }
        let stack = app.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        if stack.waitForExistence(timeout: 3) { return }
        _ = MurmurUITests.scrollUntilHittable(bar, in: app)
        bar.click()
        _ = stack.waitForExistence(timeout: 3)
    }

    @MainActor
    func testRichFixtureLightsUpComputedLanesAndMetricsStrip() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample-rich", "--ui-test-grant-studio"]
        app.launch()
        ensureTrendStackExpanded(app)

        let stack = app.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 30),
                      "The rich fixture carries HR_bpm and ecg_artifact_ratio, so a trend stack must mount")

        // Whole-record lanes come straight from the generated trend channels.
        for lane in ["hr", "quality"] {
            let row = app.descendants(matching: .any)
                .matching(identifier: "trend-lane-\(lane)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10),
                          "The \(lane) lane should render from the fixture's trend channels")
        }

        // X89's lane is the delineation proof: it renders only from beats the
        // wavelet delineator actually found in the synthetic waveform. A
        // generous timeout — delineation of the full record runs after open.
        let beatLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-hr-beats").firstMatch
        XCTAssertTrue(beatLane.waitForExistence(timeout: 60),
                      "The delineator should find the synthetic beats and produce the beat-derived HR lane")

        // Populated strip == Studio gate passed AND ECGMetricsService computed
        // a real report from the record's beats. This identifier does not
        // exist in the locked or insufficient states.
        let strip = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-strip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 30),
                      "The Variability Metrics strip should populate from the fixture's beats")

        let provenance = strip.descendants(matching: .staticText)
            .matching(identifier: "variability-metrics-provenance").firstMatch
        XCTAssertTrue(provenance.waitForExistence(timeout: 5),
                      "A populated strip names its record and beat count")
        let text = provenance.label.isEmpty
            ? ((provenance.value as? String) ?? "")
            : provenance.label
        XCTAssertTrue(text.contains("beats"),
                      "Provenance should carry a beat count, got: \(text)")
    }
}
