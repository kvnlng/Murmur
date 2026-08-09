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
//  1024×768; with the menu bar and Dock that leaves ~670 pt, so a 720-pt
//  content minimum forces the window taller than the screen and every
//  control in the bottom band reports "not hittable" — a failure mode that
//  is invisible on tall developer displays. Capping the minimum lets AppKit
//  place the whole window on-screen; nothing else about the layout changes.
//  `--ui-test-window=WxH` additionally pins the frame so the short-display
//  regime is reproducible on any machine instead of discovered in CI.
//

import Foundation
import SwiftUI

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

    /// Applies `--ui-test-window=WxH` (a CONTENT size) to the main window.
    /// Called from ContentView's launch task; a no-op outside DEBUG XCUI
    /// runs or when the flag is absent.
    ///
    /// Two timing realities this must survive: the `.task` can fire before
    /// the NSWindow exists, and SwiftUI applies its own sizing after first
    /// layout — so this waits for the window, sizes the CONTENT (frame-level
    /// resizing loses to the content-minimum constraint), and re-applies
    /// once after a beat in case late scene sizing won the first round.
    @MainActor
    public static func applyForcedWindowIfRequested() async {
        #if DEBUG
        guard UITestSupport.isRunningUITest,
              let size = UITestSupport.forcedWindowSize else { return }
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
        // Keep re-asserting briefly: macOS state restoration re-applies a
        // PERSISTED frame from earlier manual sessions asynchronously after
        // launch, silently overriding a single early setContentSize.
        for _ in 0..<15 {
            let content = window.contentRect(forFrameRect: window.frame).size
            if abs(content.width - size.width) < 1, abs(content.height - size.height) < 1 {
                break
            }
            window.setContentSize(size)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let final = window.contentRect(forFrameRect: window.frame).size
        NSLog("WindowSizing: forced content \(size) → final \(final)")
        #endif
    }
}
