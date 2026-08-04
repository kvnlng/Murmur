//
//  ReviewQueueLaunch.swift
//  MurmurUITests
//
//  One place to launch a test that reaches INSIDE a review-queue group.
//
//  ## The problem this solves
//
//  Review-queue groups render COLLAPSED. A group row (`finding-group-<cat>`)
//  is present; its exemplar rows (`finding-row-<cat>`) are not, until the
//  group is expanded. So a test that addresses an exemplar row must pass
//  `--ui-test-expand-all-findings-groups`, and twelve of them do — each having
//  remembered independently.
//
//  Forgetting is invisible in the worst way: the row simply isn't in the tree,
//  so the failure reads "element does not exist" with nothing pointing at the
//  cause. Nobody debugging that message would guess "the group is collapsed".
//
//  ## Why the default was NOT inverted
//
//  The obvious alternative — expand by default under XCUI, with a flag to
//  collapse — was considered and rejected. **Collapsed-by-default is deliberate
//  product behaviour**, not a test inconvenience: it is what an analyst sees,
//  and `testReviewQueueGroupsCollapseByDefault` exists specifically to guard it
//  (`MurmurUITests.swift`). Inverting under XCUI would mean no test could ever
//  observe the app's real default again — the guard test would be reduced to
//  asserting a state it had to ask for, which is not the same claim.
//
//  Trading coverage of analyst-facing default behaviour for test convenience is
//  the wrong way round. So the default stands, and the flag becomes hard to
//  forget instead of unnecessary.
//

import XCTest

extension XCTestCase {
    /// Launch with review-queue groups expanded, for a test that addresses
    /// `finding-row-<category>` rows inside them.
    ///
    /// Pass the fixture and any other flags; the expand flag is added here.
    ///
    ///     let app = launchWithExpandedFindingsGroups(["--ui-test-sample"])
    ///
    /// A test that asserts something about the COLLAPSED state must not use
    /// this — launch normally, and say in a comment that the collapsed default
    /// is the thing under test.
    @MainActor
    func launchWithExpandedFindingsGroups(
        _ arguments: [String],
        replacingDefaults: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        let all = arguments + [ReviewQueueLaunch.expandGroups]
        // Performance and large-dataset tests ASSIGN launchArguments rather
        // than appending, to keep the environment minimal and timings
        // comparable. Preserve that distinction rather than flattening it.
        if replacingDefaults {
            app.launchArguments = all
        } else {
            app.launchArguments += all
        }
        app.launch()
        return app
    }
}

enum ReviewQueueLaunch {
    /// Expands every review-queue group so exemplar rows are addressable
    /// without first clicking a disclosure chevron.
    static let expandGroups = "--ui-test-expand-all-findings-groups"
}
