//
//  MurmurUITrendStackTests.swift
//  MurmurUITests
//
//  X74 — the shared-axis trend stack.
//
//  What XCUI can reach: that the lanes exist, that the caption names its
//  populations, and that the Lanes menu removes a row. What it cannot reach is
//  the thing the ticket is actually about — whether every lane maps the same
//  instant to the same x — because a Swift Charts lane and a `Canvas` expose
//  nothing about what they painted. That was verified against pixels on the
//  synthetic fixture (HR + quality on one axis) and on NSRDB 16265 at 25.5 h.
//
//  So the assertion that earns its place here is the ABSENCE test: the stack
//  renders nothing at all if its loading task never runs, and that failure
//  looks exactly like "this record has no lanes".
//

import XCTest

final class MurmurUITrendStackTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    /// X85 made the whole stack foldable behind `@AppStorage`, so every test
    /// that asserts lane CONTENT inherits whatever fold state the container
    /// last persisted — the X72 lesson, again: a suite run that starts with
    /// the stack folded fails every lane assertion that runs before the fold
    /// test happens to heal the state. Drive to expanded first, the same way
    /// `testHeaderBarFoldsTheStackWhole` always has.
    @MainActor
    private func ensureTrendStackExpanded(_ app: XCUIApplication, timeout: TimeInterval = 20) {
        let bar = app.descendants(matching: .any)
            .matching(identifier: "trend-stack-bar").firstMatch
        // No stack chrome at all — let the test's own assertion say so.
        guard bar.waitForExistence(timeout: timeout) else { return }
        let stack = app.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        if stack.waitForExistence(timeout: 3) { return }
        _ = MurmurUITests.scrollUntilHittable(bar, in: app)
        bar.click()
        _ = stack.waitForExistence(timeout: 3)
    }

    /// The Context drawer's expansion is `@AppStorage`, so whatever the last
    /// run (or a developer's manual session) left behind is what this test
    /// inherits — and an expanded drawer pushes the Lanes menu below the
    /// fold, where XCUI reports it "not hittable". Tests that CLICK stack
    /// chrome collapse the drawer first; existence-only tests don't care.
    ///
    /// #231, and the reason it is CI-shaped: `murmur.notesDrawerExpanded`
    /// DEFAULTS TO FALSE, so on a clean machine `panel.exists` is false and
    /// this whole body returns early without clicking anything. The path only
    /// executes when an earlier test in the same run left the drawer open —
    /// `MurmurUINotesDrawerTests` does, and it sorts before this file. Running
    /// the trend-stack tests alone, which is what local debugging does, skips
    /// the code CI fails in. Reproduce with:
    ///
    ///     defaults write com.kevinlong.murmur murmur.notesDrawerExpanded -bool true
    ///
    /// (Done. The path then runs, and passes, on a developer machine — so the
    /// suite-order dependency explains the local/CI split but is not by itself
    /// the fault.)
    @MainActor
    private func collapseContextDrawer(_ app: XCUIApplication) {
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        guard panel.exists else { return }
        let contextBar = app.descendants(matching: .any)
            .matching(identifier: "context-bar").firstMatch
        XCTAssertTrue(contextBar.waitForExistence(timeout: 5))
        // The bar rides the same scrolling context as the stack, and callers
        // arrive here AFTER `ensureTrendStackExpanded` may have scrolled the
        // stack into view — which carries the bar off the TOP of the
        // viewport. Clicking a scrolled-out element doesn't error on macOS:
        // XCUI resolves a hit point outside the window, the click lands
        // nowhere, and the drawer just stays open — which is exactly how this
        // presented on Cloud's short display, as a bare "Collapsing the
        // Context bar should unmount the drawer" with no click error above it.
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(contextBar, in: app),
                      "The Context bar should scroll into view before it is clicked")
        // Activation, and it is the one variable this build changes.
        //
        // The previous build settled #231's timeout hypothesis by killing it:
        // raised to 10 s, the drawer STILL had not unmounted. Ten seconds is
        // not slowness, it is "never" — the collapse is not happening at all,
        // so the click is not landing.
        //
        // What promotes activation from plausible to likely is the other half
        // of that same build: #232's recents row, whose ONLY change was
        // `clickInWindow`, went green. That is the in-window-click-swallowed
        // mechanism demonstrated on Cloud hardware rather than merely quoted
        // from `MurmurUIPurchaseTests` — and this bar is the one site the
        // guard was deliberately stripped from when the experiment was cut to
        // one variable per test. Same signature, same runner, now with a
        // worked example next door.
        MurmurUITests.clickInWindow(contextBar, in: app)
        // Left at 10 s ON PURPOSE, though hypothesis 3 is dead. Reverting it
        // to 3 s would change two things at once; and since 10 s alone has
        // already been shown insufficient, it cannot be credited if this
        // passes. Attribution stays clean. Fold it back to 3 s once activation
        // is confirmed.
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(panel, timeout: 10),
                      "Collapsing the Context bar should unmount the drawer")
    }

    /// The fixture carries `HR_bpm` and `ecg_artifact_ratio`, so both
    /// whole-record lanes must appear. This is the regression guard for the
    /// deadlock found during X74's pixel pass: the load task hung off a view
    /// that only existed once loading had succeeded, so no samples ever
    /// loaded, so the stack rendered empty — and every existence assertion
    /// simply found nothing, which reads as "no lanes in this record".
    @MainActor
    func testStackRendersItsWholeRecordLanes() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()
        ensureTrendStackExpanded(app)

        let stack = app.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 20),
                      "A record with trend and quality channels should carry a trend stack")

        for lane in ["hr", "quality"] {
            let row = app.descendants(matching: .any)
                .matching(identifier: "trend-lane-\(lane)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5),
                          "The \(lane) lane should render — an empty stack is how the load deadlock presents")
        }
    }

    /// Provenance travels with the numbers. The lanes come from different
    /// channels at different rates, and a stack that looks like one chart
    /// invites the assumption that it is one.
    @MainActor
    func testCaptionNamesEachLanesSource() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()
        ensureTrendStackExpanded(app)

        let caption = app.descendants(matching: .any)
            .matching(identifier: "trend-stack-caption").firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 20),
                      "The stack should carry a provenance caption")

        let spoken = spokenName(caption)
        XCTAssertTrue(spoken.contains("HR_bpm"),
                      "Caption should name the HR channel, got '\(spoken)'")
        XCTAssertTrue(spoken.contains("ecg_artifact_ratio"),
                      "Caption should name the quality channel, got '\(spoken)'")
        XCTAssertTrue(spoken.contains("one axis"),
                      "Caption should state the shared span, got '\(spoken)'")
    }

    /// The Lanes menu removes a row. Asserted by disappearance rather than by
    /// the menu's checkmark: a menu that toggles its own state while the stack
    /// ignores it would pass any check on the menu alone.
    ///
    /// Runs in a FORCED SHORT WINDOW: this test failed "not hittable" on
    /// Xcode Cloud's 1024×768 VMs, where the production minimum window can't
    /// fit the screen and the stack's bottom chrome hangs off it. With
    /// WindowSizing capping the minimum under XCUI runs the window fits; the
    /// forced size reproduces that regime on every machine so the regression
    /// can't reach CI unseen.
    @MainActor
    func testLanesMenuRemovesALane() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=1000x600"]
        app.launch()
        ensureTrendStackExpanded(app)

        let hrLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-hr").firstMatch
        XCTAssertTrue(hrLane.waitForExistence(timeout: 20))
        collapseContextDrawer(app)

        let menu = app.descendants(matching: .any)
            .matching(identifier: "trend-lanes-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // Short window: the trend stack sits past the fold of the scrolling
        // context — bring it into view the way an analyst would.
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(menu, in: app),
                      "The Lanes menu never became clickable, even after scrolling the stack into view")
        MurmurUITests.clickInWindow(menu, in: app)

        let toggle = app.menuItems["trend-lane-toggle-hr"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "The Lanes menu should offer the HR lane")
        toggle.click()

        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(hrLane, timeout: 5),
                      "Switching a lane off should remove its row from the stack")
    }

    /// X76 wire-up: the injected series carries the exact value 1.50 in every
    /// window, so this asserts the RENDERED value column equals it — catching
    /// a binding slip between `RollingLFHFContext` and the screen that a
    /// green unit suite would miss (the X52 §5 pattern).
    ///
    /// Forced short window, like `testLanesMenuRemovesALane` — but pinned to
    /// 1220×678, NOT that test's 1000×600. Measured, because the two sizes do
    /// NOT behave alike and the intuitive one is the wrong one: at 1000×600
    /// the Lanes menu is reachable and this test passes with no scroll at all,
    /// which is why its 1000×600 sibling has always been green on Cloud while
    /// this one was not. 1220×678 is what X100's no-flag default RESOLVES to
    /// on Cloud's 1280×768 VMs, and it reproduces the CI failure verbatim on a
    /// developer display: "Not hittable: MenuButton … 'trend-lanes-menu'",
    /// frame at y=786 in a 678-pt window.
    @MainActor
    func testLFHFLaneRendersInjectedSeries() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-inject-lfhf-lane",
                                "--ui-test-window=1220x678"]
        app.launch()
        ensureTrendStackExpanded(app)

        let lane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-lfhf").firstMatch
        XCTAssertTrue(lane.waitForExistence(timeout: 20),
                      "The injected LF/HF series should render its lane")

        let value = lane.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == '1.50' OR value == '1.50'"))
            .firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5),
                      "The lane's value column should render the injected 1.50")

        // The Lanes menu offers the lane once the series exists.
        collapseContextDrawer(app)
        let menu = app.descendants(matching: .any)
            .matching(identifier: "trend-lanes-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        // Bottom-of-stack chrome on a short display: existence is not reach.
        // Omitting this is what failed on Cloud ("Not hittable: MenuButton …
        // identifier: 'trend-lanes-menu'"), and the injected LF/HF lane makes
        // it worse by growing the stack a row taller than the fold allows.
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(menu, in: app),
                      "The Lanes menu should scroll into view")
        MurmurUITests.clickInWindow(menu, in: app)
        XCTAssertTrue(app.menuItems["trend-lane-toggle-lfhf"].waitForExistence(timeout: 5),
                      "The Lanes menu should offer LF / HF when the series exists")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The paid gate, from the free side: with no entitlements the series is
    /// never computed, so the lane must be absent. Anchored on the quality
    /// lane so this can't pass simply because the stack failed to load.
    @MainActor
    func testFreeViewerNeverShowsLFHFLane() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-no-entitlements"]
        app.launch()
        ensureTrendStackExpanded(app)

        let qualityLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-quality").firstMatch
        XCTAssertTrue(qualityLane.waitForExistence(timeout: 20),
                      "The quality lane should render — without it this test proves nothing")

        let lfhfLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-lfhf").firstMatch
        XCTAssertFalse(lfhfLane.exists,
                       "The free viewer must never render the LF/HF measurement lane")

        // X89: beat-derived HR rides the delineator's beats, which are
        // Studio-gated — the free viewer must not carry the lane either.
        let beatHRLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-hr-beats").firstMatch
        XCTAssertFalse(beatHRLane.exists,
                       "The free viewer must never render the beat-derived HR lane")
    }

    /// X89 wire-up, the X52 §5 pattern: the injected fiducial store carries
    /// 30 beats at a uniform 800 ms R–R — exactly 75.0 bpm — so this asserts
    /// the RENDERED value column equals the computed rate, catching a
    /// binding slip between `BeatHeartRateSeries` and the screen that a
    /// green unit suite would miss.
    ///
    /// Pinned to Cloud's resolved default (1220×678), for the reason spelled
    /// out on `testLFHFLaneRendersInjectedSeries`. This test clicks both the
    /// Context bar and the Lanes menu, and injects two lanes on top of the
    /// fixture's own — the tallest stack any of these tests build.
    @MainActor
    func testBeatDerivedHRLaneRendersComputedRate() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-inject-qtc-lane=455",
                                "--ui-test-window=1220x678"]
        app.launch()
        ensureTrendStackExpanded(app)

        let lane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-hr-beats").firstMatch
        XCTAssertTrue(lane.waitForExistence(timeout: 20),
                      "Published beats should produce the beat-derived HR lane")

        let value = lane.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == '75.0' OR value == '75.0'"))
            .firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5),
                      "800 ms R–R must render as exactly 75.0 bpm in the value column")

        // The Lanes menu offers the lane once beats exist.
        collapseContextDrawer(app)
        let menu = app.descendants(matching: .any)
            .matching(identifier: "trend-lanes-menu").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(menu, in: app),
                      "The Lanes menu should scroll into view")
        // #236. Hittability is already handled by the scroll above and it
        // passes — the click reaches the element and the menu does not open,
        // which is the in-window-click-swallowed signature for the third time
        // on this runner (#232 and #231 both went green on activation alone).
        //
        // These sites briefly had this guard: added in #233, reverted in #234
        // as speculative spread, because they were not failing and activation
        // had no evidence behind it then. That call was right on the evidence
        // available — unevidenced guards are what made #233 unreadable — but
        // it queued this failure up behind #231 instead of clearing both at
        // once. A build cycle traded for a definitive answer.
        MurmurUITests.clickInWindow(menu, in: app)
        XCTAssertTrue(app.menuItems["trend-lane-toggle-hr-beats"].waitForExistence(timeout: 5),
                      "The Lanes menu should offer the beat-derived HR lane")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// X85: the header bar folds the stack whole, like the Context drawer —
    /// and unfolds it again.
    @MainActor
    func testHeaderBarFoldsTheStackWhole() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=1000x600"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "trend-stack-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        collapseContextDrawer(app)

        let stack = app.descendants(matching: .any)
            .matching(identifier: "trend-stack").firstMatch
        // Drive to a known state first — the fold is @AppStorage, so this
        // test inherits whatever a previous run left behind (the X72
        // lesson: never blind-toggle persisted state).
        if !stack.exists {
            XCTAssertTrue(MurmurUITests.scrollUntilHittable(bar, in: app))
            bar.click()
            XCTAssertTrue(stack.waitForExistence(timeout: 3),
                          "Unfolding from a persisted-folded state should mount the stack")
        }

        XCTAssertTrue(MurmurUITests.scrollUntilHittable(bar, in: app),
                      "The trend-stack bar should scroll into view")
        bar.click()
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(stack, timeout: 3),
                      "Clicking the bar should fold the stack whole")
        bar.click()
        XCTAssertTrue(stack.waitForExistence(timeout: 3),
                      "Clicking the bar again should unfold the stack")
    }
}
