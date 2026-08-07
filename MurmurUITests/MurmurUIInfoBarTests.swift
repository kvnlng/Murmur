//
//  MurmurUIInfoBarTests.swift
//  MurmurUITests
//
//  X69 — the window's bottom rail.
//
//  The interesting half of this region is not that it renders; it is that two
//  of its fields were previously unreachable from outside the render path. The
//  zoom tier and points-per-beat lived in `ChannelPanel`'s private `@State`,
//  and the resolved level-of-detail lived inside `WaveformCanvas.Coordinator`,
//  which SwiftUI owns. So the assertions worth writing are the ones that prove
//  those numbers arrive and then CHANGE when the trace changes — an info bar
//  that reports a stale LOD forever would pass any existence check.
//

import XCTest

final class MurmurUIInfoBarTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func spokenName(_ element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return (element.value as? String) ?? ""
    }

    @MainActor
    func testInfoBarStatesTheRecordsFacts() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10),
                      "The window should carry an info bar")

        // Assert CONTENT. An element that exists but announces nothing passes
        // an existence check and tells a VoiceOver user nothing — and a
        // `Text` on macOS surfaces its string as the accessibility value, not
        // the label, which is why this reads both.
        let spoken = spokenName(bar)
        XCTAssertTrue(spoken.contains("lead"),
                      "Info bar should name the lead count, got '\(spoken)'")
        XCTAssertTrue(spoken.contains("Hz"),
                      "Info bar should name the sample rate, got '\(spoken)'")
        XCTAssertTrue(spoken.contains("samples/lead"),
                      "Info bar should name the sample count, got '\(spoken)'")
        XCTAssertTrue(spoken.contains("window"),
                      "Info bar should name the current window, got '\(spoken)'")
    }

    /// The synthetic fixture carries no base date/time, so there is no start
    /// instant to state — and the honest rendering of that is silence, not the
    /// retired `summaryDetail`'s "no absolute start time", which spent a field
    /// announcing an absence.
    @MainActor
    func testInfoBarSaysNothingAboutAStartTimeTheRecordDoesNotHave() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))

        let spoken = spokenName(bar)
        XCTAssertFalse(spoken.contains("starts"),
                       "A record with no absolute start must not claim one, got '\(spoken)'")
        XCTAssertFalse(spoken.lowercased().contains("no absolute"),
                       "An absent start time is stated by omission, not announced")
    }

    /// The render-state plumbing, end to end.
    ///
    /// Zooming changes points-per-beat, which can cross a tier boundary and
    /// change the LOD the canvas resolves. This asserts the info bar's text
    /// actually MOVES — the plumbing could publish once at mount and never
    /// again, and every existence check would still pass.
    @MainActor
    func testInfoBarTracksTheTraceAsItZooms() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-initial-duration=2"]
        app.launch()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "info-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))

        // Wait for the first resolved frame — the tier is published from a
        // `.task`, so it is not there at mount.
        let hasTier = NSPredicate(format: "value CONTAINS[c] 'zoom tier' OR label CONTAINS[c] 'zoom tier'")
        let tierArrived = XCTNSPredicateExpectation(predicate: hasTier, object: bar)
        XCTAssertEqual(XCTWaiter.wait(for: [tierArrived], timeout: 10), .completed,
                       "Info bar should report the zoom tier once the trace has drawn a frame")

        let before = spokenName(bar)

        // Zoom out repeatedly. `-` is the bedside zoom-out key.
        app.typeKey("-", modifierFlags: [])
        app.typeKey("-", modifierFlags: [])
        app.typeKey("-", modifierFlags: [])

        let changed = NSPredicate(format: "value != %@ AND label != %@", before, before)
        let moved = XCTNSPredicateExpectation(predicate: changed, object: bar)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed,
                       "Info bar should follow the trace as it zooms; stayed at '\(before)'")
    }
}
