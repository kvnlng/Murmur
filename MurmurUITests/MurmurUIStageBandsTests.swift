//
//  MurmurUIStageBandsTests.swift
//  MurmurUITests
//
//  X70 — the stage's zoom ladder and band ladder.
//
//  What XCUI can and cannot reach here, stated up front: the bands are drawn
//  content. The hour band is a `Path`, the record band is `OverviewMap`'s
//  strip, and the trace is a Metal canvas — none of them expose what they have
//  PAINTED to the accessibility tree. So these tests assert the things that
//  are genuinely observable: that the controls exist, that clicking a rung
//  moves the viewport to the right width, and that the pin releases. The
//  shared time mapping is verified against pixels instead, on a real record.
//

import XCTest

final class MurmurUIStageBandsTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func viewportWidth(_ app: XCUIApplication) -> Int64? {
        let state = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        guard state.exists else { return nil }
        // "start=<n> end=<n>"
        let parts = state.label.split(separator: " ")
        guard parts.count == 2,
              let s = Int64(parts[0].replacingOccurrences(of: "start=", with: "")),
              let e = Int64(parts[1].replacingOccurrences(of: "end=", with: "")) else { return nil }
        return e - s
    }

    @MainActor
    func testZoomLadderSetsTheWindowWidth() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let state = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10))

        // The synthetic fixture is short, so the ladder offers its finest
        // rungs. 2 s must be reachable on any record — a ladder that drops its
        // finest rung makes the shortest recordings the hardest to inspect.
        let twoSeconds = app.buttons.matching(identifier: "zoom-ladder-2s").firstMatch
        XCTAssertTrue(twoSeconds.waitForExistence(timeout: 5),
                      "The ladder should offer a 2 s rung")

        // Captured BEFORE the click. Reading `state.label` after it would
        // compare the changed value against itself, and the predicate could
        // never become true.
        let before = viewportWidth(app)
        let beforeLabel = state.label
        twoSeconds.click()

        let changed = NSPredicate(format: "label != %@", beforeLabel)
        let moved = XCTNSPredicateExpectation(predicate: changed, object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed,
                       "Clicking a ladder rung should change the viewport")

        let after = viewportWidth(app)
        XCTAssertNotEqual(before, after, "The window width should have changed")
        // The fixture runs at a known rate; 2 s of it is a small window, and
        // what matters is that the rung landed near its own width rather than
        // somewhere arbitrary.
        if let after {
            XCTAssertLessThan(after, 2000,
                              "A 2 s rung should produce a small window, got \(after) samples")
        }
    }

    /// DECISIONS §5: a ladder click IS a manual zoom, so it releases the hold.
    /// Honouring the pin instead would make the ladder silently do nothing,
    /// which is the worst of the available behaviours.
    @MainActor
    func testZoomLadderReleasesTheWindowHold() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let hold = app.descendants(matching: .any)
            .matching(identifier: "window-lock-toggle").firstMatch
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        hold.click()

        let state = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        let heldLabel = state.label

        let twoSeconds = app.buttons.matching(identifier: "zoom-ladder-2s").firstMatch
        XCTAssertTrue(twoSeconds.waitForExistence(timeout: 3))
        twoSeconds.click()

        // If the pin had won, the width would still be the held one.
        let changed = NSPredicate(format: "label != %@", heldLabel)
        let moved = XCTNSPredicateExpectation(predicate: changed, object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed,
                       "A ladder click must win over the window hold, not be swallowed by it")
    }

    /// The hour band renders only when the record is longer than an hour.
    /// Below that the record band already IS the hour, and two bands showing
    /// the same span with different boxes is a puzzle rather than a ladder.
    @MainActor
    func testShortRecordGetsNoHourBand() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let stage = app.descendants(matching: .any)
            .matching(identifier: "pinned-stage").firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 10))

        let hourBand = app.descendants(matching: .any)
            .matching(identifier: "hour-band").firstMatch
        XCTAssertFalse(hourBand.exists,
                       "A record shorter than an hour should carry no hour band")
    }
}
