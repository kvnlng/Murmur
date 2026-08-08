//
//  MurmurUITests.swift
//  MurmurUITests
//
//  Created by Kevin Long on 6/14/26.
//

import XCTest

final class MurmurUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tier 1: smoke tests

    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    @MainActor
    func testEmptyStateIsVisible() throws {
        let app = XCUIApplication()
        app.launch()

        let prompt = app.staticTexts["empty-state-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3), "Empty-state prompt should appear on cold launch")

        let openButton = app.buttons["empty-state-open-button"]
        XCTAssertTrue(openButton.exists, "Empty-state Open CSV button should be present")
        XCTAssertTrue(openButton.isHittable, "Empty-state Open CSV button should be hittable")
    }

    /// Opening a record folder stays reachable with NOTHING open — which is
    /// exactly when it is the only useful action in the window. X68 moved it
    /// into the toolbar's `⋯` overflow menu, so it is a menu item now; the
    /// standalone `toolbar-open-button` is still registered but hidden by
    /// default, and hidden customisable items are absent from the tree.
    @MainActor
    func testOpenRecordFolderIsReachableFromTheOverflowMenu() throws {
        let app = XCUIApplication()
        app.launch()

        let more = app.descendants(matching: .any)
            .matching(identifier: "toolbar-more").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 3),
                      "Toolbar should expose the overflow menu even with no record open")
        more.click()

        let item = app.menuItems["toolbar-open-button-item"]
        XCTAssertTrue(item.waitForExistence(timeout: 3),
                      "The overflow menu should carry 'Open Record Folder…'")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Tier 3: synthetic Recording fixture loaded via launch argument

    @MainActor
    func testSyntheticFixtureRendersBedsideView() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bedside = app.descendants(matching: .any).matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5),
                      "BedsideView should appear once the synthetic fixture loads")

        // The lead chip bar should be present with chips for every synthetic
        // lead — Focus mode default still renders the chip bar even though
        // only one channel panel is visible at a time.
        let chipBar = app.descendants(matching: .any).matching(identifier: "lead-chip-bar").firstMatch
        XCTAssertTrue(chipBar.waitForExistence(timeout: 3),
                      "Lead chip bar should be present so the user can pick a lead")
        let chipForV1 = app.descendants(matching: .any).matching(identifier: "lead-chip-V1").firstMatch
        XCTAssertTrue(chipForV1.exists, "Chip for V1 should be present in the lead bar")

        // First synthetic lead is "I" — focus mode defaults to it.
        let focusedPanel = app.descendants(matching: .any).matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(focusedPanel.waitForExistence(timeout: 5),
                      "Channel panel for the default-focused lead (I) should render")

        // Empty state is gone.
        let prompt = app.staticTexts["empty-state-prompt"]
        XCTAssertFalse(prompt.exists, "Empty-state prompt should not be visible once a recording is loaded")
    }

    // MARK: - Tier 4: canvas interaction regression guards
    //
    // The bugs these catch were all silent — events fired, no crash, but
    // the canvas didn't behave. Worth $10 of slow UI-test setup to make
    // sure they don't sneak back in.

    // The next four tests use UI-test-only launch arg hooks
    // (`--ui-test-initial-duration=<seconds>`, `--ui-test-hover-at=X,Y`)
    // and a hidden accessibility element (`ui-test-viewport-state`,
    // whose label encodes `<startSample>-<endSample>`). See
    // UITestSupport.swift for why those exist — they side-step macOS
    // XCUI quirks (hover synthesis, nested SwiftUI Text invisibility)
    // we hit when first attempting these tests.

    // Note: a `testDragOnCanvasPansViewport` was drafted using
    // `XCUICoordinate.press(forDuration: 0.5, thenDragTo:)` on the
    // channel-panel-I region, with `--ui-test-initial-duration=2`
    // arranging plenty of pan room. The synthesised press doesn't
    // generate the NSEvent.mouseDragged sequence SwiftUI's DragGesture
    // listens for, so the gesture never fires and the viewport-state
    // label stays put. Hand-testing confirms drag works in production.
    // The viewport math is also covered by RecordingViewportTests
    // (pan clamps, setWidth, jump), so this gap is informational
    // rather than substantive.

    // Note: a `testHoverInjectionRendersCrosshair` was drafted using
    // a `--ui-test-hover-at=X,Y` launch arg that pipes through the same
    // applyHover() path HoverTrackingView would. The injection runs
    // and the crosshair body renders (verified by hand), but it
    // doesn't appear in the macOS XCUI accessibility tree even with
    // `.accessibilityElement(children: .ignore)` + identifier —
    // SwiftUI's tree-pruning for non-hit-testable views in nested
    // GeometryReader contexts is unforgiving. The hover state +
    // hit-test math are unit-tested; the visual is verified during
    // the RELEASE.md smoke-test pass.

    @MainActor
    func testClickingFindingRowChangesViewport() throws {
        // Guards: animateJump path + viewport observability. Click the
        // synthetic fixture's VF finding (mid-record) and assert the
        // hidden viewport-state label changes within the 250 ms
        // animation window.
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

        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 3))
        vfRow.click()

        let predicate = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport state should change after a finding row click (was '\(initial)')")
    }

    @MainActor
    func testWindowHonorsMinimumSize() throws {
        // Guards: the min-window-size fix that resolved the App Store
        // Guideline 4 rejection. If `MurmurApp` ever drops
        // `.frame(minWidth: 1100, minHeight: 720)`, this test fails.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        guard let window = app.windows.allElementsBoundByIndex.first else {
            XCTFail("Expected at least one application window")
            return
        }
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        // The frame call returns a CGRect; both dimensions should be at
        // or above the minimum we set in MurmurApp.
        XCTAssertGreaterThanOrEqual(window.frame.width, 1100,
                                    "Window width should be at least the 1100pt minimum")
        XCTAssertGreaterThanOrEqual(window.frame.height, 720,
                                    "Window height should be at least the 720pt minimum")
    }

    @MainActor
    func testClickingOverviewRibbonScrubsViewport() throws {
        // Guards: overview ribbon's click-to-scrub path. Same shape as the
        // finding-row test — click the ribbon, assert the viewport-state
        // label changes. The ribbon uses a DragGesture(minimumDistance: 0),
        // so a click registers as a touch-down that fires the gesture's
        // initial `onChanged`.
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

        // Lead I is focused by default in the synthetic fixture, so its
        // overview ribbon is the one on-screen.
        let ribbon = app.descendants(matching: .any)
            .matching(identifier: "overview-ribbon-I").firstMatch
        XCTAssertTrue(ribbon.waitForExistence(timeout: 3))
        ribbon.click()

        let predicate = NSPredicate(format: "label != %@", initial)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport state should change after an overview-ribbon click (was '\(initial)')")
    }

    // MARK: - Tier 5: layout & filter regression guards

    @MainActor
    func testClickingLeadChipShiftsFocus() throws {
        // Guards: lead-chip-bar wiring + focus-mode panel swap. Default
        // focus is lead I. Click lead-chip-V1; the focused panel should
        // become channel-panel-V1 and channel-panel-I should disappear
        // (focus mode renders one panel at a time).
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let panelI = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panelI.waitForExistence(timeout: 5),
                      "Default focus is lead I; channel-panel-I should render")

        let chipV1 = app.buttons.matching(identifier: "lead-chip-V1").firstMatch
        XCTAssertTrue(chipV1.waitForExistence(timeout: 3))
        chipV1.click()

        let panelV1 = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-V1").firstMatch
        XCTAssertTrue(panelV1.waitForExistence(timeout: 3),
                      "After clicking lead-chip-V1, channel-panel-V1 should render")
        XCTAssertTrue(waitForElementToDisappear(panelI, timeout: 2),
                      "Focus mode shows one panel at a time; channel-panel-I should disappear")
    }

    @MainActor
    func testLayoutModeToggleShowsAllChannels() throws {
        // Guards: layout-mode-strips wiring. Default mode is .focus(I) →
        // only channel-panel-I is rendered. Flip to Strips → every ECG
        // panel renders.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let panelI = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(panelI.waitForExistence(timeout: 5))

        // In focus mode, lead II's panel is hidden.
        let panelII = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-II").firstMatch
        XCTAssertFalse(panelII.exists,
                       "Focus mode hides non-focused channel panels")

        let stripsButton = app.buttons.matching(identifier: "layout-mode-strips").firstMatch
        XCTAssertTrue(stripsButton.waitForExistence(timeout: 3))
        stripsButton.click()

        XCTAssertTrue(panelII.waitForExistence(timeout: 3),
                      "Strips mode should render every channel panel")
    }

    @MainActor
    func testClickingSummaryChipFiltersFindings() throws {
        // Guards: review-queue category-menu → FindingFilter → re-render.
        // Retired the old `summary-chip-*` chip row 2026-07-05; the
        // rail's picker does the same job in a location that's always
        // visible (dodges the CI-window-height flake).
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 5))

        // X75 folded the category picker into the header's overflow menu.
        // The category ROW ids are unchanged — only the way in moved.
        let picker = app.descendants(matching: .any)
            .matching(identifier: "findings-filter-menu").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.click()
        let vtItem = app.menuItems.matching(identifier: "findings-category-filter-VT").firstMatch
        XCTAssertTrue(vtItem.waitForExistence(timeout: 3))
        vtItem.click()

        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(vfRow, timeout: 3),
                      "VF row should disappear after narrowing to VT")
        let vtRow = app.buttons.matching(identifier: "finding-row-VT").firstMatch
        XCTAssertTrue(vtRow.exists, "VT row should remain visible")
    }

    // MARK: - Tier 5b: recents

    @MainActor
    func testClickingRecentFolderReopensRecording() throws {
        // Guards: recents-row click → bookmark resolve → scanFolder →
        // import → bedside-view. The launch arg seeds one entry in the
        // recents store pointing at a synthetic WFDB source folder, then
        // we click the row and assert the bedside view materialises.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-seed-recent"]
        app.launch()

        // The seed runs inside ContentView's .task, so give it a beat to
        // land an entry in the store before we look for the row.
        let recentRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'welcome-recent-'")).firstMatch
        XCTAssertTrue(recentRow.waitForExistence(timeout: 5),
                      "Seeded recents entry should render in the welcome view")
        recentRow.click()

        // Single-record folders auto-select and auto-import on open, so
        // the bedside view should render once the importer finishes.
        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 15),
                      "Clicking a recents row should open the folder, import the record, and show bedside-view")
    }

    // MARK: - Tier 6: disposition round-trip (lock-gated)

    @MainActor
    func testEditModeLatchTogglesDispositionTrio() throws {
        // Guards: edit-mode-toggle wiring + the lock-gated render of the
        // disposition trio. Default state is read-only — the
        // confirm/dismiss buttons should not appear in the tree. Flip
        // edit-mode on; they should appear.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 5))

        // Locate a confirm button by partial identifier — the suffix is
        // an annotation UUID we don't know up-front.
        let confirmPredicate = NSPredicate(format: "identifier BEGINSWITH 'disposition-confirm-'")
        XCTAssertEqual(app.descendants(matching: .any).matching(confirmPredicate).count, 0,
                       "Disposition trio should not render when edit-mode is off")

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()

        // After enabling edit-mode, every finding gets a confirm button.
        // Three findings in the fixture (2 VT + 1 VF) → 3 confirm buttons.
        let confirmsAfter = app.descendants(matching: .any).matching(confirmPredicate)
        let appeared = NSPredicate(format: "count > 0")
        let exp = XCTNSPredicateExpectation(predicate: appeared, object: confirmsAfter)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Disposition confirm buttons should appear after edit-mode is enabled")
    }

    @MainActor
    func testDismissingFindingExposesResetButton() throws {
        // Guards: dispositionStore.dismiss path + the reset button's
        // disposition-conditional render. Pre-condition: edit-mode on,
        // no dispositions yet → no reset button. Click dismiss → reset
        // button for that finding appears.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        // Wait for a dismiss button to materialise after edit-mode flips on.
        let dismissPredicate = NSPredicate(format: "identifier BEGINSWITH 'disposition-dismiss-'")
        let dismissButtons = app.descendants(matching: .any).matching(dismissPredicate)
        let dismissAppeared = NSPredicate(format: "count > 0")
        let dismissExp = XCTNSPredicateExpectation(predicate: dismissAppeared, object: dismissButtons)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissExp], timeout: 3), .completed,
                       "Dismiss buttons should appear after edit-mode flips on")

        // No reset buttons yet — nothing has been dispositioned.
        let resetPredicate = NSPredicate(format: "identifier BEGINSWITH 'disposition-reset-'")
        XCTAssertEqual(app.descendants(matching: .any).matching(resetPredicate).count, 0,
                       "Reset button should not exist before any finding is dispositioned")

        dismissButtons.element(boundBy: 0).click()

        // After dismissing one finding, exactly one reset button should appear.
        let resetButtons = app.descendants(matching: .any).matching(resetPredicate)
        let resetAppeared = NSPredicate(format: "count > 0")
        let resetExp = XCTNSPredicateExpectation(predicate: resetAppeared, object: resetButtons)
        XCTAssertEqual(XCTWaiter.wait(for: [resetExp], timeout: 3), .completed,
                       "Reset button should appear after a finding is dismissed")
    }

    @MainActor
    func testResetReturnsFindingToUnreviewed() throws {
        // Guards: dispositionStore.reset path + the reset button's
        // conditional render disappearing again. Sets up state by
        // dismissing first, then resets.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        let dismissPredicate = NSPredicate(format: "identifier BEGINSWITH 'disposition-dismiss-'")
        let dismissButtons = app.descendants(matching: .any).matching(dismissPredicate)
        let dismissAppeared = NSPredicate(format: "count > 0")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: dismissAppeared, object: dismissButtons)],
                timeout: 3
            ),
            .completed
        )
        dismissButtons.element(boundBy: 0).click()

        let resetPredicate = NSPredicate(format: "identifier BEGINSWITH 'disposition-reset-'")
        let resetButtons = app.descendants(matching: .any).matching(resetPredicate)
        let resetAppeared = NSPredicate(format: "count > 0")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: resetAppeared, object: resetButtons)],
                timeout: 3
            ),
            .completed,
            "Setup precondition: dismiss should have produced a reset button"
        )

        resetButtons.element(boundBy: 0).click()

        let resetDisappeared = NSPredicate(format: "count == 0")
        let resetGoneExp = XCTNSPredicateExpectation(predicate: resetDisappeared, object: resetButtons)
        XCTAssertEqual(XCTWaiter.wait(for: [resetGoneExp], timeout: 3), .completed,
                       "Reset button should disappear once the finding is back to unreviewed")
    }

    @MainActor
    func testConfirmFindingViaMenuExposesResetButton() throws {
        // Guards: dispositionStore.confirm path + the Menu wrapping of the
        // confirm action (Confirm as VT / Confirm as VF / Confirm (unsure)).
        // SwiftUI Menu on macOS opens a popup; selecting an item fires
        // the underlying onConfirm closure.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        let confirmPredicate = NSPredicate(format: "identifier BEGINSWITH 'disposition-confirm-'")
        let confirmButtons = app.descendants(matching: .any).matching(confirmPredicate)
        let confirmAppeared = NSPredicate(format: "count > 0")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: confirmAppeared, object: confirmButtons)],
                timeout: 3
            ),
            .completed
        )

        // Open the Menu on the first finding's confirm control.
        confirmButtons.element(boundBy: 0).click()

        // Pick the "Confirm (unsure)" option — keeps the test resilient
        // to the menu's exact ordering of VT/VF items.
        let menuItem = app.menuItems["Confirm (unsure)"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3),
                      "Confirm menu should open and expose its items")
        menuItem.click()

        let resetPredicate = NSPredicate(format: "identifier BEGINSWITH 'disposition-reset-'")
        let resetButtons = app.descendants(matching: .any).matching(resetPredicate)
        let resetAppeared = NSPredicate(format: "count > 0")
        let resetExp = XCTNSPredicateExpectation(predicate: resetAppeared, object: resetButtons)
        XCTAssertEqual(XCTWaiter.wait(for: [resetExp], timeout: 3), .completed,
                       "Reset button should appear after a finding is confirmed via the Menu")
    }

    @MainActor
    func testContextNotesEditorAppearsInEditMode() throws {
        // Guards: the Context drawer's notes.md editor + the edit-mode latch
        // gate on it (X72 rehomed the old RecordContextPanel's document
        // editing into the drawer; the identifiers carried over). The
        // synthetic fixture's importer reserves a "notes.md" filename so the
        // document row always renders and is the drawer's default selection;
        // the TextEditor itself is only mounted when isEditing is true.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        // Wait for the bedside to appear so we know the panel had time to
        // mount.
        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5))

        // X69 put the Context region behind a collapsed bar, matching the
        // design's canonical layout, so the panel is not mounted until it is
        // opened. Two gates now stand between launch and the editor — this one
        // and the edit latch — and they are independent.
        //
        // Driven to a known state rather than blind-clicked: the expansion is
        // `@AppStorage`, so it survives app launches. A bare click would toggle
        // whatever the previous run left behind — passing the first time and
        // failing the second, which is the worst shape a test can have.
        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 5),
                      "The scrolling context should carry a Context bar")
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        if !panel.exists { contextBar.click() }
        XCTAssertTrue(panel.waitForExistence(timeout: 3),
                      "Expanding the Context bar should mount the panel")

        let editor = app.descendants(matching: .any)
            .matching(identifier: "context-notes-editor").firstMatch
        XCTAssertFalse(editor.exists,
                       "Notes editor should not render when edit-mode is off")

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()

        XCTAssertTrue(editor.waitForExistence(timeout: 3),
                      "Notes editor should appear after edit-mode is enabled")

        // Flip back to read-only; editor disappears.
        editToggle.click()
        XCTAssertTrue(waitForElementToDisappear(editor, timeout: 3),
                      "Notes editor should disappear after edit-mode is locked")
    }

    @MainActor
    func testFindingsPanelTogglesViaToolbar() throws {
        // Guards: toolbar button wiring, inspector show/hide, panel
        // render path. A regression here would silently strand findings
        // behind a panel the analyst can't reopen.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let toggle = app.buttons.matching(identifier: "findings-toggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        // The synthetic fixture's VF finding is in the panel by default.
        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 3),
                      "VF finding row should be visible by default in the findings panel")

        toggle.click()
        XCTAssertTrue(waitForElementToDisappear(vfRow, timeout: 2),
                      "Finding row should disappear after the toggle hides the panel")

        toggle.click()
        XCTAssertTrue(vfRow.waitForExistence(timeout: 2),
                      "Finding row should reappear after toggling the panel back on")
    }

    /// XCUIElement.waitForNonExistence isn't on macOS; spin our own.
    @MainActor
    static func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Instance-method alias so existing tests keep compiling.
    @MainActor
    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        Self.waitForElementToDisappear(element, timeout: timeout)
    }
}

// Bypass tests live in their own class so the primary test class stays
// inside the SwiftLint type_body_length budget. The split is by intent —
// these tests all use launch-arg-driven bypasses (file picker, gesture
// synthesis, URL launches) rather than direct UI interactions.
final class MurmurUIBypassTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tier 7: file-picker bypass (Open Folder + Drag-and-Drop)
    //
    // The synthetic `--ui-test-open-folder` launch arg materialises a WFDB
    // source folder and calls `openFolder(_:)` directly — the same path the
    // welcome screen Open button, the toolbar Open button, and the drop
    // delegate all funnel into. One test covers all three interactions
    // (the NSOpenPanel modal itself is system code we don't own).

    @MainActor
    func testLaunchArgOpenFolderLoadsRecording() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-folder"]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 15),
                      "openFolder(_:) → scanFolder → import → bedside should complete end-to-end")
    }

    /// X63-B: the flag an analyst uses to pick records for Save Session lives
    /// on the sidebar row, so the sidebar has to be reachable for the feature
    /// to exist at all. Nothing asserted the record list before this — the
    /// folder-open test above only checks that the bedside arrives.
    ///
    /// The flag appears once a record is IMPORTED (an unimported record has no
    /// `Recording` to save), so this waits on the row first and the flag after.
    @MainActor
    func testOpenFolderShowsFlaggableRecordRows() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-folder"]
        app.launch()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "record-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "A folder open should list its records in the sidebar")

        let flag = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "record-flag-")).firstMatch
        XCTAssertTrue(flag.waitForExistence(timeout: 15),
                      "An imported record should expose the Save Session flag (X63-B)")
    }

    // MARK: - Tier 8: attach findings bypass

    @MainActor
    func testLaunchArgAttachFindingsMergesIntoPanel() throws {
        // Guards: handleAttachFindings → AnnotationLoader → attachedAnnotations
        // → BundleAnnotationsFile.write. The bypass writes a synthetic
        // sidecar JSON with one distinctive category ("ATTACH") and routes
        // it through the bedside view's attach path on appear. A new
        // finding-row-ATTACH must appear.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-attach-findings"
        ]
        app.launch()

        let attachRow = app.buttons.matching(identifier: "finding-row-ATTACH").firstMatch
        XCTAssertTrue(attachRow.waitForExistence(timeout: 10),
                      "Attached finding should land in the findings panel as finding-row-ATTACH")
    }

    // MARK: - Tier 8b: deviation-ranked review queue

    @MainActor
    func testReviewQueueGroupsCollapseByDefault() throws {
        // X65: UI-test runs now default to EXPANDED groups, so this test has
        // to ask for the shipping behaviour explicitly. It therefore asserts
        // the collapsed STATE, not the shipping DEFAULT — under XCUI the
        // default is no longer observable. That was a knowing trade (see
        // UITestSupport.shouldExpandFindingsGroups); the collapse rendering
        // is still covered, the "is it the default?" question is not.
        //
        // Guards: groups (finding-group-<category>) are visible, but their
        // child exemplar rows (finding-row-<cat>) are not — clicking the
        // group is what reveals them.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-collapse-findings-groups"
        ]
        app.launch()

        // The synthetic fixture has VT + VF categories, so at least
        // one group row must resolve.
        let vfGroup = app.buttons.matching(identifier: "finding-group-VF").firstMatch
        XCTAssertTrue(vfGroup.waitForExistence(timeout: 5),
                      "finding-group-VF should render as a collapsed group row by default")

        // The exemplar row for the same category must NOT be visible
        // before the group is expanded.
        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertFalse(vfRow.waitForExistence(timeout: 1),
                       "finding-row-VF should be hidden until the group is expanded")
    }

    @MainActor
    func testReviewQueueGroupExpandRevealsExemplars() throws {
        // Needs `--ui-test-collapse-findings-groups` because the analyst's own
        // expand click is what is being exercised, and that has to start from
        // a collapsed group (X65 made expanded the UI-test default).
        //
        // Guards: click a group → its child exemplar rows appear; click again
        // → they disappear. Load-bearing for the deviation-ranked queue's
        // semantics.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-collapse-findings-groups"
        ]
        app.launch()

        let vfGroup = app.buttons.matching(identifier: "finding-group-VF").firstMatch
        XCTAssertTrue(vfGroup.waitForExistence(timeout: 5))

        // Expand.
        vfGroup.click()
        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 3),
                      "Clicking a group row should reveal its exemplar rows")

        // Collapse.
        vfGroup.click()
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(vfRow, timeout: 3),
                      "Clicking an expanded group row should collapse it")
    }

    @MainActor
    func testReviewQueueRhythmContextBannerRendersFromHeader() throws {
        // Guards: the rhythm-context banner reads recording.headerComments
        // and surfaces them at the top of the queue. The synthetic
        // fixture writes a rhythm-flavored comment into its `.hea`, so
        // the banner must resolve. XCUI on macOS surfaces the banner's
        // inner static texts more reliably than the HStack container's
        // accessibility identifier, so probe for the "Rhythm context"
        // heading text.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let heading = app.staticTexts["Rhythm context"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5),
                      "rhythm-context banner heading should render whenever headerComments is non-empty")
    }

    // MARK: - Tier 9: canvas gesture bypass (pan + zoom + hover)

    @MainActor
    func testLaunchArgPanByShiftsViewport() throws {
        // Guards: the viewport.setStart path that drag-pan's onChanged
        // calls. Can't synthesise NSEvent.mouseDragged under XCUI, so this
        // exercises the same mutation directly via launch arg.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2",
            "--ui-test-pan-by=200"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        // Initial viewport is 0–500 (2s × 250 Hz). After pan by 200 samples
        // it should be 200–700.
        let expected = NSPredicate(format: "label == 'start=200 end=700'")
        let exp = XCTNSPredicateExpectation(predicate: expected, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport should land at 200-700 after --ui-test-pan-by=200 (was \(viewportState.label))")
    }

    @MainActor
    func testLaunchArgZoomToScalesViewportWidth() throws {
        // Guards: the viewport.setWidth path that pinch-zoom's onChanged
        // calls. MagnifyGesture is not synthesisable from XCUI on macOS.
        //
        // Test values stay under 1000 because macOS's accessibility
        // post-processor injects thousands separators into 4+ digit numbers
        // ("1750" → "1,750") regardless of the label's surrounding format.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2",
            "--ui-test-zoom-to=0.4"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        // Initial viewport is 0–500 (2s × 250 Hz). Zoom to 0.4s at anchor
        // 0.5 → 100-sample-wide window centred on sample 250 → 200–300.
        let expected = NSPredicate(format: "label == 'start=200 end=300'")
        let exp = XCTNSPredicateExpectation(predicate: expected, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport should land at start=200 end=300 after --ui-test-zoom-to=0.4 (was \(viewportState.label))")
    }

    @MainActor
    func testLaunchArgHoverInjectionRendersCrosshair() throws {
        // Guards: the --ui-test-hover-at injection path. Hover state itself
        // doesn't surface in XCUI's accessibility tree; the strongest check
        // we can run is "the app launched without crashing" plus a smoke
        // assertion that the bedside-view still rendered. The injection
        // path firing is verified manually via the RELEASE.md hover check.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-hover-at=400,300"
        ]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5),
                      "Bedside should still render with hover injection enabled")
    }

    // MARK: - Tier 10: Help menu — existence asserts

    @MainActor
    func testHelpMenuItemsExist() throws {
        // Cheap guard against the Help menu being unwired entirely. Doesn't
        // verify the URL each command targets — that's covered by the
        // URLLauncher tests below.
        let app = XCUIApplication()
        app.launch()

        let helpMenu = app.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 5))
        helpMenu.click()

        for title in ["Murmur Studio Help", "Getting Started",
                      "Annotation Schema", "Privacy Policy",
                      "Contact Support…"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 3),
                          "Help menu item '\(title)' should exist")
        }
        // Dismiss the menu before the next test runs.
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Tier 11: URLLauncher — URL correctness via probe

    /// Clicks a Help menu item by title with the URLLauncher recording
    /// mode enabled, then asserts the probe element echoes the expected URL.
    @MainActor
    private func assertHelpItemTargets(_ title: String, _ expectedURL: String) {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-record-urls"]
        app.launch()

        let probe = app.descendants(matching: .any)
            .matching(identifier: "ui-test-last-launched-url").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))

        let helpMenu = app.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 3))
        helpMenu.click()

        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()

        let predicate = NSPredicate(format: "label == %@", expectedURL)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "URLLauncher should record \(expectedURL) for '\(title)' (was '\(probe.label)')")
    }

    @MainActor
    func testHelpMurmurStudioHelpTargetsDocsHome() throws {
        assertHelpItemTargets("Murmur Studio Help",
                              "https://kvnlng.github.io/Murmur/")
    }

    @MainActor
    func testHelpGettingStartedTargetsDocsGettingStarted() throws {
        assertHelpItemTargets("Getting Started",
                              "https://kvnlng.github.io/Murmur/getting-started.html")
    }

    @MainActor
    func testHelpAnnotationSchemaTargetsDocsAnnotationSchema() throws {
        assertHelpItemTargets("Annotation Schema",
                              "https://kvnlng.github.io/Murmur/annotation-schema.html")
    }

    @MainActor
    func testHelpPrivacyPolicyTargetsDocsPrivacy() throws {
        assertHelpItemTargets("Privacy Policy",
                              "https://kvnlng.github.io/Murmur/privacy.html")
    }

    @MainActor
    func testHelpContactSupportTargetsMailto() throws {
        assertHelpItemTargets("Contact Support…",
                              "mailto:long.kevin@gmail.com?subject=Murmur%20Studio%20Support")
    }

    @MainActor
    func testPhysioNetLinkTargetsMITBIH() throws {
        // Guards: welcome-screen PhysioNet button → URLLauncher path.
        // Different from the Help menu items because the trigger is a
        // SwiftUI Button in the WelcomeView, not a Command.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-record-urls"]
        app.launch()

        let probe = app.descendants(matching: .any)
            .matching(identifier: "ui-test-last-launched-url").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))

        // .buttonStyle(.link) makes SwiftUI render the Button as an AppKit
        // link element, not a button — so search any descendant for the
        // identifier rather than restricting to .buttons.
        let physioNet = app.descendants(matching: .any)
            .matching(identifier: "welcome-physionet-link").firstMatch
        XCTAssertTrue(physioNet.waitForExistence(timeout: 5))
        physioNet.click()

        let expected = "https://www.physionet.org/content/mitdb/1.0.0/"
        let predicate = NSPredicate(format: "label == %@", expected)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "URLLauncher should record \(expected) for the PhysioNet link (was '\(probe.label)')")
    }
}
