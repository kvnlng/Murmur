//
//  FiducialOverlay.swift
//  MurmurCore
//
//  SwiftUI overlay drawn above the Metal ECG canvas that renders the
//  per-beat fiducials from `IntervalMarkingsContext`. Zoom level-of-
//  detail per the interval-markings spec:
//
//    - Zoomed OUT (> 30 s viewport): R-ticks only — beat presence at a
//      glance without the visual clutter of thousands of P/T marks.
//    - Mid zoom (3–30 s): R + QRS boundaries. Enough to see QRS width
//      when scanning arrhythmia.
//    - Zoomed IN (< 3 s): full P / QRS-on/off / T fiducials. This is
//      where the analyst actually reads intervals.
//
//  Confidence-flagged: low-confidence fiducials render dimmer + with
//  a hollow marker so the analyst can see where the detector is
//  unsure. Matches the spec's "visible honesty beats false precision"
//  guardrail.
//
//  Focused beat (from the calipers panel) draws a subtle accent glow
//  so the analyst knows which beat's numbers are on screen. Pure
//  overlay; no gesture handling here (calipers own that).
//

import SwiftUI

struct FiducialOverlay: View {

    /// Beats to render. Caller slices by viewport before passing in.
    let beats: [MarkingsBeat]

    /// Absolute time-range the canvas is showing (seconds from
    /// recording start). Aligned with `viewport.startSample/endSample`
    /// divided by `sampleRate`.
    let viewportSampleRange: Range<Int64>

    /// Sample rate — same value the orchestrator wrote into the
    /// context. 0 disables drawing.
    let sampleRate: Double

    /// LOD chosen by the caller based on the viewport window length.
    let detailLevel: MarkingsDetailLevel

    /// The R-peak sample index of the beat currently focused by the
    /// calipers panel, or nil when nothing is focused.
    let focusedRPeakSampleIndex: Int64?

    /// Layers the analyst has enabled. R-peak marks always render;
    /// P / QRS / T marks only render when their layer is in this
    /// set AND the current detail level permits them.
    let enabledLayers: Set<MarkingsFiducialLayer>

    /// Canvas dimensions passed from the enclosing `GeometryReader`.
    let canvasSize: CGSize

    /// Semantic-zoom tier for the current viewport. The mockup at
    /// Planning/design/waveform-zoom-lod.html explicitly DROPS
    /// per-beat fiducial ticks at Scan ("Drops: per-beat chips,
    /// fiducial ticks, normal-beat marks") and at Context (rail is
    /// landmarks + focus locator only). At those tiers the per-beat
    /// R-ticks + boundary marks this overlay draws became the residual
    /// "blue marker per beat" Kevin saw on wide-zoom recordings —
    /// this gate omits them entirely. The Metal focus locator + the
    /// SwiftUI landmark/flagged rail carry the "which beats matter"
    /// signal at those tiers. Default `.inspect` preserves existing
    /// callers/tests that haven't been tier-wired.
    var tier: WaveformZoomTier = .inspect

    /// The single authority on what this overlay draws at this zoom (X61).
    /// The Layers chip resolves the SAME policy so the control cannot claim
    /// a layer is on while this body drops it.
    private var policy: FiducialRenderPolicy {
        FiducialRenderPolicy.resolve(tier: tier, detailLevel: detailLevel)
    }

    var body: some View {
        // Fiducial per-beat marks live at Inspect only. Scan + Context
        // drop them per the ratified spec + Kevin's 2026-07-07 note
        // (per-beat blue markers should disappear alongside the
        // caliper marker).
        if !policy.drawsMarks {
            EmptyView()
        } else if canvasSize.width > 0, sampleRate > 0, !beats.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(beats) { beat in
                    beatMarks(for: beat)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("fiducial-overlay")
        }
    }

    // MARK: - Per-beat drawing

    @ViewBuilder
    private func beatMarks(for beat: MarkingsBeat) -> some View {
        // R-tick at every LOD. R marks always render — they anchor
        // beat identity and never get toggled off.
        rTick(atSample: beat.rPeakSampleIndex, focused: beat.rPeakSampleIndex == focusedRPeakSampleIndex)

        // A layer draws only where the policy allows it AND the analyst has
        // enabled it. Both conditions read from the same policy the Layers
        // chip reports, so "enabled" on the chip and "drawn" here cannot
        // disagree without a test noticing.
        let drawable = policy.renderableLayers.intersection(enabledLayers)

        let focused = beat.rPeakSampleIndex == focusedRPeakSampleIndex

        // QRS boundaries at .qrsOnly and higher, gated by layer toggle.
        if drawable.contains(.qrs) {
            if let q = beat.qrsOnset { boundaryTick(fiducial: q, colorStyle: .qrs, focused: focused) }
            if let s = beat.qrsOffset { boundaryTick(fiducial: s, colorStyle: .qrs, focused: focused) }
        }

        // P / T fiducials at .fullFiducials, each gated by its own
        // layer toggle so an analyst on a QT study can hide P and
        // vice versa without changing the zoom.
        if detailLevel == .fullFiducials {
            if drawable.contains(.p) {
                if let p = beat.pOnset { boundaryTick(fiducial: p, colorStyle: .p, focused: focused) }
                if let p = beat.pOffset { boundaryTick(fiducial: p, colorStyle: .p, focused: focused) }
            }
            if drawable.contains(.t) {
                if let t = beat.tOnset { boundaryTick(fiducial: t, colorStyle: .t, focused: focused) }
                if let t = beat.tOffset { boundaryTick(fiducial: t, colorStyle: .t, focused: focused) }
                // Tangent↔isoelectric bracket (project_qtc_trend_uncertainty_wireup_spec.md
                // Phase 6): the T-offset fiducial is the tangent-based
                // POINT estimate; the isoelectric endpoint marks where
                // the signal actually settles. The visible span between
                // them is the per-beat T-offset uncertainty bounded by
                // two independent algorithms. Drawn only at full-zoom
                // LOD (where fiducial ticks are already visible) and
                // only when both endpoints are available — an
                // unavailable upper edge suppresses the bracket rather
                // than fabricating a substitute.
                if let tangent = beat.tOffset,
                   let iso = beat.tOffsetIsoelectricSampleIndex {
                    tOffsetBracket(tangentSample: tangent.sampleIndex,
                                   isoelectricSample: iso)
                }
            }
        }
    }

    /// Horizontal bracket connecting the tangent and isoelectric
    /// T-offset endpoints. Neutral ink (this is app-computed
    /// measurement uncertainty, not an analyst finding) with small
    /// vertical caps at each end. Positioned at the same y-band as
    /// the boundary-tick dots so the bracket reads as an extension of
    /// the T-offset fiducial.
    @ViewBuilder
    private func tOffsetBracket(tangentSample: Int64, isoelectricSample: Int64) -> some View {
        if let xTan = xPosition(forSample: tangentSample),
           let xIso = xPosition(forSample: isoelectricSample) {
            let lo = min(xTan, xIso)
            let hi = max(xTan, xIso)
            let width = max(hi - lo, 1)
            let color = Color.primary.opacity(0.55)
            // Horizontal span
            Rectangle()
                .fill(color)
                .frame(width: width, height: 1)
                .offset(x: lo, y: 25)
            // End caps — 3-pt tall vertical ticks at each endpoint.
            Rectangle()
                .fill(color)
                .frame(width: 1, height: 3)
                .offset(x: lo - 0.5, y: 24)
            Rectangle()
                .fill(color)
                .frame(width: 1, height: 3)
                .offset(x: hi - 0.5, y: 24)
        }
    }

    // MARK: - Individual marks

    /// A slightly taller tick with a small label, drawn at every beat's
    /// R-peak regardless of LOD.
    @ViewBuilder
    private func rTick(atSample sample: Int64, focused: Bool) -> some View {
        if let x = xPosition(forSample: sample) {
            let color = focused ? Color.accentColor : Color.accentColor.opacity(0.65)
            Rectangle()
                .fill(color)
                .frame(width: focused ? 2 : 1.2, height: 12)
                .offset(x: x - (focused ? 1 : 0.6), y: 0)
        }
    }

    /// Where the glyph band ends and the trace's space begins — the X93
    /// hairlines start here so the confidence dots stay legible.
    private static let hairlineTopInset: CGFloat = 28

    /// A short tick + optional dot for a boundary fiducial (P/QRS/T).
    /// Confidence modulates alpha; low-confidence gets a hollow ring
    /// so the analyst can spot it.
    ///
    /// X93 (#142): at full-fiducial zoom — exactly the window the Layers
    /// chip claims "all" — each drawn boundary ALSO extends as a faint
    /// full-height hairline through the trace. The 8-pt ticks lived only
    /// in the top glyph band, hundreds of points above the waveform they
    /// annotate, and read as grid noise: "available" on the chip while
    /// nothing visible touched the complexes (Kevin's 2026-08-09 note).
    /// The mockup reserved full-height lines for the focused beat; this
    /// extends them, faintly, to every drawn boundary at the one zoom
    /// where the spec says the analyst reads intervals — the focused
    /// beat's lines render stronger, keeping that hierarchy.
    @ViewBuilder
    private func boundaryTick(
        fiducial: MarkingsFiducial,
        colorStyle: FiducialColor,
        focused: Bool = false
    ) -> some View {
        if let x = xPosition(forSample: fiducial.sampleIndex) {
            // Alpha bottoms out at 0.30 so even low-confidence marks
            // stay visible (analyst can then click to edit).
            let alpha = max(0.30, fiducial.confidence)
            let color = colorStyle.color.opacity(alpha)
            let isLowConfidence = fiducial.confidence < 0.6
            Rectangle()
                .fill(color)
                .frame(width: 1, height: 8)
                .offset(x: x - 0.5, y: 14)
            // Confidence marker: filled dot for confident, hollow ring
            // for unsure.
            if isLowConfidence {
                Circle()
                    .strokeBorder(color, lineWidth: 1)
                    .frame(width: 5, height: 5)
                    .offset(x: x - 2.5, y: 22)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .offset(x: x - 2, y: 22.5)
            }
            if detailLevel == .fullFiducials, canvasSize.height > Self.hairlineTopInset {
                Rectangle()
                    .fill(colorStyle.color.opacity(
                        hairlineAlpha(confidence: fiducial.confidence, focused: focused)))
                    .frame(width: 1, height: canvasSize.height - Self.hairlineTopInset)
                    .offset(x: x - 0.5, y: Self.hairlineTopInset)
            }
        }
    }

    /// Faint for context, stronger where the analyst is looking. Confidence
    /// still modulates — an unsure boundary must not paint an authoritative
    /// line — but within a band that stays visible on the red ECG paper.
    private func hairlineAlpha(confidence: Double, focused: Bool) -> Double {
        let base = 0.10 + 0.12 * min(max(confidence, 0), 1)
        return focused ? min(0.45, base * 2) : base
    }

    // MARK: - Coordinate mapping

    /// Convert a sample index into an x-coordinate in canvas points.
    /// Returns `nil` for samples outside the viewport.
    private func xPosition(forSample sample: Int64) -> CGFloat? {
        let start = viewportSampleRange.lowerBound
        let end = viewportSampleRange.upperBound
        guard sample >= start, sample <= end, end > start else { return nil }
        let span = Double(end - start)
        let fraction = Double(sample - start) / span
        return CGFloat(fraction) * canvasSize.width
    }

    // MARK: - Color palette

    private enum FiducialColor {
        case p
        case qrs
        case t

        var color: Color {
            switch self {
            case .p:   return Color(hue: 0.75, saturation: 0.55, brightness: 0.85)  // violet
            case .qrs: return Color(hue: 0.02, saturation: 0.65, brightness: 0.90)  // red-orange
            case .t:   return Color(hue: 0.55, saturation: 0.55, brightness: 0.80)  // teal
            }
        }
    }
}
