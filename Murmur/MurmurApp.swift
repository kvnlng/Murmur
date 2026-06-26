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
                Button("Murmur Studio Help") { NSWorkspace.shared.open(HelpURL.home) }
                    .keyboardShortcut("?", modifiers: .command)
                Button("Getting Started")     { NSWorkspace.shared.open(HelpURL.gettingStarted) }
                Button("Annotation Schema")   { NSWorkspace.shared.open(HelpURL.annotationSchema) }
                Divider()
                Button("Privacy Policy")      { NSWorkspace.shared.open(HelpURL.privacy) }
                Button("Contact Support…")    { NSWorkspace.shared.open(HelpURL.support) }
            }
        }
    }
}
