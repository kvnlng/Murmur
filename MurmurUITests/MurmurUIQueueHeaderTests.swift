//
//  MurmurUIQueueHeaderTests.swift
//  MurmurUITests
//
//  X75 — the review queue's header and grouping.
//
//  Separate from `MurmurUIReviewQueueTests`, which is X48's guard on the
//  collapsed-normals row's provenance claim. Two files because they guard
//  unrelated promises about the same panel, and because one file per concern
//  keeps either from being lost when the other is rewritten.
//
//  The disposition segments are the interesting part: they are both the tally
//  and the filter, so an assertion that only checks they RENDER would pass
//  against a control that displays counts and does nothing. What is asserted
//  here is that selecting one changes the list.
//

import XCTest

final class MurmurUIQueueHeaderTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    @MainActor
    func testHeaderCarriesTheDispositionSegments() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "disposition-filter").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10),
                      "The queue header should carry the disposition segments")

        for bucket in ["toReview", "confirmed", "dismissed"] {
            let chip = app.descendants(matching: .any)
                .matching(identifier: "disposition-filter-\(bucket)").firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 3),
                          "Missing the \(bucket) segment")
        }

        // The segments replaced the passive tally, so they have to carry the
        // counts it used to show — otherwise the header lost information
        // rather than gaining a control.
        let toReview = app.descendants(matching: .any)
            .matching(identifier: "disposition-filter-toReview").firstMatch
        let spoken = spokenName(toReview)
        XCTAssertTrue(spoken.contains("To review"),
                      "The segment should name its bucket, got '\(spoken)'")
        XCTAssertTrue(spoken.rangeOfCharacter(from: .decimalDigits) != nil,
                      "The segment should carry its count, got '\(spoken)'")
    }

    /// Selecting a segment must actually narrow the queue. The synthetic
    /// fixture has findings and no dispositions, so everything is unreviewed:
    /// switching to Confirmed should empty the flagged list.
    @MainActor
    func testSelectingASegmentFiltersTheQueue() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let toReview = app.descendants(matching: .any)
            .matching(identifier: "disposition-filter-toReview").firstMatch
        XCTAssertTrue(toReview.waitForExistence(timeout: 10))

        // Default is "To review" — the work that remains, which is what a
        // queue is for.
        XCTAssertTrue(spokenName(toReview).contains("selected"),
                      "The queue should open on the work that remains")

        let queueCount = app.descendants(matching: .any)
            .matching(identifier: "findings-panel").firstMatch
        _ = queueCount.waitForExistence(timeout: 3)

        let confirmed = app.descendants(matching: .any)
            .matching(identifier: "disposition-filter-confirmed").firstMatch
        XCTAssertTrue(confirmed.waitForExistence(timeout: 3))
        confirmed.click()

        let nowSelected = NSPredicate(format: "label CONTAINS[c] 'selected'")
        let exp = XCTNSPredicateExpectation(predicate: nowSelected, object: confirmed)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Clicking a segment should select it")

        // Nothing is confirmed on a fresh fixture, so the flagged groups go.
        // The collapsed-normals row is expected to SURVIVE: normals are never
        // a review task, and hiding them would make that row's count
        // contradict the queue around it.
        let vtGroup = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'finding-group-'")).firstMatch
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(vtGroup, timeout: 3),
                      "With nothing confirmed, the flagged groups should clear")
    }

    /// The filter menu shows an active state, otherwise a narrowed queue is
    /// indistinguishable from a quiet recording.
    @MainActor
    func testFilterMenuReportsWhetherItIsActive() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let menu = app.descendants(matching: .any)
            .matching(identifier: "findings-filter-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertEqual(spokenName(menu), "Filters",
                       "With no filters set the menu should not claim to be active")
    }
}
