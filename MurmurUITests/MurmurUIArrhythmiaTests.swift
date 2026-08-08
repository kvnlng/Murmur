//
//  MurmurUIArrhythmiaTests.swift
//  MurmurUITests
//
//  XCUI wire-up coverage for the arrhythmia candidate review flow (A2).
//  The scan itself needs real detectors + a long fixture, so these tests
//  use the `--ui-test-arrhythmia-candidates` bypass: BedsideView publishes
//  a fixed candidate set into ArrhythmiaScanContext — the same state a
//  completed scan produces — so the queue group and the region-keyed
//  disposition wire-up are assertable without running the detectors
//  in-process. The detector correctness itself is benchmarked in
//  Murmur-Extensions (AFDB / MIT-BIH suites).
//
//  Sidecar isolation (arrhythmia vs VT/VF dispositions) is proven by
//  unit tests over the store; here we prove the panel actually ROUTES a
//  confirm/dismiss into the arrhythmia store and reflects it.
//

import XCTest

final class MurmurUIArrhythmiaTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Click an element once it is actually clickable — `waitForExistence`
    /// is not `waitForHittable` (see MurmurUIVTVFTests for the race this
    /// guards against).
    @MainActor
    private func clickWhenHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "\(what) should exist", file: file, line: line)
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: timeout), .completed,
                       "\(what) exists but never became clickable", file: file, line: line)
        element.click()
    }

    private func launchWithCandidates() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-arrhythmia-candidates"]
        app.launch()
        return app
    }

    /// Candidates render as one group in time order with the correct count.
    @MainActor
    func testArrhythmiaGroupRendersWithCount() throws {
        let app = launchWithCandidates()

        let header = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-group-header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5),
                      "Arrhythmia candidate group should render in the review queue")

        let count = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-count").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        XCTAssertEqual(count.label, "3", "Three synthetic candidates were injected")

        // Injection order is brady → pause → AFib by start time; row 0 must
        // be the earliest (time order, not a score ranking).
        let row0 = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-row-0").firstMatch
        XCTAssertTrue(row0.waitForExistence(timeout: 3))
        XCTAssertTrue(row0.label.contains("Bradycardia candidate"),
                      "Row 0 should be the earliest candidate (got: \(row0.label))")
    }

    /// Confirming routes into the arrhythmia region store and the row
    /// reflects the confirmed state.
    @MainActor
    func testConfirmCandidateUpdatesState() throws {
        let app = launchWithCandidates()

        let row0 = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-row-0").firstMatch
        XCTAssertTrue(row0.waitForExistence(timeout: 5))

        clickWhenHittable(
            app.descendants(matching: .any).matching(identifier: "edit-mode-toggle").firstMatch,
            "Edit-mode toggle"
        )
        clickWhenHittable(
            app.descendants(matching: .any).matching(identifier: "arrhythmia-candidate-confirm-0").firstMatch,
            "Candidate confirm control"
        )

        let state0 = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-state-0").firstMatch
        let confirmed = NSPredicate(format: "label == %@", "confirmed")
        let exp = XCTNSPredicateExpectation(predicate: confirmed, object: state0)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed,
                       "Confirm should route into the region store and render as confirmed")
    }

    /// Dismissing updates the state leaf the same way.
    @MainActor
    func testDismissCandidateUpdatesState() throws {
        let app = launchWithCandidates()

        let row1 = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-row-1").firstMatch
        XCTAssertTrue(row1.waitForExistence(timeout: 5))

        clickWhenHittable(
            app.descendants(matching: .any).matching(identifier: "edit-mode-toggle").firstMatch,
            "Edit-mode toggle"
        )
        clickWhenHittable(
            app.descendants(matching: .any).matching(identifier: "arrhythmia-candidate-dismiss-1").firstMatch,
            "Candidate dismiss control"
        )

        let state1 = app.descendants(matching: .any)
            .matching(identifier: "arrhythmia-candidate-state-1").firstMatch
        let dismissed = NSPredicate(format: "label == %@", "dismissed")
        let exp = XCTNSPredicateExpectation(predicate: dismissed, object: state1)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed,
                       "Dismiss should route into the region store and render as dismissed")
    }
}
