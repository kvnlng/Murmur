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

import AppKit
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

    /// Lane rows are matched by TITLE, not identifier. Measured: with
    /// `.accessibilityIdentifier` set on the menu item, XCUI reported the
    /// item's `identifier` as empty and `menuItems["trend-lane-toggle-hr"]`
    /// as non-existent, while `title` was the label exactly. Identifiers
    /// survive on the in-window `Menu`s this suite also drives; they do not
    /// survive onto a menu-bar `NSMenuItem`. So these are the labels from
    /// `BedsideTrendStack.availableLanes` and they are load-bearing.
    private enum LaneItem {
        static let hr = "Trends · HR"
        static let beatHR = "HR · beat-derived"
        static let lfhf = "LF / HF"
    }

    /// Open View ▸ Trend Lanes.
    ///
    /// #236 moved the lane picker out of the trend stack's own header and into
    /// the menu bar. The old site was a `Menu` at the bottom of the last
    /// section of a long scrolling column: reaching it needed
    /// `scrollUntilHittable` plus `clickInWindow`, and on Cloud's 768-pt screen
    /// the dropdown still had nowhere to open — the diagnostic that shipped in
    /// #235 came back `toggles=[] total=170`, i.e. the click landed and no menu
    /// appeared. The user reproduced the same thing by hand at full resolution:
    /// the dropdown rendered underneath the Variability Metrics strip.
    ///
    /// Anywhere inside the window has an edge somewhere. The menu bar does not,
    /// which is also the pattern behind every menu-driven test in this suite
    /// staying green (X22 hoisted the navigation keys there for the same class
    /// of reason).
    @MainActor
    private func openLanesMenu(_ app: XCUIApplication) {
        // ONE View menu, not two. `CommandMenu("View")` was the obvious
        // spelling and it is wrong — SwiftUI already synthesises a View menu
        // for the toolbar, so the bar read `Edit | View | View | Navigate`
        // and this subscript failed with "Multiple matching elements found".
        // The app now appends via `CommandGroup(after: .toolbar)`; the
        // assertion below is what catches a regression back to two.
        let views = app.menuBarItems.matching(identifier: "View")
        XCTAssertTrue(app.menuBarItems["View"].waitForExistence(timeout: 10),
                      "#236 put the lane picker in the menu bar — the View menu should exist")
        XCTAssertEqual(views.count, 1,
                       "Exactly one View menu; a second means someone re-added CommandMenu(\"View\")")
        app.menuBarItems["View"].click()
    }

    /// What XCUI can see with the Lanes menu open, as one line.
    ///
    /// DIAGNOSTIC, not a guard. Kept from #236's in-window era because it is
    /// the only channel out of Cloud: the check-run `output.text` that Xcode
    /// Cloud publishes to GitHub carries failure messages and nothing else. It
    /// is an `@autoclosure`, so none of this runs unless the assertion fails.
    ///
    /// Three-way discriminator:
    ///   - `items=[]` → the View menu never opened
    ///   - items listed without the lane asked for → that lane has no row,
    ///     i.e. `availableTrendLanes` didn't offer it
    ///   - the title is present but the assertion failed → XCUI sees it and
    ///     cannot resolve it by subscript, i.e. reachability, not existence
    @MainActor
    private static func menuInventory(_ app: XCUIApplication) -> String {
        let items = app.menuBarItems["View"].menus.firstMatch
            .menuItems.allElementsBoundByIndex
            .map(\.title)
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        let screen = NSScreen.main.map { "\(Int($0.frame.height))pt (visible \(Int($0.visibleFrame.height))pt)" }
            ?? "unknown"
        return "items=[\(items)] window=\(app.windows.firstMatch.frame) screen=\(screen)"
    }

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

        openLanesMenu(app)

        let toggle = app.menuItems[LaneItem.hr]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "The Lanes menu should offer the HR lane — " + Self.menuInventory(app))
        toggle.click()

        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(hrLane, timeout: 5),
                      "Switching a lane off should remove its row from the stack")
    }

    /// X76 wire-up: the injected series carries the exact value 1.50 in every
    /// window, so this asserts the RENDERED value column equals it — catching
    /// a binding slip between `RollingLFHFContext` and the screen that a
    /// green unit suite would miss (the X52 §5 pattern).
    ///
    /// Pinned to 1220×678 — what X100's no-flag default RESOLVES to on Cloud's
    /// 1280×768 VMs. Kept after #236 even though the picker moved to the menu
    /// bar and the geometry no longer decides whether this test can reach it:
    /// a short window is the regime where a lane row is most likely to be
    /// squeezed out of the stack entirely, and that is what the value
    /// assertion above is for. The 678 also documents the size Cloud actually
    /// runs, which nothing else in this file records.
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
        openLanesMenu(app)
        XCTAssertTrue(app.menuItems[LaneItem.lfhf].waitForExistence(timeout: 5),
                      "The Lanes menu should offer LF / HF when the series exists — "
                      + Self.menuInventory(app))
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
        // #236 was reported against THIS assertion. The picker now lives in
        // the menu bar, so there is no scroll and no in-window click left to
        // swallow: the diagnostic below stays only to name the failure if the
        // lane itself stops being offered.
        openLanesMenu(app)
        XCTAssertTrue(app.menuItems[LaneItem.beatHR].waitForExistence(timeout: 5),
                      "The Lanes menu should offer the beat-derived HR lane — "
                      + Self.menuInventory(app))
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
