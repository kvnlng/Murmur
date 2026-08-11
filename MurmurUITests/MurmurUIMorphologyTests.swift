//
//  MurmurUIMorphologyTests.swift
//  MurmurUITests
//
//  X112 (#188, §2.2 option c) — the Morphology drawer section end to end on
//  the rich fixture: the clusters render as unlabelled cards, endorsement
//  stays behind the Editing latch, and endorsing flips the row's state —
//  "the algorithm clusters, the human classifies", wired for real.
//

import XCTest

final class MurmurUIMorphologyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The context bar and drawer sit past the fold on short displays —
    /// scroll into view (shared helper) before clicking.
    @MainActor
    private func scrollIntoViewAndClick(
        _ element: XCUIElement,
        within app: XCUIApplication,
        timeout: TimeInterval = 5,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "\(what) should exist", file: file, line: line)
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(element, in: app),
                      "\(what) never became hittable, even after scrolling",
                      file: file, line: line)
        element.click()
    }

    @MainActor
    func testMorphologySectionEndorsementFlow() throws {
        let app = XCUIApplication()
        // A large window from the start: the rich fixture mounts every lane,
        // and the context bar must stay on-screen rather than past a fold
        // that keeps moving while async lanes arrive.
        app.launchArguments += ["--ui-test-sample-rich", "--ui-test-grant-studio",
                                "--ui-test-window=1600x1100"]
        app.launch()

        // Wait for the collapsed bar to ANNOUNCE the clusters before touching
        // anything: that both proves the orchestrator finished and lets the
        // rich fixture's async lanes (delineation, LF/HF, X89) finish
        // growing the scroll layout — scrolling earlier chases a moving fold.
        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 30),
                      "The scrolling context should carry a Context bar")
        let announced = NSPredicate(format: "label CONTAINS %@", "morphology cluster")
        let announcement = XCTNSPredicateExpectation(predicate: announced, object: contextBar)
        XCTAssertEqual(XCTWaiter.wait(for: [announcement], timeout: 90), .completed,
                       "The collapsed bar should count the clusters once the orchestrator publishes")
        // Drive to a KNOWN state, never blind-toggle (the notes-drawer
        // lesson): only click if the panel isn't already open.
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        if !panel.exists {
            scrollIntoViewAndClick(contextBar, within: app, timeout: 30, "Context disclosure bar")
        }
        XCTAssertTrue(panel.waitForExistence(timeout: 5),
                      "The drawer should be open after the disclosure click")
        let row = app.descendants(matching: .any)
            .matching(identifier: "note-row-morphology").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "The Morphology row should list once clustering completes")
        scrollIntoViewAndClick(row, within: app, "Morphology row")

        let card = app.descendants(matching: .any)
            .matching(identifier: "morphology-cluster-row-0").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5),
                      "The majority cluster should render as card 0")

        let state = app.descendants(matching: .any)
            .matching(identifier: "morphology-cluster-state-0").firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.label, "not endorsed",
                       "Nothing auto-promotes — a fresh record has no endorsed baseline")

        // The latch: endorsement is authoring, locked until Editing.
        let endorse = app.descendants(matching: .any)
            .matching(identifier: "morphology-endorse-0").firstMatch
        XCTAssertTrue(endorse.waitForExistence(timeout: 3))
        XCTAssertFalse(endorse.isEnabled,
                       "Endorsement must stay behind the Editing latch")

        scrollIntoViewAndClick(
            app.descendants(matching: .any).matching(identifier: "edit-mode-toggle").firstMatch,
            within: app, "Edit-mode toggle")
        scrollIntoViewAndClick(endorse, within: app, "Endorse control")

        let endorsed = NSPredicate(format: "label == %@", "endorsed")
        let exp = XCTNSPredicateExpectation(predicate: endorsed, object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed,
                       "Endorsing should flip the cluster's state leaf")

        let withdraw = app.descendants(matching: .any)
            .matching(identifier: "morphology-withdraw-0").firstMatch
        XCTAssertTrue(withdraw.waitForExistence(timeout: 3),
                      "An endorsed card should offer withdrawal, not a second endorsement")
    }
}
