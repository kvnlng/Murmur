//
//  ChannelPanel.swift
//  MurmurCore
//
//  One lead's panel: the Metal waveform canvas, the SwiftUI overlays drawn on
//  top of it (annotation rail, fiducials, crosshair), and the gestures that
//  pan and zoom the shared viewport. Extracted from BedsideView in X67 — at
//  ~990 lines it was the single largest thing in that file, and it is where
//  the stage tickets (X70, X71) land.
//

import AppKit
import Charts
import SwiftUI

struct ChannelPanel: View {
    enum Sizing {
        /// Strips mode — compact stacked layout. Floor is small enough that a
        /// short window can still show a couple of leads at once.
        case strip
        /// Focus mode — chart fills the available vertical space. Floor is the
        /// smallest window-height the analyst is likely to ever want.
        case focus

        var canvasMinHeight: CGFloat {
            switch self {
            case .strip: return 130
            case .focus: return 360
            }
        }

        var expands: Bool {
            self == .focus
        }
    }

    let channel: Channel
    let directory: URL
    let viewport: RecordingViewport
    /// Shared calibration (X40). The focus-sized panel publishes its measured
    /// canvas size + visible mV span here so the readout can convert to
    /// clinical units; strip panels don't (the readout is a focus-mode surface).
    let calibration: Calibration
    let annotations: [Annotation]
    /// VT/VF model candidate episodes (range annotations) to draw as
    /// translucent bands on the trace so a queue jump lands on a visible
    /// region. Kept separate from `annotations` because candidates route
    /// through the region-keyed disposition store, not the annotation one.
    var candidates: [Annotation] = []
    var sizing: Sizing = .strip
    /// Leads overlaid on top of `channel`, in selection order (X64-B). Empty
    /// for the single-lead stage and for every strip panel — strips mode is
    /// unchanged and remains the separated multi-lead reading.
    ///
    /// These contribute a trace and nothing else: no paper, no grid, no marks,
    /// no hit testing. Everything that carries a MEASUREMENT belongs to
    /// `channel`, the designated primary.
    var overlayChannels: [Channel] = []

    @State private var clippedRanges: [ClippedRange] = []
    /// Recording-wide min/max for this channel, populated by the same
    /// background scan that builds `clippedRanges`. nil until the scan
    /// finishes (or empty for zero-sample channels). Drives both the
    /// header range badge and the per-channel Y-axis autoscale.
    @State private var sampleRange: MinMaxScanner.Range?
    /// This panel's measured canvas height in points, feeding the gain-derived
    /// amplitude window (X40). 0 until first layout → displayRange falls back
    /// to ±5 mV meanwhile.
    @State private var canvasHeightPoints: CGFloat = 0

    // Per-gesture starting state so each gesture is computed against the
    // viewport as it was when the gesture began, not the most recent update.
    @State private var dragStartRange: Range<Int64>?
    @State private var zoomStartWidth: Int64?

    /// Signature of the visible annotation set on the previous drag tick.
    /// What goes into the set depends on `hapticMode` — IDs for the
    /// "every new annotation" mode, categories for the "new category
    /// only" mode. A non-empty delta vs. this set triggers a haptic
    /// tick. Reset on drag start.
    @State private var lastHapticSignature: Set<String> = []

    /// Visual translation in points applied to the chart content while a
    /// drag is pulling past a viewport boundary. Stays at zero when the
    /// drag is within the recording's bounds. When the user pulls past
    /// `startSample == 0` or `endSample == totalSamples`, the excess
    /// drag distance is fed through a rubber-band damping curve and the
    /// chart shifts to follow the cursor partially — the classic
    /// iOS-style elastic edge. Springs back to 0 on drag release.
    @State private var overscrollPx: CGFloat = 0

    /// User preference for haptic feedback during pan. Stored in
    /// UserDefaults via `@AppStorage`; defaults to `.off` so first-launch
    /// is silent. Live-read every onChanged so toggling the Settings
    /// picker takes effect on the next drag without restart.
    @AppStorage(HapticPreferences.modeKey)
    private var hapticMode: HapticMode = HapticPreferences.defaultMode

    // Hover-driven tooltip: which finding is under the cursor, and where
    // (in canvas-local coordinates) the cursor currently sits.
    @State private var hoveredAnnotation: Annotation?
    @State private var hoverLocation: CGPoint = .zero
    /// True while the pointer is anywhere over the canvas. Drives the
    /// vertical crosshair + time readout — present even when there's no
    /// finding under the cursor.
    @State private var hoverIsActive: Bool = false

    /// Bidirectional hover coordination with the variability lane. The
    /// canvas publishes its own hover time (source .ecg) so the lane
    /// highlights the corresponding sample, and reads back the lane's
    /// hover (source .lane) so it can draw a translucent band over
    /// the beats that produced the hovered metric — the "window-on-
    /// signal" signature interaction from the variability-lane spec.
    @State private var laneContext = VariabilityLaneContext.shared

    /// Read of the per-beat fiducial store — powers the FiducialOverlay
    /// drawn above the Metal canvas. Written by the App target's
    /// IntervalMarkingsOrchestrator.
    @State private var markingsContext = IntervalMarkingsContext.shared

    /// Semantic-zoom tier for the waveform per
    /// project_waveform_zoom_lod_spec.md. Persists across body evals so
    /// `WaveformZoomTierSelector.select(current:)`'s hysteresis is
    /// honoured — otherwise the tier would strobe on slow zooms across
    /// a threshold. Written asynchronously via `.task(id:)` when the
    /// resolved tier for the current viewport differs from the stored
    /// value.
    @State private var waveformZoomTier: WaveformZoomTier = .inspect

    private static let yMin: Double = -5
    private static let yMax: Double =  5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            HStack(alignment: .top, spacing: 0) {
                WaveformVoltageAxis(yMin: displayRange.lowerBound, yMax: displayRange.upperBound, durationSeconds: durationSeconds)
                    .frame(minHeight: sizing.canvasMinHeight)
                canvasArea
            }
            .frame(maxHeight: sizing.expands ? .infinity : nil)
            // At Context zoom the density lane below the trace used to
            // render bulk-category intensity here, but the ratified
            // design (Kevin, 2026-07-07) hands the far-out density job
            // off to the pinned Overview strip below — a heatmap-style
            // strip beneath the trace was competing visually with the
            // Overview and duplicating the density surface. The trace
            // area at Context now shows envelope silhouette + rare
            // landmarks + focus locator ONLY; the Overview carries
            // the "where in the recording" density read.
            leadLegend
            WaveformTimeAxis(startTime: startTime, endTime: endTime)
                .padding(.leading, 56)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channel-panel-\(channel.name)")
        .task { await scanForOffScale() }
    }

    /// True when more than one lead is on this stage. Gates every piece of
    /// overlay chrome, so the single-lead stage stays exactly what it was.
    private var isOverlaying: Bool { !overlayChannels.isEmpty }

    /// Every lead on this stage in render order — primary first, which is also
    /// the rank `LeadPalette` hands out inks by.
    private var stagedLeads: [Channel] { [channel] + overlayChannels }

    /// Spoken description of one staged lead. The ink NAME is spoken because a
    /// swatch says nothing to VoiceOver, and "which trace is which" is exactly
    /// what this surface has to answer.
    private func leadDescription(rank: Int, lead: Channel) -> String {
        rank == 0
            ? "\(lead.name), primary lead, black"
            : "\(lead.name), overlaid in \(LeadPalette.ink(rank: rank).name)"
    }

    /// Left-edge label per overlaid trace, in that trace's ink.
    ///
    /// Absent entirely on the single-lead stage — one unlabelled black trace is
    /// what the stage has always shown, and §5.3 requires that case to be
    /// unchanged.
    @ViewBuilder
    private var leadEdgeLabels: some View {
        if !overlayChannels.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(stagedLeads.enumerated()), id: \.element.id) { rank, lead in
                    Text(lead.name)
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(LeadPalette.ink(rank: rank).color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.regularMaterial))
                        .accessibilityLabel(leadDescription(rank: rank, lead: lead))
                        .accessibilityIdentifier("lead-edge-label-\(lead.name)")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Legend beneath the stage, keyed to the trace inks, naming which lead is
    /// primary. The primary is stated rather than implied because the marks,
    /// the inspector and the calibration readout all belong to it — an analyst
    /// reading a fiducial needs to know which trace it was measured from.
    @ViewBuilder
    private var leadLegend: some View {
        if !overlayChannels.isEmpty {
            HStack(spacing: 12) {
                ForEach(Array(stagedLeads.enumerated()), id: \.element.id) { rank, lead in
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(LeadPalette.ink(rank: rank).color)
                            .frame(width: 16, height: 3)
                        Text(lead.name)
                            .font(.caption2.monospaced().weight(.semibold))
                        if rank == 0 {
                            Text("primary")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(leadDescription(rank: rank, lead: lead))
                    .accessibilityIdentifier("lead-legend-\(lead.name)")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 56)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lead-legend")
        }
    }

    /// Effective display range for the canvas + voltage axis.
    ///   • A canonical gain is set (Standard View / a preset / Fit to window)
    ///     → the mV window is DERIVED from that gain + this panel's height +
    ///     the display's physical size, centred on the baseline (X40).
    ///   • Otherwise → the legacy fixed ±5 mV reference (also the fallback
    ///     until the canvas is measured or when the display size is untrusted).
    /// There is no live Auto-Y mode any more — a scale that rescaled per window
    /// was the amplitude-ruler incoherence X40 closes; fitting is now one-shot.
    private var displayRange: ClosedRange<Double> {
        if let gain = calibration.gainMillimetersPerMillivolt,
           canvasHeightPoints > 0,
           let mmPerPoint = DisplayMetrics.millimetersPerPoint(),
           let halfSpan = CalibrationMath.millivoltHalfSpan(
               gainMillimetersPerMillivolt: gain,
               canvasHeightPoints: Double(canvasHeightPoints),
               millimetersPerPoint: mmPerPoint
           ) {
            return -halfSpan...halfSpan
        }
        return Self.yMin...Self.yMax
    }

    /// One-shot "Fit amplitude to window" (X40) — replaces the deleted live
    /// Auto Y. Computes a single gain so the observed excursion fits the
    /// baseline-centred window (10% headroom), sets the shared gain, and the
    /// view is then in a plain non-standard gain state the readout reports.
    /// Per-channel observed range but SHARED gain, matching the focused lead.
    private func fitAmplitudeToWindow() {
        guard let range = sampleRange, !range.isEmpty,
              canvasHeightPoints > 0,
              let mmPerPoint = DisplayMetrics.millimetersPerPoint() else { return }
        let extent = Double(max(abs(range.min), abs(range.max))) * 1.1
        guard let gain = CalibrationMath.fitGain(
            extentMillivolts: extent,
            canvasHeightPoints: Double(canvasHeightPoints),
            millimetersPerPoint: mmPerPoint
        ) else { return }
        calibration.gainMillimetersPerMillivolt = gain
    }

    /// Publish this panel's trace geometry to the shared calibration so the
    /// readout can report clinical units. Only the focus-sized panel writes —
    /// the readout is a focus-mode surface and strip panels would clobber it.
    private func publishCalibrationGeometry(canvasSize: CGSize) {
        guard sizing == .focus else { return }
        calibration.canvasSize = canvasSize
        calibration.visibleMillivoltSpan = displayRange.upperBound - displayRange.lowerBound
    }

    private var canvasArea: some View {
        // Read the canvas size directly via GeometryReader instead of the
        // preference-key + onPreferenceChange dance. In Swift 6 strict
        // concurrency, `onPreferenceChange`'s `@Sendable` perform closure
        // silently swallows `@State` mutations on the host view, leaving
        // canvasSize permanently at .zero — which then trips the
        // `canvasSize.width > 0` guards in panGesture and the crosshair.
        // Capturing `geo.size` synchronously below avoids the indirection
        // entirely.
        GeometryReader { geo in
            let liveSize = geo.size
            // Points-per-beat for THIS viewport, at THIS panel's width.
            // Feeds the semantic zoom tier — the annotation-rail
            // treatment, the fiducial detail level, and (in follow-up
            // commits) the density lane all key off the same value so
            // every layer stays in lockstep with what the trace itself
            // is showing.
            //
            // BEAT SOURCE: prefer the delineator's fiducial store when
            // it's populated (paid ECG Metrics active), otherwise fall
            // back to counting the wfdb.atr POINT annotations in the
            // viewport. Without this fallback, the tier stays at
            // .inspect forever for free-viewer users looking at a
            // MIT-BIH recording — the whole zoom-out simplification
            // never fires because the compute-side beat count is empty.
            let delineatorBeats = markingsContext.beats.count(where: {
                $0.rPeakSampleIndex >= viewport.startSample
                && $0.rPeakSampleIndex <= viewport.endSample
            })
            let beatsInWindow: Int = {
                if delineatorBeats > 0 { return delineatorBeats }
                return visibleAnnotations.reduce(0) { partial, ann in
                    ann.kind == .point ? partial + 1 : partial
                }
            }()
            let pointsPerBeat = WaveformZoomTierSelector.pointsPerBeat(
                plotWidthPoints: Double(liveSize.width),
                beatsInWindow: beatsInWindow
            )
            let resolvedTier = WaveformZoomTierSelector.select(
                pointsPerBeat: pointsPerBeat,
                current: waveformZoomTier
            )
            ZStack(alignment: .topLeading) {
                // Chart content — translated by the rubber-band offset so
                // the trace, off-scale markers, and annotation labels all
                // move together when the user pulls past a viewport
                // boundary. Cursor-anchored overlays below the Group are
                // intentionally NOT offset so the crosshair / tooltip
                // stay locked to the cursor while the chart bands away.
                Group {
                    // Layer 1 — paper, grid, and (single-lead only) the trace.
                    //
                    // This canvas always exists and always owns the paper, the
                    // grid and the wheel handler, so its identity is the stable
                    // one across ⌘-click. If the paper moved to whichever lead
                    // happened to be last in the selection, every add would
                    // tear down and rebuild the background.
                    //
                    // With leads overlaid it hands its TRACE and its MARKS to
                    // layer 3 — see below for why.
                    WaveformCanvas(
                        channel: channel,
                        directory: directory,
                        startSample: viewport.startSample,
                        endSample: viewport.endSample,
                        annotations: isOverlaying ? [] : visibleAnnotations,
                        focusedBeatSampleIndex: isOverlaying ? nil : markingsContext.focusedBeatSampleIndex,
                        displayMin: displayRange.lowerBound,
                        displayMax: displayRange.upperBound,
                        onScroll: { handleWheelScroll($0, canvasWidth: liveSize.width) },
                        drawsTrace: !isOverlaying
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Layer 2 — the overlaid leads. Same viewport, same
                    // `displayRange`: that is the true-shared-gain
                    // requirement, and it holds BY CONSTRUCTION rather than by
                    // agreement, because `displayRange` derives from the
                    // shared calibration gain and this panel's height. There
                    // is no per-lead value that could drift. No annotations
                    // and no focused beat — marks belong to the lead they were
                    // measured from.
                    ForEach(Array(overlayChannels.enumerated()), id: \.element.id) { index, overlay in
                        WaveformCanvas(
                            channel: overlay,
                            directory: directory,
                            startSample: viewport.startSample,
                            endSample: viewport.endSample,
                            annotations: [],
                            focusedBeatSampleIndex: nil,
                            displayMin: displayRange.lowerBound,
                            displayMax: displayRange.upperBound,
                            traceColor: LeadPalette.ink(rank: index + 1).simd,
                            drawsPaper: false
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .id(overlay.id)
                    }

                    // Layer 3 — the primary's trace and marks, ON TOP.
                    //
                    // Found by looking at the pixels, not by reasoning about
                    // them: with the primary at the back, an overlaid lead
                    // paints straight over it wherever the two traces coincide
                    // — which is most of the record, since every lead shares
                    // the isoelectric baseline. The reference trace, the one
                    // every mark and every measurement belongs to, was the one
                    // you couldn't see.
                    if isOverlaying {
                        WaveformCanvas(
                            channel: channel,
                            directory: directory,
                            startSample: viewport.startSample,
                            endSample: viewport.endSample,
                            annotations: visibleAnnotations,
                            focusedBeatSampleIndex: markingsContext.focusedBeatSampleIndex,
                            displayMin: displayRange.lowerBound,
                            displayMax: displayRange.upperBound,
                            drawsPaper: false
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }

                    WaveformClippingOverlay(
                        clippedRanges: clippedRanges,
                        startSample: viewport.startSample,
                        endSample: viewport.endSample
                    )

                    WaveformAnnotationOverlay(
                        annotations: visibleAnnotations,
                        startSample: viewport.startSample,
                        endSample: viewport.endSample,
                        tier: resolvedTier
                    )

                    // VT/VF candidate regions as translucent bands. Range
                    // annotations aren't drawn by the chip rail (point-only),
                    // so without this a queue jump to a candidate lands on a
                    // trace with no marker for the episode.
                    VTVFCandidateBandOverlay(
                        candidates: visibleCandidates,
                        startSample: viewport.startSample,
                        endSample: viewport.endSample
                    )
                }
                .offset(x: overscrollPx)

                // Per-trace edge labels. Required, not decoration: colour is
                // never the sole discriminator on this surface. An analyst
                // with any red-green deficiency — or on a projector, or with
                // the display's colour profile fighting them — still has to be
                // able to say which trace is which. NOT offset by the
                // rubber band: these are anchored to the frame like the axis
                // labels, not painted onto the chart.
                leadEdgeLabels
                    .allowsHitTesting(false)

                HoverTrackingView { location in
                    applyHover(location, in: liveSize)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: liveSize) {
                    #if DEBUG
                    // If `--ui-test-hover-at=X,Y` was passed, fire the same
                    // hover-update path that HoverTrackingView would.
                    // `id: liveSize` re-runs the task once GeometryReader
                    // measures, so the injection happens against a real
                    // canvas size (not .zero on first body evaluation).
                    if liveSize.width > 0, let pt = UITestSupport.hoverPoint {
                        applyHover(pt, in: liveSize)
                    }
                    #endif
                }

                if hoverIsActive, liveSize.width > 0 {
                    hoverCrosshair(in: liveSize)
                }

                // Lane-hover → ECG band overlay. The "highlight the beats
                // in THAT window" half of the window-on-signal linkage:
                // when the analyst hovers the variability lane below,
                // draw a translucent band over the beats whose RRs
                // populate the hovered window. Only renders when the
                // hover source is the lane — the ECG's own hover uses
                // the crosshair above instead.
                laneWindowBand(in: liveSize)
                    .allowsHitTesting(false)

                // Fiducial overlay — P/QRS/T marks per beat, LOD-
                // driven by viewport duration. Hidden when the
                // context is empty (no entitlement / no beats).
                FiducialOverlay(
                    beats: markingsContext.beats(inSampleRange: viewport.startSample...viewport.endSample),
                    viewportSampleRange: viewport.startSample..<viewport.endSample,
                    sampleRate: markingsContext.sampleRate,
                    detailLevel: MarkingsDetailLevel.level(forViewportSeconds: viewport.durationSeconds),
                    focusedRPeakSampleIndex: markingsContext.focusedBeatSampleIndex,
                    enabledLayers: markingsContext.enabledLayers,
                    canvasSize: liveSize,
                    tier: resolvedTier
                )

                if let hovered = hoveredAnnotation {
                    AnnotationTooltip(annotation: hovered, sampleRate: channel.sampleRate)
                        .frame(maxWidth: 260, alignment: .leading)
                        .offset(tooltipOffset(in: liveSize))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                // Invisible accessibility element exposing the resolved
                // tier + the beats-in-window count that fed the selector.
                // Lets XCUI tests assert "did zooming out actually cross
                // a tier?" without inspecting Metal render state. Same
                // pattern as the ui-test-viewport-state overlay at the
                // BedsideView level. Format uses letter separators so
                // macOS's accessibility comma-injection doesn't rewrite
                // 4+ digit numbers.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityIdentifier("ui-test-waveform-tier")
                    .accessibilityLabel("tier=\(resolvedTier.rawValue) beats=\(beatsInWindow)")
                    .allowsHitTesting(false)
            }
            // Persist the resolved tier back to @State so the next
            // body pass has the correct `current` input for the
            // hysteresis rule. Async by construction (Task-scheduled);
            // acceptable because the visible tier this frame is already
            // `resolvedTier` — the state write is only to inform the
            // NEXT frame's selector call.
            .task(id: resolvedTier) {
                if resolvedTier != waveformZoomTier {
                    waveformZoomTier = resolvedTier
                }
            }
            // X61: publish what the fiducial overlay is actually drawing, so
            // the Layers chip (a level up, with no access to canvas geometry
            // and therefore no way to know the tier) can report it instead of
            // claiming every enabled layer is on screen. Only the focus-sized
            // panel writes — same rule as the calibration geometry below, and
            // the chip only exists in focus mode.
            .task(id: FiducialRenderPolicy.resolve(
                tier: resolvedTier,
                detailLevel: MarkingsDetailLevel.level(forViewportSeconds: viewport.durationSeconds)
            )) {
                guard sizing == .focus else { return }
                markingsContext.set(renderPolicy: FiducialRenderPolicy.resolve(
                    tier: resolvedTier,
                    detailLevel: MarkingsDetailLevel.level(forViewportSeconds: viewport.durationSeconds)
                ))
            }
            .contentShape(Rectangle())
            .gesture(panGesture(in: liveSize))
            .gesture(zoomGesture(in: liveSize))
            // Publish the focused trace's geometry so the calibration readout
            // (a level up, beside the viewport indicator) can convert points →
            // mm. Height + mV span both feed pointsPerMillivolt; width feeds
            // pointsPerSecond. Only the focus-sized panel writes.
            .onChange(of: liveSize, initial: true) { _, size in
                canvasHeightPoints = size.height
                publishCalibrationGeometry(canvasSize: size)
            }
            .onChange(of: displayRange) { _, _ in
                publishCalibrationGeometry(canvasSize: liveSize)
            }
        }
        .frame(minHeight: sizing.canvasMinHeight, maxHeight: sizing.expands ? .infinity : nil)
    }

    // MARK: Hover hit-testing
    // Mouse tracking is delivered by `HoverTrackingView` (an
    // NSTrackingArea-backed overlay). It calls back with the cursor
    // location on enter/move and `nil` on exit; canvasArea routes
    // through applyHover so the UI-test injection takes the same path.

    private func applyHover(_ location: CGPoint?, in canvasSize: CGSize) {
        if let location {
            hoverLocation = location
            hoverIsActive = true
            hoveredAnnotation = hitTest(at: location, in: canvasSize)
            // Publish the hovered time to the shared variability-lane
            // context so the lane can highlight the sample whose
            // window contains this instant. `setHover` guards against
            // stale hover-exits from other surfaces clobbering us.
            laneContext.setHover(
                time: cursorTimeSeconds(at: location, in: canvasSize),
                from: .ecg
            )
            // Also focus the nearest fiducial beat so the FiducialOverlay
            // highlights the R-tick + the BeatCalipers readout tracks
            // the analyst's cursor.
            let cursorSample = cursorSampleIndex(at: location, in: canvasSize)
            markingsContext.focus(beatSampleIndex: markingsContext.nearestBeat(toSampleIndex: cursorSample)?.rPeakSampleIndex)
        } else {
            hoverIsActive = false
            hoveredAnnotation = nil
            laneContext.setHover(time: nil, from: .ecg)
            markingsContext.focus(beatSampleIndex: nil)
        }
    }

    /// Absolute sample index at the given canvas-local point.
    private func cursorSampleIndex(at location: CGPoint, in canvasSize: CGSize) -> Int64 {
        let cursorX = max(0, min(canvasSize.width, location.x))
        let span = max(1, viewport.endSample - viewport.startSample)
        return viewport.startSample + Int64(Double(span) * Double(cursorX / canvasSize.width))
    }

    /// Absolute time (seconds from recording start) at the given
    /// canvas-local point, using the same viewport math the
    /// `hoverCrosshair` overlay uses.
    private func cursorTimeSeconds(at location: CGPoint, in canvasSize: CGSize) -> Double {
        let cursorX = max(0, min(canvasSize.width, location.x))
        let span = max(1, viewport.endSample - viewport.startSample)
        let sample = viewport.startSample + Int64(Double(span) * Double(cursorX / canvasSize.width))
        return Double(sample) / channel.sampleRate
    }

    /// 1-px vertical line at the cursor with a floating time label at the
    /// top edge. Receives the canvas size from the enclosing GeometryReader
    /// so the Rectangle can be sized explicitly to the canvas height
    /// (without an explicit height it collapses to ~12 pt and vanishes).
    /// Translucent band over the ECG covering the RR-window of the
    /// variability lane's hovered sample. Renders only when the hover
    /// source is the lane and the window intersects the current
    /// viewport — otherwise emits an `EmptyView`.
    @ViewBuilder
    private func laneWindowBand(in canvasSize: CGSize) -> some View {
        if laneContext.hoveredSource == .lane,
           let t = laneContext.hoveredTimeSeconds,
           let sample = laneContext.sample(atTimeSeconds: t),
           canvasSize.width > 0,
           channel.sampleRate > 0 {
            let sr = channel.sampleRate
            let startSec = Double(viewport.startSample) / sr
            let endSec = Double(viewport.endSample) / sr
            let spanSec = max(0.0001, endSec - startSec)
            // Clip the band to the visible viewport before computing
            // pixel coords — a window that starts before the visible
            // range must still render its visible half.
            let bandStart = max(startSec, sample.windowStartSeconds)
            let bandEnd = min(endSec, sample.windowEndSeconds)
            if bandEnd > bandStart {
                let x1 = CGFloat((bandStart - startSec) / spanSec) * canvasSize.width
                let x2 = CGFloat((bandEnd - startSec) / spanSec) * canvasSize.width
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: max(1, x2 - x1), height: canvasSize.height)
                    .offset(x: x1)
                    .accessibilityIdentifier("lane-window-band")
            }
        }
    }

    @ViewBuilder
    private func hoverCrosshair(in canvasSize: CGSize) -> some View {
        let cursorX = max(0, min(canvasSize.width, hoverLocation.x))
        let span = max(1, viewport.endSample - viewport.startSample)
        let cursorSample = viewport.startSample + Int64(Double(span) * Double(cursorX / canvasSize.width))
        let cursorTime = Double(cursorSample) / channel.sampleRate

        // `.topLeading` alignment + `.offset` keeps each subview's layout
        // area tight (1 pt wide for the rule, intrinsic for the label).
        // We avoided `.position(x:y:)` here because that modifier expands
        // the view's reported area to fill the parent — even with
        // `.allowsHitTesting(false)` on the ZStack, the expanded area
        // appeared to confuse SwiftUI's drag-gesture recognizer and
        // intermittently cancel pans mid-drag once the cursor crossed
        // the crosshair's frozen position.
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 1, height: canvasSize.height)
                .offset(x: cursorX - 0.5)
            Text(String(format: "%.3f s", cursorTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.thinMaterial)
                )
                .fixedSize()
                .offset(
                    x: max(0, min(canvasSize.width - 56, cursorX - 28)),
                    y: 4
                )
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        // Forced leaf — SwiftUI drops non-hit-testable views from the
        // macOS XCUI accessibility tree without this.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("hover-crosshair")
    }

    /// Returns the finding under `point`, preferring ranges that strictly
    /// contain the hover sample. Otherwise picks the nearest point finding
    /// within a small pixel tolerance so the analyst doesn't have to land
    /// exactly on a one-pixel-wide tick.
    private func hitTest(at point: CGPoint, in canvasSize: CGSize) -> Annotation? {
        guard canvasSize.width > 0 else { return nil }
        let span = max(1, viewport.endSample - viewport.startSample)
        let fraction = max(0, min(1, Double(point.x / canvasSize.width)))
        let hoverSample = viewport.startSample + Int64(Double(span) * fraction)

        if let inside = visibleAnnotations.first(where: { ann in
            guard ann.kind == .range else { return false }
            let end = ann.endSampleIndex ?? ann.sampleIndex
            return hoverSample >= ann.sampleIndex && hoverSample <= end
        }) {
            return inside
        }

        let tolerancePx: CGFloat = 6
        let toleranceSamples = Int64(Double(span) * Double(tolerancePx / canvasSize.width))
        return visibleAnnotations
            .filter { $0.kind == .point && abs($0.sampleIndex - hoverSample) <= toleranceSamples }
            .min(by: { abs($0.sampleIndex - hoverSample) < abs($1.sampleIndex - hoverSample) })
    }

    /// Offset the tooltip away from the cursor so the cursor itself doesn't
    /// land inside the tooltip rectangle (which would obscure what the user
    /// is pointing at). Flip the tooltip to the cursor's left when there
    /// isn't enough room on the right.
    private func tooltipOffset(in canvasSize: CGSize) -> CGSize {
        let nudgeX: CGFloat = 14
        let tooltipWidth: CGFloat = 240
        let tooltipHeightApprox: CGFloat = 92
        var x = hoverLocation.x + nudgeX
        if x + tooltipWidth > canvasSize.width {
            x = max(0, hoverLocation.x - nudgeX - tooltipWidth)
        }
        var y = hoverLocation.y + nudgeX
        if y + tooltipHeightApprox > canvasSize.height {
            y = max(0, hoverLocation.y - tooltipHeightApprox - nudgeX)
        }
        return CGSize(width: x, height: y)
    }

    /// Annotations that overlap the current viewport. Point findings are visible
    /// when their sample falls inside the range; range findings are visible when
    /// their [start, end] interval intersects it. The list is sorted by sample
    /// index, so we can scan from a small lookahead window.
    private var visibleAnnotations: [Annotation] {
        guard !annotations.isEmpty else { return [] }
        let range = viewport.rangeSamples
        return annotations.filter { ann in
            switch ann.kind {
            case .point:
                return range.contains(ann.sampleIndex)
            case .range:
                let start = ann.sampleIndex
                let end   = ann.endSampleIndex ?? ann.sampleIndex
                return end >= range.lowerBound && start < range.upperBound
            }
        }
    }

    /// Candidate episodes whose [start, end] interval intersects the
    /// viewport — the subset the band overlay needs to draw.
    private var visibleCandidates: [Annotation] {
        guard !candidates.isEmpty else { return [] }
        let range = viewport.rangeSamples
        return candidates.filter { c in
            let start = c.sampleIndex
            let end = c.endSampleIndex ?? c.sampleIndex
            return end >= range.lowerBound && start < range.upperBound
        }
    }

    private var startTime: Double {
        Double(viewport.startSample) / channel.sampleRate
    }
    private var endTime: Double {
        Double(viewport.endSample) / channel.sampleRate
    }
    private var durationSeconds: Double { endTime - startTime }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(channel.name).font(.headline)
            Text(channel.unit.isEmpty ? "" : "(\(channel.unit))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !clippedRanges.isEmpty {
                Label("\(clippedRanges.count) off-scale", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("\(clippedRanges.count) segment\(clippedRanges.count == 1 ? "" : "s") exceed ±5 mV and aren't drawn")
            }
            if let range = sampleRange, !range.isEmpty {
                Text(String(format: "%.2f – %.2f", range.min, range.max))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Recording-wide voltage range observed on this channel")
                    .accessibilityIdentifier("channel-range-\(channel.name)")
                Button {
                    fitAmplitudeToWindow()
                } label: {
                    Label("Fit amplitude", systemImage: "arrow.up.and.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Set the gain once so this channel's observed amplitude fills the window (10% headroom). A one-shot fit, not a live rescale — the calibration readout then reports the resulting gain.")
                .accessibilityIdentifier("fit-amplitude-\(channel.name)")
            }
            Spacer()
            Text(timeWindowLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("time-window-label")
            Text("\(Int(channel.sampleRate)) Hz")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timeWindowLabel: String {
        // X49: the shared m:ss.d formatter (raw seconds moved to the inspector).
        ViewportTimeFormat.window(startSeconds: startTime, endSeconds: endTime)
    }

    /// One-time scan over the full channel at panel mount. Runs the
    /// clipping detector AND the min/max scanner in the same detached
    /// task so each panel reads the channel file off the main thread
    /// exactly once. Feeds the chevron overlay, the off-scale header
    /// badge, and the informational range badge.
    private func scanForOffScale() async {
        let url = directory.appendingPathComponent(channel.storageFileName)
        let total = channel.sampleCount
        guard total > 0 else { return }
        struct ScanResult: Sendable {
            let clipped: [ClippedRange]
            let range: MinMaxScanner.Range?
        }
        let result: ScanResult = await Task.detached(priority: .utility) {
            guard let access = try? BinaryRecordingFile.mappedAccess(url: url) else {
                return ScanResult(clipped: [], range: nil)
            }
            let samples = access.samples(range: 0..<total)
            let clipped = ClippedRangeScanner.scan(
                samples: samples,
                clipMin: Float(Self.yMin),
                clipMax: Float(Self.yMax)
            )
            let range = MinMaxScanner.scan(samples: samples)
            return ScanResult(clipped: clipped, range: range)
        }.value
        await MainActor.run {
            clippedRanges = result.clipped
            sampleRange = result.range
        }
    }

    // MARK: Gestures

    private func panGesture(in canvasSize: CGSize) -> some Gesture {
        // minimumDistance: 1 keeps a one-pixel dead zone so a click that
        // jitters by a hair doesn't read as a drag, but eliminates the
        // 2-pt accumulation delay that read as start-of-pan hesitation.
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRange == nil {
                    dragStartRange = viewport.rangeSamples
                    lastHapticSignature = hapticSignature(for: visibleAnnotations)
                }
                guard let start = dragStartRange, canvasSize.width > 0 else { return }
                let width = start.upperBound - start.lowerBound
                let samplesPerPixel = Double(width) / Double(canvasSize.width)
                let desiredDeltaSamples = Int64(-value.translation.width * samplesPerPixel)
                let proposedStart = start.lowerBound + desiredDeltaSamples
                // Clamp to recording bounds — the viewport itself never
                // exceeds [0, totalSamples - width].
                let maxStart = max(0, viewport.totalSamples - width)
                let clampedStart = max(0, min(maxStart, proposedStart))
                viewport.setStart(clampedStart)
                // The pixel distance the cursor pulled past the boundary
                // (positive when pulling past the left edge, negative when
                // pulling past the right). Feed through rubber-band damping
                // so the chart shifts visibly to follow the cursor but with
                // diminishing return — the classic iOS elastic edge.
                let overshootSamples = Double(clampedStart - proposedStart)
                let overshootPx = CGFloat(overshootSamples / samplesPerPixel)
                overscrollPx = RubberBand.damp(
                    overshoot: overshootPx,
                    canvasWidth: canvasSize.width
                )
                // Keep the crosshair tracking the cursor during the drag.
                // NSTrackingArea suppresses mouseMoved while a button is
                // down, so the hover path can't update hoverLocation;
                // without this the crosshair freezes at the drag-start
                // position and analysts can't tell whether the chart is
                // unresponsive or rubber-banding against a boundary.
                hoverLocation = value.location
                hoverIsActive = true
                emitHapticIfAnnotationsEntered()
            }
            .onEnded { value in
                defer {
                    dragStartRange = nil
                    lastHapticSignature = []
                }
                guard canvasSize.width > 0 else { return }
                // Spring the rubber-band back to neutral. Snappy enough
                // that it feels like a release, not a glide.
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    overscrollPx = 0
                }
                // DragGesture estimates a momentum trajectory in
                // `predictedEndLocation`. The difference between the
                // release point and the predicted rest position is the
                // post-release displacement under the system's default
                // deceleration, divided by ~0.5s to get a per-second
                // velocity (which startPanMomentum then re-eases).
                let dragVelocityPx = Double(value.predictedEndLocation.x - value.location.x)
                let span = Double(viewport.endSample - viewport.startSample)
                let samplesPerPixel = span / Double(canvasSize.width)
                // Drag-right means the viewport pans left → negate.
                let velocitySamplesPerSec = -dragVelocityPx * samplesPerPixel / 0.5
                viewport.startPanMomentum(velocitySamplesPerSec: velocitySamplesPerSec)
            }
    }

    /// Apply one coalesced mouse-wheel gesture (X38). Mirrors the pinch
    /// `zoomGesture` and drag `panGesture` by mutating the shared viewport
    /// directly: zoom is exponential at 1.35× per detent, anchored at the
    /// pointer's fraction so retreat is as cheap as descent for a mouse user;
    /// pan shifts the window by the scrolled distance. `canvasWidth` is the
    /// live trace width in points.
    private func handleWheelScroll(_ scroll: WheelScroll, canvasWidth: CGFloat) {
        // The recording span bounds every viewport figure; clamping the Double
        // to it BEFORE the Int64 conversion is essential — a big zoom-out burst
        // sends `factor` (and the raw product) past Int64.max, and converting
        // that traps at runtime. setWidth / pan re-clamp anyway, so bounded
        // input is behaviour-preserving.
        let total = Double(max(viewport.minSamples, viewport.totalSamples))

        // Calibration lock (X40 §4): pan stays free, zoom is held.
        if scroll.zoomDetents != 0, !calibration.locked {
            let factor = pow(1.35, -scroll.zoomDetents)   // detents > 0 → zoom in
            if let width = RecordingViewport.zoomedWidthSamples(
                currentWidth: viewport.endSample - viewport.startSample,
                factor: factor,
                totalSamples: viewport.totalSamples
            ) {
                viewport.setWidth(width, anchorFraction: scroll.anchorFractionX)
            }
        }
        if scroll.panPoints != 0, canvasWidth > 0 {
            let span = Double(viewport.endSample - viewport.startSample)
            let samplesPerPoint = span / Double(canvasWidth)
            let delta = (scroll.panPoints * samplesPerPoint).rounded()
            if delta.isFinite {
                viewport.pan(bySamples: Int64(min(max(delta, -total), total)))
            }
        }
    }

    private func zoomGesture(in canvasSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Calibration lock (X40 §4): a pinch can't change the timebase
                // calibration while locked.
                guard !calibration.locked else { return }
                if zoomStartWidth == nil {
                    zoomStartWidth = viewport.endSample - viewport.startSample
                }
                guard let startWidth = zoomStartWidth else { return }
                let factor = 1.0 / max(0.01, value.magnification)
                let newWidth = Int64(Double(startWidth) * factor)
                viewport.setWidth(newWidth, anchorFraction: 0.5)
            }
            .onEnded { _ in zoomStartWidth = nil }
    }

    /// Fires a single `.alignment` haptic tick when the signature of the
    /// visible annotation set has grown since the previous drag tick.
    /// What "grown" means depends on `hapticMode`:
    ///   • `.off` — no-op
    ///   • `.allAnnotations` — any new annotation (by ID) entering the
    ///     viewport triggers a tick
    ///   • `.categoryTransitions` — only a new *category* (not seen on
    ///     the previous tick) triggers a tick, so clustered findings of
    ///     the same kind don't produce a buzz
    /// Force Touch trackpad only; a no-op on Magic Mouse and external
    /// pointing devices.
    private func emitHapticIfAnnotationsEntered() {
        guard hapticMode != .off else { return }
        let current = hapticSignature(for: visibleAnnotations)
        if !current.subtracting(lastHapticSignature).isEmpty {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }
        lastHapticSignature = current
    }

    /// Projects a visible-annotation list into the comparison set that
    /// `emitHapticIfAnnotationsEntered` diffs against. The projection
    /// depends on the active `hapticMode` so the same diff-on-grow logic
    /// services both per-annotation and per-category modes.
    private func hapticSignature(for visible: [Annotation]) -> Set<String> {
        switch hapticMode {
        case .off:
            return []
        case .allAnnotations:
            return Set(visible.map { String(describing: $0.id) })
        case .categoryTransitions:
            return Set(visible.map(\.category))
        }
    }
}
