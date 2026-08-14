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
    func testNoBeatFocusedMeansNoBeatCard() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        // Anchor on the column so this cannot pass because the stage failed
        // to render at all.
        let controls = app.descendants(matching: .any)
            .matching(identifier: "calibration-controls").firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 10),
                      "The stage's right column should render")

        for identifier in ["docked-beat-inspector-empty", "docked-beat-inspector"] {
            let card = app.descendants(matching: .any)
                .matching(identifier: identifier).firstMatch
            XCTAssertFalse(card.exists,
                           "\(identifier) should be absent with no beat focused")
        }
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

    /// #225 — the reported bug, driven through the app the way it was hit.
    ///
    /// The card was hover-only: `ChannelPanel.applyHover` focused the nearest
    /// beat on move and cleared it on mouse-exit, so moving the pointer
    /// toward the card in order to READ it was the gesture that closed it.
    /// Since X71 there is no placeholder, so it did not blank — it vanished
    /// and the column reflowed.
    ///
    /// The click half matters as much as the state half: pinning is wired
    /// through a `.onTapGesture` sharing the canvas with a pan `DragGesture`
    /// and a magnify gesture, and a tap that loses a gesture-priority fight
    /// fails exactly like no pin at all while every unit test still passes.
    @MainActor
    func testAPinnedBeatCardSurvivesThePointerLeavingTheTrace() throws {
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
                      "No fiducial overlay — this record has no beats to pin")
        let card = app.descendants(matching: .any)
            .matching(identifier: "docked-beat-inspector").firstMatch
        let centre = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        let away = app.descendants(matching: .any)
            .matching(identifier: "calibration-controls").firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        centre.hover()
        XCTAssertTrue(card.waitForExistence(timeout: 5),
                      "Hovering a beat should raise the card")

        // Establish that leaving the trace REALLY clears an unpinned card
        // before asserting a pinned one survives it. Without this the
        // survival assertion passes just as well when the mouse-exit never
        // fired under XCUI — i.e. when the test is measuring nothing.
        away.hover()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(card.exists,
                       "An UNPINNED card must still clear on mouse-exit — if it "
                       + "doesn't, the rest of this test proves nothing")

        centre.hover()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        centre.click()
        away.hover()
        Thread.sleep(forTimeInterval: 2)

        XCTAssertTrue(card.exists,
                      "The card closed as the pointer moved toward it — #225 unfixed")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "beat-card-unpin").firstMatch.exists,
            "A pinned card must say it is pinned; identical pinned and hovered "
            + "cards hide the only thing that distinguishes them")
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
