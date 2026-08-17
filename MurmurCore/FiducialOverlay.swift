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

    /// The beat the analyst pinned (#225), if any. Drawn with a filled cap
    /// on its R-tick so the pin is findable while the cursor is elsewhere —
    /// without it, hovering another beat moves the focus locator away and
    /// nothing on the trace says which beat the card will return to.
    var pinnedRPeakSampleIndex: Int64?

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

    /// #227 — the patient-normal template, for the focused beat's ghost
    /// spans. Nil when the record has no template; only the solid spans
    /// draw then, since there is no normal to deviate from.
    var template: MarkingsTemplate?

    /// #227 — the analyst's Interval Spans toggle
    /// (`IntervalMarkingsContext.showIntervalSpans`), threaded in like
    /// `enabledLayers` rather than read from the context, so snapshots can
    /// exercise both states without touching process-wide defaults.
    var drawIntervalSpans: Bool = false

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

        // The focused beat's PR / QRS / QT spans (#227) — the trace showing
        // the same object the beat card reports. Focused beat only: every
        // beat treated identically is the reason the density gate exists,
        // and spans on hundreds of beats would be clutter, not reading.
        if drawIntervalSpans, focused, policy.drawsIntervalSpans {
            intervalSpanBars(for: beat)
        }

        // QRS boundaries at .qrsOnly and higher, gated by layer toggle.
        if drawable.contains(.qrs) {
            if let q = beat.qrsOnset { boundaryTick(fiducial: q, layer: .qrs, focused: focused) }
            if let s = beat.qrsOffset { boundaryTick(fiducial: s, layer: .qrs, focused: focused) }
            layerLetter(onset: beat.qrsOnset, offset: beat.qrsOffset, layer: .qrs)
        }

        // P / T fiducials at .fullFiducials, each gated by its own
        // layer toggle so an analyst on a QT study can hide P and
        // vice versa without changing the zoom.
        if detailLevel == .fullFiducials {
            if drawable.contains(.p) {
                if let p = beat.pOnset { boundaryTick(fiducial: p, layer: .p, focused: focused) }
                if let p = beat.pOffset { boundaryTick(fiducial: p, layer: .p, focused: focused) }
                layerLetter(onset: beat.pOnset, offset: beat.pOffset, layer: .p)
            }
            if drawable.contains(.t) {
                if let t = beat.tOnset { boundaryTick(fiducial: t, layer: .t, focused: focused) }
                if let t = beat.tOffset { boundaryTick(fiducial: t, layer: .t, focused: focused) }
                layerLetter(onset: beat.tOnset, offset: beat.tOffset, layer: .t)
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

    // MARK: - Interval spans (#227)

    /// Rows anchor at the BOTTOM of the canvas, beneath the trace — the
    /// bracket-lane half of the issue's "both" answer, kept inside this
    /// overlay so it shares the x-mapping with the marks it summarises.
    /// Nested magnitudes read top-to-bottom: PR, QRS inside QT.
    private static let spanRowStride: CGFloat = 8
    private static let spanBarHeight: CGFloat = 4
    private static let spanGhostHeight: CGFloat = 2
    /// Bottom margin + three rows must fit below the glyph band or the rows
    /// would overprint the letters they annotate.
    private static let spanBandHeight: CGFloat = 28

    @ViewBuilder
    private func intervalSpanBars(for beat: MarkingsBeat) -> some View {
        if canvasSize.height > Self.hairlineTopInset + Self.spanBandHeight {
            ForEach(IntervalSpans.spans(for: beat, template: template)) { span in
                intervalSpanBar(span)
            }
        }
    }

    /// One span: a solid bar for THIS beat's duration, and beneath it a
    /// thinner ghost running to the template's — a bullet chart per
    /// interval. The two bars share their start, so the length difference
    /// at the far end IS the deviation the beat card states in ms.
    @ViewBuilder
    private func intervalSpanBar(_ span: IntervalSpan) -> some View {
        if let xs = xClamped(span.startSample),
           let xe = xClamped(span.endSample), xe > xs {
            let y = canvasSize.height - Self.spanBandHeight
                + CGFloat(span.kind.row) * Self.spanRowStride
            let color = FiducialPalette.color(for: span.kind.paletteLayer)
            Rectangle()
                .fill(color.opacity(0.60))
                .frame(width: xe - xs, height: Self.spanBarHeight)
                .offset(x: xs, y: y)
            if let ghostEnd = span.ghostEndSample(sampleRate: sampleRate),
               let xg = xClamped(ghostEnd), xg > xs {
                Rectangle()
                    .fill(color.opacity(0.32))
                    .frame(width: xg - xs, height: Self.spanGhostHeight)
                    .offset(x: xs, y: y + Self.spanBarHeight + 1)
            }
        }
    }

    /// Like `xPosition`, but a sample past the viewport edge maps to the
    /// edge instead of vanishing — a span half in view draws its visible
    /// half rather than nothing.
    private func xClamped(_ sample: Int64) -> CGFloat? {
        xPosition(forSample: min(max(sample, viewportSampleRange.lowerBound),
                                 viewportSampleRange.upperBound))
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
            let pinned = sample == pinnedRPeakSampleIndex
            let color = focused ? Color.accentColor : Color.accentColor.opacity(0.65)
            Rectangle()
                .fill(color)
                .frame(width: focused ? 2 : 1.2, height: 12)
                .offset(x: x - (focused ? 1 : 0.6), y: 0)
            // The pin's own mark (#225): a filled cap at the head of the
            // R-tick. Deliberately NOT a colour change — the pinned beat is
            // frequently also the focused one, and a treatment that collided
            // with focus would vanish exactly when both are true.
            if pinned {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .offset(x: x - 3, y: -1)
            }
        }
    }

    /// Where the glyph band ends and the trace's space begins — the X93
    /// hairlines start here so the confidence dots stay legible.
    /// #226 widened the band to hold the larger dot. Internal because
    /// `SnapshotTests.belowGlyphBand` crops at exactly this line to ask
    /// "did anything reach the trace" — it had its own copy of the number,
    /// so widening the band here silently moved the test's crop into the
    /// glyph band and failed an assertion about the trace.
    /// Where the glyph band ends and the trace's space begins.
    ///
    /// 31 → 38 for #249. The band held a tick (y 13–21) and a 7 pt confidence
    /// dot (21–28); a letter legible enough to outrank the queue's 9 pt glyph
    /// needs ~17 pt of line height, so it runs 19–36 and the boundary has to
    /// clear it. Leaving it at 31 put glyph pixels below the band, which is
    /// exactly what `SnapshotTests.belowGlyphBand` is built to catch — #226 hit
    /// the same edge when it enlarged the dot, and that test's comment records
    /// it.
    ///
    /// The cost is 7 pt of trace height, taken from the top of the hairlines.
    /// The alternative was a letter small enough to fit the old band, which
    /// would fail the feedback's actual ask: the bedside tag has to read larger
    /// than the queue's.
    static let hairlineTopInset: CGFloat = 38

    /// The confidence dot. #226: was 4 pt filled / 5 pt hollow, which is
    /// under the size of a small grid square — at that scale a mark reads as
    /// a printing artifact rather than as a statement about a boundary.
    private static let dotDiameter: CGFloat = 7

    /// Line box reserved for a letter tag, so its bottom edge (19 + this) stays
    /// above `hairlineTopInset`. Fixed rather than intrinsic — see the offset
    /// site.
    static let letterBandHeight: CGFloat = 17

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
        layer: MarkingsFiducialLayer,
        focused: Bool = false
    ) -> some View {
        if let x = xPosition(forSample: fiducial.sampleIndex) {
            // #226: the floor rises from 0.30. On pale-pink paper a deep ink
            // at 30% is a grey suggestion — and it landed on exactly the
            // marks the analyst most needs to see, since low confidence is
            // what a fiducial edit pass goes looking for.
            let alpha = max(0.60, fiducial.confidence)
            let base = FiducialPalette.color(for: layer)
            let color = base.opacity(alpha)
            let isLowConfidence = fiducial.confidence < 0.6
            Rectangle()
                .fill(color)
                .frame(width: 1.5, height: 8)
                .offset(x: x - 0.75, y: 13)
            // #249 — the dot is now the FALLBACK. Where there is room, one
            // letter per layer (see `layerLetter`) sits in this y-band instead
            // and names the wave; where there is not, this is what shipped
            // before and it still fits.
            if !lettersFit {
                if isLowConfidence {
                    Circle()
                        .strokeBorder(color, lineWidth: 1.5)
                        .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                        .offset(x: x - Self.dotDiameter / 2, y: 21)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                        .offset(x: x - Self.dotDiameter / 2, y: 21)
                }
            }
            if detailLevel == .fullFiducials, canvasSize.height > Self.hairlineTopInset {
                Rectangle()
                    .fill(base.opacity(
                        hairlineAlpha(confidence: fiducial.confidence, focused: focused)))
                    .frame(width: 1, height: canvasSize.height - Self.hairlineTopInset)
                    .offset(x: x - 0.5, y: Self.hairlineTopInset)
            }
        }
    }

    /// The letter naming one wave of one beat, centred between its two ticks.
    ///
    /// One per LAYER, not per boundary. Per boundary put "QRS" at both edges of
    /// a complex 24 pt wide at the zoom the letters exist for — the tags
    /// overlapped each other inside every beat. Centred, the ticks keep marking
    /// the edges precisely and the letter says which wave they belong to, which
    /// is what a letter is for.
    ///
    /// Confidence is the WEAKER of the pair. A span is only as trustworthy as
    /// its shakier edge, and rounding up would let a confident onset vouch for
    /// an offset the delineator guessed at.
    @ViewBuilder
    private func layerLetter(
        onset: MarkingsFiducial?,
        offset: MarkingsFiducial?,
        layer: MarkingsFiducialLayer
    ) -> some View {
        if lettersFit,
           let onset, let offset,
           let x = FiducialGeometry.letterPosition(
            onsetX: xPosition(forSample: onset.sampleIndex),
            offsetX: xPosition(forSample: offset.sampleIndex)) {
            let confidence = min(onset.confidence, offset.confidence)
            let alpha = max(0.60, confidence)
            let isLowConfidence = confidence < 0.6
            FiducialLetterTag(
                layer: layer,
                pointSize: FiducialPalette.bedsideLetterPointSize,
                weight: isLowConfidence ? .regular : .semibold)
                // Confidence in the two channels a glyph has: weight above and
                // alpha here, preserving the filled-vs-hollow distinction the
                // dot carried.
                .opacity(isLowConfidence ? alpha * 0.85 : alpha)
                // Height fixed rather than intrinsic: the band's bottom edge
                // is a constant that other code (and a snapshot test) reasons
                // about, so the glyph's footprint must be knowable without
                // rendering it.
                .frame(width: FiducialPalette.letterMinimumSpacing,
                       height: Self.letterBandHeight)
                .offset(x: x - FiducialPalette.letterMinimumSpacing / 2, y: 19)
                .allowsHitTesting(false)
        }
    }

    /// Whether every letter this frame would draw has room, measured on the
    /// positions themselves.
    ///
    /// All-or-nothing on purpose. A per-letter decision would drop tags
    /// wherever a rhythm happened to tighten, so the same wave would be named
    /// in one beat and not the next — and an absent letter reads as "no P
    /// wave here", which is a finding, not a layout outcome. Uniform letters
    /// or uniform dots is the only pair of states that says one thing.
    private var lettersFit: Bool {
        FiducialGeometry.lettersFit(positions: letterPositions)
    }

    /// Where every letter would go, in the same order the drawing walks.
    private var letterPositions: [CGFloat] {
        let drawable = policy.renderableLayers.intersection(enabledLayers)
        var positions: [CGFloat] = []
        for beat in beats {
            for layer in MarkingsFiducialLayer.allCases where drawable.contains(layer) {
                if layer == .qrs || detailLevel == .fullFiducials,
                   let x = FiducialGeometry.letterPosition(
                    onsetX: onsetFiducial(beat, layer).flatMap { xPosition(forSample: $0.sampleIndex) },
                    offsetX: offsetFiducial(beat, layer).flatMap { xPosition(forSample: $0.sampleIndex) }) {
                    positions.append(x)
                }
            }
        }
        return positions
    }

    private func onsetFiducial(_ beat: MarkingsBeat, _ layer: MarkingsFiducialLayer) -> MarkingsFiducial? {
        switch layer {
        case .p:   return beat.pOnset
        case .qrs: return beat.qrsOnset
        case .t:   return beat.tOnset
        }
    }

    private func offsetFiducial(_ beat: MarkingsBeat, _ layer: MarkingsFiducialLayer) -> MarkingsFiducial? {
        switch layer {
        case .p:   return beat.pOffset
        case .qrs: return beat.qrsOffset
        case .t:   return beat.tOffset
        }
    }

    /// Faint for context, stronger where the analyst is looking. Confidence
    /// still modulates — an unsure boundary must not paint an authoritative
    /// line — but within a band that stays visible on the red ECG paper.
    ///
    /// #226 raised the band from 0.10–0.22. It did not stay visible: at 0.10,
    /// in the paper's own hue, a one-point line was indistinguishable from
    /// the grid it crossed. The hierarchy the comment describes is preserved,
    /// an octave up — context lines still read as context, the focused beat's
    /// still read as stronger, and both are now actually on screen.
    private func hairlineAlpha(confidence: Double, focused: Bool) -> Double {
        let base = 0.22 + 0.16 * min(max(confidence, 0), 1)
        return focused ? min(0.60, base * 1.7) : base
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

    // (Moved by #249) `FiducialColor`, a parallel enum of the same three cases
    // as `MarkingsFiducialLayer`. The letter→colour map now lives in
    // `FiducialPalette` so the Review queue can read the same one — the point
    // of the feedback's "always the same for each letter" is that one
    // definition exists, which two enums cannot provide. The #226 history that
    // was recorded here moved with it.
}
