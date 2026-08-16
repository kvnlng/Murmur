//
//  MurmurUIStageColumnTests.swift
//  MurmurUITests
//
//  X71 — the stage's right column.
//
//  The change worth guarding is a REMOVAL: the focus-beat readout no longer
//  keeps a placeholder card on screen when nothing is focused. An absence is
//  easy to break silently — a merge that restores the empty state would pass
//  every existing test, because they only ever asserted presence.
//

import XCTest

final class MurmurUIStageColumnTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    @MainActor
    /// #246 inverted this test's subject. It used to pin X71's "no empty
    /// state" — card absent until focus. TestFlight reversed that: the card
    /// is always mounted, and no-focus is a STATE it shows (the revived
    /// `docked-beat-inspector-empty`), not an absence.
    func testNoBeatFocusedShowsThePlaceholderCard() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        // Anchor on the column so this cannot pass because the stage failed
        // to render at all.
        let controls = app.descendants(matching: .any)
            .matching(identifier: "calibration-controls").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 10),
                      "The stage's right column should render")

        let card = app.descendants(matching: .any)
            .matching(identifier: "docked-beat-inspector").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5),
                      "#246: the beat card must be mounted before any beat is focused")
        let placeholder = app.descendants(matching: .any)
            .matching(identifier: "docked-beat-inspector-empty").firstMatch
        XCTAssertTrue(placeholder.exists,
                      "With no beat focused the card must say so in its status line")
    }

    /// The keyboard hint moved here from the retired `summaryHeader`. Without
    /// it the shortcuts would exist only in the menu bar, and the retirement
    /// would have quietly cost the stage its only on-screen mention of them.
    @MainActor
    func testColumnCarriesTheKeyboardHint() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let hint = app.descendants(matching: .any)
            .matching(identifier: "stage-keyboard-hint").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10),
                      "The right column should carry a keyboard hint")
        let spoken = spokenName(hint)
        XCTAssertTrue(spoken.contains("J") && spoken.contains("K"),
                      "The hint should name the finding-jump keys, got '\(spoken)'")
    }

    /// The pieces both beat-card tests need.
    ///
    /// Since #246 the card is ALWAYS mounted — it holds its frame and shows an
    /// empty state rather than unmounting — so `docked-beat-inspector` exists
    /// unconditionally and asserting on it proves nothing. The placeholder is
    /// the whole signal: `docked-beat-inspector-empty` shows exactly when no
    /// beat is focused, so "the card is showing readings" is its ABSENCE.
    private struct BeatCardStage {
        let placeholder: XCUIElement
        let onBeat: XCUICoordinate
        let offTrace: XCUICoordinate
    }

    @MainActor
    private func launchBeatCardStage() -> BeatCardStage {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample-rich=two-morphology",
                                "--ui-test-grant-studio"]
        app.launch()

        // Zoom in first. Above the Inspect tier `FiducialRenderPolicy` draws
        // no marks at all, so the overlay renders `EmptyView` and there is
        // nothing on the canvas to address — the app opens wider than that.
        let zoom = app.descendants(matching: .any)
            .matching(identifier: "zoom-ladder-2s").firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 30), "No 2 s zoom step")
        zoom.click()

        let overlay = app.descendants(matching: .any)
            .matching(identifier: "fiducial-overlay").firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 20),
                      "No fiducial overlay — this record has no beats to read")

        return BeatCardStage(
            placeholder: app.descendants(matching: .any)
                .matching(identifier: "docked-beat-inspector-empty").firstMatch,
            onBeat: overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
            offTrace: app.descendants(matching: .any)
                .matching(identifier: "calibration-controls").firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }

    /// Readings follow the pointer: they arrive on a beat and leave with it.
    ///
    /// The second half is an invariant, not a courtesy — readings on screen
    /// with nothing pinned and the pointer off the trace are readings for a
    /// beat nobody is pointing at. It is also what makes the pin test below
    /// mean anything: that test reads "the data stayed", which only implicates
    /// the pin if data does NOT stay on its own.
    @MainActor
    func testABeatsReadingsArriveOnHoverAndLeaveWithIt() throws {
        let stage = launchBeatCardStage()

        stage.onBeat.hover()
        XCTAssertTrue(stage.placeholder.waitForNonExistence(timeout: 5),
                      "Hovering a beat must raise its readings — the card stayed empty")

        stage.offTrace.hover()
        XCTAssertTrue(stage.placeholder.waitForExistence(timeout: 5),
                      "Readings are up with nothing pinned and the pointer off the "
                      + "trace — they belong to a beat nobody is pointing at")
    }

    /// #225 — the reported bug, driven through the app the way it was hit.
    ///
    /// The card was hover-only: `ChannelPanel.applyHover` focused the nearest
    /// beat on move and cleared it on mouse-exit, so moving the pointer toward
    /// the card in order to READ it was the gesture that closed it. Under X71
    /// there was no placeholder, so it did not blank — it vanished and the
    /// column reflowed. #246 has since restored the placeholder and pinned the
    /// card's frame, so the fault now shows as the card emptying instead.
    ///
    /// The click half matters as much as the state half: pinning is wired
    /// through a `.onTapGesture` sharing the canvas with a pan `DragGesture`
    /// and a magnify gesture, and a tap that loses a gesture-priority fight
    /// fails exactly like no pin at all while every unit test still passes.
    @MainActor
    func testAPinnedBeatCardSurvivesThePointerLeavingTheTrace() throws {
        let stage = launchBeatCardStage()

        stage.onBeat.hover()
        XCTAssertTrue(stage.placeholder.waitForNonExistence(timeout: 5),
                      "Hovering a beat must raise its readings before they can be pinned")
        stage.onBeat.click()

        stage.offTrace.hover()
        // A settle is unavoidable: the assertion is that something does NOT
        // appear, so there is no positive event to wait on. The hover test
        // bounds how long the same exit takes to clear an unpinned card.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(stage.placeholder.exists,
                       "The pinned beat's readings gave way to the placeholder "
                       + "as the pointer left — #225 unfixed")
    }

    /// X28's elapsed / wall-clock switch was honoured by exactly one surface,
    /// `viewportIndicator`, which X71 deleted after X69 moved the window range
    /// to the info bar. This guards that the info bar carries the switch
    /// rather than having silently dropped wall-clock from the app.
    @MainActor
    func testInfoBarWindowRangeStatesTheRecordTotal() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))

        let spoken = spokenName(bar)
        XCTAssertTrue(spoken.contains("window"),
                      "Info bar should name the window, got '\(spoken)'")
        // "of <total>" came across with the retired indicator. Without it the
        // window range says where you are but not what it is out of.
        XCTAssertTrue(spoken.contains(" of "),
                      "Info bar should state the window against the record total, got '\(spoken)'")
    }
}
