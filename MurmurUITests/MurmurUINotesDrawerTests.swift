//
//  MurmurUINotesDrawerTests.swift
//  MurmurUITests
//
//  X72 — the Context drawer and its anchored notes.
//
//  The drawer's expansion is `@AppStorage`, so every test drives it to a
//  known state rather than blind-toggling (a bare click would flip whatever
//  the previous run left behind — passing the first time and failing the
//  second, the worst shape a test can have).
//
//  Anchored notes live in `MurSessionState`, saved only by File ▸ Save
//  Session — NSSavePanel is system-modal and not XCUI-drivable, so the save
//  round-trip is covered by unit tests on the state type; what XCUI covers
//  here is the drawer itself: the three persistence rows, note creation
//  behind the Editing latch, and the anchor jump.
//

import XCTest

final class MurmurUINotesDrawerTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launch with the fixture and force the drawer open, whatever state the
    /// previous run persisted.
    @MainActor
    /// Click an element that may sit past the fold of the scrolling context
    /// on a short display — scroll it into view over the context bar (the
    /// shared MurmurUITests helper), then click.
    private func scrollIntoViewAndClick(
        _ element: XCUIElement,
        within app: XCUIApplication,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(element, in: app),
                      "\(what) never became hittable, even after scrolling",
                      file: file, line: line)
        element.click()
    }

    private func launchWithDrawerOpen(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ] + extraArguments
        app.launch()

        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 10),
                      "The scrolling context should carry a Context bar")
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        if !panel.exists { contextBar.click() }
        XCTAssertTrue(panel.waitForExistence(timeout: 3),
                      "Expanding the Context bar should mount the drawer")
        return app
    }

    /// The drawer's list carries all three persistence schedules as rows:
    /// the read-only `.hea` block and the notes.md record document. (The
    /// third kind — anchored rows — starts empty and is covered by the
    /// creation test.)
    @MainActor
    func testDrawerListsThePersistenceRows() throws {
        let app = launchWithDrawerOpen()

        let heaRow = app.descendants(matching: .any)
            .matching(identifier: "note-row-hea").firstMatch
        XCTAssertTrue(heaRow.waitForExistence(timeout: 5),
                      "The fixture's .hea comments should surface as the pinned read-only row")

        let documentRow = app.descendants(matching: .any)
            .matching(identifier: "note-row-document").firstMatch
        XCTAssertTrue(documentRow.waitForExistence(timeout: 3),
                      "notes.md should surface as the record-document row")

        // Notes are session edits, so creation sits behind the same Editing
        // latch as every other analyst edit.
        let newNote = app.buttons.matching(identifier: "notes-drawer-new-note").firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        XCTAssertFalse(newNote.isEnabled,
                       "New note must be disabled while Editing is locked")
    }

    /// Creating a note: unlock, create, and the note surfaces everywhere at
    /// once — stepper readout, collapsed-bar entry count, and the info bar.
    @MainActor
    func testNewNoteRequiresEditingAndSurfacesCounts() throws {
        let app = launchWithDrawerOpen()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()

        let newNote = app.buttons.matching(identifier: "notes-drawer-new-note").firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        XCTAssertTrue(newNote.isEnabled, "Unlocking Editing should enable New note")
        newNote.click()

        let readout = app.descendants(matching: .any)
            .matching(identifier: "notes-drawer-stepper-readout").firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 3))
        let spoken = readout.label.isEmpty ? (readout.value as? String ?? "") : readout.label
        XCTAssertEqual(spoken, "1 of 1",
                       "A fresh note should be selected, so the stepper reads 1 of 1")

        // The editor mounts for the new note (Editing is unlocked).
        let editor = app.descendants(matching: .any)
            .matching(identifier: "anchored-note-editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3),
                      "Selecting the fresh note should mount its editor")

        // The info bar counts it. The bar combines its children, and a
        // combined SwiftUI text lands in the AX VALUE, not the label — the
        // X69 lesson; check both.
        let infoBar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(infoBar.waitForExistence(timeout: 3))
        let barText = [infoBar.label, infoBar.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(barText.contains("1 note"),
                      "The info bar should carry the note count, got '\(barText)'")

        // And its footer states the real persistence schedule — the
        // DECISIONS §4 copy, not the wireframe's false autosave sentence.
        let status = app.descendants(matching: .any)
            .matching(identifier: "note-save-status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        let statusText = status.label.isEmpty ? (status.value as? String ?? "") : status.label
        XCTAssertTrue(statusText.contains("Save Session"),
                      "The anchored footer must point at File ▸ Save Session, got '\(statusText)'")
    }

    /// Clicking a note row moves the trace to the note's anchor.
    ///
    /// Runs in a FORCED SHORT WINDOW (Xcode Cloud's 1024×768 VMs, where this
    /// test first failed "not hittable"): the note row can legitimately land
    /// below the drawer's fold, so the test scrolls it into view — which is
    /// also what a real analyst on a small display would do.
    @MainActor
    func testNoteRowClickJumpsViewport() throws {
        let app = launchWithDrawerOpen(extraArguments: ["--ui-test-window=1000x600"])

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))

        // Create a note anchored to the opening 2 s window.
        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()
        let newNote = app.buttons.matching(identifier: "notes-drawer-new-note").firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        scrollIntoViewAndClick(newNote, within: app, "the new-note button")

        // Move the trace away from the anchor: a click on the overview strip
        // recentres mid-record (lead I is the fixture's focused default).
        // (Scrolling down for the drawer may have pushed the ribbon above
        // the fold — the helper sweeps both directions.)
        let ribbon = app.descendants(matching: .any)
            .matching(identifier: "overview-ribbon-I").firstMatch
        XCTAssertTrue(ribbon.waitForExistence(timeout: 3))
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(ribbon, in: app),
                      "The overview ribbon should scroll back into view")
        let beforeScrub = viewportState.label
        ribbon.click()
        let scrubbed = NSPredicate(format: "label != %@", beforeScrub)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: scrubbed, object: viewportState)],
                timeout: 3
            ),
            .completed,
            "The overview scrub should move the viewport off the note's anchor"
        )

        // Click the note's row — the trace must come back to the anchor.
        // Addressed by the stable positional identifier (X98): anchored rows
        // are `note-row-anchored-<index>` in list order, so the fresh note is
        // index 0 and no BEGINSWITH predicate is needed to find it.
        let afterScrub = viewportState.label
        let noteRow = app.descendants(matching: .any)
            .matching(identifier: "note-row-anchored-0").firstMatch
        XCTAssertTrue(noteRow.waitForExistence(timeout: 3),
                      "The created note should render a list row")
        scrollIntoViewAndClick(noteRow, within: app, "the note row")

        let jumped = NSPredicate(format: "label != %@", afterScrub)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: jumped, object: viewportState)],
                timeout: 3
            ),
            .completed,
            "Clicking the note row should move the trace to its anchor (was '\(afterScrub)')"
        )
    }

    /// X77 (#113): quitting with an unsaved anchored note warns instead of
    /// silently discarding, Cancel keeps the app alive, and Discard and Quit
    /// actually terminates.
    @MainActor
    func testQuitWithUnsavedNotesWarnsAndHonorsBothChoices() throws {
        let app = launchWithDrawerOpen()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()
        let newNote = app.buttons.matching(identifier: "notes-drawer-new-note").firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()

        app.typeKey("q", modifierFlags: .command)
        // NSAlert buttons; scoped to the whole app because the alert is
        // app-modal, not a window sheet.
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "⌘Q with an unsaved note should raise the warning alert")
        cancel.click()

        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 3),
                      "Cancel should abort the quit — the app must still be running")

        app.typeKey("q", modifierFlags: .command)
        let discard = app.buttons["Discard and Quit"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                      "Discard and Quit should terminate the app")
    }

    /// X86 (#135), replacing the X77 record-switch confirmation this spot
    /// used to test: switching records with an unsaved note no longer
    /// interrupts. The note rides along in memory — the one-time crash-loss
    /// disclosure presents on the first carrying switch (forced here, since
    /// XCUI runs share the app container's defaults), the second record
    /// opens fresh, and switching back restores the first record's note.
    @MainActor
    func testSwitchingRecordsCarriesUnsavedNotes() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-folder=2", "--ui-test-crash-loss-notice"]
        app.launch()

        // The first record auto-selects and imports; drive the drawer open.
        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 20),
                      "The first record should import and present its bedside")
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        if !panel.exists { contextBar.click() }
        XCTAssertTrue(panel.waitForExistence(timeout: 3))

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()
        let newNote = app.buttons.matching(identifier: "notes-drawer-new-note").firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()

        let readout = app.descendants(matching: .any)
            .matching(identifier: "notes-drawer-stepper-readout").firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 3))
        XCTAssertEqual(spokenName(readout), "1 of 1")

        // The record navigator may have yielded to the review-queue
        // inspector: X82's coexistence rule collapses whichever panel was
        // least recently requested when the window can't hold both, and the
        // inspector wins by default. Requesting the navigator through its
        // detail-side toggle is the analyst's own recovery path — and the
        // only one that works on Xcode Cloud's 1024-wide screens, where the
        // two panels can never coexist.
        let row2 = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'record-row-' AND identifier CONTAINS 'synth2'"
            )).firstMatch
        if !row2.waitForExistence(timeout: 3) {
            let sidebarToggle = app.descendants(matching: .any)
                .matching(identifier: "toolbar-sidebar-toggle").firstMatch
            XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
            sidebarToggle.click()
        }
        XCTAssertTrue(row2.waitForExistence(timeout: 10),
                      "The folder fixture should list a second record")
        row2.click()

        // No confirmation — instead, the one-time crash-loss disclosure.
        // Scoped to the window: alert buttons also surface as Touch Bar
        // elements, which XCUI refuses to click.
        let noticeOK = app.windows.firstMatch.buttons["OK"].firstMatch
        XCTAssertTrue(noticeOK.waitForExistence(timeout: 5),
                      "The first carrying switch should present the crash-loss notice")
        noticeOK.click()

        // The switch proceeded: second record, fresh bedside, no notes.
        let noNotes = NSPredicate(format: "label == 'no notes' OR value == 'no notes'")
        let landed = XCTNSPredicateExpectation(
            predicate: noNotes,
            object: app.descendants(matching: .any)
                .matching(identifier: "notes-drawer-stepper-readout").firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 20), .completed,
                       "The switch should land on the second record with no notes")

        // Switch back: the first record's unsaved note was carried, not lost.
        let row1 = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'record-row-' AND identifier CONTAINS 'synth.hea'"
            )).firstMatch
        XCTAssertTrue(row1.waitForExistence(timeout: 5))
        row1.click()

        // "1 note", not "1 of 1": the note count is back but nothing is
        // stepper-selected on a restore — selection is navigation state, and
        // the analyst hadn't stepped to it when they switched away.
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == '1 note' OR value == '1 note'"),
            object: app.descendants(matching: .any)
                .matching(identifier: "notes-drawer-stepper-readout").firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 20), .completed,
                       "Switching back should restore the carried unsaved note")
    }

    /// X86: the quit guard covers the whole in-memory set. The unsaved note
    /// lives on a record the analyst switched AWAY from — the open record is
    /// clean — and ⌘Q must still warn, because quitting loses the carried
    /// work just as surely as it loses on-screen work.
    @MainActor
    func testQuitWarnsAboutCarriedUnsavedNotes() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-folder=2"]
        app.launch()

        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 20))
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        if !panel.exists { contextBar.click() }
        XCTAssertTrue(panel.waitForExistence(timeout: 3))

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()
        let newNote = app.buttons.matching(identifier: "notes-drawer-new-note").firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()

        // Switch to the clean second record (see the carry test for why the
        // navigator may need requesting first).
        let row2 = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'record-row-' AND identifier CONTAINS 'synth2'"
            )).firstMatch
        if !row2.waitForExistence(timeout: 3) {
            let sidebarToggle = app.descendants(matching: .any)
                .matching(identifier: "toolbar-sidebar-toggle").firstMatch
            XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
            sidebarToggle.click()
        }
        XCTAssertTrue(row2.waitForExistence(timeout: 10))
        row2.click()

        let noNotes = NSPredicate(format: "label == 'no notes' OR value == 'no notes'")
        let landed = XCTNSPredicateExpectation(
            predicate: noNotes,
            object: app.descendants(matching: .any)
                .matching(identifier: "notes-drawer-stepper-readout").firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 20), .completed,
                       "The open record must be the clean one for this test to prove anything")

        app.typeKey("q", modifierFlags: .command)
        // NSAlert buttons; app-scoped because the alert is app-modal.
        let discard = app.buttons["Discard and Quit"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5),
                      "⌘Q with a CARRIED unsaved note should still raise the warning")
        discard.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                      "Discard and Quit should terminate the app")
    }

    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    /// X78 (#117), the open-side half: File ▸ Open Recent with an unsaved
    /// note warns; Cancel keeps the note, Discard and Open proceeds to a
    /// fresh session without it. Open Recent is the one open path XCUI can
    /// drive end-to-end — the panel-backed paths (Open Record…, Open
    /// Session…) are NSOpenPanel-modal, but all of them funnel through the
    /// same `runGuardingUnsavedNotes` choke point this exercises.
    @MainActor
    func testOpeningWithUnsavedNotesWarns() throws {
        let app = XCUIApplication()
        // The folder open records itself into Open Recent, which is what
        // gives this test its second-open affordance.
        app.launchArguments += ["--ui-test-open-folder"]
        app.launch()

        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 20))
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        if !panel.exists { contextBar.click() }
        XCTAssertTrue(panel.waitForExistence(timeout: 3))

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()
        let newNote = app.buttons.matching(identifier: "notes-drawer-new-note").firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 3))
        newNote.click()

        let readout = app.descendants(matching: .any)
            .matching(identifier: "notes-drawer-stepper-readout").firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 3))
        XCTAssertEqual(spokenName(readout), "1 of 1")

        // Drive File ▸ Open Recent ▸ <the folder just opened>.
        func clickRecentEntry() {
            let fileMenu = app.menuBarItems["File"]
            XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
            fileMenu.click()
            let openRecent = app.menuItems["Open Recent"]
            XCTAssertTrue(openRecent.waitForExistence(timeout: 3))
            openRecent.click()
            let entry = openRecent.menuItems.matching(NSPredicate(
                format: "NOT (title IN {'No Recent Records', 'Clear Menu'})"
            )).firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 3),
                          "The opened folder should appear under Open Recent")
            entry.click()
        }

        clickRecentEntry()
        // Window-scoped: the confirmation's buttons also surface as Touch
        // Bar elements XCUI refuses to click.
        let discard = app.windows.firstMatch.buttons["Discard and Open"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5),
                      "Reopening with an unsaved note should raise the confirmation")
        app.windows.firstMatch.buttons["Cancel"].firstMatch.click()

        XCTAssertTrue(readout.waitForExistence(timeout: 3))
        XCTAssertEqual(spokenName(readout), "1 of 1",
                       "Cancel must keep the note intact")

        clickRecentEntry()
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()

        // The reopen lands on a fresh session: same record, no notes.
        let noNotes = NSPredicate(format: "label == 'no notes' OR value == 'no notes'")
        let landed = XCTNSPredicateExpectation(
            predicate: noNotes,
            object: app.descendants(matching: .any)
                .matching(identifier: "notes-drawer-stepper-readout").firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 20), .completed,
                       "Discard and Open should reopen with no notes")
    }

    /// The guard's other half: no unsaved notes, no alert — a clean session
    /// quits without friction. Also catches a false-positive dirty check
    /// (a baseline bug that made every quit warn would fail here).
    @MainActor
    func testQuitWithoutNotesJustQuits() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()
        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 10))

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10),
                      "A session with no unsaved notes should quit without a warning")
    }

    /// ⌘⇧N toggles the drawer from anywhere — it dispatches through the menu,
    /// not a focus-dependent key handler (the X35/P13 lesson).
    @MainActor
    func testCommandShiftNTogglesDrawer() throws {
        let app = launchWithDrawerOpen()

        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(panel, timeout: 3),
                      "⌘⇧N should collapse the open drawer")

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(panel.waitForExistence(timeout: 3),
                      "⌘⇧N should reopen the collapsed drawer")
    }

    // MARK: - X84: right-click authoring on the trace

    /// The right-click chooser exists but its authoring items honour the
    /// Editing latch — same rule as the drawer's own buttons.
    @MainActor
    func testRightClickMenuHonorsEditingLatch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let stagePanel = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(stagePanel.waitForExistence(timeout: 10))
        stagePanel.rightClick()

        let newNoteItem = app.menuItems["bedside-context-new-note"]
        XCTAssertTrue(newNoteItem.waitForExistence(timeout: 3),
                      "Right-clicking the trace should offer a new-note item")
        XCTAssertFalse(newNoteItem.isEnabled,
                       "Note creation must stay behind the Editing latch")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Right-click creates both context-note kinds: location-marked at the
    /// clicked spot, and the location-less record note. Creation opens the
    /// drawer on the fresh note so it can be typed into immediately.
    @MainActor
    func testRightClickCreatesBothNoteKinds() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 10))
        editToggle.click()

        let stagePanel = app.descendants(matching: .any)
            .matching(identifier: "channel-panel-I").firstMatch
        XCTAssertTrue(stagePanel.waitForExistence(timeout: 5))

        // Location-marked, at the clicked time.
        stagePanel.rightClick()
        let newNoteItem = app.menuItems["bedside-context-new-note"]
        XCTAssertTrue(newNoteItem.waitForExistence(timeout: 3))
        newNoteItem.click()

        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 3),
                      "Creating from the trace should open the drawer on the fresh note")
        let readout = app.descendants(matching: .any)
            .matching(identifier: "notes-drawer-stepper-readout").firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 3))
        XCTAssertEqual(spokenName(readout), "1 of 1")

        // Location-less record note. It sorts to the head of the anchor
        // order (no anchor), so the fresh selection reads 1 of 2.
        stagePanel.rightClick()
        let recordNoteItem = app.menuItems["bedside-context-new-record-note"]
        XCTAssertTrue(recordNoteItem.waitForExistence(timeout: 3))
        recordNoteItem.click()
        let selectionIsFresh = NSPredicate(format: "label == '1 of 2' OR value == '1 of 2'")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: selectionIsFresh, object: readout)],
                timeout: 3
            ),
            .completed,
            "The record note should be created and selected (was '\(spokenName(readout))')"
        )
    }
}
