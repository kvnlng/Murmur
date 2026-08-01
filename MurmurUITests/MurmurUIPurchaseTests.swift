//
//  MurmurUIPurchaseTests.swift
//  MurmurUITests
//
//  Single-IAP pivot (2026-08-01) + X55 §1. The purchase surface is now ONE
//  all-inclusive product ("Murmur Studio"). The X55 §1 defect — the VT/VF row
//  rendering outside its container — required two or more product rows to be
//  expressible; with a single row it cannot occur. This test verifies that in
//  the live app (Settings → the purchase section) AND guards against a
//  regression that reintroduces multiple product rows or a retired product ID.
//

import XCTest

final class MurmurUIPurchaseTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Any purchase-row state carries an identifier ending in the product ID
    /// (`purchase-buy-…studio`, `-checking-…`, `-owned-…`, etc.), so matching by
    /// the product-ID suffix finds the row whatever state it resolved to.
    private func rowExists(_ app: XCUIApplication, productIDSuffix: String, timeout: TimeInterval = 0) -> Bool {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ENDSWITH %@", productIDSuffix))
            .firstMatch
        return timeout > 0 ? match.waitForExistence(timeout: timeout) : match.exists
    }

    @MainActor
    func testPurchaseSurfaceIsOneAllInclusiveRow() throws {
        let app = XCUIApplication()
        // Unowned state so the row renders a Buy / checking affordance, not "Owned".
        app.launchArguments += ["--ui-test-sample", "--ui-test-initial-duration=2", "--ui-test-no-entitlements"]
        app.launch()

        // Open the SwiftUI Settings scene (macOS: ⌘,).
        app.typeKey(",", modifierFlags: .command)

        // The one all-inclusive Studio row is present, in whatever load state.
        XCTAssertTrue(
            rowExists(app, productIDSuffix: "com.kevinlong.murmur.studio", timeout: 8),
            "the single Murmur Studio purchase row should be present in Settings"
        )

        // None of the retired per-module product rows render — proof there is no
        // multi-row layout left for X55 §1 to be about.
        for retired in [
            "com.kevinlong.murmur.metrics",
            "com.kevinlong.murmur.vtdetection",
            "com.kevinlong.murmur.annotationauthoring"
        ] {
            XCTAssertFalse(
                rowExists(app, productIDSuffix: retired),
                "retired product row \(retired) must not render under the single IAP"
            )
        }
    }
}
