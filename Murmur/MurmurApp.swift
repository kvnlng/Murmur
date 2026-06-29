//
//  MurmurApp.swift
//  Murmur
//
//  Created by Kevin Long on 6/14/26.
//

import AppKit
import MurmurCore
import SwiftUI

@main
struct MurmurApp: App {
    /// User-facing Help menu destinations. The docs site is the public face
    /// of the app now that the source repo is private; every entry below
    /// links into it (or to a mailto for direct support).
    private enum HelpURL {
        static let home            = URL(string: "https://kvnlng.github.io/Murmur/")!
        static let gettingStarted  = URL(string: "https://kvnlng.github.io/Murmur/getting-started.html")!
        static let annotationSchema = URL(string: "https://kvnlng.github.io/Murmur/annotation-schema.html")!
        static let privacy         = URL(string: "https://kvnlng.github.io/Murmur/privacy.html")!
        static let support         = URL(string: "mailto:long.kevin@gmail.com?subject=Murmur%20Studio%20Support")!
    }

    init() {
        // Register the baseline producers that ship with the free viewer.
        // The MurmurCore bootstrap encapsulates the DEBUG vs RELEASE
        // policy — in DEBUG it registers the synthetic producer so the
        // pipeline UI is exercisable; in RELEASE it's a no-op and paid
        // frameworks register themselves on framework load.
        Task { @MainActor in
            await bootstrapBaselineProducers()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1320, height: 880)
        .commands {
            // Replace the system Help menu (which would otherwise point at a
            // non-existent Help Book) with links into the public docs site
            // and a mailto for direct support.
            CommandGroup(replacing: .help) {
                Button("Murmur Studio Help") { URLLauncher.shared.open(HelpURL.home) }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Getting Started")     { URLLauncher.shared.open(HelpURL.gettingStarted) }
                Button("Annotation Schema")   { URLLauncher.shared.open(HelpURL.annotationSchema) }
                Divider()
                // Citation routing: until the paid IAPs ship, both menu
                // items emit the free-viewer entry only. When VT / Silver
                // land, this picks up tier-aware multi-entry citation per
                // ROADMAP "Citation routing".
                Button("Copy Citation (BibTeX)") {
                    _ = copyViewerCitationToPasteboard(asBibTeX: true)
                }
                Button("Copy Citation (RIS)") {
                    _ = copyViewerCitationToPasteboard(asBibTeX: false)
                }
                Divider()
                Button("Privacy Policy")      { URLLauncher.shared.open(HelpURL.privacy) }
                Button("Contact Support…")    { URLLauncher.shared.open(HelpURL.support) }
            }
        }
        // App-wide preferences. Adds a "Settings…" item under the app menu
        // with the standard ⌘, shortcut.
        Settings {
            SettingsView()
        }
    }
}
