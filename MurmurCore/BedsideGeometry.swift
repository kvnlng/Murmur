//
//  BedsideGeometry.swift
//  MurmurCore
//
//  Sizes that MORE THAN ONE view has to agree about.
//
//  Every layout bug in the 2026-08-12 batch (#205, #208, #210) was the same
//  shape: two numbers that must agree, written in two files, drifting on
//  independent schedules. The caliper card was sized for a 220 pt column that
//  had since become 186; nothing connected the two, so nothing noticed for
//  weeks. A constant that only one view reads does not belong here — this is
//  for the ones a container and its content both depend on, so the agreement
//  has a single home and a test can assert it.
//

import Foundation
import SwiftUI

/// Height policy for the Variability Metrics strip where it rides above the
/// monitor as a top safe-area inset: **as tall as its content, never taller
/// than the cap**.
///
/// A modifier rather than two lines inline in `BedsideView`, so the test and
/// the app measure the same construction. Written inline, the test could only
/// pin a copy of the idiom — and a copy still passes after someone edits the
/// original, which is the exact failure mode this batch is about.
///
/// `fixedSize` is what keeps the cap a CEILING: a bare `.frame(maxHeight:)`
/// offered more than its maximum claims the whole maximum, which reserved
/// ~95 pt of dead space under the strip (#208).
///
/// The cap used to be load-bearing against the split view's width-0 minimum
/// probe, where the `LazyVGrid` collapses to one column and its ideal height
/// runs to 1811 pt (measured). `MeasurementWidthFloor` answers that probe
/// properly now, so the cap is back to being a ceiling and nothing else.
struct MetricsStripInsetHeight: ViewModifier {
    static let cap: CGFloat = 260

    /// Width the strip is MEASURED at when it is proposed something narrower
    /// than any real layout — see `MeasurementWidthFloor`.
    ///
    /// 600 pt is just under the narrowest the detail column can structurally
    /// become (the focus canvas floor of 360 plus the 186 pt docked column
    /// plus padding), so the clamp only ever engages on a proposal that is
    /// not a real layout. A higher floor would report a height too small for
    /// genuinely narrow columns — trading this bug for an overflow, which is
    /// the same mistake in the other direction.
    static let measurementWidthFloor: CGFloat = 600

    func body(content: Content) -> some View {
        MeasurementWidthFloor(floor: Self.measurementWidthFloor) { content }
            .frame(maxHeight: Self.cap, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Reports its child's height measured at **at least** `floor` points of
/// width, while laying the child out at whatever width it is actually given.
///
/// Exists because the split view sizes its detail column by proposing width 0
/// — not a layout anyone will ever see — and the metrics strip's `LazyVGrid`
/// answers that honestly by collapsing to one column and stacking every tile
/// into a ~1811 pt tower (measured). That answer then propagates as the
/// column's minimum height and shoves the whole stage off-window (#207).
///
/// A layout should not report a pathological size for a pathological
/// proposal. The floor makes the strip answer the width-0 question the way it
/// would answer a real one, and the reported WIDTH stays the proposal, so
/// this cannot widen anything.
struct MeasurementWidthFloor: Layout {
    let floor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let measured = subview.sizeThatFits(
            ProposedViewSize(width: max(proposal.width ?? floor, floor),
                             height: proposal.height))
        return CGSize(width: proposal.width ?? measured.width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

public enum BedsideGeometry {
    /// Width of the stage's right-hand column — calibration controls, the
    /// Layers chip, and the docked beat card (X71 narrowed this from 220).
    ///
    /// `BeatCalipers.Columns.totalWidth` must fit inside it; `LayoutFitTests`
    /// pins that. A view wider than this draws past the stage and under the
    /// review-queue inspector, which is #205.
    public static let dockedColumnWidth: CGFloat = 186
}
