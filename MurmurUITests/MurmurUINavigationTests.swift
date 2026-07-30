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
    /// that runs at panel mount. Focus mode is the default so only the
    /// first ECG channel ("I" in the synthetic fixture) is in the view
    /// tree — that's the panel we look up by accessibility id.
    @MainActor
    func testChannelRangeBadgeAppearsForSyntheticFixture() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let badge = app.descendants(matching: .any)
            .matching(identifier: "channel-range-I").firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 8),
                      "Lead I (focused by default) should have a min/max badge once the scan completes")
    }

    /// The "Fit amplitude to window" button appears alongside the
    /// channel-range badge once the scan completes (X40 replaced the live
    /// Auto-Y toggle with this one-shot fit). Guards: scanner result reaches
    /// the panel header, the button carries a findable accessibility id.
    @MainActor
    func testFitAmplitudeButtonAppearsForSyntheticFixture() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let fit = app.descendants(matching: .any)
            .matching(identifier: "fit-amplitude-I").firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 8),
                      "Lead I (focused by default) should expose a Fit-amplitude button once the scan completes")
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

    // MARK: - Persistent-stage layout (Phase 0 of the viewer redesign)

    /// The trace + docked inspector + overview map all render inside a
    /// single accessible `pinned-stage` container in focus mode. Guards
    /// the layout skeleton the later redesign phases mount into: if any
    /// of these four identifiers stops resolving under `pinned-stage`,
    /// the persistent-stage promise is broken. Focus mode is the
    /// default; the `--ui-test-sample` fixture carries no fiducial
    /// store, so `docked-beat-inspector-empty` is the correct assertion
    /// (the populated variant lights up once a per-patient template
    /// exists — Phase 3).
    @MainActor
    func testPersistentStageHousesTraceInspectorAndOverview() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let stage = app.descendants(matching: .any).matching(identifier: "pinned-stage").firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 5),
                      "pinned-stage container should host the focus-mode layout")

        let panel = app.descendants(matching: .any).matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3),
                      "Trace panel should render inside the pinned stage")

        let inspector = app.descendants(matching: .any)
            .matching(identifier: "docked-beat-inspector-empty").firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 3),
                      "Docked inspector empty state should sit beside the trace with no beat focused")

        let overview = app.descendants(matching: .any).matching(identifier: "overview-map").firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 3),
                      "Merged overview map should render inside the pinned stage")
    }

    // MARK: - Review queue Phase 1 free-tier defaults

    /// Free-tier default sort is `.structural` — non-normal categories
    /// surfaced above the collapsed normal mass by frequency. The
    /// synthetic fixture does not own ECG Metrics and carries no
    /// fiducial template, so the LockedView seam ("Rank by departure
    /// from this patient's normal — ECG Metrics") should also be
    /// visible. Guards the ratified measurement-layer gating rule.
    ///
    /// The seam element is the load-bearing assertion. When
    /// `PurchaseStore.owns(.ecgMetrics) && markingsContext.template
    /// != nil` becomes true the seam disappears — its very existence
    /// is a signal that the measurement layer is gated. We deliberately
    /// don't assert the sort picker's visible label because macOS
    /// surfaces Menu-in-inspector labels inconsistently to the XCUI
    /// accessibility tree.
    @MainActor
    func testFreeTierDepartureUnlockSeamIsVisible() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        // Sort picker existence proves the review queue rendered; the
        // seam existence proves the paid gate is on and honestly signalled.
        let sortPicker = app.descendants(matching: .any)
            .matching(identifier: "findings-sort-picker").firstMatch
        XCTAssertTrue(sortPicker.waitForExistence(timeout: 5),
                      "Findings sort picker should render on the review queue")

        let seam = app.descendants(matching: .any)
            .matching(identifier: "departure-sort-unlock-seam").firstMatch
        XCTAssertTrue(seam.waitForExistence(timeout: 3),
                      "Departure-sort unlock seam should be visible without ECG Metrics")
    }

    @MainActor
    func testDispositionControlsExposeAccessibilityLabels() throws {
        // AX2: the confirm/dismiss disposition controls are image-only, so
        // without explicit labels VoiceOver reads the SF Symbol descriptions
        // ("Selected" / "Close") on every finding row. Assert the explicit
        // labels are present, and that the findings confidence picker carries
        // its sibling-style identifier rather than the chevron symbol name.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-expand-all-findings-groups"
        ]
        app.launch()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        let confirms = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'disposition-confirm-'"))
        let appeared = NSPredicate(format: "count > 0")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: appeared, object: confirms)], timeout: 3),
                       .completed, "Disposition confirm controls should appear in edit mode")
        XCTAssertEqual(confirms.firstMatch.label, "Confirm finding",
                       "Confirm control should expose an explicit accessibility label, not the SF Symbol name")

        let dismiss = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'disposition-dismiss-'")).firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
        XCTAssertEqual(dismiss.label, "Dismiss finding",
                       "Dismiss control should expose an explicit accessibility label, not the SF Symbol name")

        let confidencePicker = app.descendants(matching: .any)
            .matching(identifier: "findings-confidence-picker").firstMatch
        XCTAssertTrue(confidencePicker.waitForExistence(timeout: 3),
                      "Findings confidence picker should carry an explicit sibling-style identifier, not 'chevron.down'")
    }

    @MainActor
    func testViewportPositionElementIsExposedForVoiceOver() throws {
        // AX4: a VoiceOver user must be able to learn where they are in the
        // recording. Assert the human-readable viewport-position element
        // exists and speaks a clock-time window ("Viewing m:ss to m:ss…").
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
        app.launch()

        let position = app.descendants(matching: .any)
            .matching(identifier: "viewport-position").firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 5),
                      "A human-readable viewport-position element should exist for VoiceOver")
        XCTAssertTrue(position.label.hasPrefix("Viewing "),
                      "Viewport position should speak a clock-time window, got '\(position.label)'")
    }
}
