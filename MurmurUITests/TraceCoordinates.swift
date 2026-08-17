//
//  TraceCoordinates.swift
//  MurmurUITests
//
//  Where on the trace a UI test is allowed to point.
//
//  One home rather than a constant repeated per suite: the reasoning below is
//  the whole content of the rule, and a copy of it in two files drifts the way
//  every other duplicated size in this project has.
//

import XCTest

enum TraceCoordinates {
    /// Vertical position, as a fraction of the trace element's frame, that a
    /// test may hover or click.
    ///
    /// **Not 0.5.** The centre column scrolls (#202 / #207) — deliberately, so
    /// that a short window costs the analyst a scroll rather than a surface —
    /// and XCUI resolves a normalized offset against the element's FULL
    /// accessibility frame, including whatever sits below the scroll viewport.
    /// On Xcode Cloud's short runner roughly 46% of the canvas is in view, so
    /// `dy: 0.5` resolved to a point outside the viewport and the hover landed
    /// on the status-bar row. Three UI tests failed that way through builds
    /// 138–141 (#277), with the app behaving correctly the entire time: nothing
    /// was under the pointer, so nothing was shown. The test was aiming
    /// somewhere the analyst cannot see either.
    ///
    /// The scroll sits at the top on launch, so the canvas's upper band is
    /// visible in any window that shows the stage at all. 0.2 keeps margin
    /// against the runner's ~46%.
    ///
    /// Vertical position does not choose a beat, which is why moving it costs
    /// nothing: `ChannelPanel.cursorSampleIndex` derives the sample from
    /// `location.x` alone, and `nearestBeat` is a binary search with no
    /// distance tolerance, so any x inside the canvas focuses the nearest
    /// beat. `dy` only has to land on the canvas.
    static let hoverableY: CGFloat = 0.2
}
