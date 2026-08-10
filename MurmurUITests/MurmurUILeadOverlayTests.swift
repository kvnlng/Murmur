//
//  MurmurUILeadOverlayTests.swift
//  MurmurUITests
//
//  X64 — the focus stage overlaying several leads on one time axis and one
//  amplitude axis.
//
//  Since X94 the overlay is BUILT by plain-clicking lead chips, so the
//  gesture itself is XCUI-drivable (testClickingLeadChipTogglesOverlay… in
//  MurmurUITests). The `--ui-test-overlay-leads=…` seed predates that —
//  X64's ⌘-click couldn't be synthesized — and stays because it still makes
//  each downstream test independent of the gesture: these tests verify that
//  the extra traces reach the stage and that each is identified by something
//  other than its colour. The one ungestured path left is ⌥-click (show
//  alone) — XCUI has no modifier-click, so that exit is covered by
//  `LeadSelectionTests` plus the chip-click toggles here.
//

import XCTest

final class MurmurUILeadOverlayTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// What VoiceOver would actually announce for `element`.
    ///
    /// A SwiftUI `Text` on macOS surfaces its string as the accessibility
    /// VALUE, not the label — asserting on `.label` alone reads empty for an
    /// element that speaks perfectly well. `MurmurUIAccessibilityTests` checks
    /// both for the same reason.
    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    /// Click once the element is actually hittable, not merely present.
    ///
    /// `waitForExistence` returns as soon as the element is in the tree, which
    /// on this stage happens before layout has placed it — a click then lands
    /// on nothing and the test fails somewhere else entirely. (X65 was exactly
    /// this, misdiagnosed as a missing launch flag.)
    @MainActor
    private func clickWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "exists == true AND isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "Element never became hittable"
        )
        element.click()
    }

    @MainActor
    func testClickingLeadChipTogglesOverlayAndPromotesPrimary() throws {
        // Guards: X94's chip-click semantics, end to end. Default focus is
        // lead I. Clicking lead-chip-V1 TOGGLES V1 onto the stage (the panel
        // stays lead I's — an overlaid lead contributes a trace, not a
        // panel); clicking lead-chip-I then removes I, promoting V1 to
        // primary, and the one panel becomes channel-panel-V1. This is the
        // first XCUI coverage the gesture has ever had — the old ⌘-click
        // couldn't be synthesized, which is how X94 shipped broken-looking.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let panelI = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panelI.waitForExistence(timeout: 5),
                      "Default focus is lead I; channel-panel-I should render")

        let chipV1 = app.buttons.matching(identifier: "lead-chip-V1").firstMatch
        XCTAssertTrue(chipV1.waitForExistence(timeout: 3))
        chipV1.click()

        // V1 joins the stage as an overlay: legend appears, panel stays I's.
        let legendV1 = app.descendants(matching: .any)
            .matching(identifier: "lead-legend-V1").firstMatch
        XCTAssertTrue(legendV1.waitForExistence(timeout: 3),
                      "Clicking an unstaged chip should overlay that lead")
        XCTAssertTrue(panelI.exists,
                      "Overlaying must not swap the panel — I is still primary")

        // Clicking the primary's chip removes it; V1 is promoted.
        let chipI = app.buttons.matching(identifier: "lead-chip-I").firstMatch
        chipI.click()
        let panelV1 = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-V1").firstMatch
        XCTAssertTrue(panelV1.waitForExistence(timeout: 3),
                      "Removing the primary should promote the next staged lead")
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(panelI, timeout: 2),
                      "The removed lead's panel should be gone")
    }

    @MainActor
    func testOverlayLabelsEveryLeadOnTheStage() throws {
        // Guards the "colour is never the sole discriminator" requirement. If
        // this passes only because the traces render, the analyst still has no
        // way to say which line is V1 — so what is asserted is the LABELS.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-overlay-leads=I,V1"]
        app.launch()

        let primaryLabel = app.descendants(matching: .any)
            .matching(identifier: "lead-edge-label-I").firstMatch
        XCTAssertTrue(primaryLabel.waitForExistence(timeout: 5),
                      "The primary lead should carry an edge label while leads are overlaid")

        let overlayLabel = app.descendants(matching: .any)
            .matching(identifier: "lead-edge-label-V1").firstMatch
        XCTAssertTrue(overlayLabel.waitForExistence(timeout: 3),
                      "The overlaid lead should carry an edge label in its own ink")

        // Assert the CONTENT, not just existence. An element that is present
        // but announces an empty string is worse than a missing one: it passes
        // an existence check and tells a VoiceOver user nothing. The ink name
        // is spoken because a swatch is silent.
        XCTAssertTrue(spokenName(overlayLabel).contains("olive"),
                      "Edge label should name the trace's ink, got '\(spokenName(overlayLabel))'")

        let legend = app.descendants(matching: .any)
            .matching(identifier: "lead-legend").firstMatch
        XCTAssertTrue(legend.waitForExistence(timeout: 3), "The stage should carry a legend")
        for lead in ["I", "V1"] {
            let row = app.descendants(matching: .any)
                .matching(identifier: "lead-legend-\(lead)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 2),
                          "Legend should have a row for lead \(lead)")
        }
    }

    @MainActor
    func testInspectorNamesTheLeadItsNumbersCameFrom() throws {
        // With two traces beside one column of intervals, a QT or a
        // calibration reading that doesn't say which lead it came from is a
        // number attached to nothing.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-overlay-leads=I,V1"]
        app.launch()

        let note = app.descendants(matching: .any)
            .matching(identifier: "primary-lead-note").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5),
                      "The docked inspector should name the lead it measures from")
        XCTAssertEqual(spokenName(note), "Measured on I",
                       "The note has to say WHICH lead; an element that exists but announces nothing is worse than a missing one")
    }

    @MainActor
    func testOverlaidLeadDoesNotGetItsOwnPanel() throws {
        // The overlay is one stage with N traces, not N stacked panels — that
        // is what strips mode is. If an overlaid lead ever grew its own
        // ChannelPanel it would bring a second voltage axis and a second set of
        // marks with it, which is the amplitude claim X64 exists to avoid.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-overlay-leads=I,V1"]
        app.launch()

        let panelI = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panelI.waitForExistence(timeout: 5),
                      "The primary lead owns the one panel on the stage")

        let panelV1 = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-V1").firstMatch
        XCTAssertFalse(panelV1.exists,
                       "An overlaid lead contributes a trace, not a panel of its own")
    }

    @MainActor
    func testClickingStagedChipsTogglesEachBackOut() throws {
        // The way out under X94: every staged lead's chip is one click from
        // removing it, down to (but never past) the last one. Toggle both
        // extras off a three-lead stage and the overlay chrome must unwind.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-overlay-leads=I,V1"]
        app.launch()

        let overlayLabel = app.descendants(matching: .any)
            .matching(identifier: "lead-edge-label-V1").firstMatch
        XCTAssertTrue(overlayLabel.waitForExistence(timeout: 5))

        // Clicking an UNstaged chip adds it — three leads on the stage.
        let chipII = app.buttons.matching(identifier: "lead-chip-II").firstMatch
        clickWhenHittable(chipII)
        let legendII = app.descendants(matching: .any)
            .matching(identifier: "lead-legend-II").firstMatch
        XCTAssertTrue(legendII.waitForExistence(timeout: 3),
                      "Clicking an unstaged chip should add its lead to the overlay")

        // Toggle both overlays back off.
        clickWhenHittable(chipII)
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(legendII, timeout: 3),
                      "Clicking a staged chip should remove its lead")
        let chipV1 = app.buttons.matching(identifier: "lead-chip-V1").firstMatch
        clickWhenHittable(chipV1)

        let legend = app.descendants(matching: .any)
            .matching(identifier: "lead-legend").firstMatch
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(legend, timeout: 3),
                      "With one lead on the stage there is nothing to legend")

        // The last staged lead refuses to toggle off — no zero-lead stage.
        let chipI = app.buttons.matching(identifier: "lead-chip-I").firstMatch
        clickWhenHittable(chipI)
        let panelI = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panelI.waitForExistence(timeout: 3),
                      "Clicking the last remaining lead must hold, not empty the stage")
    }

    @MainActor
    func testSingleLeadStageCarriesNoOverlayChrome() throws {
        // §5.3: with one lead selected the stage must look exactly as it did
        // before X64. This is the regression nobody re-checks, because it is
        // the case that already worked.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let panelI = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panelI.waitForExistence(timeout: 5))

        let legend = app.descendants(matching: .any)
            .matching(identifier: "lead-legend").firstMatch
        XCTAssertFalse(legend.exists, "The single-lead stage should carry no legend")

        let edgeLabel = app.descendants(matching: .any)
            .matching(identifier: "lead-edge-label-I").firstMatch
        XCTAssertFalse(edgeLabel.exists,
                       "The single-lead stage should carry no per-trace edge label")

        let note = app.descendants(matching: .any)
            .matching(identifier: "primary-lead-note").firstMatch
        XCTAssertFalse(note.exists,
                       "With one lead there is nothing to disambiguate; the note would be noise")
    }
}
