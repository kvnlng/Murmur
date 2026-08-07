//
//  ToolbarGlyphs.swift
//  MurmurCore
//
//  Every SF Symbol the window toolbar uses, in one place, so that "no two
//  buttons look the same" is a rule a test can enforce instead of a thing
//  someone has to notice.
//
//  X60: Kevin reported the toolbar icons were hard to follow. Looking at the
//  running build, three collisions:
//
//    - `doc.badge.plus` was used TWICE — "Open Record Folder" (ContentView)
//      and "Attach findings…" (BedsideView). Pixel-identical, two positions
//      apart, doing unrelated things.
//    - `lock.fill` appeared twice: the edit-mode toggle (closed = read-only)
//      and the 10-second window hold (closed = engaged). Same glyph, and the
//      two locks govern different things.
//    - `doc.badge.plus` and `doc.badge.arrow.up` (Export WFDB) are the same
//      document outline at 16 pt, pointing opposite directions — import vs
//      export.
//
//  Icon-only buttons carry their whole meaning in the glyph, because the
//  hover text that was supposed to back them up renders nothing on macOS 26
//  (see the X60 PR). So a duplicate glyph is not a cosmetic issue here — it
//  makes two actions genuinely indistinguishable.
//

import Foundation

/// SF Symbol names for the window toolbar. Toggles list BOTH states, because
/// a toggle's two states are two things the analyst sees and must be able to
/// tell apart from every other button.
enum ToolbarGlyph {

    // MARK: Record / file actions

    /// Opens a FOLDER of WFDB records — was `doc.badge.plus`, which both
    /// misdescribed the action and duplicated `attachFindings`.
    static let openRecordFolder = "folder.badge.plus"

    /// Merges a producer's annotations INTO this recording. Import, so it
    /// pairs with `exportReport`'s share glyph pointing the other way.
    static let attachFindings = "square.and.arrow.down"

    // MARK: Exports

    static let exportReport = "square.and.arrow.up"
    static let exportSnapshot = "camera"
    static let exportWFDB = "doc.badge.arrow.up"

    // MARK: Toggles — both states

    /// Edit mode. Keeps the padlock: closed padlock = read-only is the
    /// canonical macOS metaphor, and after X60 this is the toolbar's ONLY
    /// padlock.
    static let editModeLocked = "lock.fill"
    static let editModeUnlocked = "lock.open.fill"

    /// 10-second window hold. Was a second padlock; a pin says "held in
    /// place" without competing with the edit lock.
    static let windowHeld = "pin.fill"
    static let windowFree = "pin"

    // MARK: Panels / scans

    static let scanVTVF = "waveform.badge.magnifyingglass"
    /// DEBUG-only producers sheet.
    static let producers = "wand.and.stars"

    // MARK: Side panels (X68)

    /// Shows/hides the record navigator. Was declared inline in
    /// `ContentView` and so escaped the uniqueness test entirely — the one
    /// glyph in the toolbar that nothing was checking.
    static let navigatorToggle = "sidebar.leading"

    /// Shows/hides the review queue. Was `stethoscope.circle`, which named a
    /// clinical role rather than the thing the button does. The two side
    /// panels are the same kind of action in opposite directions, so they
    /// read as a mirrored pair — and the pairing is only legible once both
    /// are declared here.
    static let reviewQueue = "sidebar.trailing"

    // MARK: Overflow

    /// Rarely-used actions: Open Record Folder, Customize Toolbar….
    static let moreActions = "ellipsis.circle"

    /// The analyst's notes drawer (X72). Declared here now so the glyph
    /// vocabulary is complete and the uniqueness test covers it before the
    /// button that uses it exists.
    static let notes = "note.text"

    /// Everything above. The uniqueness test walks this; a new toolbar button
    /// belongs here, not inline at the call site — `navigatorToggle` spent
    /// X63-B through X67 declared inline in `ContentView` and unchecked.
    static let all: [String] = [
        openRecordFolder, attachFindings,
        exportReport, exportSnapshot, exportWFDB,
        editModeLocked, editModeUnlocked,
        windowHeld, windowFree,
        scanVTVF, producers,
        navigatorToggle, reviewQueue,
        moreActions, notes,
    ]
}
