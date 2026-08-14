//
//  MurmurUIBypassTests.swift
//  MurmurUITests
//
//  Split out of MurmurUITests.swift, which had reached SwiftLint's 1000-line
//  file ceiling. The split is by intent, and was already drawn: these tests
//  all drive the app through launch-arg-driven bypasses (file picker, gesture
//  synthesis, URL launches) rather than through direct UI interaction, and
//  the class existed for that reason before it had a file of its own.
//

import AppKit
import XCTest

final class MurmurUIBypassTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tier 7: file-picker bypass (Open Folder + Drag-and-Drop)
    //
    // The synthetic `--ui-test-open-folder` launch arg materialises a WFDB
    // source folder and calls `openFolder(_:)` directly — the same path the
    // welcome screen Open button, the toolbar Open button, and the drop
    // delegate all funnel into. One test covers all three interactions
    // (the NSOpenPanel modal itself is system code we don't own).

    @MainActor
    func testLaunchArgOpenFolderLoadsRecording() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-folder"]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 15),
                      "openFolder(_:) → scanFolder → import → bedside should complete end-to-end")
    }

    /// X63-B: the flag an analyst uses to pick records for Save Session lives
    /// on the sidebar row, so the sidebar has to be reachable for the feature
    /// to exist at all. Nothing asserted the record list before this — the
    /// folder-open test above only checks that the bedside arrives.
    ///
    /// The flag appears once a record is IMPORTED (an unimported record has no
    /// `Recording` to save), so this waits on the row first and the flag after.
    @MainActor
    func testOpenFolderShowsFlaggableRecordRows() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-open-folder"]
        app.launch()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "record-row-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15),
                      "A folder open should list its records in the sidebar")

        let flag = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "record-flag-")).firstMatch
        XCTAssertTrue(flag.waitForExistence(timeout: 15),
                      "An imported record should expose the Save Session flag (X63-B)")
    }

    // MARK: - Tier 8: attach findings bypass

    @MainActor
    func testLaunchArgAttachFindingsMergesIntoPanel() throws {
        // Guards: handleAttachFindings → AnnotationLoader → attachedAnnotations
        // → BundleAnnotationsFile.write. The bypass writes a synthetic
        // sidecar JSON with one distinctive category ("ATTACH") and routes
        // it through the bedside view's attach path on appear. A new
        // finding-row-ATTACH must appear.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-attach-findings"
        ]
        app.launch()

        let attachRow = app.buttons.matching(identifier: "finding-row-ATTACH").firstMatch
        XCTAssertTrue(attachRow.waitForExistence(timeout: 10),
                      "Attached finding should land in the findings panel as finding-row-ATTACH")
    }

    // MARK: - Tier 8b: deviation-ranked review queue

    @MainActor
    func testReviewQueueGroupsCollapseByDefault() throws {
        // X65: UI-test runs now default to EXPANDED groups, so this test has
        // to ask for the shipping behaviour explicitly. It therefore asserts
        // the collapsed STATE, not the shipping DEFAULT — under XCUI the
        // default is no longer observable. That was a knowing trade (see
        // UITestSupport.shouldExpandFindingsGroups); the collapse rendering
        // is still covered, the "is it the default?" question is not.
        //
        // Guards: groups (finding-group-<category>) are visible, but their
        // child exemplar rows (finding-row-<cat>) are not — clicking the
        // group is what reveals them.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-collapse-findings-groups"
        ]
        app.launch()

        // The synthetic fixture has VT + VF categories, so at least
        // one group row must resolve.
        let vfGroup = app.buttons.matching(identifier: "finding-group-VF").firstMatch
        XCTAssertTrue(vfGroup.waitForExistence(timeout: 5),
                      "finding-group-VF should render as a collapsed group row by default")

        // The exemplar row for the same category must NOT be visible
        // before the group is expanded.
        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertFalse(vfRow.waitForExistence(timeout: 1),
                       "finding-row-VF should be hidden until the group is expanded")
    }

    @MainActor
    func testReviewQueueGroupExpandRevealsExemplars() throws {
        // Needs `--ui-test-collapse-findings-groups` because the analyst's own
        // expand click is what is being exercised, and that has to start from
        // a collapsed group (X65 made expanded the UI-test default).
        //
        // Guards: click a group → its child exemplar rows appear; click again
        // → they disappear. Load-bearing for the deviation-ranked queue's
        // semantics.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-collapse-findings-groups"
        ]
        app.launch()

        let vfGroup = app.buttons.matching(identifier: "finding-group-VF").firstMatch
        XCTAssertTrue(vfGroup.waitForExistence(timeout: 5))

        // Expand.
        vfGroup.click()
        let vfRow = app.buttons.matching(identifier: "finding-row-VF").firstMatch
        XCTAssertTrue(vfRow.waitForExistence(timeout: 3),
                      "Clicking a group row should reveal its exemplar rows")

        // Collapse.
        vfGroup.click()
        XCTAssertTrue(MurmurUITests.waitForElementToDisappear(vfRow, timeout: 3),
                      "Clicking an expanded group row should collapse it")
    }

    @MainActor
    func testReviewQueueRhythmContextBannerRendersFromHeader() throws {
        // Guards: the rhythm-context banner reads recording.headerComments
        // and surfaces them at the top of the queue. The synthetic
        // fixture writes a rhythm-flavored comment into its `.hea`, so
        // the banner must resolve. XCUI on macOS surfaces the banner's
        // inner static texts more reliably than the HStack container's
        // accessibility identifier, so probe for the "Rhythm context"
        // heading text.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let heading = app.staticTexts["Rhythm context"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5),
                      "rhythm-context banner heading should render whenever headerComments is non-empty")
    }

    // MARK: - Tier 9: canvas gesture bypass (pan + zoom + hover)

    @MainActor
    func testLaunchArgPanByShiftsViewport() throws {
        // Guards: the viewport.setStart path that drag-pan's onChanged
        // calls. Can't synthesise NSEvent.mouseDragged under XCUI, so this
        // exercises the same mutation directly via launch arg.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2",
            "--ui-test-pan-by=200"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        // Initial viewport is 0–500 (2s × 250 Hz). After pan by 200 samples
        // it should be 200–700.
        let expected = NSPredicate(format: "label == 'start=200 end=700'")
        let exp = XCTNSPredicateExpectation(predicate: expected, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport should land at 200-700 after --ui-test-pan-by=200 (was \(viewportState.label))")
    }

    @MainActor
    func testLaunchArgZoomToScalesViewportWidth() throws {
        // Guards: the viewport.setWidth path that pinch-zoom's onChanged
        // calls. MagnifyGesture is not synthesisable from XCUI on macOS.
        //
        // Test values stay under 1000 because macOS's accessibility
        // post-processor injects thousands separators into 4+ digit numbers
        // ("1750" → "1,750") regardless of the label's surrounding format.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-initial-duration=2",
            "--ui-test-zoom-to=0.4"
        ]
        app.launch()

        let viewportState = app.descendants(matching: .any)
            .matching(identifier: "ui-test-viewport-state").firstMatch
        XCTAssertTrue(viewportState.waitForExistence(timeout: 5))
        // Initial viewport is 0–500 (2s × 250 Hz). Zoom to 0.4s at anchor
        // 0.5 → 100-sample-wide window centred on sample 250 → 200–300.
        let expected = NSPredicate(format: "label == 'start=200 end=300'")
        let exp = XCTNSPredicateExpectation(predicate: expected, object: viewportState)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Viewport should land at start=200 end=300 after --ui-test-zoom-to=0.4 (was \(viewportState.label))")
    }

    @MainActor
    func testLaunchArgHoverInjectionRendersCrosshair() throws {
        // Guards: the --ui-test-hover-at injection path. Hover state itself
        // doesn't surface in XCUI's accessibility tree; the strongest check
        // we can run is "the app launched without crashing" plus a smoke
        // assertion that the bedside-view still rendered. The injection
        // path firing is verified manually via the RELEASE.md hover check.
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-test-sample",
            "--ui-test-hover-at=400,300"
        ]
        app.launch()

        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5),
                      "Bedside should still render with hover injection enabled")
    }

    // MARK: - Tier 10: Help menu — existence asserts

    @MainActor
    func testHelpMenuItemsExist() throws {
        // Cheap guard against the Help menu being unwired entirely. Doesn't
        // verify the URL each command targets — that's covered by the
        // URLLauncher tests below.
        let app = XCUIApplication()
        app.launch()

        let helpMenu = app.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 5))
        helpMenu.click()

        for title in ["Murmur Studio Help", "Getting Started",
                      "Annotation Schema", "Privacy Policy",
                      "Contact Support…"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 3),
                          "Help menu item '\(title)' should exist")
        }
        // Dismiss the menu before the next test runs.
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Tier 11: URLLauncher — URL correctness via probe

    /// Clicks a Help menu item by title with the URLLauncher recording
    /// mode enabled, then asserts the probe element echoes the expected URL.
    @MainActor
    private func assertHelpItemTargets(_ title: String, _ expectedURL: String) {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-record-urls"]
        app.launch()

        let probe = app.descendants(matching: .any)
            .matching(identifier: "ui-test-last-launched-url").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))

        let helpMenu = app.menuBarItems["Help"]
        XCTAssertTrue(helpMenu.waitForExistence(timeout: 3))
        helpMenu.click()

        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()

        let predicate = NSPredicate(format: "label == %@", expectedURL)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "URLLauncher should record \(expectedURL) for '\(title)' (was '\(probe.label)')")
    }

    @MainActor
    func testHelpMurmurStudioHelpTargetsDocsHome() throws {
        assertHelpItemTargets("Murmur Studio Help",
                              "https://kvnlng.github.io/Murmur/")
    }

    @MainActor
    func testHelpGettingStartedTargetsDocsGettingStarted() throws {
        assertHelpItemTargets("Getting Started",
                              "https://kvnlng.github.io/Murmur/getting-started.html")
    }

    @MainActor
    func testHelpAnnotationSchemaTargetsDocsAnnotationSchema() throws {
        assertHelpItemTargets("Annotation Schema",
                              "https://kvnlng.github.io/Murmur/annotation-schema.html")
    }

    @MainActor
    func testHelpPrivacyPolicyTargetsDocsPrivacy() throws {
        assertHelpItemTargets("Privacy Policy",
                              "https://kvnlng.github.io/Murmur/privacy.html")
    }

    @MainActor
    func testHelpContactSupportTargetsMailto() throws {
        assertHelpItemTargets("Contact Support…",
                              "mailto:long.kevin@gmail.com?subject=Murmur%20Studio%20Support")
    }

    @MainActor
    func testPhysioNetLinkTargetsMITBIH() throws {
        // Guards: welcome-screen PhysioNet button → URLLauncher path.
        // Different from the Help menu items because the trigger is a
        // SwiftUI Button in the WelcomeView, not a Command — which also makes
        // it the only URL test that clicks INSIDE the window rather than
        // through `app.menuItems`. What Cloud reported was a click XCUI was
        // happy with and a probe still '' three seconds later; the activation
        // mechanism in `clickInWindow` is the leading explanation for that,
        // but read its status note — it is documented and plausible, not
        // demonstrated. The scroll below is the part that is measured.
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-record-urls"]
        app.launch()

        let probe = app.descendants(matching: .any)
            .matching(identifier: "ui-test-last-launched-url").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))

        // .buttonStyle(.link) makes SwiftUI render the Button as an AppKit
        // link element, not a button — so search any descendant for the
        // identifier rather than restricting to .buttons.
        let physioNet = app.descendants(matching: .any)
            .matching(identifier: "welcome-physionet-link").firstMatch
        XCTAssertTrue(physioNet.waitForExistence(timeout: 5))
        // The link is the LAST row of the welcome card, and the card is pushed
        // down by however many recents the suite ahead of it left behind — so
        // its reach is not a constant, and on a short window it goes past the
        // fold. Scrolling first also drops the click from ~23 s to ~6 s, since
        // XCUI's own scroll-into-view runs through the hit-test stall X98
        // documents.
        XCTAssertTrue(MurmurUITests.scrollUntilHittable(physioNet, in: app),
                      "The PhysioNet link should scroll into view")
        MurmurUITests.clickInWindow(physioNet, in: app)

        let expected = "https://www.physionet.org/content/mitdb/1.0.0/"
        let predicate = NSPredicate(format: "label == %@", expected)
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "URLLauncher should record \(expected) for the PhysioNet link (was '\(probe.label)')")
    }
}
