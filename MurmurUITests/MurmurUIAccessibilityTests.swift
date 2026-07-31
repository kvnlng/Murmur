//
//  MurmurUIAccessibilityTests.swift
//  MurmurUITests
//
//  A standing guard that elements carrying a known identifier also carry a
//  spoken name (X51 §6). Two of the five defects the 2026-07-31 audit found
//  were silent regressions against a previously-verified state, and nothing in
//  the suite guarded accessibility labels — so a rebuilt view could drop a
//  name and no test noticed. This is the cheap sweep that would have caught
//  §1 / §3 / §4 together.
//

import XCTest

final class MurmurUIAccessibilityTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// An element carries a spoken name if EITHER its `label` (buttons, and
    /// anything with an explicit `.accessibilityLabel`) or its `value` (macOS
    /// static text exposes its string here, not in `label`) is non-empty.
    private func hasSpokenName(_ element: XCUIElement) -> Bool {
        if !element.label.isEmpty { return true }
        if let value = element.value as? String, !value.isEmpty { return true }
        return false
    }

    @MainActor
    func testKnownElementsCarryNonEmptyLabels() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-initial-duration=2"]
        app.launch()

        // The overview span readout is present for any loaded recording, so it
        // anchors the sweep — if this has no name, §5 regressed.
        let overview = app.descendants(matching: .any)
            .matching(identifier: "overview-window-label").firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 8),
                      "overview-window-label should exist once a recording is loaded (X51 §5)")
        XCTAssertTrue(hasSpokenName(overview), "overview-window-label must carry a spoken name")

        // Sweep the rest: any that render in the sample must be named. Absent
        // ones (e.g. the paid lanes without the ECG Metrics entitlement) are
        // skipped — X48 adds the definitive queue-row assertion on a record
        // fixture that has collapsed normals.
        let mustBeNamedIfPresent = [
            "collapsed-normals-row",             // X51 §1 — X48's target
            "interval-trend-lane-add-guide",     // X51 §3 — RUO disclosure
            "interval-trend-lane-summary",       // X51 §2
            "variability-lane-summary",          // X51 §2
            "docked-beat-inspector-empty"        // X51 §4
        ]
        for identifier in mustBeNamedIfPresent {
            let element = app.descendants(matching: .any)
                .matching(identifier: identifier).firstMatch
            if element.waitForExistence(timeout: 2) {
                XCTAssertTrue(hasSpokenName(element),
                              "\(identifier) must carry a spoken name (label or value)")
            }
        }
    }
}
