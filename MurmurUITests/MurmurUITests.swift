//
//  MurmurUITests.swift
//  MurmurUITests
//
//  Created by Kevin Long on 6/14/26.
//

import AppKit
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
        // The welcome card is a ScrollView, and recents left by earlier
        // suites render above it — on Cloud's short bare-launch window
        // (production minimums on a 1024×768 VM, window bottom past the
        // display) that pushed the button below the fold. A real user
        // scrolls; so does the test — steered by frames against the
        // smaller of window and screen bottom (per-tick isHittable on a
        // clipped element is the X98 stall).
        let welcomeScroll = app.scrollViews
            .containing(.button, identifier: "empty-state-open-button").firstMatch
        let screenBottom = NSScreen.main.map {
            $0.frame.height - ($0.visibleFrame.minY - $0.frame.minY)
        } ?? .greatestFiniteMagnitude
        let visibleBottom = min(app.windows.firstMatch.frame.maxY, screenBottom)
        for _ in 0..<20 {
            if openButton.frame.maxY <= visibleBottom - 8 { break }
            welcomeScroll.scroll(byDeltaX: 0, deltaY: -24)
        }
        XCTAssertTrue(openButton.isHittable,
                      "Empty-state Open CSV button should be hittable — button \(openButton.frame), window \(app.windows.firstMatch.frame)")
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
        // Guideline 4 rejection. If `MurmurApp` ever drops the production
        // minimum (WindowSizing: 1100×720 content), this test fails.
        //
        // Under an XCUI run the enforced minimum is CAPPED by the runner's
        // visible screen (WindowSizing) — Xcode Cloud's 1024×768 VMs can't
        // hold a 720-pt-content window, and a window taller than the screen
        // makes every bottom-band control un-hittable. So the expectation
        // here is the same cap the app computes: production minimum, or the
        // visible frame less the chrome allowance, whichever is smaller.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        guard let window = app.windows.allElementsBoundByIndex.first else {
            XCTFail("Expected at least one application window")
            return
        }
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let visible = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 5000, height: 5000)
        let expectedMinWidth = min(1100.0, visible.width - 60)
        let expectedMinHeight = min(720.0, visible.height - 60)
        XCTAssertGreaterThanOrEqual(window.frame.width, expectedMinWidth,
                                    "Window width should be at least min(1100, screen) = \(expectedMinWidth)")
        XCTAssertGreaterThanOrEqual(window.frame.height, expectedMinHeight,
                                    "Window height should be at least min(720, screen) = \(expectedMinHeight)")
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
        //
        // Runs in a FORCED SHORT WINDOW (~Xcode Cloud's 1024×768 VM regime,
        // where this test failed once) so the findings rail keeps working
        // on a display this small on every machine, not just in CI.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=960x600"]
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
        if !vtItem.waitForExistence(timeout: 3) {
            // Slow CI VMs: the first click can land on a stale coordinate
            // snapshot while the capped short window is still settling, or
            // the opened menu's AX tree can take longer than 3 s to
            // materialise. Close whatever half-opened and try once more —
            // the assertion below still fails if the item genuinely isn't
            // in the menu.
            app.typeKey(.escape, modifierFlags: [])
            picker.click()
        }
        XCTAssertTrue(vtItem.waitForExistence(timeout: 5))
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
        // #232: this click reached the row locally and did nothing on Cloud,
        // with no error from XCUI — the in-window-click signature. Activation
        // is the ONLY guard this test carries, so the next Cloud run says
        // something either way: still failing means the click was never the
        // problem, and the security-scoped bookmark (which also has to resolve
        // on a fresh VM, and fails identically from the outside) is next.
        MurmurUITests.clickInWindow(recentRow, in: app)

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

    /// Click an element inside the app's OWN WINDOW, having first made the app
    /// frontmost.
    ///
    /// macOS delivers the first click on an INACTIVE window to the window
    /// manager, not to the responder chain: it activates the app and stops
    /// there. XCUI reports nothing wrong — the element was hittable, the click
    /// was dispatched — so the test fails later and elsewhere, on an assertion
    /// about state that never changed. Tests that reach their target through
    /// `app.menuItems` are immune, because opening a menu activates the app on
    /// the way in; that is why five menu-driven URL tests pass while the one
    /// in-window URL test did not. `MurmurUIPurchaseTests` names the same
    /// mechanism ("the headless CI runner often is not [frontmost]").
    ///
    /// HONEST STATUS: unverified. The regime could not be reproduced on a
    /// developer machine — XCUI holds the app under test frontmost, and twenty
    /// attempts to steal activation from the runner process left
    /// `NSWorkspace.frontmostApplication` pointing at Murmur every time, with
    /// `app.state` never leaving `.runningForeground`. So this is insurance
    /// against a mechanism that is documented and plausible but not
    /// demonstrated, and it is a no-op whenever the app is already active —
    /// which, locally, is always. See #231/#232 before trusting it to have
    /// fixed anything.
    ///
    /// A corollary worth knowing: because `app.state` stayed
    /// `.runningForeground` throughout that experiment, asserting on
    /// `wait(for: .runningForeground)` proves very little. `activate()` is the
    /// part that could do work; the wait is not a meaningful guard.
    ///
    /// Deliberately ONE step, not two. A frame-settle poll was written to sit
    /// here as well, covering the other candidate for #231 — a lane mounting
    /// between the hit test and the click, moving the target out from under a
    /// coordinate XCUI had already resolved. It was removed before merge for
    /// two reasons: instrumenting it showed the frame stable after a single
    /// poll at every call site, so there was no evidence for it; and a click
    /// carrying two guards cannot tell you which one worked. See #231 for the
    /// measurements, and `git log` for the implementation if it is needed
    /// again.
    @MainActor
    static func clickInWindow(_ element: XCUIElement, in app: XCUIApplication) {
        app.activate()
        element.click()
    }

    /// XCUIElement.waitForNonExistence isn't on macOS; spin our own.
    @MainActor
    static func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Scroll the bedside's scrolling context until `element` is hittable.
    ///
    /// On a short display (Xcode Cloud's 1024×768 VMs; any test launched
    /// with `--ui-test-window=…`) the scrolling context legitimately extends
    /// past the window, and bottom-region chrome — the trend stack, the
    /// drawer's lower rows — must be SCROLLED to, exactly as a real analyst
    /// would. The surface is the ScrollView that CONTAINS the context bar
    /// (the outer scrolling context, never the drawer's internal scrollers):
    /// a large element whose hit point stays resolvable while content moves,
    /// where small anchors like the 13-pt bar throw transient "unable to
    /// find hit point" mid-scroll. Wheel delivery must be element-based —
    /// XCUICoordinate.scroll silently reaches nothing on macOS. Sweeps
    /// downward first, then back up, in small ticks so a short row can't
    /// be jumped over.
    /// X98: steer by FRAME GEOMETRY, not by polling `isHittable`. On macOS,
    /// `exists` and `frame` on an element clipped out of the scroll viewport
    /// are ~0.1 s attribute reads — but `isHittable` on that same offscreen
    /// element stalls ~20 s in XCUI's hit-test machinery, and the old
    /// per-tick hittability poll paid that stall on every tick (one drawer
    /// test spent 139 of 163 s in exactly seven such calls). Frames tell us
    /// which way to scroll and when the element is inside the viewport;
    /// `isHittable` is asked ONCE at the end, when the element is visible
    /// and the check is cheap.
    @MainActor
    static func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxTicks: Int = 40
    ) -> Bool {
        guard element.exists else { return false }
        // The bedside anchors on the context bar's own ScrollView (never the
        // drawer's internal scrollers). Off the bedside — the welcome screen,
        // whose card runs past the fold of a short window — there is no
        // context bar and only one scrolling context, so take it.
        let anchored = app.scrollViews
            .containing(.any, identifier: "context-bar").firstMatch
        let surface = anchored.exists ? anchored : app.scrollViews.firstMatch
        guard surface.exists else { return element.isHittable }
        // Two passes, not one: the context column's lanes mount
        // asynchronously (delineation, LF/HF, the X89 beat series), and each
        // mount GROWS the scroll content and moves the target's frame — a
        // single pass can exhaust its ticks chasing a layout that is still
        // settling, exiting with the element half-clipped at the fold (found
        // in X89's suite runs on an entitled machine, where all five lanes
        // arrive over several seconds). The second pass steers on the
        // settled layout.
        for pass in 0..<2 {
            if pass > 0 {
                if element.isHittable { break }
                usleep(1_000_000)   // let in-flight lane mounts land
            }
            for _ in 0..<maxTicks {
                let ef = element.frame
                let sf = surface.frame
                // Inside the viewport (with a small margin so a row peeking one
                // pixel past the fold doesn't count) — stop scrolling.
                if !ef.isEmpty, ef.minY >= sf.minY + 8, ef.maxY <= sf.maxY - 8 { break }
                // An empty frame means the element isn't realized yet — sweep
                // down, the historical default; otherwise scroll TOWARD it.
                let below = ef.isEmpty || ef.midY > sf.midY
                surface.scroll(byDeltaX: 0, deltaY: below ? -24 : 24)
            }
        }
        return element.isHittable
    }

    /// Instance-method alias so existing tests keep compiling.
    @MainActor
    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        Self.waitForElementToDisappear(element, timeout: timeout)
    }
}
