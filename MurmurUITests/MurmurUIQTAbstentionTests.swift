//
//  MurmurUIQTAbstentionTests.swift
//  MurmurUITests
//
//  X109 (#185, cardiologist review §2.4) + #357 §1.5 — what a record with
//  no conventionally-named lead does now, end to end on the same fixture
//  (X105 machinery: lead II written as telemetry-style "MCL1", so the
//  record genuinely carries no II/V5):
//
//   1. QT is MEASURED — on the analysis lead — and the QTc lane's repro
//      caption discloses that the lead is not a conventional QT lead. The
//      X109 record-wide abstention this test used to assert is retired
//      with the name gate that was its only trigger (#357 §1.5): a lead is
//      never skipped for being called the wrong thing.
//   2. Manual QT calipers stay behind the Editing latch, then a two-click
//      Q-onset → T-offset placement mints an analyst-authored measurement
//      that lands in the review queue with explicit provenance — §2.4's
//      sanctioned override, unchanged.
//

import XCTest

final class MurmurUIQTAbstentionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNonConventionalLeadDisclosureAndManualCaliperOverride() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample-rich=no-qt-leads", "--ui-test-grant-studio"]
        app.launch()

        let stagePanel = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(stagePanel.waitForExistence(timeout: 30),
                      "The renamed-lead fixture should open with lead I focused")

        // 1. The QTc lane's repro caption — the citation the analyst copies —
        // names the lead the intervals were measured on and discloses that it
        // isn't a conventional QT lead. The markings compute is async, so the
        // caption's lead fragment appears when the orchestrator publishes.
        let caption = app.descendants(matching: .any)
            .matching(identifier: "interval-trend-lane-repro-caption").firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 30),
                      "The QTc lane must publish its repro caption")
        let text = caption.label.isEmpty
            ? ((caption.value as? String) ?? "") : caption.label
        XCTAssertTrue(text.contains("not a conventional QT lead (II/V5)"),
                      "No lead on this record reads as II/V5 — the caption must "
                      + "disclose the lead it measured, got: \(text)")
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "interval-trend-lane-qt-withheld").firstMatch.exists,
            "#357 §1.5: QT is measured on the analysis lead, never withheld for a name")

        // 2a. The caliper items honour the Editing latch, same as every
        // authoring surface.
        stagePanel.rightClick()
        let begin = app.menuItems["bedside-context-qt-caliper-begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 3),
                      "Right-click should offer QT caliper placement")
        XCTAssertFalse(begin.isEnabled,
                       "Caliper placement must stay behind the Editing latch")
        app.typeKey(.escape, modifierFlags: [])

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        // 2b. Two-click placement at two distinct trace positions. The
        // menu's sample comes from the panel's continuous-hover state, so
        // hover each point first — a bare right-click can carry the STALE
        // hover position, collapsing the span to zero.
        let qOnset = stagePanel.coordinate(
            withNormalizedOffset: CGVector(dx: 0.35, dy: TraceCoordinates.hoverableY))
        qOnset.hover()
        usleep(300_000)
        qOnset.rightClick()
        XCTAssertTrue(begin.waitForExistence(timeout: 3))
        begin.click()

        let tOffset = stagePanel.coordinate(
            withNormalizedOffset: CGVector(dx: 0.6, dy: TraceCoordinates.hoverableY))
        tOffset.hover()
        usleep(300_000)
        tOffset.rightClick()
        let complete = app.menuItems["bedside-context-qt-caliper-complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 3),
                      "With a Q onset pending, the menu should offer completion")
        complete.click()

        // The analyst-authored measurement lands in the review queue under
        // its own provenance-labelled group. Group headers COMPOSE their
        // child texts into one AX label (the X65 lesson), so match by
        // containment, not as a standalone static text.
        let group = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Manual QT calipers'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10),
                      "The completed caliper should mint a review-queue group with analyst provenance")
    }
}
