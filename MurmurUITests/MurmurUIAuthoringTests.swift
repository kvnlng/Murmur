//
//  MurmurUIAuthoringTests.swift
//  MurmurUITests
//
//  Wire-up coverage for drag-to-author range findings on the interval trend
//  lane. The DragGesture itself isn't XCUI-drivable on macOS (same limitation
//  as pan/zoom), so `--ui-test-author-range` invokes the authoring handler
//  directly with a fixed range; this test asserts the finding was created and
//  persisted by reading the authored-count leaf — the plumbing (handler →
//  Annotation → BundleAnnotationsFile → derived rangeFindings) that snapshot
//  and unit tests can't reach end-to-end.
//

import XCTest

final class MurmurUIAuthoringTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDragToAuthorCreatesAndPersistsRangeFinding() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-author-range"]
        app.launch()

        let leaf = app.descendants(matching: .any)
            .matching(identifier: "ui-test-authored-count").firstMatch
        XCTAssertTrue(leaf.waitForExistence(timeout: 5))

        let one = NSPredicate(format: "label == %@", "1")
        let exp = XCTNSPredicateExpectation(predicate: one, object: leaf)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed,
                       "Authoring should create + persist exactly one range finding")
    }
}
