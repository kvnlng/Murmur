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

    /// Launch arguments that pin the Context drawer SHUT.
    ///
    /// Handled in app code (`UITestSupport.shouldCollapseContextDrawer`), the
    /// same way X65 pinned the review queue's group state — the drawer renders
    /// closed regardless of what `@AppStorage` inherited from an earlier test
    /// or a developer's manual session. No click, no animation, no waiting for
    /// an unmount.
    ///
    /// **The obvious shortcut is a trap.** Passing `-murmur.notesDrawerExpanded
    /// NO` puts the value in `UserDefaults`' argument domain, which outranks
    /// the app domain and needs no production change at all. It also breaks
    /// this suite: with `MurmurUINotesDrawerTests` running first, the injected
    /// beat and LF/HF lanes stop rendering entirely and the tests fail on lane
    /// EXISTENCE, twenty seconds of waiting apiece. Isolated to the argument
    /// alone — unmodified helper code, one added launch argument, reproducible.
    /// Root cause not established; the flag below sidesteps it. Do not
    /// "simplify" this back.
    ///
    /// **Why this replaced a helper that clicked the bar shut.** These tests
    /// do not care whether the drawer works; they need it OUT OF THE WAY so
    /// the Lanes menu is reachable. The old `collapseContextDrawer` collapsed
    /// it by hand and asserted the unmount, which made a setup step fail as
    /// though it were the subject — three Cloud builds reported "Collapsing
    /// the Context bar should unmount the drawer" when the actual casualty was
    /// a beat-rate assertion 200 lines further down that never got to run.
    ///
    /// Worse, it was not deterministic. The helper opened with
    /// `guard panel.exists else { return }`, and the drawer's state was
    /// inherited from whatever ran before — `MurmurUINotesDrawerTests` leaves
    /// it open and sorts earlier. So a given build might exercise the click
    /// path or skip it entirely, and the two are indistinguishable in the
    /// report. Builds that looked like controlled experiments were not:
    /// identical helper code passed on one Cloud run and failed on the next.
    ///
    /// Drawer open/close has its own coverage, where it belongs —
    /// `MurmurUINotesDrawerTests.testCommandShiftNTogglesDrawer` and
    /// `launchWithDrawerOpen`. It does not need a second, accidental home
    /// here.
    private static let drawerShut = ["--ui-test-context-drawer-collapsed"]

    /// The drawer really is shut. Cheap, and it fails HERE — naming the
    /// precondition — rather than fifty lines later as an unreachable menu.
    @MainActor
    private func assertContextDrawerShut(_ app: XCUIApplication) {
        let panel = app.descendants(matching: .any)
            .matching(identifier: "context-panel").firstMatch
        XCTAssertFalse(panel.exists,
                       "`drawerShut` should have pinned the Context drawer closed at launch — "
                       + "an open drawer pushes the stack's bottom chrome past the fold")
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
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=1000x600"] + Self.drawerShut
        app.launch()
        ensureTrendStackExpanded(app)

        let hrLane = app.descendants(matching: .any)
            .matching(identifier: "trend-lane-hr").firstMatch
        XCTAssertTrue(hrLane.waitForExistence(timeout: 20))
        assertContextDrawerShut(app)

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
                                "--ui-test-window=1220x678"] + Self.drawerShut
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
        assertContextDrawerShut(app)
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
                                "--ui-test-window=1220x678"] + Self.drawerShut
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
        assertContextDrawerShut(app)
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
        app.launchArguments += ["--ui-test-sample", "--ui-test-window=1000x600"] + Self.drawerShut
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "trend-stack-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        assertContextDrawerShut(app)

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
