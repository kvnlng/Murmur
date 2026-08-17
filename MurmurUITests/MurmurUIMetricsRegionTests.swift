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
