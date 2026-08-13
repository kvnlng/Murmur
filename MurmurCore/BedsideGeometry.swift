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
/// The cap earns its keep against the split view's width-0 minimum probe,
/// where the strip's `LazyVGrid` collapses to a single column and its ideal
/// height runs to ~1800 pt. `fixedSize` is what keeps the cap a CEILING: a
/// bare `.frame(maxHeight:)` offered more than its maximum claims the whole
/// maximum, which reserved ~95 pt of dead space under the strip (#208).
struct MetricsStripInsetHeight: ViewModifier {
    static let cap: CGFloat = 260

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: Self.cap, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
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
