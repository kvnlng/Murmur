//
//  WindowSizing.swift
//  MurmurCore
//
//  The main window's minimum-size policy, in one place the App target and
//  the tests can both read.
//
//  Production is unconditional: 1100×720 content minimum (the App Store
//  Guideline 4 fix) — a real analyst never sees anything else, and the
//  minimum is a product decision this file does not soften.
//
//  Under an XCUI run (DEBUG + any `--ui-test*` argument) the minimum is
//  capped by the runner's VISIBLE screen frame. Xcode Cloud's Mac VMs run
//  1280×768 (measured 2026-08-12: the policy default resolved a 1220×702
//  window frame there); the menu bar leaves ~738 pt, so a 720-pt
//  content minimum forces the window taller than the screen and every
//  control in the bottom band reports "not hittable" — a failure mode that
//  is invisible on tall developer displays. Capping the minimum lets AppKit
//  place the whole window on-screen; nothing else about the layout changes.
//  `--ui-test-window=WxH` additionally pins the frame so the short-display
//  regime is reproducible on any machine instead of discovered in CI.
//
//  X100 (#165): window size under XCUI is ALWAYS an explicit choice, never
//  inherited state. macOS re-applies the frame persisted by the LAST launch —
//  including the 1000×600 frames short-display tests deliberately force — so
//  a test that omitted `--ui-test-window` used to open at whatever the
//  previous test left behind (verified during X86: an inherited ~1100 pt
//  frame dropped below the 1160 pt side-panel coexistence width and failed a
//  record-switch test on unmodified main). Now every XCUI launch resolves a
//  content size: the pinned `WxH` verbatim up to what the screen can hold,
//  `max` to fill the visible frame, and NO flag to a generous default
//  clamped to the visible frame. Nothing may exceed the visible frame: an
//  oversized window gets its origin pushed off-screen by AppKit, that frame
//  is PERSISTED, and because `setContentSize` never moves the origin, every
//  later suite inherits a window whose bottom band is unreachable.
//

import Foundation
import SwiftUI

#if DEBUG
extension UITestSupport {
    /// Explicit window size from `--ui-test-window=<width>x<height>`. Lets a
    /// test reproduce a SHORT DISPLAY deterministically on any machine —
    /// Xcode Cloud's Mac VMs run 1280×768, where the production minimum
    /// window (1100×720 content) cannot fit the visible frame and
    /// bottom-of-window controls go off-screen ("not hittable"). Tests that
    /// interact with bottom-region chrome launch with this flag so the
    /// constraint is exercised locally, not discovered in CI.
    static var forcedWindowSize: CGSize? {
        guard let raw = value(forFlag: "ui-test-window") else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]),
              w > 300, h > 300 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// X100 (#165): `--ui-test-window=max` fills the visible screen frame —
    /// the biggest window this runner can honestly give.
    static var wantsMaximizedWindow: Bool {
        value(forFlag: "ui-test-window") == "max"
    }
}
#endif

public enum WindowSizing {
    /// The production content minimums (the Guideline 4 fix). The guard
    /// test pins these; change them only as a product decision.
    public static let productionMinWidth: CGFloat = 1100
    public static let productionMinHeight: CGFloat = 720

    /// Clearance between the content minimum and the screen's visible
    /// frame, covering the title bar + unified toolbar so "content fits"
    /// implies "window fits".
    ///
    /// MEASURED, not derived (#241): a launch pinned to 1220×678 on a display
    /// tall enough that no clamping applies came back `frame=(68, 31, 1220,
    /// 744)` — 744 − 678 = 66 pt of chrome for this app's title bar + unified
    /// toolbar. At the previous 60 a content height resolved as
    /// `visible.height - chromeAllowance` still produced a frame 6 pt taller
    /// than the visible frame, which made `isPlacedOnScreen` unsatisfiable and
    /// ran the applier's full retry loop on every affected launch. Re-measure
    /// if the toolbar's display mode or the title bar's height changes.
    static let chromeAllowance: CGFloat = 66

    /// The minimums to enforce for THIS launch. Production values unless
    /// this is a DEBUG XCUI run on a screen too short (or narrow) to hold
    /// them — then capped so the window can physically fit.
    public static func effectiveMinimums() -> (width: CGFloat, height: CGFloat) {
        #if DEBUG
        if UITestSupport.isRunningUITest {
            return minimums(cappedBy: testWindowContentSize(
                pinned: UITestSupport.forcedWindowSize,
                maximized: UITestSupport.wantsMaximizedWindow,
                visible: NSScreen.main?.visibleFrame.size))
        }
        #endif
        return (productionMinWidth, productionMinHeight)
    }

    /// The pure half of `effectiveMinimums()`: the production minimums capped
    /// by the content size the policy actually resolved.
    ///
    /// #241 — this used to cap against the raw `--ui-test-window` pin while
    /// `testWindowContentSize` capped against the SCREEN, and nothing
    /// reconciled the two. With `1220x678` pinned on Cloud's 1280×768 VM the
    /// policy asked for 632 pt of content and the minimum demanded 678; a
    /// SwiftUI `.frame(minHeight:)` outranks `setContentSize`, so AppKit gave
    /// 678, `applyTestWindowPolicy` re-applied a size the constraint
    /// immediately overrode for all 15 iterations, and the resulting 744-pt
    /// window overflowed a 692-pt visible frame by 52 pt. Every control in
    /// that band reported "not hittable" — the exact failure this file exists
    /// to prevent, in exactly the short-display regime the pins reproduce.
    ///
    /// Deriving from the resolved size makes `minimums(cappedBy: r) <= r` true
    /// by construction rather than by parallel arithmetic that agrees only on
    /// tall developer displays.
    static func minimums(cappedBy resolved: CGSize) -> (width: CGFloat, height: CGFloat) {
        (min(productionMinWidth, resolved.width),
         min(productionMinHeight, resolved.height))
    }

    /// The no-flag XCUI default (X100): generous enough for full side-panel
    /// coexistence (≥ 1160 pt) and the whole bedside bottom band, clamped to
    /// the runner's visible frame so Cloud's 1280×768 VMs get the largest
    /// window that fits.
    public static let defaultTestWindowSize = CGSize(width: 1400, height: 900)

    /// Pure resolution of the X100 policy — what CONTENT size this XCUI
    /// launch should get. Split from the applier so unit tests can pin the
    /// table: pinned `WxH` wins verbatim UP TO what the screen can hold
    /// (the short-display regime must reproduce exactly, and a short-display
    /// pin by definition fits; a pin LARGER than the screen can never be a
    /// legitimate repro — it builds a window whose bottom band is off-screen
    /// and whose persisted frame poisons every later launch, which is how
    /// 1600×1100 pins took down six unrelated suites on Cloud's short-display
    /// VMs), `max` fills the visible frame, no flag takes the generous
    /// default clamped to the visible frame.
    static func testWindowContentSize(
        pinned: CGSize?,
        maximized: Bool,
        visible: CGSize?
    ) -> CGSize {
        let fill = visible.map {
            CGSize(width: $0.width - chromeAllowance,
                   height: $0.height - chromeAllowance)
        }
        if let pinned {
            // The cap is asymmetric because chrome is vertical: a window is
            // exactly as wide as its content, but the title bar rides on top
            // of it — so width clamps to the full visible width (short
            // displays must keep reproducing the standing 1000×600 pins
            // exactly) while height leaves the chrome allowance.
            guard let visible else { return pinned }
            return CGSize(width: min(pinned.width, visible.width),
                          height: min(pinned.height, visible.height - chromeAllowance))
        }
        guard let fill else { return defaultTestWindowSize }
        if maximized { return fill }
        return CGSize(width: min(defaultTestWindowSize.width, fill.width),
                      height: min(defaultTestWindowSize.height, fill.height))
    }

    /// Applies the X100 window policy (a CONTENT size) to the main window on
    /// EVERY DEBUG XCUI launch. Called from ContentView's launch task; a
    /// no-op outside XCUI runs, so bare production-path launch tests (no
    /// `--ui-test*` argument at all) keep the untouched launch experience.
    ///
    /// Two timing realities this must survive: the `.task` can fire before
    /// the NSWindow exists, and SwiftUI applies its own sizing after first
    /// layout — so this waits for the window, sizes the CONTENT (frame-level
    /// resizing loses to the content-minimum constraint), and re-applies
    /// until it sticks, because macOS state restoration re-applies the
    /// PERSISTED frame asynchronously after launch — the exact inheritance
    /// this policy exists to kill.
    @MainActor
    public static func applyTestWindowPolicy() async {
        #if DEBUG
        guard UITestSupport.isRunningUITest else { return }
        let size = testWindowContentSize(
            pinned: UITestSupport.forcedWindowSize,
            maximized: UITestSupport.wantsMaximizedWindow,
            visible: NSScreen.main?.visibleFrame.size
        )
        // Wait for the window to attach (the .task can beat it).
        var window: NSWindow?
        for _ in 0..<60 {
            window = NSApp.keyWindow ?? NSApp.windows.first
            if window != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let window else {
            NSLog("WindowSizing: no window attached; forced size not applied")
            return
        }
        var converged = false
        for _ in 0..<15 {
            let content = layoutSize(of: window)
            if abs(content.width - size.width) < 1, abs(content.height - size.height) < 1,
               isPlacedOnScreen(window) {
                converged = true
                break
            }
            window.setContentSize(frameSize(forLayout: size, of: window))
            constrainOntoScreen(window)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let final = layoutSize(of: window)
        guard converged else {
            // #241: exhausting the loop used to be indistinguishable from
            // succeeding — same log line either way — so a launch whose window
            // never reached its policy size looked exactly like one that did,
            // and that ambiguity cost several build cycles on #231 and #236.
            // Still a log rather than a hard failure: the loop is bounded at
            // 15 × 200 ms, and a contended VM that merely runs slow must not
            // turn a soft geometry problem into a launch crash. The marker is
            // deliberately greppable — `grep 'WINDOW POLICY DID NOT CONVERGE'`
            // over a downloaded Cloud log answers "was the geometry what the
            // test thought it was?" before any assertion is read.
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            NSLog("""
                  WindowSizing: WINDOW POLICY DID NOT CONVERGE after 15 attempts — \
                  wanted content \(size), settled at \(final); frame \(window.frame), \
                  visible \(visible.map(String.init(describing:)) ?? "unknown"), \
                  minimums \(minimums(cappedBy: size)). \
                  Geometry-dependent assertions in this launch ran against a window \
                  the policy did not choose; treat their results as unattributable.
                  """)
            return
        }
        NSLog("WindowSizing: policy content \(size) → final \(final) at \(window.frame.origin)")
        #endif
    }

    #if DEBUG
    /// The size the policy is actually talking about: the area SwiftUI lays
    /// content out in.
    ///
    /// NOT `contentRect(forFrameRect:)` (#241). The main window carries
    /// `fullSizeContentView` (measured `styleMask=32783` = titled | closable |
    /// miniaturizable | resizable | fullSizeContentView), which is what a
    /// SwiftUI window with a unified toolbar gets. Under that mask the content
    /// VIEW genuinely spans the whole frame, so `contentRect(forFrameRect:)`
    /// subtracts no chrome and returns the frame size — while
    /// `contentLayoutRect`, the rect excluding the title bar and toolbar,
    /// returns what the analyst can actually see.
    ///
    /// The two disagree by exactly `chromeAllowance`, and the applier compared
    /// the wrong one against a size expressed in the right one. Measured on a
    /// tall display with nothing to clamp, `--ui-test-window=1220x678`:
    ///
    /// ```
    /// frame=(17, 339, 1220, 744)  contentRect=(17, 339, 1220, 744)
    /// contentLayoutRect=(0, 0, 1220, 678)
    /// ```
    ///
    /// The window was correct — layout 678, exactly as asked. `setContentSize`
    /// accounts for the chrome on the way in; only the read-back did not. So
    /// the loop re-applied an already-correct size 15 times and exited on
    /// exhaustion, burning ~3 s of its 200 ms sleeps on EVERY XCUI launch on
    /// EVERY display, then logging a `final` that had never matched. Unlike
    /// the two defects #241 names, this one was never short-display-specific.
    @MainActor
    private static func layoutSize(of window: NSWindow) -> CGSize {
        window.contentLayoutRect.size
    }

    /// The size to hand `setContentSize` so the window ends up with `layout`
    /// available to SwiftUI.
    ///
    /// Same `fullSizeContentView` root as `layoutSize(of:)`, from the other
    /// side (#241). The content VIEW spans the whole frame under that mask, so
    /// `setContentSize` sizes the FRAME — while every size this policy deals in
    /// is a LAYOUT size, which is what the analyst sees and what
    /// `testWindowContentSize` clamps against the screen. The applier passed
    /// one as the other.
    ///
    /// It went unnoticed because the two coincide whenever the resolved size is
    /// at or below the production minimum: SwiftUI's `.frame(minHeight:)` then
    /// equals the requested layout and drags the frame up by exactly the chrome
    /// the call failed to add. Both standing pins (`1220x678`, `1000x600`) sit
    /// below 720, so both landed right for the wrong reason. `--ui-test-window=max`
    /// does not — measured on a 1728×1002 visible frame it asked for 936 pt of
    /// layout, `setContentSize(936)` made the FRAME 936, the minimum of 720 was
    /// already satisfied so nothing corrected it, and the window came up with
    /// 870 pt of layout: a full chrome allowance short of maximized, on every
    /// launch, on every display.
    ///
    /// Measured from the live window rather than adding `chromeAllowance`,
    /// because here there IS a window to ask. The constant stays where it has
    /// to be a prediction — `testWindowContentSize`, which resolves before any
    /// window exists.
    @MainActor
    private static func frameSize(forLayout layout: CGSize, of window: NSWindow) -> CGSize {
        let chrome = window.frame.size.height - window.contentLayoutRect.height
        // A window mid-teardown can report a zero or negative layout rect;
        // fall back to the predicted allowance rather than shrinking to fit
        // a garbage measurement.
        let allowance = chrome > 0 && chrome < window.frame.size.height
            ? chrome : chromeAllowance
        return CGSize(width: layout.width, height: layout.height + allowance)
    }

    /// `setContentSize` resizes around a FIXED origin — so a frame that
    /// state restoration placed partly off-screen (AppKit pushes an
    /// oversized window's origin below the screen bottom) stays off-screen
    /// after the policy shrinks it, and every bottom-band control keeps
    /// reporting "not hittable". Size and placement must both be corrected.
    @MainActor
    private static func isPlacedOnScreen(_ window: NSWindow) -> Bool {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return true
        }
        return visible.contains(window.frame)
    }

    @MainActor
    private static func constrainOntoScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        var origin = window.frame.origin
        origin.x = min(max(origin.x, visible.minX),
                       max(visible.minX, visible.maxX - window.frame.width))
        origin.y = min(max(origin.y, visible.minY),
                       max(visible.minY, visible.maxY - window.frame.height))
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }
    #endif
}
