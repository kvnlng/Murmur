//
//  MurmurUIRUONoticeTests.swift
//  MurmurUITests
//
//  X4b: XCUI wire-up for the first-run RUO disclosure. The launch gate's
//  truth table is unit-tested (RUOFirstRunNoticeTests); here we prove the
//  sheet actually presents under the force flag, that acknowledging
//  dismisses it, and that an ordinary test launch never sees it — the
//  suppression every other test in this suite depends on.
//

import XCTest

final class MurmurUIRUONoticeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Forced launch presents the notice; acknowledging dismisses it and
    /// the app is usable behind it.
    @MainActor
    func testNoticePresentsAndAcknowledges() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-first-run-ruo"]
        app.launch()

        let notice = app.descendants(matching: .any)
            .matching(identifier: "ruo-first-run-notice").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5),
                      "The forced first-run RUO notice should present at launch")

        let acknowledge = app.descendants(matching: .any)
            .matching(identifier: "ruo-first-run-acknowledge").firstMatch
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 3))
        acknowledge.click()

        let gone = NSPredicate(format: "exists == false")
        let exp = XCTNSPredicateExpectation(predicate: gone, object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed,
                       "Acknowledging should dismiss the notice")

        // The app behind the sheet is intact — the bedside still mounted.
        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5),
                      "The recording should be usable after acknowledging")
    }

    /// Ordinary UI-test launches never see the notice — the suppression the
    /// rest of this suite depends on.
    @MainActor
    func testOrdinaryTestLaunchIsSuppressed() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5))

        let notice = app.descendants(matching: .any)
            .matching(identifier: "ruo-first-run-notice").firstMatch
        XCTAssertFalse(notice.exists,
                       "UI-test launches must suppress the first-run notice")
    }
}
