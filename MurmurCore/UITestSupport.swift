//
//  UITestSupport.swift
//  Murmur
//
//  Centralised launch-argument hooks for the MurmurUITests target.
//  Wrapped in `#if DEBUG` so production App Store builds get none of this
//  code — the hooks exist purely to side-step XCUI macOS quirks that bit
//  the canvas polish pass (XCUICoordinate.hover() doesn't fire AppKit
//  NSTrackingArea events; pinch-zoom is awkward to synthesise) and to
//  make accessibility-restricted nested SwiftUI Texts reachable from
//  the test runner.
//
//  Supported arguments (all opt-in, all gated behind DEBUG):
//
//    --ui-test-sample
//        Already-existing flag handled by ContentView. Loads the
//        synthetic multi-frequency fixture on launch so the bedside
//        view renders without the welcome-screen detour.
//
//    --ui-test-initial-duration=<seconds>
//        Overrides BedsideView.initialDurationSeconds. With a value
//        smaller than the recording length, the viewport starts
//        zoomed in so a drag-pan actually has somewhere to move to —
//        the default 10 s window encompasses the whole 10 s synthetic
//        fixture, so drag would otherwise clamp at sample 0 and the
//        test would assert no visible change.
//
//    --ui-test-hover-at=<x>,<y>
//        Injects a single hover update at the given canvas-local
//        point right after first paint. Bypasses NSTrackingArea
//        synthesis entirely — the test runner just asks the app to
//        pretend the cursor's there, and the existing hover-update
//        closure runs as if HoverTrackingView had fired.
//
//    --ui-test-seed-recent
//        Materialises a synthetic WFDB folder into a unique temp
//        directory and seeds it as a recents-store entry, without
//        auto-loading. Lets a UI test land on the welcome screen
//        with one clickable recents row so the row-click → bookmark
//        resolve → import → bedside path runs end-to-end. Wipes the
//        existing recents list first so each run starts deterministic.
//

#if DEBUG
import Foundation
import CoreGraphics

enum UITestSupport {

    /// Returns the value parsed from `--<flag>=<value>` in
    /// `ProcessInfo.processInfo.arguments`, or nil if the flag is absent
    /// or the value isn't parseable as the requested type.
    private static func value(forFlag flag: String) -> String? {
        let prefix = "--\(flag)="
        for arg in ProcessInfo.processInfo.arguments where arg.hasPrefix(prefix) {
            return String(arg.dropFirst(prefix.count))
        }
        return nil
    }

    /// If `--ui-test-initial-duration=N` is set, returns N seconds.
    /// BedsideView falls back to its own `initialDurationSeconds`
    /// constant when this returns nil.
    static var initialDurationSeconds: Double? {
        guard let raw = value(forFlag: "ui-test-initial-duration"),
              let n = Double(raw), n > 0 else { return nil }
        return n
    }

    /// If `--ui-test-hover-at=X,Y` is set, returns the point in canvas
    /// coordinates. The canvas's hover-update closure is invoked with
    /// this point after the first layout, exactly as if `HoverTrackingView`
    /// had received a mouseEntered NSEvent at that location.
    static var hoverPoint: CGPoint? {
        guard let raw = value(forFlag: "ui-test-hover-at") else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }
}
#endif
