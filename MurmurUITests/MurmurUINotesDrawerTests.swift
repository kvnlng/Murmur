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
    private func launchWithDrawerOpen() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2"
        ]
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
    @MainActor
    func testNoteRowClickJumpsViewport() throws {
        let app = launchWithDrawerOpen()

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
        newNote.click()

        // Move the trace away from the anchor: a click on the overview strip
        // recentres mid-record (lead I is the fixture's focused default).
        let ribbon = app.descendants(matching: .any)
            .matching(identifier: "overview-ribbon-I").firstMatch
        XCTAssertTrue(ribbon.waitForExistence(timeout: 3))
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
        let afterScrub = viewportState.label
        let noteRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'note-row-' AND identifier != 'note-row-hea' AND identifier != 'note-row-document'"))
            .firstMatch
        XCTAssertTrue(noteRow.waitForExistence(timeout: 3),
                      "The created note should render a list row")
        noteRow.click()

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
}
