//
//  WaveformRenderStateContext.swift
//  MurmurCore
//
//  What the trace is ACTUALLY drawing right now, published so the info bar can
//  say it.
//
//  X69. Both facts the info bar reports about rendering were, until now,
//  unreachable from outside the canvas:
//
//    - the semantic zoom tier and its `pointsPerBeat` reading lived in
//      `ChannelPanel`'s private `@State`, and
//    - the level-of-detail actually selected lived in
//      `WaveformCanvas.Coordinator`, a class SwiftUI owns and nothing else
//      can see into.
//
//  Neither is a *setting* — both are consequences of the viewport, the canvas
//  width and the beat density, decided per frame deep in the render path. So
//  they are published outward rather than lifted upward: the info bar reports
//  what happened, it does not get a say.
//
//  Same shape as `IntervalMarkingsContext.set(renderPolicy:)`, which exists
//  because the Layers chip had the identical problem — a surface one level up
//  that needs to state what the renderer chose, with no access to the geometry
//  the choice was made from. A chip that claims every enabled layer is on
//  screen when the renderer has dropped two is the defect that pattern fixed.
//
//  ## Exactly one writer
//
//  A recording in strips mode has one `ChannelPanel` per lead, and a panel
//  with overlaid leads has three `WaveformCanvas`es. Left unguarded that is a
//  dozen writers racing to describe one info bar, last-write-wins.
//
//  So writes are fenced twice: `ChannelPanel` publishes only when
//  `sizing == .focus`, and `WaveformCanvas` only when it is the canvas that
//  owns the paper. Those two conditions pick out one canvas — the same one
//  whose identity stays stable across ⌘-click, which is also the primary lead
//  every mark and measurement belongs to.
//

import Foundation
import Observation

/// The level-of-detail a canvas resolved for the current viewport.
///
/// `raw` is not "level 0" — it is the absence of decimation, and saying so
/// costs nothing while `L0 · 1 sample/bin` would be a small lie about what the
/// pyramid contains.
public enum WaveformLOD: Equatable, Sendable {
    /// Painting raw samples: at most one sample per pixel, no pyramid read.
    case raw
    /// Painting a min/max envelope from pyramid level `level` (1-based),
    /// each bin covering `binSamples` raw samples.
    case pyramid(level: Int, binSamples: Int)

    /// How the info bar says it. `PyramidBuilder` cascades 10× per level, so
    /// the bin size is derivable — but deriving it in the view would duplicate
    /// the builder's arithmetic in a second place, and the two would drift.
    public var label: String {
        switch self {
        case .raw:
            return "raw samples"
        case .pyramid(let level, let binSamples):
            return "L\(level) · \(binSamples) samples/bin"
        }
    }
}

/// Process-wide publication of the focused trace's render state.
///
/// Deliberately holds no policy and no defaults worth trusting before a first
/// frame: `lod` is `nil` until a canvas has actually resolved one, so the info
/// bar can omit the field rather than assert a level nothing has drawn.
@MainActor
@Observable
public final class WaveformRenderStateContext {
    public static let shared = WaveformRenderStateContext()

    /// Points of canvas width per beat in the current window. Drives the tier.
    public private(set) var pointsPerBeat: Double?

    /// The semantic zoom regime the trace is rendering under.
    public private(set) var zoomTier: WaveformZoomTier?

    /// What the canvas is painting from. `nil` before the first resolved frame.
    public private(set) var lod: WaveformLOD?

    public init() {}

    /// Written by the focus-sized `ChannelPanel`, once per tier change.
    ///
    /// A non-finite `pointsPerBeat` is stored as `nil`, not passed through.
    /// `WaveformZoomTierSelector.pointsPerBeat` returns `.nan` to mean "no
    /// beats in this window" — a real and common state, since it is what every
    /// record looks like between mount and the first delineated frame. NaN is
    /// that selector's way of saying *there is no reading*, so this stores the
    /// absence rather than an unusable number. (Passing it through cost a
    /// launch crash: the info bar's `Int(ppb.rounded())` traps on NaN.)
    public func set(zoomTier: WaveformZoomTier, pointsPerBeat: Double) {
        self.zoomTier = zoomTier
        self.pointsPerBeat = pointsPerBeat.isFinite ? pointsPerBeat : nil
    }

    /// Written by the paper-owning `WaveformCanvas` when its LOD selection
    /// changes. Guarded against redundant writes at the call site so a
    /// per-frame render path doesn't invalidate the info bar 60 times a
    /// second.
    public func set(lod: WaveformLOD) {
        guard self.lod != lod else { return }
        self.lod = lod
    }

    /// Closing a record must not leave the previous one's numbers on screen.
    public func clear() {
        pointsPerBeat = nil
        zoomTier = nil
        lod = nil
    }
}
