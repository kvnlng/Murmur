//
//  MurmurUIQTAbstentionTests.swift
//  MurmurUITests
//
//  X109 (#185, cardiologist review §2.4) — principled QT abstention and
//  its sanctioned override, end to end on the no-conventional-lead
//  fixture (X105 machinery: lead II written as telemetry-style "MCL1", so
//  the record genuinely carries no II/V5):
//
//   1. The QTc lane renders the §2.4 null state — a plain status, not an
//      error — where the metric normally sits.
//   2. Manual QT calipers stay behind the Editing latch, then a two-click
//      Q-onset → T-offset placement mints an analyst-authored measurement
//      that lands in the review queue with explicit provenance.
//

import XCTest

final class MurmurUIQTAbstentionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAbstentionNullStateAndManualCaliperOverride() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample-rich=no-qt-leads", "--ui-test-grant-studio"]
        app.launch()

        let stagePanel = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(stagePanel.waitForExistence(timeout: 30),
                      "The renamed-lead fixture should open with lead I focused")

        // 1. The §2.4 null state, where the QTc metric normally sits. The
        // markings compute is async — the withheld status appears when the
        // orchestrator publishes.
        let withheld = app.descendants(matching: .any)
            .matching(identifier: "interval-trend-lane-qt-withheld").firstMatch
        XCTAssertTrue(withheld.waitForExistence(timeout: 30),
                      "A record with no conventional lead must state the QT withholding")
        let text = withheld.label.isEmpty
            ? ((withheld.value as? String) ?? "") : withheld.label
        XCTAssertTrue(text.contains("Conventional leads (II, V5) absent"),
                      "The null state must be the §2.4 status, got: \(text)")

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
        let qOnset = stagePanel.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        qOnset.hover()
        usleep(300_000)
        qOnset.rightClick()
        XCTAssertTrue(begin.waitForExistence(timeout: 3))
        begin.click()

        let tOffset = stagePanel.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
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
