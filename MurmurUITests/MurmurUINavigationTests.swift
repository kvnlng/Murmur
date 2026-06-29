//
//  MurmurUINavigationTests.swift
//  MurmurUITests
//
//  XCUI coverage for keyboard-driven viewport navigation (arrow keys,
//  +/-, J/K) and the DEBUG-only Producers sheet that exposes the
//  registered FindingProducer instances. These tests live in their
//  own file to keep MurmurUITests.swift under SwiftLint's
//  file_length cap.
//
//  The keyboard tests rely on `BedsideView.focusable()` taking key
//  focus once the bedside view is clicked. The synthetic-fixture
//  launch arg pre-seeds a recording so the viewport-state label
//  exists before any key event is sent.
//

import XCTest

final class MurmurUINavigationTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Keyboard navigation

    /// Right-arrow → `panByOneViewport(.right)` → `viewport.setStart`.
    /// Asserts the hidden viewport-state label changes within the
    /// SwiftUI re-render window.
    @MainActor
    func testKeyboardRightArrowPansViewport() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        let initial = viewportState.label

        // Bedside view must own keyboard focus before `.onKeyPress` fires.
        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 3))
        bedside.click()

        app.typeKey(.rightArrow, modifierFlags: [])

        let changed = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: changed, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Right arrow should pan the viewport (was '\(initial)')")
    }

    /// `=` is the unshifted form of `+` on US keyboards; we bind both so
    /// the analyst doesn't have to hold shift to zoom in.
    @MainActor
    func testKeyboardEqualsKeyZoomsIn() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        let initial = viewportState.label

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 3))
        bedside.click()

        app.typeKey("=", modifierFlags: [])

        let changed = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: changed, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "'=' should zoom in and change the viewport (was '\(initial)')")
    }

    /// J → `jumpToNextFinding` → `viewport.animateJump`. The synthetic
    /// fixture carries findings; a fresh J press from sample 0 should
    /// land on the earliest one.
    @MainActor
    func testKeyboardJJumpsToNextFinding() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        let initial = viewportState.label

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 3))
        bedside.click()

        app.typeKey("j", modifierFlags: [])

        let changed = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: changed, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "J should jump to next finding (was '\(initial)')")
    }

    // MARK: - Producers panel (DEBUG)

    /// The Producers toolbar button is gated on `#if DEBUG`. The DEBUG
    /// path of `bootstrapBaselineProducers` registers the synthetic
    /// producer before BedsideView appears, so the button must be
    /// present once a recording is loaded.
    @MainActor
    func testProducersToolbarButtonExistsInDebug() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let button = app.buttons.matching(identifier: "producers-toggle").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "DEBUG builds should expose a 'producers-toggle' toolbar button")
    }

    /// Click the Producers button → modal sheet → synthetic producer
    /// row. Validates the bootstrap → registry → ProducersPanel chain
    /// end-to-end.
    @MainActor
    func testProducersSheetListsRegisteredSynthetic() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let button = app.buttons.matching(identifier: "producers-toggle").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()

        let row = app.descendants(matching: .any)
            .matching(identifier: "producer-row-murmur.synthetic").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3),
                      "Sheet should list a row for murmur.synthetic")
    }

    // MARK: - Toolbar additions

    /// The findings inspector picker for sort mode. Guards: the
    /// FindingSort enum + the `findings-sort-picker` accessibility id
    /// stay reachable through the inspector chrome.
    @MainActor
    func testFindingsSortPickerExists() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        // Inspector is open by default; if it isn't, the toolbar
        // button toggles it.
        let picker = app.descendants(matching: .any)
            .matching(identifier: "findings-sort-picker").firstMatch
        if !picker.waitForExistence(timeout: 3) {
            let toggle = app.buttons.matching(identifier: "findings-toggle").firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.click()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "FindingsPanel header should expose a 'findings-sort-picker'")
    }

    /// Toolbar button that opens the NSSavePanel for the markdown
    /// report. Guards: the toolbar item identifier
    /// `export-report` and its button-ness so other XCUI flows can
    /// later open a save panel against this button.
    @MainActor
    func testExportReportToolbarButtonExists() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let button = app.buttons.matching(identifier: "export-report").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "Toolbar should expose an 'export-report' button")
    }

    /// Channel-range badge. Populated by the background min/max scan
    /// that runs at panel mount. Synthetic fixture uses lead "II", so
    /// the identifier resolves deterministically.
    @MainActor
    func testChannelRangeBadgeAppearsForSyntheticFixture() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let badge = app.descendants(matching: .any)
            .matching(identifier: "channel-range-II").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 8),
                      "Lead II should have a min/max badge once the scan completes")
    }

    /// Auto-Y toggle appears alongside the channel-range badge once the
    /// scan completes. Guards: scanner result reaches the panel header,
    /// Toggle is given an accessibility identifier the test can find.
    @MainActor
    func testAutoscaleYToggleAppearsForSyntheticFixture() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let toggle = app.descendants(matching: .any)
            .matching(identifier: "autoscale-y-II").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8),
                      "Lead II should expose an autoscale-Y toggle once the scan completes")
    }

    /// Toolbar button that opens the PNG-snapshot save panel. Guards
    /// the `export-snapshot` accessibility id stays reachable so other
    /// XCUI flows can later drive a snapshot save through this button.
    @MainActor
    func testExportSnapshotToolbarButtonExists() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let button = app.buttons.matching(identifier: "export-snapshot").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "Toolbar should expose an 'export-snapshot' button")
    }
}
