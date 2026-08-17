//
//  FiducialRenderPolicy.swift
//  MurmurCore
//
//  What the fiducial overlay will actually draw for a given viewport,
//  independent of what the analyst has toggled on. ONE authority, read by
//  both the renderer (`FiducialOverlay`) and the control (`BedsideView`'s
//  Layers chip).
//
//  X61: the chip offered P / QRS / T toggles and reported `Layers · all`
//  while the renderer was dropping P and T. The toggles were not broken —
//  they were gated TWICE, by the semantic zoom tier (`WaveformZoomTier`,
//  keyed on points-per-beat) and by the detail level (`MarkingsDetailLevel`,
//  keyed on viewport seconds), and neither gate was visible in the control.
//  Standard View opens at roughly a 4.5 s window, which lands in `.qrsOnly`,
//  so on a freshly opened record two of the three toggles did nothing.
//
//  The fix is not to loosen the gates — the zoom spec's density rule stands
//  (project_waveform_zoom_lod_spec.md). It is to make the control report
//  them. That only stays true if the control and the renderer read the SAME
//  rule, so the rule lives here rather than inline in the overlay's body.
//  Two copies of one rule is exactly how the two drifted apart in the first
//  place.
//

import Foundation

/// The renderer's answer to "what am I drawing at this zoom?".
public struct FiducialRenderPolicy: Sendable, Equatable {

    /// Whether per-beat marks are drawn at all. False at every tier above
    /// Inspect, where the mockup explicitly drops per-beat fiducial ticks
    /// and the focus locator + landmark rail carry the signal instead.
    /// When false, even R-ticks are absent — no toggle can change that.
    public let drawsMarks: Bool

    /// The toggleable layers the renderer will honour, given `drawsMarks`.
    /// R marks are not in this set: they anchor beat identity and are never
    /// toggleable.
    public let renderableLayers: Set<MarkingsFiducialLayer>

    /// Why layers are missing, when they are. Drives the analyst-facing
    /// explanation on the Layers chip — the chip names the binding
    /// constraint rather than guessing at one.
    public enum Suppression: Sendable, Equatable {
        /// Nothing suppressed — every layer can render.
        case none
        /// Too many beats on screen; the overlay is off entirely.
        case tooManyBeatsOnScreen
        /// The window is too long for these layers, though marks do render.
        case windowTooLong
    }

    public let suppression: Suppression

    /// Resolve the policy for a viewport. Pure — no geometry, no view state.
    public static func resolve(
        tier: WaveformZoomTier,
        detailLevel: MarkingsDetailLevel
    ) -> FiducialRenderPolicy {
        // Tier dominates: above Inspect the overlay draws nothing at all,
        // whatever the detail level says.
        guard tier == .inspect else {
            return .init(
                drawsMarks: false,
                renderableLayers: [],
                suppression: .tooManyBeatsOnScreen
            )
        }
        switch detailLevel {
        case .fullFiducials:
            return .init(
                drawsMarks: true,
                renderableLayers: [.p, .qrs, .t],
                suppression: .none
            )
        case .qrsOnly:
            return .init(drawsMarks: true, renderableLayers: [.qrs], suppression: .windowTooLong)
        case .rTicksOnly:
            return .init(drawsMarks: true, renderableLayers: [], suppression: .windowTooLong)
        }
    }

    /// Layers the analyst has enabled that the renderer is currently
    /// dropping. Empty when the control and the canvas agree — which is the
    /// only state in which the chip may report the enabled set plainly.
    public func suppressedLayers(
        enabled: Set<MarkingsFiducialLayer>
    ) -> Set<MarkingsFiducialLayer> {
        drawsMarks ? enabled.subtracting(renderableLayers) : enabled
    }

    /// Canonical P·QRS·T ordering for every readout, so a conduction-study
    /// analyst can confirm the set at a glance.
    private static let readoutOrder: [MarkingsFiducialLayer] = [.p, .qrs, .t]

    /// The same canonical ordering, for callers outside this file.
    ///
    /// #248 moved the layer controls to the menu bar and left an in-window
    /// note naming what the zoom is holding back. That note lists layers, so
    /// it needs this ordering — and it needs to be THIS ordering, not a
    /// second one that happens to agree today. Waveform order is the whole
    /// point: P·QRS·T is how the sequence is read.
    public static func readoutOrdered(
        _ layers: Set<MarkingsFiducialLayer>
    ) -> [MarkingsFiducialLayer] {
        readoutOrder.filter(layers.contains)
    }

    /// The Layers chip's readout. Reports what the canvas is SHOWING, with a
    /// suffix naming what the zoom is holding back — so a toggle that cannot
    /// act is never silent about it.
    ///
    /// Lives here rather than in the view because it is the sentence that
    /// makes the control honest, and a sentence nobody can test is how the
    /// control came to lie in the first place.
    public func summary(enabled: Set<MarkingsFiducialLayer>) -> String {
        let showing = Self.readoutOrder.filter {
            drawsMarks && enabled.contains($0) && renderableLayers.contains($0)
        }
        let held = Self.readoutOrder.filter { suppressedLayers(enabled: enabled).contains($0) }

        let head: String
        if !drawsMarks {
            head = "hidden"
        } else if showing.isEmpty {
            head = "R only"
        } else if showing.count == Self.readoutOrder.count {
            head = "all"
        } else {
            head = showing.map(\.displayName).joined(separator: "·")
        }
        guard drawsMarks, !held.isEmpty else { return head }
        return "\(head) · \(held.map(\.displayName).joined(separator: "·")) hidden"
    }

    /// One sentence naming the binding constraint, or nil when nothing the
    /// analyst enabled is being dropped. Quotes the thresholds from
    /// `MarkingsDetailLevel` rather than restating them, so the copy cannot
    /// drift away from the rule it describes.
    public func explanation(
        enabled: Set<MarkingsFiducialLayer>
    ) -> String? {
        guard !suppressedLayers(enabled: enabled).isEmpty else { return nil }
        switch suppression {
        case .none:
            return nil
        case .tooManyBeatsOnScreen:
            return "Beat marks are hidden with this many beats on screen. Zoom in to show them."
        case .windowTooLong:
            if renderableLayers.isEmpty {
                return String(
                    format: "Beat marks need a window under %g s.",
                    MarkingsDetailLevel.qrsMaxSeconds
                )
            }
            return String(
                format: "P and T marks need a window under %g s.",
                MarkingsDetailLevel.fullFiducialsMaxSeconds
            )
        }
    }
}
