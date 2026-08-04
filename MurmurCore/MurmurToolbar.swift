//
//  MurmurToolbar.swift
//  MurmurCore
//
//  The window toolbar's customisation identity.
//
//  X60: the toolbar is assembled from TWO places — `ContentView` contributes
//  the open-folder button in every shell, `BedsideView` contributes the rest
//  once a recording is open. SwiftUI merges both into one `NSToolbar`, and a
//  toolbar is only customisable if EVERY contribution is customisable: while
//  ContentView still used a plain `.toolbar`, View → Customize Toolbar…
//  appeared in the menu but was greyed out.
//
//  So both sides pass this same identifier. One toolbar, one saved layout.
//
//  Changing this string discards every analyst's saved toolbar layout, since
//  macOS persists customisation under it. Don't.
//

import Foundation

enum MurmurToolbar {
    static let identifier = "murmur.main.toolbar"
}
