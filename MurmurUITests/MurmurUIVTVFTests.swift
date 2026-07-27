//
//  MurmurUIVTVFTests.swift
//  MurmurUITests
//
//  XCUI wire-up coverage for the VT/VF candidate review flow. The scan
//  itself needs Core ML + a VT-like fixture, so these tests use the
//  `--ui-test-vtvf-candidates` bypass: it grants the VT/VF IAP and injects
//  a fixed candidate set into VTVFScanContext — the same state a committed
//  scan produces — so the queue integration, the entitlement gate, and the
//  region-keyed disposition wire-up are assertable without running the
//  model in-process.
//
//  The disposition-SURVIVAL rule (a rescan re-derives candidates but keeps
//  the analyst's calls) is proven by the unit tests over
//  VTVFCandidateDispositionStore; here we prove the panel actually ROUTES
//  a confirm/dismiss into that store and reflects it — the wire-up the
//  flow spec says can't be checked by unit tests alone.
//

import XCTest

final class MurmurUIVTVFTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithCandidates() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-vtvf-candidates"]
        app.launch()
        return app
    }

    // MARK: - Entitlement gate

    /// With the VT/VF IAP owned, the scan toolbar action surfaces.
    @MainActor
    func testScanActionVisibleWhenEntitled() throws {
        let app = launchWithCandidates()
        let scanAction = app.descendants(matching: .any)
            .matching(identifier: "vtvf-scan-action").firstMatch
        XCTAssertTrue(scanAction.waitForExistence(timeout: 5),
                      "Scan action should appear once the VT/VF IAP is owned")
    }

    /// The free viewer (no IAP) must never see the scan action — the model
    /// is never implied to be present.
    @MainActor
    func testScanActionHiddenWithoutEntitlement() throws {
        let app = XCUIApplication()
        // `--ui-test-no-entitlements` guarantees a hermetic free viewer: it
        // stops PurchaseStore from adopting any StoreKit-test transaction a
        // developer may have persisted locally, so this gate assertion can't
        // be broken by ambient machine state (it would still pass on a clean
        // CI runner, but this makes it deterministic everywhere).
        app.launchArguments += ["--ui-test-sample", "--ui-test-no-entitlements"]
        app.launch()

        // Wait for the bedside so the toolbar has mounted.
        let bedside = app.descendants(matching: .any)
            .matching(identifier: "bedside-view").firstMatch
        XCTAssertTrue(bedside.waitForExistence(timeout: 5))

        let scanAction = app.descendants(matching: .any)
            .matching(identifier: "vtvf-scan-action").firstMatch
        XCTAssertFalse(scanAction.waitForExistence(timeout: 1),
                       "Scan action must not appear in the free viewer")
    }

    // MARK: - WFDB export

    /// End-to-end: confirming a candidate and exporting writes exactly the
    /// confirmed finding to the `.mur` annotator. The count routes through the
    /// amber filter and the byte writer, so only an XCUI assertion on the
    /// exposed result proves the plumbing (snapshot/unit tests can't reach it).
    @MainActor
    func testWFDBExportWritesConfirmedFinding() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-test-sample", "--ui-test-export-wfdb"]
        app.launch()

        let leaf = app.descendants(matching: .any)
            .matching(identifier: "ui-test-wfdb-export").firstMatch
        XCTAssertTrue(leaf.waitForExistence(timeout: 5))

        let expected = NSPredicate(format: "label == %@", "annotator=mur count=1")
        let exp = XCTNSPredicateExpectation(predicate: expected, object: leaf)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 5), .completed,
                       "Export should write one confirmed finding to the .mur annotator")
    }

    // MARK: - Candidate group

    /// Candidates render as one group with the correct count.
    @MainActor
    func testCandidateGroupRendersWithCount() throws {
        let app = launchWithCandidates()

        // The top candidate row proves the group rendered; the count leaf
        // proves the group header reflects the injected set.
        let row0 = app.descendants(matching: .any)
            .matching(identifier: "vtvf-candidate-row-0").firstMatch
        XCTAssertTrue(row0.waitForExistence(timeout: 5),
                      "Candidate group should render in the review queue")

        let count = app.descendants(matching: .any)
            .matching(identifier: "vtvf-candidate-count").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        XCTAssertEqual(count.label, "2", "Two synthetic candidates were injected")
    }

    // MARK: - Disposition wire-up

    /// Confirming a candidate via the Menu routes into the region store and
    /// the row reflects the confirmed state.
    @MainActor
    func testConfirmCandidateUpdatesState() throws {
        let app = launchWithCandidates()

        let row0 = app.descendants(matching: .any)
            .matching(identifier: "vtvf-candidate-row-0").firstMatch
        XCTAssertTrue(row0.waitForExistence(timeout: 5),
                      "Top candidate row should exist")

        // Disposition controls are gated on the editing latch.
        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 3))
        editToggle.click()

        let confirm = app.descendants(matching: .any)
            .matching(identifier: "vtvf-candidate-confirm-0").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.click()

        let menuItem = app.menuItems["Confirm as VT"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3),
                      "Candidate confirm menu should expose VT/VF/unsure")
        menuItem.click()

        let state0 = app.descendants(matching: .any)
            .matching(identifier: "vtvf-candidate-state-0").firstMatch
        XCTAssertTrue(state0.waitForExistence(timeout: 3))
        let confirmed = NSPredicate(format: "label == %@", "confirmed")
        let exp = XCTNSPredicateExpectation(predicate: confirmed, object: state0)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Confirming a candidate should route into the region store")
    }

    /// Dismissing a candidate marks it dismissed.
    @MainActor
    func testDismissCandidateUpdatesState() throws {
        let app = launchWithCandidates()

        let editToggle = app.descendants(matching: .any)
            .matching(identifier: "edit-mode-toggle").firstMatch
        XCTAssertTrue(editToggle.waitForExistence(timeout: 5))
        editToggle.click()

        let dismiss = app.descendants(matching: .any)
            .matching(identifier: "vtvf-candidate-dismiss-1").firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
        dismiss.click()

        let state1 = app.descendants(matching: .any)
            .matching(identifier: "vtvf-candidate-state-1").firstMatch
        XCTAssertTrue(state1.waitForExistence(timeout: 3))
        let dismissed = NSPredicate(format: "label == %@", "dismissed")
        let exp = XCTNSPredicateExpectation(predicate: dismissed, object: state1)
        XCTAssertEqual(XCTWaiter.wait(for: [exp], timeout: 3), .completed,
                       "Dismissing a candidate should route into the region store")
    }
}
