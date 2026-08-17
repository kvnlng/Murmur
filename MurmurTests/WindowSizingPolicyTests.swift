//
//  WindowSizingPolicyTests.swift
//  MurmurTests
//
//  X100 (#165) — the pure resolution table behind `applyTestWindowPolicy`.
//  The applier itself needs a live NSWindow (XCUI territory); what a unit
//  test can pin is the policy: pinned sizes verbatim, `max` fills, no flag
//  takes the generous default clamped to the runner's visible frame.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("XCUI window policy resolution (X100)")
struct WindowSizingPolicyTests {
    private let bigScreen = CGSize(width: 2560, height: 1415)
    // A short display like Cloud's Mac VMs (measured 2026-08-12: 1280×768
    // with a 30 pt menu bar). Deliberately narrower than a real VM so the
    // table's clamping rows exercise BOTH axes.
    private let cloudVM = CGSize(width: 1024, height: 743)

    @Test("A pinned WxH that fits wins verbatim — the short-display regime must reproduce exactly")
    func pinnedWinsVerbatim() {
        let size = WindowSizing.testWindowContentSize(
            pinned: CGSize(width: 1000, height: 600), maximized: false, visible: bigScreen)
        #expect(size == CGSize(width: 1000, height: 600))
        // On the small screen too: a short-display pin fits by definition.
        let onSmall = WindowSizing.testWindowContentSize(
            pinned: CGSize(width: 1000, height: 600), maximized: true, visible: cloudVM)
        #expect(onSmall == CGSize(width: 1000, height: 600))
    }

    @Test("A pin larger than the screen clamps to the largest window that fits")
    func oversizedPinClamps() {
        // The 2026-08-11 Cloud failure: 1600×1100 pinned on the short VM
        // built an off-screen window whose persisted frame poisoned six
        // later suites. A pin must never exceed the visible frame.
        let size = WindowSizing.testWindowContentSize(
            pinned: CGSize(width: 1600, height: 1100), maximized: false, visible: cloudVM)
        // Width caps at the FULL visible width (chrome is vertical — the
        // window is exactly as wide as its content); height leaves the
        // chrome allowance for the title bar.
        #expect(size.width == cloudVM.width)
        #expect(size.height == cloudVM.height - WindowSizing.chromeAllowance)
    }

    @Test("The clamp is per-axis — a pin oversized in one dimension keeps the other verbatim")
    func oversizedPinClampsPerAxis() {
        let size = WindowSizing.testWindowContentSize(
            pinned: CGSize(width: 900, height: 1100), maximized: false, visible: cloudVM)
        #expect(size.width == 900)
        #expect(size.height == cloudVM.height - WindowSizing.chromeAllowance)
    }

    @Test("No visible frame leaves a pin verbatim — nothing to clamp against")
    func pinWithoutScreenStaysVerbatim() {
        let size = WindowSizing.testWindowContentSize(
            pinned: CGSize(width: 1600, height: 1100), maximized: false, visible: nil)
        #expect(size == CGSize(width: 1600, height: 1100))
    }

    @Test("`max` fills the visible frame minus chrome allowance")
    func maxFillsVisible() {
        let size = WindowSizing.testWindowContentSize(
            pinned: nil, maximized: true, visible: bigScreen)
        #expect(size.width == bigScreen.width - WindowSizing.chromeAllowance)
        #expect(size.height == bigScreen.height - WindowSizing.chromeAllowance)
    }

    @Test("No flag on a big display gets exactly the generous default")
    func defaultOnBigDisplay() {
        let size = WindowSizing.testWindowContentSize(
            pinned: nil, maximized: false, visible: bigScreen)
        #expect(size == WindowSizing.defaultTestWindowSize)
    }

    @Test("No flag on a short-display VM clamps to the largest window that fits")
    func defaultClampsToCloudVM() {
        let size = WindowSizing.testWindowContentSize(
            pinned: nil, maximized: false, visible: cloudVM)
        #expect(size.width == cloudVM.width - WindowSizing.chromeAllowance)
        #expect(size.height == cloudVM.height - WindowSizing.chromeAllowance)
        #expect(size.width < WindowSizing.defaultTestWindowSize.width)
    }

    @Test("No visible frame reported falls back to the default, not to inheritance")
    func noScreenFallsBackToDefault() {
        let size = WindowSizing.testWindowContentSize(
            pinned: nil, maximized: false, visible: nil)
        #expect(size == WindowSizing.defaultTestWindowSize)
    }

    // MARK: - #241: the minimum may never outrank the resolved size

    /// The invariant the whole issue reduces to.
    ///
    /// A SwiftUI `.frame(minHeight:)` outranks `setContentSize`, so a minimum
    /// larger than the size the policy resolved is not a preference AppKit
    /// weighs — it is the size the window gets, and the policy's retry loop
    /// spins its full 15 iterations re-applying a size the constraint
    /// immediately overrides. Every row of the resolution table has to satisfy
    /// this, not just the ones a developer display happens to exercise.
    @Test("The enforced minimum never exceeds the resolved content size",
          arguments: [
            // (pinned, maximized, visible) — the whole table, both screens.
            (CGSize(width: 1000, height: 600), false, CGSize(width: 2560, height: 1415)),
            (CGSize(width: 1000, height: 600), false, CGSize(width: 1024, height: 743)),
            (CGSize(width: 1600, height: 1100), false, CGSize(width: 1024, height: 743)),
            (CGSize(width: 900, height: 1100), false, CGSize(width: 1024, height: 743)),
            (CGSize(width: 1220, height: 678), false, CGSize(width: 1280, height: 692)),
            (nil, true, CGSize(width: 1024, height: 743)),
            (nil, false, CGSize(width: 1024, height: 743)),
            (nil, false, CGSize(width: 2560, height: 1415)),
            (nil, false, nil),
            (CGSize(width: 1600, height: 1100), false, nil),
          ] as [(CGSize?, Bool, CGSize?)])
    func minimumNeverOutranksTheResolvedSize(
        pinned: CGSize?, maximized: Bool, visible: CGSize?
    ) {
        let resolved = WindowSizing.testWindowContentSize(
            pinned: pinned, maximized: maximized, visible: visible)
        let minimums = WindowSizing.minimums(cappedBy: resolved)
        #expect(minimums.width <= resolved.width)
        #expect(minimums.height <= resolved.height)
    }

    /// The measured #239 launch, which is where the defect was found.
    ///
    /// `--ui-test-window=1220x678` on Cloud's 1280×768 VM (692 pt visible).
    /// The old `effectiveMinimums` capped against the raw PIN — `min(720,
    /// 678)` = 678 — while the policy resolved `min(678, 692 - chrome)` = 626.
    /// AppKit honoured 678, the frame came out 744 pt on a 692 pt visible
    /// frame, and the bottom 52 pt of the window went off-screen.
    @Test("The #239 short-display launch: the minimum yields to the screen, not the pin")
    func cloudShortDisplayPinDoesNotOverflow() {
        let visible = CGSize(width: 1280, height: 692)
        let resolved = WindowSizing.testWindowContentSize(
            pinned: CGSize(width: 1220, height: 678), maximized: false, visible: visible)
        #expect(resolved.height == visible.height - WindowSizing.chromeAllowance)

        let minimums = WindowSizing.minimums(cappedBy: resolved)
        #expect(minimums.height == resolved.height)
        // The regression itself: capping against the pin gave 678 here.
        #expect(minimums.height < 678)
        // And the whole point — content plus chrome now fits the screen.
        #expect(minimums.height + WindowSizing.chromeAllowance <= visible.height)
    }

    /// The allowance is a MEASUREMENT (frame 744 for content 678), so a change
    /// to it is a claim about this app's chrome and should be deliberate.
    /// Anything smaller re-opens #241's second defect: a content height of
    /// `visible.height - chromeAllowance` yields a frame taller than the
    /// visible frame, `isPlacedOnScreen` can never be satisfied, and the
    /// applier burns its full retry loop on every affected launch.
    @Test("The chrome allowance covers the measured title bar + unified toolbar")
    func chromeAllowanceCoversMeasuredChrome() {
        #expect(WindowSizing.chromeAllowance >= 744 - 678)
    }

    @Test("The default clears side-panel coexistence and the production minimums")
    func defaultIsGenerous() {
        // 1160 pt is SidePanelCoexistenceContext.coexistenceWidth — the X86
        // failure this ticket exists to prevent regressed exactly here.
        #expect(WindowSizing.defaultTestWindowSize.width >= 1160)
        #expect(WindowSizing.defaultTestWindowSize.width >= WindowSizing.productionMinWidth)
        #expect(WindowSizing.defaultTestWindowSize.height >= WindowSizing.productionMinHeight)
    }
}
