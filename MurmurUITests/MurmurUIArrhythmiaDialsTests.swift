//
//  MurmurUIArrhythmiaDialsTests.swift
//  MurmurUITests
//
//  X91 (#140) — the analyst's rate-band dials, end to end through REAL
//  detection: no injection flags anywhere. The rich fixture (X99) generates
//  a seeded ~72 bpm sinus record, so at the default 60–100 band the rate
//  detector finds nothing; raising the bradycardia threshold above the
//  fixture's mean rate MUST mint candidates from a real rescan, and a time
//  window longer than any run must take them away again. Same-seed
//  generation makes both transitions deterministic.
//
//  Also guards the X91 render-condition change: the group header (and the
//  dials it carries) stays mounted when a scan ran and found nothing —
//  otherwise tightening the dials would unmount the way back.
//

import XCTest

final class MurmurUIArrhythmiaDialsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func candidateCount(_ app: XCUIApplication) -> Int? {
        let leaf = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-count").firstMatch
        guard leaf.exists else { return nil }
        return Int(leaf.label)
    }

    /// Poll the count leaf until it reports `target` (rescans are async).
    @MainActor
    private func waitForCandidateCount(
        _ app: XCUIApplication, toReach target: (Int) -> Bool, timeout: TimeInterval = 20
    ) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Int?
        while Date() < deadline {
            last = candidateCount(app)
            if let last, target(last) { return last }
            usleep(300_000)
        }
        return last
    }

    /// Open the dials popover and wait until its content is queryable.
    @MainActor
    private func openDials(_ app: XCUIApplication) {
        let gear = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-scan-settings").firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "The dials button should sit on the header")
        gear.click()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 5),
                      "The dials popover should open on click")
    }

    @MainActor
    private func closeDials(_ app: XCUIApplication) {
        app.typeKey(.escape, modifierFlags: [])
        _ = MurmurUITests.waitForElementToDisappear(app.popovers.firstMatch, timeout: 3)
    }

    /// Type a value into a dial field: select-all + type + return commits
    /// the TextField binding, which re-keys the orchestrator's scan task.
    /// Verifies the commit by reading the field back — a popover field that
    /// silently missed focus would otherwise present as "rescan did nothing".
    @MainActor
    private func setDial(_ app: XCUIApplication, field identifier: String, to value: String) {
        let field = app.popovers.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "Dial field \(identifier) should be in the popover")
        field.click()
        usleep(200_000)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
        field.typeKey(.return, modifierFlags: [])
        usleep(200_000)
        XCTAssertEqual(field.value as? String, value,
                       "The typed value should commit into \(identifier)")
    }

    @MainActor
    func testDialsRescanRealDetection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample-rich", "--ui-test-grant-studio"]
        app.launch()

        // The group mounts because the scan RAN — the fixture's sinus rhythm
        // sits inside the default 60–100 band, so this is the zero-candidate
        // header the X91 render change exists for.
        let header = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-group-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30),
                      "The arrhythmia group should mount once the scan has run, even with 0 candidates")
        let baseline = try XCTUnwrap(
            waitForCandidateCount(app, toReach: { _ in true }),
            "The candidate-count leaf should exist alongside the header")

        // Let the launch computes land before driving the popover: the
        // delineation/metrics pipelines re-render the bedside view as they
        // publish, and a popover opened mid-churn can be torn down under the
        // test's cursor. The populated strip is the "startup settled" signal.
        let strip = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-strip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 30),
                      "The metrics strip populating marks the launch pipelines as settled")

        // Raise the bradycardia threshold above the fixture's ~72 bpm mean:
        // real runs must appear from a real rescan.
        openDials(app)
        setDial(app, field: "arrhythmia-dial-low", to: "80")
        closeDials(app)

        let raised = waitForCandidateCount(app, toReach: { $0 > baseline })
        XCTAssertNotNil(raised)
        XCTAssertGreaterThan(try XCTUnwrap(raised), baseline,
                             "lowBpm 80 over a ~72 bpm record must mint bradycardia candidates")

        // The caption echoes the dialed band (X58 discipline). The subtitle
        // folds into the header button's composed AX label, so read it there.
        let echo = NSPredicate(format: "label CONTAINS 'outside 80–100 bpm'")
        let echoExp = XCTNSPredicateExpectation(predicate: echo, object: header)
        XCTAssertEqual(XCTWaiter.wait(for: [echoExp], timeout: 5), .completed,
                       "The group caption should cite the analyst's band, not the default")

        // A time window longer than any run suppresses them all again — the
        // rate dials never touch pause/AFib candidates, so the count returns
        // exactly to baseline.
        openDials(app)
        setDial(app, field: "arrhythmia-dial-window", to: "175")
        closeDials(app)

        let suppressed = waitForCandidateCount(app, toReach: { $0 == baseline })
        XCTAssertEqual(suppressed, baseline,
                       "A 175 s window over a 180 s record must suppress every rate-band run")
    }
}
