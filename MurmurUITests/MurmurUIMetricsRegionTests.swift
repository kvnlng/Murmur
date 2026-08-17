//
//  MurmurUIMetricsRegionTests.swift
//  MurmurUITests
//
//  The Variability Metrics region is always on screen (#291).
//
//  Reported against the plain synthetic fixture: the metrics were simply not
//  there. `VariabilityMetricsStrip` handled three states — populated,
//  insufficient-scope (X95), locked — and had no `else`, so a recording with
//  nothing measurable rendered NOTHING and the region vanished.
//
//  The bug is a HOLE, not permanent absence, which is what makes the deadline
//  below the whole test. At t=0 `summary` is nil, `insufficientScope` is nil and
//  `isLocked` is false — no branch matched, so nothing mounted until the
//  orchestrator published its first state. Measured, first branch to appear:
//
//      before the fix:  plain synth 22.3 s · synth+studio 9.3 s
//      after the fix:   both 0.5 s
//
//  A test that merely waits for the region to show up passes in BOTH regimes —
//  the first version of this suite did exactly that, and proved nothing. So
//  these assert that a branch is present PROMPTLY: for ten to twenty seconds
//  after opening a record, the analyst was looking at a bedside with no
//  Variability Metrics region at all, which is what was reported.
//
//  The invariant, stated as 12a states it: every region present at its final
//  size with values blank, never the region absent.
//

import XCTest

final class MurmurUIMetricsRegionTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Every state the strip can be in. One of these must exist, always.
    private static let branchIdentifiers = [
        "variability-metrics-strip",
        "variability-metrics-insufficient",
        "variability-metrics-unlock-seam",
        "variability-metrics-unmeasured",
    ]

    /// How long after the bedside renders the region may take to appear.
    ///
    /// Tight on purpose. Generous enough to absorb one layout pass on a loaded
    /// machine, far below the 9.3 s the fastest pre-fix case took — the
    /// difference between "mounted immediately, values blank" and "mounted once
    /// the orchestrator finishes" is the entire defect.
    private static let promptly: TimeInterval = 3

    @MainActor
    private func assertRegionPresent(_ app: XCUIApplication, fixture: String) {
        // Anchor on a surface that always mounts, so a failure here cannot be
        // "the bedside never rendered" wearing this test's name.
        let infoBar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(infoBar.waitForExistence(timeout: 30),
                      "\(fixture): the bedside should render at all")

        let deadline = Date().addingTimeInterval(Self.promptly)
        var present: String?
        repeat {
            present = Self.branchIdentifiers.first { id in
                app.descendants(matching: .any).matching(identifier: id).firstMatch.exists
            }
            if present != nil { break }
            usleep(400_000)
        } while Date() < deadline

        XCTAssertNotNil(present,
                        "\(fixture): no Variability Metrics branch on screen within "
                        + "\(Self.promptly)s of the bedside rendering. Before the fix this hole "
                        + "lasted 9–22 s, during which the region was simply missing — which is "
                        + "how it was reported, and reads as the feature being absent rather "
                        + "than as having nothing to report")
    }

    /// The reported case. No entitlement, no seeded normals — 22.3 s of nothing
    /// before the fix, 0.5 s after.
    @MainActor
    func testPlainSyntheticFixtureStillShowsTheMetricsRegion() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()
        assertRegionPresent(app, fixture: "plain synth")
    }

    /// Entitled but with nothing measurable: isolates the empty path from the
    /// locked one. The entitlement only changed how LONG the hole lasted
    /// (9.3 s vs 22.3 s), never whether there was one — which is what ruled it
    /// out as the cause.
    @MainActor
    func testEntitledButUnmeasurableRecordStillShowsTheRegion() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-grant-studio"]
        app.launch()
        assertRegionPresent(app, fixture: "synth + studio")
    }

    /// The control. Seeded normals populate the strip, so this proves the
    /// fixture CAN measure and that the tests above are not passing on a
    /// placeholder that has replaced real content.
    @MainActor
    func testSeededNormalsStillPopulateTheStrip() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-grant-studio",
                                "--ui-test-seed-atr-normals=8"]
        app.launch()
        let strip = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-strip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 30),
                      "Seeded normals should populate the strip — if this fails the "
                      + "placeholder has swallowed a case that used to work")
    }

    /// The card must not change size when the numbers arrive. 12a's rule is
    /// dimensional, not just existential: "every region present at its FINAL
    /// SIZE with values blank". A short placeholder that grows into the
    /// populated grid is the frame moving — one launch, one card, measured
    /// before and after the orchestrator publishes.
    @MainActor
    func testUnmeasuredCardHoldsTheStripsFinalSize() throws {
        // Two launches, one geometry (X100 pins the window per launch, so
        // the frames are comparable): the plain fixture holds the
        // unmeasured card stably; the seeded one populates. A single
        // seeded launch can't catch the transient unmeasured state — the
        // orchestrator publishes faster than XCUI's first query.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-grant-studio"]
        app.launch()
        let unmeasured = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-unmeasured").firstMatch
        XCTAssertTrue(unmeasured.waitForExistence(timeout: 30),
                      "the plain fixture renders the unmeasured card")
        let idleFrame = unmeasured.frame
        app.terminate()

        // 300 seeded beats → 299 intervals, above the Task Force minimum of
        // 256, so this compares the advisory-free populated rendering.
        // (Advisories are size-neutral anyway — they ride the section header
        // line — which testInsufficientScopeHoldsTheCardsSize pins.)
        let seeded = XCUIApplication()
        seeded.launchArguments += ["--ui-test-sample", "--ui-test-grant-studio",
                                   "--ui-test-seed-atr-normals=300"]
        seeded.launch()
        let strip = seeded.descendants(matching: .any)
            .matching(identifier: "variability-metrics-strip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 40),
                      "seeded normals should populate the strip")
        let populatedFrame = strip.frame

        XCTAssertEqual(idleFrame.width, populatedFrame.width, accuracy: 2,
                       "populating the card must not change its width")
        XCTAssertEqual(idleFrame.height, populatedFrame.height, accuracy: 8,
                       "populating the card must not change its height — the unmeasured "
                       + "state renders the same grid with em-dash values "
                       + "(idle \(idleFrame.height) pt vs populated \(populatedFrame.height) pt)")
    }

    /// The third state the size rule covers: narrowing to Window scope on an
    /// unmeasurable stretch (X95's insufficient branch) must not collapse the
    /// card. Reported live: "when you select window, the Variability Metrics
    /// card collapsed" — the insufficient branch still rendered the old
    /// header-plus-caption stub while the other states held the full grid.
    /// Advisories ride the section header line (they change how the numbers
    /// read, so they stay visible — but they cost no height), so parity here
    /// is strict: same grid, same size, glyphs and one warning are all that
    /// change.
    @MainActor
    func testInsufficientScopeHoldsTheCardsSize() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-grant-studio"]
        app.launch()
        let unmeasured = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-unmeasured").firstMatch
        XCTAssertTrue(unmeasured.waitForExistence(timeout: 30),
                      "the plain fixture renders the unmeasured card")
        let idleFrame = unmeasured.frame

        // Window scope over the sample fixture holds 0 normal beats — the
        // insufficient branch, reached exactly the way the analyst reaches it.
        let windowSegment = app.radioButtons["Window"].firstMatch
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(windowSegment, in: app),
                      "The scope picker's Window segment should be clickable")
        windowSegment.click()
        let insufficient = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-insufficient").firstMatch
        XCTAssertTrue(insufficient.waitForExistence(timeout: 10),
                      "Window scope with too few beats renders the insufficient card")
        let scopedFrame = insufficient.frame

        XCTAssertEqual(idleFrame.width, scopedFrame.width, accuracy: 2,
                       "switching scope must not change the card's width")
        XCTAssertEqual(idleFrame.height, scopedFrame.height, accuracy: 8,
                       "switching scope must not change the card's height — the "
                       + "insufficient state renders the same grid with its explanation "
                       + "inline on the section header, never a collapsed stub (12a). "
                       + "Unmeasured \(idleFrame.height) pt vs insufficient \(scopedFrame.height) pt")
    }

    /// The scope picker is why this matters beyond tidiness. X95's whole point
    /// was that unmounting takes the picker with it and strands the analyst in
    /// a scope they cannot leave; a placeholder without it would repeat that.
    @MainActor
    func testTheEmptyRegionKeepsTheScopePickerReachable() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-grant-studio"]
        app.launch()
        assertRegionPresent(app, fixture: "synth + studio")

        let unmeasured = app.descendants(matching: .any)
            .matching(identifier: "variability-metrics-unmeasured").firstMatch
        guard unmeasured.exists else {
            throw XCTSkip("This fixture reached a different branch; the picker is asserted "
                          + "for the empty one specifically")
        }
        XCTAssertTrue(app.radioButtons["Window"].firstMatch.exists
                      || app.radioButtons["Whole record"].firstMatch.exists,
                      "The empty region must keep the scope picker — losing it is the X95 "
                      + "failure, where the analyst had no control left to change the answer")
    }
}
