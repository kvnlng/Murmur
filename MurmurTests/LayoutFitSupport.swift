//
//  LayoutFitSupport.swift
//  MurmurTests
//
//  Measuring what a view DEMANDS, as opposed to what it is handed.
//
//  The snapshot suite cannot see this class of bug: `SnapshotTests.render`
//  forces `.frame(width:height:)` before rasterising, so a view that wants
//  more than its container can give is told its size and drawn happily. That
//  is how a 218 pt card sat in a 186 pt column for weeks (#205) and a 260 pt
//  inset reserved space for 172 pt of content (#208) with every test green.
//
//  `sizeThatFits(in:)` asks the other question — given this proposal, how big
//  do you insist on being? Fast enough to be a unit test (~40 ms), so these
//  run on every PR rather than behind the snapshot suite's CI skip.
//

import AppKit
import SwiftUI

/// The size `view` insists on, given `proposal`. A dimension larger than the
/// proposal is the view overflowing its container — the invariant these
/// tests exist to pin.
@MainActor
func demandedSize<V: View>(_ view: V, proposal: CGSize) -> CGSize {
    NSHostingController(rootView: view).sizeThatFits(in: proposal)
}

/// Height demanded when offered far more than any real container would.
/// A view that answers with the proposal rather than its content height is
/// GREEDY — the `.frame(maxHeight:)` trap (#208).
@MainActor
func demandedHeightGivenRoom<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    demandedSize(view, proposal: CGSize(width: width, height: 4000)).height
}

/// Rendered width of `string` at `font` — for pinning a fixed column against
/// its measured worst-case content instead of a hardcoded number that goes
/// stale when the format or the font metrics change.
func measuredWidth(_ string: String, font: NSFont) -> CGFloat {
    (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
}
