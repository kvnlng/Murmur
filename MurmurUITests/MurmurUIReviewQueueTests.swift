//
//  MurmurUIReviewQueueTests.swift
//  MurmurUITests
//
//  X48 wire-up guard: the collapsed-normals row must state the ACTUAL source of
//  its grouping (the annotator's normal-beat code) rather than claiming an
//  app-computed "patient's template" it never built — the template's beat
//  membership is exactly that same annotator code (Recording.normalBeatSample-
//  Indices). Seeds normal beats into the synthetic fixture so the row renders,
//  then asserts its spoken label attributes the source and drops the app-voice
//  authorship claim. Complements the X51 accessibility sweep, which only
//  checked that the row carries SOME name.
//

import XCTest

final class MurmurUIReviewQueueTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCollapsedNormalsRowStatesItsSourceNotAppVoice() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-seed-beat-annotations=40"]
        app.launch()

        let row = app.descendants(matching: .any)
            .matching(identifier: "collapsed-normals-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "Seeded normal beats should produce a collapsed-normals row")

        let label = row.label
        XCTAssertTrue(label.contains("coded normal"),
                      "The row must attribute the grouping to whoever coded the beats normal — got \"\(label)\"")
        // The defect X48 fixes: the app claimed authorship of a grouping it did
        // not compute. That claim must be gone.
        XCTAssertFalse(label.contains("patient's template"),
                       "The row must not speak in the app's voice about a template it never built — got \"\(label)\"")
    }
}
