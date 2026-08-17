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
//  ## Display mode: icon-only, and why that reversed (#253, reversing X60)
//
//  X60 opened the toolbar on Icon AND Text, seeded on fresh install by a
//  `ToolbarDisplayModeDefault` type this ticket deleted. Its reasoning was
//  sound and is worth keeping rather than losing with the code: `.help()`
//  renders no tooltip anywhere in this app on macOS 26, so an icon-only button
//  has no way at all to say what it is, and "an affordance nobody discovers is
//  not an affordance." Customize Toolbar… makes labels reachable; X60 made
//  them the state the analyst starts in.
//
//  What changed is not that reasoning but its premise. The design's icon-only
//  toolbar (option 11a, Region 1) rests on discoverability living in the menu
//  bar — and when #253 was picked up, 8 of the 12 toolbar items had no
//  menu-bar equivalent at all. #287 gave every one of them a menu row, with a
//  UI suite pinning that they stay reachable and that their actions actually
//  fire. The affordance X60 protected now exists somewhere that is not a
//  broken API, so the labels can go.
//
//  ## Why there is no seed any more
//
//  The reversal is a DELETION, not a flipped constant. Measured directly with
//  the toolbar configuration key cleared:
//
//  ```
//  seed on   → displayMode=1 (iconAndLabel), stored TB Display Mode = 1
//  seed off  → displayMode=2 (iconOnly),     stored TB Display Mode = 2
//  ```
//
//  Icon-only is AppKit's own default, so seeding it would write a value the
//  system already chooses. That matters beyond tidiness: the seed worked by
//  writing `NSToolbar Configuration <identifier>` / `TB Display Mode`, AppKit's
//  private persistence format and not documented API — the one fragile part
//  X60 flagged in its own header. Deleting the seed removes that dependency
//  outright instead of carrying it for a no-op.
//
//  Two consequences worth stating:
//
//  - An analyst who ALREADY launched a seeded build keeps Icon and Text. macOS
//    owns the key once written, and X60's own rule — a customisation whose
//    result evaporates on relaunch is worse than not offering one — applies to
//    this change too. Only fresh installs see icon-only.
//  - Customize Toolbar… still reaches labels, so the analyst who wants them
//    back has the same route X60 built.
//

import Foundation

enum MurmurToolbar {
    static let identifier = "murmur.main.toolbar"
}
