//
//  URLLauncher.swift
//  MurmurCore
//
//  Indirection layer around `NSWorkspace.shared.open(_:)` so URL launches from
//  Help menu commands can be intercepted by UI tests. (Until #242 the welcome
//  screen's PhysioNet link routed through here too — the pattern outlived it.)
//  Production behavior: open the URL via NSWorkspace (browser, mail client,
//  whatever the system has registered for the scheme).
//
//  Under `--ui-test-record-urls`: don't open anything; record the URL on
//  `lastLaunchedURL`. A hidden accessibility element mounted in `ContentView`
//  echoes the URL string into the test runner, letting XCUI assert "the
//  Privacy Policy menu item targets the right URL" without the test process
//  launching a browser and losing focus.
//
//  This is a deliberate seam, not a full DI layer — the launcher is a global
//  singleton so menu commands and SwiftUI links can call into it without
//  threading instances down the view tree. Tests rely on the singleton.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class URLLauncher {
    public static let shared = URLLauncher()

    /// Most recently routed URL. Read by `URLLauncherProbe` in DEBUG and
    /// echoed onto an accessibility element for XCUI assertions.
    public private(set) var lastLaunchedURL: URL?

    private init() {}

    public func open(_ url: URL) {
        lastLaunchedURL = url
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-record-urls") {
            // Under test recording, never actually launch — that would steal
            // focus from the test runner and most likely fail the test.
            return
        }
        #endif
        NSWorkspace.shared.open(url)
    }
}
