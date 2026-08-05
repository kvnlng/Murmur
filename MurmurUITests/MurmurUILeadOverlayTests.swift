//
//  MurmurUILeadOverlayTests.swift
//  MurmurUITests
//
//  X64 — the focus stage overlaying several leads on one time axis and one
//  amplitude axis.
//
//  What these tests can and cannot reach: the overlay is BUILT by ⌘-clicking a
//  lead chip, and XCUI on macOS has no modifier-click. So the selection is
//  seeded with `--ui-test-overlay-leads=…` — the same `LeadSelection` the chip
//  bar constructs — and what is verified here is everything downstream of it:
//  that the extra traces reach the stage, that each is identified by something
//  other than its colour, and that plain-clicking a chip gets back out.
//  `LeadSelectionTests` covers the ⌘-click semantics themselves.
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
    func testPlainClickingAChipLeavesTheOverlay() throws {
        // The way out. Spec §5.1: collapsing back to a single lead has to be
        // one obvious click away from any state the stage is in.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-overlay-leads=I,V1"]
        app.launch()

        let overlayLabel = app.descendants(matching: .any)
            .matching(identifier: "lead-edge-label-V1").firstMatch
        XCTAssertTrue(overlayLabel.waitForExistence(timeout: 5))

        let chipII = app.buttons.matching(identifier: "lead-chip-II").firstMatch
        clickWhenHittable(chipII)

        let panelII = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-II").firstMatch
        XCTAssertTrue(panelII.waitForExistence(timeout: 3),
                      "A plain chip click should focus that lead alone")

        let legend = app.descendants(matching: .any)
            .matching(identifier: "lead-legend").firstMatch
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(legend, timeout: 3),
                      "With one lead on the stage there is nothing to legend")
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
