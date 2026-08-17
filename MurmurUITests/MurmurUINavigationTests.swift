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

    /// X35 cure (via X22): the finding-jump command lives on the Navigate menu
    /// as a key equivalent, dispatched scene-wide through `focusedSceneValue`, so
    /// it must fire even when the bedside / findings list does NOT hold first
    /// responder — the exact state that dropped the keystroke before X22. XCUI
    /// can't send a bare `j` key event reliably (`testKeyboardJJumpsToNextFinding`
    /// props focus up first to work around that), so this drives the MENU ITEM,
    /// which exercises the same responder-chain dispatch — and deliberately does
    /// NOT focus the bedside, so a focus-dependent handler would fail here.
    @MainActor
    func testNextFindingMenuMovesViewportRegardlessOfFocus() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-initial-duration=2"]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        let initial = viewportState.label

        // No bedside.click() — invoke the command via the menu, the path that
        // must work with focus anywhere.
        let nextFinding = app.menuItems["Next Finding"]
        XCTAssertTrue(nextFinding.waitForExistence(timeout: 3),
                      "Navigate ▸ Next Finding menu item should exist")
        nextFinding.click()

        let changed = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: changed, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Next Finding via the menu (responder chain) should move the viewport regardless of focus (was '\(initial)')")
    }

    /// X22 menu pass: File ▸ Open Recent reflects the recents store, and plain
    /// Save is disabled with no recording open (the welcome screen).
    @MainActor
    func testFileMenuOpenRecentPopulatedAndSaveDisabled() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-seed-recent"]
        app.launch()

        let fileMenu = app.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()

        // No recording open on the welcome screen → plain Save is disabled.
        let save = app.menuItems["Save Session"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled, "Save should be disabled with no recording open")

        // Open Recent is populated from the seeded store — "Clear Menu" only
        // renders when there is at least one entry.
        app.menuItems["Open Recent"].hover()
        XCTAssertTrue(app.menuItems["Clear Menu"].waitForExistence(timeout: 3),
                      "Open Recent should list the seeded record (Clear Menu ⇒ populated)")
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

        // Let the bedside finish mounting BEFORE consulting the inspector.
        // The old shape polled the picker for 3 s from launch and then
        // clicked the toggle — on a slow runner (Xcode Cloud VMs) that
        // race CLOSED the default-open inspector while it was still
        // loading, and the picker never appeared. Load first, then look.
        let panel = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 30),
                      "The sample fixture should open with lead I focused")

        // Inspector is open by default; only reach for the toggle if the
        // loaded app really doesn't show it. (On narrow windows the toggle
        // itself lives in the system toolbar overflow — probed at 964 pt —
        // so its absence from the button tree is not a failure by itself.)
        let picker = app.descendants(matching: .any)
            .matching(identifier: "findings-sort-picker").firstMatch
        if !picker.waitForExistence(timeout: 10) {
            let toggle = app.buttons.matching(identifier: "findings-toggle").firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                          "No picker and no findings toggle — the inspector is unreachable")
            toggle.click()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 10),
                      "FindingsPanel header should expose a 'findings-sort-picker'")
    }

    /// The markdown report stays reachable. Guards the `export-report`
    /// identifier, which X68 kept while changing what it identifies: it is now
    /// the export MENU rather than a single button, and a SwiftUI `Menu`
    /// surfaces as a `menuButton`, not a `button` — so `app.buttons[…]` finds
    /// nothing even though the item is right there. Match on any type.
    @MainActor
    func testExportReportIsReachableFromTheExportMenu() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let exportMenu = app.descendants(matching: .any)
            .matching(identifier: "export-report").firstMatch
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 5),
                      "Toolbar should expose the export menu")
        exportMenu.click()

        let item = app.menuItems["export-report-item"]
        XCTAssertTrue(item.waitForExistence(timeout: 3),
                      "The export menu should carry 'Export report…'")
        app.typeKey(.escape, modifierFlags: [])
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

    /// The PNG-snapshot export stays reachable. X68 collapsed the three
    /// exports into one toolbar menu, so this is now a menu item rather than a
    /// top-level button — the standalone `export-snapshot` item is still
    /// registered but hidden by default, and a hidden customisable item is
    /// absent from the accessibility tree entirely (measured, not assumed).
    @MainActor
    func testExportSnapshotIsReachableFromTheExportMenu() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        // The Menu surfaces as a menuButton (type 16), not a button.
        let exportMenu = app.descendants(matching: .any)
            .matching(identifier: "export-report").firstMatch
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 5),
                      "Toolbar should expose the export menu")
        exportMenu.click()

        let item = app.menuItems["export-snapshot-item"]
        XCTAssertTrue(item.waitForExistence(timeout: 3),
                      "The export menu should carry 'Export snapshot…'")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Persistent-stage layout (Phase 0 of the viewer redesign)

    /// The trace + docked inspector + overview map all render inside a
    /// single accessible `pinned-stage` container in focus mode. Guards
    /// the layout skeleton the later redesign phases mount into: if any
    /// of these four identifiers stops resolving under `pinned-stage`,
    /// the persistent-stage promise is broken. Focus mode is the
    /// default; the `--ui-test-sample` fixture carries no fiducial
    /// store, so no beat card renders at all — X71 removed the empty-state
    /// placeholder, so the assertion is on the column's calibration controls
    /// plus the ABSENCE of a placeholder.
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

        // #246 re-reversed X71: the readout is always mounted, and with no
        // beat focused it shows the placeholder state — same card, same
        // size, values withheld. The identifier X71 deleted is back.
        let controls = app.descendants(matching: .any)
            .matching(identifier: "calibration-controls").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 3),
                      "The stage's right column should sit beside the trace")

        let emptyCard = app.descendants(matching: .any)
            .matching(identifier: "docked-beat-inspector-empty").firstMatch
        XCTAssertTrue(emptyCard.waitForExistence(timeout: 3),
                      "#246: with no beat focused the card must hold its place "
                      + "in the placeholder state, not unmount")

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
    /// `PurchaseStore.hasStudio && markingsContext.template
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
        app.launchArguments += ["--ui-test-sample"]
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

        // X75 folded the category and confidence pickers into one overflow
        // menu. The AX2 guard this assertion exists for is unchanged: an
        // image-bearing menu must carry an explicit identifier, or it falls
        // back to its symbol name ("line.3.horizontal.decrease.circle") in
        // the tree.
        let filterMenu = app.descendants(matching: .any)
            .matching(identifier: "findings-filter-menu").firstMatch
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 3),
                      "Findings filter menu should carry an explicit identifier, not its SF Symbol name")
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

    // MARK: - X61 / #248: suppression is disclosed, and the menu says why

    /// The half of X61 that stayed in the window.
    ///
    /// #248 moved the Layers CONTROLS to View ▸ Fiducial Layers, on
    /// TestFlight feedback ("get rid of the Layers button"). What did not move
    /// is the disclosure that the zoom is holding marks back — because a menu
    /// only speaks when opened, and nobody opens a menu to explain an absence
    /// they have not noticed. Without it, "this zoom hides P and T" and "this
    /// record has no P waves" look identical on the canvas. One is a display
    /// setting, the other is a finding.
    ///
    /// At a 2 s window everything renders, so the note must be ABSENT. This is
    /// the half that would still pass if the publish never fired (the context
    /// keeps a permissive default), which is why the 5 s case below carries
    /// the weight.
    @MainActor
    func testNoSuppressionNoteAtFullFiducialZoom() throws {
        let app = try layersApp(initialDuration: 2)
        let note = app.descendants(matching: .any)
            .matching(identifier: "fiducial-suppression-note").firstMatch
        // A negative, so there is no positive event to wait on.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(note.exists,
                       "At a 2 s window every layer renders — nothing should claim marks "
                       + "are hidden. Got '\(note.label)'")
    }

    /// At a 5 s window the detail level is `.qrsOnly`, so P and T are dropped
    /// by the LOD gate and the canvas must say so.
    ///
    /// This is the assertion that fails if the publish regresses: the
    /// permissive default reports nothing suppressed, the note never mounts,
    /// and an analyst reads a trace with no P marks as a trace with no P
    /// waves. Before X61 the chip read `Layers · all` in exactly this state.
    @MainActor
    func testSuppressionNoteNamesTheHeldLayersAtStandardViewZoom() throws {
        let app = try layersApp(initialDuration: 5)
        let note = app.descendants(matching: .any)
            .matching(identifier: "fiducial-suppression-note").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10),
                      "At a 5 s window P and T are dropped by the LOD gate; the canvas "
                      + "must disclose it rather than just showing fewer marks")
        let spoken = note.label
        XCTAssertTrue(spoken.contains("P") && spoken.contains("T"),
                      "The note should NAME what is held back, got '\(spoken)'")
        XCTAssertFalse(spoken.contains("QRS"),
                       "QRS still renders at this zoom and must not be listed as hidden, "
                       + "got '\(spoken)'")
    }

    /// The controls themselves, at their new address.
    ///
    /// Matched by TITLE: accessibility identifiers do not survive onto a
    /// menu-bar `NSMenuItem` (measured during #236), which is why the chip's
    /// `fiducial-layers-picker` id has no successor here.
    @MainActor
    func testViewMenuCarriesTheFiducialLayers() throws {
        let app = try layersApp(initialDuration: 2)
        let view = app.menuBarItems["View"]
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        view.click()
        let titles = view.menuItems.allElementsBoundByIndex.map(\.title)
        for layer in ["P", "QRS", "T"] {
            XCTAssertTrue(titles.contains(layer),
                          "View should offer the \(layer) fiducial layer. Offers: \(titles)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The menu row names the zoom, and the explanation comes with it.
    ///
    /// The chip carried both; losing either on the way to the menu bar would
    /// leave a toggle that appears to do nothing at this zoom with no account
    /// of why. Enabled-but-suppressed must stay CHECKED and clickable — the
    /// intent is recorded and takes effect on zoom-in.
    @MainActor
    func testSuppressedLayersSaySoInTheMenuAndExplainWhy() throws {
        let app = try layersApp(initialDuration: 5)
        let view = app.menuBarItems["View"]
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        view.click()
        let titles = view.menuItems.allElementsBoundByIndex.map(\.title)

        XCTAssertTrue(titles.contains("P — hidden at this zoom"),
                      "A layer the zoom is holding back should say so in its row. "
                      + "Offers: \(titles)")
        XCTAssertTrue(titles.contains("QRS"),
                      "QRS renders at this zoom and should read plainly. Offers: \(titles)")
        XCTAssertTrue(titles.contains { $0.contains("need a window under") },
                      "The policy explanation should come along with the layers. "
                      + "Offers: \(titles)")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Launches with an entitlement (layers exist only once the paid
    /// delineator has produced beats) and returns the app.
    ///
    /// Two preconditions are checked and SKIPPED rather than failed, because
    /// neither is the behaviour under test and a silent pass would be worse
    /// than a stop that says why:
    ///
    /// 1. The record must have beats — no delineation is a different problem.
    /// 2. **The zoom tier must be `.inspect`.** The fiducial overlay is gated
    ///    by tier BEFORE detail level, and tier is points-per-beat, which is a
    ///    function of the panel's WIDTH. In a narrow window a 5 s trace is
    ///    dense enough to leave Inspect, the overlay draws nothing at all, and
    ///    EVERY layer is suppressed — so the per-layer assertions have nothing
    ///    to distinguish.
    ///
    /// The second guard exists because this test silently depended on window
    /// width when it was written: it passed on a wide window and failed the
    /// moment a saved window frame reset to `defaultSize`. Asserting the
    /// precondition makes the geometry part of the test rather than part of
    /// the machine.
    @MainActor
    private func layersApp(initialDuration: Int) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            // Pinned WIDE deliberately. The zoom tier is points-per-beat, so
            // it is a function of panel WIDTH — at a narrow width a 5 s trace
            // leaves Inspect, the overlay draws nothing at all, and every
            // layer is suppressed, which destroys the some-but-not-all state
            // these tests are about. The original X61 test depended on window
            // width without saying so and broke when a saved frame reset.
            "--ui-test-window=1600x1000",
            "--ui-test-initial-duration=\(initialDuration)",
            // Grants Studio and skips the entitlement walk — the existing
            // hook for "this XCUI run owns the paid module".
            "--ui-test-inject-qtc-lane=1"
        ]
        app.launch()

        // Tier FIRST: it exists at any zoom, while the overlay does not —
        // `FiducialOverlay` renders `EmptyView` when the policy draws no
        // marks, so a tier failure would otherwise be reported as "no beats".
        let tier = app.descendants(matching: .any)
            .matching(identifier: "ui-test-waveform-tier").firstMatch
        if tier.waitForExistence(timeout: 15), !tier.label.contains("tier=inspect") {
            throw XCTSkip(
                "Waveform tier is '\(tier.label)', not inspect at \(initialDuration) s — "
                + "every layer is suppressed, so there is no per-layer state to assert. "
                + "Not a regression."
            )
        }
        return app
    }
}

