//
//  MurmurUIVariabilityMetricsTests.swift
//  MurmurUITests
//
//  X95 — the Variability Metrics strip on an unmeasurable scoped window.
//
//  The reported bug: "the window will disappear if the 10s zoom is selected."
//  Mechanism: in Window scope, a viewport holding fewer than 3 normal beats
//  computed no report, the context cleared, and a nil summary unmounted the
//  WHOLE strip — scope picker included, so the one control that could undo
//  the state vanished with it. What is pinned here is the strip's presence:
//  it must stay mounted, say why it is empty, and keep the picker reachable.
//

import XCTest

final class MurmurUIVariabilityMetricsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testShortScopedWindowKeepsStripMountedWithScopePicker() throws {
        let app = XCUIApplication()
        // 8 atr-sourced normals across the 10 s fixture: whole record measures
        // (7 intervals); a 2 s window holds ~2 beats — one interval short.
        // Studio must be GRANTED: the orchestrator locks the strip behind
        // the entitlement (`guard store.hasStudio else { setLocked() }`),
        // so on a fresh container (every Xcode Cloud VM) the unlock seam
        // renders instead of the strip. This test passed for weeks on
        // entitled developer machines only — the 2026-08-12 Cloud failure's
        // branch report (populated: no, insufficient: no) is what finally
        // named the third branch.
        app.launchArguments += ["--ui-test-sample", "--ui-test-seed-atr-normals=8",
                                "--ui-test-grant-studio"]
        app.launch()

        // The populated strip, whole-record scope (the default). The
        // identifier exists ONLY on the populated variant — the insufficient
        // and locked branches carry their own — so absence means the seeded
        // compute produced no summary.
        let strip = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-strip").firstMatch
        if !strip.waitForExistence(timeout: 30) {
            let insufficient = app.descendants(matching: .any)
                .matching(identifier: "variability-metrics-insufficient").firstMatch.exists
            let locked = app.descendants(matching: .any)
                .matching(identifier: "variability-metrics-unlock-seam").firstMatch.exists
            XCTFail("The fixture should populate the Variability Metrics strip — "
                    + "insufficient-branch: \(insufficient), locked-branch: \(locked), "
                    + "window \(app.windows.firstMatch.frame)")
            return
        }

        // Narrow the scope to the visible window. The segmented picker's
        // segments surface as radio buttons on macOS.
        let windowSegment = app.radioButtons["Window"].firstMatch
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(windowSegment, in: app),
                      "The scope picker's Window segment should be clickable")
        windowSegment.click()
        XCTAssertTrue(strip.waitForExistence(timeout: 5),
                      "The 10 s fixture window holds enough beats — Window scope still measures")

        // Zoom to 2 s: ~2 normal beats, below the 3 the compute needs.
        let zoom2s = app.buttons.matching(identifier: "zoom-ladder-2s").firstMatch
        XCTAssertTrue(zoom2s.waitForExistence(timeout: 3),
                      "The 10 s fixture should offer the 2 s ladder rung")
        zoom2s.click()

        // THE BUG: the strip used to unmount entirely here. It must stay —
        // at FULL size, with the explanation riding the first section's
        // header as an advisory (the follow-up bug was this branch rendering
        // a collapsed stub) and the picker still present.
        let insufficient = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-insufficient").firstMatch
        XCTAssertTrue(insufficient.waitForExistence(timeout: 5),
                      "An unmeasurable scoped window must keep the strip mounted with its empty state")
        let advisory = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-time-domain-advisory").firstMatch
        XCTAssertTrue(advisory.waitForExistence(timeout: 3),
                      "The insufficient card must say why there are no numbers")
        let picker = app.descendants(matching: .any)
            .matching(identifier: "metrics-scope-picker").firstMatch
        XCTAssertTrue(picker.exists,
                      "The scope picker must survive the empty state — it is the way back out")

        // And it IS the way back out: Whole scope repopulates the numbers.
        let wholeSegment = app.radioButtons["Whole"].firstMatch
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(wholeSegment, in: app))
        wholeSegment.click()
        XCTAssertTrue(strip.waitForExistence(timeout: 5),
                      "Switching back to Whole scope should repopulate the strip")
    }
}
