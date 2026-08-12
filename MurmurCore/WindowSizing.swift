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
    static let chromeAllowance: CGFloat = 60

    /// The minimums to enforce for THIS launch. Production values unless
    /// this is a DEBUG XCUI run on a screen too short (or narrow) to hold
    /// them — then capped so the window can physically fit.
    public static func effectiveMinimums() -> (width: CGFloat, height: CGFloat) {
        #if DEBUG
        if UITestSupport.isRunningUITest {
            if let forced = UITestSupport.forcedWindowSize {
                return (min(productionMinWidth, forced.width),
                        min(productionMinHeight, forced.height))
            }
            if let visible = NSScreen.main?.visibleFrame {
                return (min(productionMinWidth, visible.width - chromeAllowance),
                        min(productionMinHeight, visible.height - chromeAllowance))
            }
        }
        #endif
        return (productionMinWidth, productionMinHeight)
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
        for _ in 0..<15 {
            let content = window.contentRect(forFrameRect: window.frame).size
            if abs(content.width - size.width) < 1, abs(content.height - size.height) < 1,
               isPlacedOnScreen(window) {
                break
            }
            window.setContentSize(size)
            constrainOntoScreen(window)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let final = window.contentRect(forFrameRect: window.frame).size
        NSLog("WindowSizing: policy content \(size) → final \(final) at \(window.frame.origin)")
        #endif
    }

    #if DEBUG
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
