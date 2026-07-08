//
//  WaveformCanvas.swift
//  Murmur
//
//  SwiftUI bridge to the Metal-backed `WaveformRenderer`. Wraps an MTKView,
//  owns a coordinator that holds the mmap-backed sample/pyramid accessors,
//  and re-syncs the renderer's viewport/grid/annotation state every time
//  SwiftUI calls updateNSView.
//
//  Layout: the parent (ChannelPanel) stacks this canvas under SwiftUI overlays
//  for axis labels and annotation symbols. The canvas owns just the paper,
//  grid, trace, envelope, and annotation rule lines — text stays in SwiftUI.
//

import MetalKit
import os.log
import os.signpost
import SwiftUI

/// Shared OSLog handle for the canvas + renderer hot path. Uses the
/// special `.pointsOfInterest` category so the signposts are emitted
/// unconditionally — most other categories require a subscriber (like
/// Instruments) to be attached before signposts go out. That's what
/// blocks `XCTOSSignpostMetric` from picking them up during a XCUITest
/// run, since the test runner doesn't subscribe to arbitrary subsystems
/// in the launched app process. PointsOfInterest sidesteps the gating.
///
/// We use the lower-level `os_signpost` C-style API rather than the
/// Swift `OSSignposter` wrapper because the wrapper's intervals don't
/// reliably surface in `XCTOSSignpostMetric` cross-process; the C-style
/// API hits the unified logging system directly.
let waveformRenderLog = OSLog(
    subsystem: "com.kevinlong.murmur",
    category: .pointsOfInterest
)

struct WaveformCanvas: NSViewRepresentable {
    let channel: Channel
    let directory: URL

    // Viewport snapshot — pass primitives so SwiftUI detects updates.
    let startSample: Int64
    let endSample: Int64

    // Visible annotations only (already filtered by caller).
    let annotations: [Annotation]

    /// Currently-focused beat's R-peak sample index. Drives the
    /// full-height "focus locator" rule per Move A of
    /// project_waveform_zoom_lod_spec.md. Nil when no beat is focused —
    /// no locator line rendered.
    var focusedBeatSampleIndex: Int64?

    /// Display range in mV. Defaults to ±5 (the clinical clipping
    /// reference). Set tighter by the caller when auto-scale is on so
    /// a low-amplitude channel uses the full canvas height. The
    /// clipping scanner stays anchored at ±5 separately — display
    /// range and clip detection are different concepts.
    var displayMin: Double = -5
    var displayMax: Double = 5

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly  = true
        // On-demand rendering: each SwiftUI updateNSView synchronously
        // drives one draw via `nsView.draw()`. That avoids the judder
        // pattern that pure continuous (120 Hz) render produces when
        // mouse events fire at ~60 Hz — every other frame would otherwise
        // re-present an identical scene, which the eye reads as the trace
        // stuttering. Synchronous draws keep the cadence locked to the
        // gesture event rate, so each unique frame is shown for exactly
        // one vsync.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 120
        // 4x MSAA — MTKView auto-creates an intermediate multisample
        // color texture, renders into it, and resolves to the drawable
        // via storeAction = .multisampleResolve. `framebufferOnly` only
        // affects the drawable (the resolve target), so it stays true.
        // Must match `rasterSampleCount = 4` on every pipeline state in
        // WaveformRenderer.
        if let device = MTLCreateSystemDefaultDevice(),
           device.supportsTextureSampleCount(4) {
            view.sampleCount = 4
        }

        if let renderer = WaveformRenderer() {
            view.device = renderer.device
            view.delegate = renderer
            context.coordinator.renderer = renderer
            renderer.channelSampleRate = channel.sampleRate
            context.coordinator.loadChannel(channel: channel, directory: directory)
            sync(view: view, coordinator: context.coordinator)
            view.setNeedsDisplay(view.bounds)
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        let signpostID = OSSignpostID(log: waveformRenderLog)
        os_signpost(.begin, log: waveformRenderLog, name: "UpdateNSView", signpostID: signpostID)
        defer { os_signpost(.end, log: waveformRenderLog, name: "UpdateNSView", signpostID: signpostID) }
        sync(view: nsView, coordinator: context.coordinator)
        // Synchronous draw: each viewport mutation produces exactly one
        // frame, presented at the next vsync. We don't use setNeedsDisplay
        // here because that would defer the draw to the next display-link
        // tick, adding up to ~16 ms of latency on a cold display link.
        // Calling draw() directly fires the renderer's draw(in:) callback
        // on the same runloop turn — the GPU work is queued immediately.
        nsView.draw()
    }

    // MARK: - Sync helpers

    private func sync(view: MTKView, coordinator: Coordinator) {
        let signpostID = OSSignpostID(log: waveformRenderLog)
        os_signpost(.begin, log: waveformRenderLog, name: "Sync", signpostID: signpostID)
        defer { os_signpost(.end, log: waveformRenderLog, name: "Sync", signpostID: signpostID) }
        guard let renderer = coordinator.renderer else { return }
        renderer.uniforms.startSample = Float(startSample)
        renderer.uniforms.endSample   = Float(endSample)
        renderer.uniforms.yMin        = Float(displayMin)
        renderer.uniforms.yMax        = Float(displayMax)

        // LOD selection based on the view's pixel width.
        let pixelWidth = Double(view.bounds.width)
        let sampleCount = Double(endSample - startSample)
        let samplesPerPixel = pixelWidth > 0 ? sampleCount / pixelWidth : 1
        coordinator.selectLOD(samplesPerPixel: samplesPerPixel, renderer: renderer)

        // Grid spec from the time-domain duration.
        let durationSeconds = sampleCount / channel.sampleRate
        renderer.setGrid(spec: ECGGridSpec.forDuration(seconds: durationSeconds))

        // Annotations — caller has already pre-filtered to the viewport.
        renderer.setAnnotations(annotations)

        // Focus locator — the single full-height rule that survives
        // Move A. Sent AFTER uniforms so the buffer is baked with the
        // current y-range.
        renderer.setFocusedBeat(focusedBeatSampleIndex)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var renderer: WaveformRenderer?
        var rawSampleCount: Int64 = 0
        var pyramidLevels: [PyramidLevel] = []
        private var loadedPyramidIndex: Int?

        private var rawAccess: MappedSampleAccess?
        private var pyramidAccesses: [MappedPyramidAccess] = []

        func loadChannel(channel: Channel, directory: URL) {
            let rawURL = directory.appendingPathComponent(channel.storageFileName)
            rawAccess = try? BinaryRecordingFile.mappedAccess(url: rawURL)
            rawSampleCount = channel.sampleCount

            pyramidLevels = channel.pyramid
            pyramidAccesses = channel.pyramid.compactMap { level in
                let url = directory.appendingPathComponent(level.storageFileName)
                return try? PyramidLevelFile.mappedAccess(url: url)
            }

            // Push the entire raw trace to the GPU once. For our scope
            // (≤ few-million samples per channel) the buffer fits comfortably.
            if let access = rawAccess, channel.sampleCount > 0 {
                let samples = access.samples(range: 0..<channel.sampleCount)
                renderer?.loadSamples(samples)
            }
        }

        func selectLOD(samplesPerPixel: Double, renderer: WaveformRenderer) {
            // Use raw whenever we're not painting >1 sample per pixel.
            guard samplesPerPixel > 1, !pyramidLevels.isEmpty else {
                if renderer.useEnvelope { renderer.beginLODTransition() }
                renderer.useEnvelope = false
                loadedPyramidIndex = nil
                return
            }
            // Pick the deepest level whose binSamples fits under our budget.
            var chosen: Int?
            for (idx, level) in pyramidLevels.enumerated() {
                if Double(level.binSamples) <= samplesPerPixel {
                    chosen = idx
                } else {
                    break
                }
            }
            guard let pickedIdx = chosen, pickedIdx < pyramidAccesses.count else {
                if renderer.useEnvelope { renderer.beginLODTransition() }
                renderer.useEnvelope = false
                loadedPyramidIndex = nil
                return
            }
            // Any LOD-relevant change — flipping into envelope mode, or
            // swapping to a different pyramid level — kicks off a fresh
            // crossfade. beginLODTransition() snapshots the *current* state
            // before we mutate anything, so the previous draw path stays
            // intact for the fade-out.
            let switchingIntoEnvelope = !renderer.useEnvelope
            let switchingLevel       = loadedPyramidIndex != pickedIdx
            if switchingIntoEnvelope || switchingLevel {
                renderer.beginLODTransition()
            }
            if switchingLevel {
                let level = pyramidLevels[pickedIdx]
                let access = pyramidAccesses[pickedIdx]
                let bins = access.bins(range: 0..<access.binCount)
                renderer.loadPyramid(bins: bins, binSamples: level.binSamples)
                loadedPyramidIndex = pickedIdx
            }
            renderer.useEnvelope = true
        }
    }
}

// MARK: - SwiftUI overlays

/// Time-axis tick labels along the bottom edge. Uses the `ECGGridSpec.xMajor`
/// spacing so labels align with the major paper gridlines.
struct WaveformTimeAxis: View {
    let startTime: Double           // seconds
    let endTime: Double             // seconds

    /// Minimum pixel gap between rendered tick labels. ~6 chars at caption2
    /// monospaced is ~42 pt; pad to 56 so the gap reads clean at every zoom.
    static let minLabelSpacingPx: CGFloat = 56

    /// Computes the keep-every-Nth stride that prevents tick labels from
    /// overlapping. Extracted so the App-Store-rejection-driving decimation
    /// guarantee is unit-testable without rendering a SwiftUI view.
    /// - Parameters:
    ///   - viewportWidthPx: The full chart width in points.
    ///   - durationSec: The visible window in seconds.
    ///   - majorSpacingSec: Seconds between major gridlines (from ECGGridSpec).
    ///   - minLabelSpacingPx: Minimum on-screen gap between rendered labels.
    /// - Returns: An integer `stride >= 1`. Render only majors whose index
    ///   is a multiple of this stride.
    static func decimationStride(
        viewportWidthPx: CGFloat,
        durationSec: Double,
        majorSpacingSec: Double,
        minLabelSpacingPx: CGFloat = WaveformTimeAxis.minLabelSpacingPx
    ) -> Int {
        let duration = max(0.0001, durationSec)
        let pxPerMajor = viewportWidthPx * CGFloat(majorSpacingSec / duration)
        return max(1, Int(ceil(minLabelSpacingPx / max(0.0001, pxPerMajor))))
    }

    var body: some View {
        GeometryReader { geo in
            let duration = max(0.0001, endTime - startTime)
            let spec = ECGGridSpec.forDuration(seconds: duration)
            let majors = makeGridLines(from: startTime, to: endTime, every: spec.xMajor)
            let stride = Self.decimationStride(
                viewportWidthPx: geo.size.width,
                durationSec: duration,
                majorSpacingSec: spec.xMajor
            )
            ForEach(Array(majors.enumerated()), id: \.offset) { index, t in
                if index.isMultiple(of: stride) {
                    let xFrac = (t - startTime) / duration
                    Text(format(seconds: t))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .position(x: CGFloat(xFrac) * geo.size.width, y: geo.size.height - 8)
                }
            }
        }
        .frame(height: 16)
        .allowsHitTesting(false)
    }

    private func format(seconds: Double) -> String {
        if seconds >= 60 { return String(format: "%.0f s", seconds) }
        if seconds >= 1  { return String(format: "%.1f s", seconds) }
        return String(format: "%.2f s", seconds)
    }
}

/// mV tick labels along the left edge. Uses major Y gridlines from the spec.
struct WaveformVoltageAxis: View {
    let yMin: Double
    let yMax: Double
    let durationSeconds: Double

    var body: some View {
        GeometryReader { geo in
            let spec = ECGGridSpec.forDuration(seconds: durationSeconds)
            let majors = makeGridLines(from: yMin, to: yMax, every: spec.yMajor)
            ForEach(majors, id: \.self) { v in
                let yFrac = (yMax - v) / max(0.0001, yMax - yMin)
                // Unit shown once in the panel header ("II (mV)") instead of
                // on every tick — keeps the axis from feeling cluttered.
                Text(String(format: "%.1f", v))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: 28, y: CGFloat(yFrac) * geo.size.height)
            }
        }
        .frame(width: 56)
        .allowsHitTesting(false)
    }
}

/// ▲/▼ chevron markers at the top/bottom edge of the canvas, drawn at each
/// `ClippedRange` whose [start, end] interval intersects the viewport. The
/// chevron direction shows whether the signal went off-scale up or down.
struct WaveformClippingOverlay: View {
    let clippedRanges: [ClippedRange]
    let startSample: Int64
    let endSample: Int64

    var body: some View {
        GeometryReader { geo in
            let span = max(1, endSample - startSample)
            ForEach(visible, id: \.startSample) { range in
                let midSample = (range.startSample + range.endSample) / 2
                let frac = Double(midSample - startSample) / Double(span)
                let x = CGFloat(max(0, min(1, frac))) * geo.size.width
                let isAbove = range.direction == .above
                Image(systemName: isAbove ? "chevron.compact.up" : "chevron.compact.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange.opacity(0.8))
                    .position(x: x, y: isAbove ? 6 : geo.size.height - 6)
            }
        }
        .allowsHitTesting(false)
    }

    private var visible: [ClippedRange] {
        guard !clippedRanges.isEmpty else { return [] }
        return clippedRanges.filter { range in
            range.endSample > startSample && range.startSample < endSample
        }
    }
}

/// Annotation labels anchored to the top of the canvas. For point findings
/// the label sits at the finding's sample. For ranges, the label sits at
/// the range midpoint. Color comes from `CategoryPalette` so labels match
/// the rule/fill.
///
/// Adjacent same-category point annotations collapse into single
/// `Cat ×N` aggregates when the viewport is zoomed out far enough that
/// their text labels would overlap — the merge threshold is computed
/// from the current samples-per-pixel times an approximate label width.
/// Range annotations always render unmerged because their own extents
/// already convey position.
///
/// Clusters (count > 1) render as capsule badges with the category
/// color as the fill and the count as a monospaced suffix; single-
/// annotation clusters render as plain colored text. The distinct
/// badge treatment makes the "hit-counter" visual obvious at low zoom
/// where many identical-category points collapse into one glyph.
struct WaveformAnnotationOverlay: View {
    let annotations: [Annotation]   // already filtered to viewport
    let startSample: Int64
    let endSample: Int64

    /// Current semantic-zoom tier per project_waveform_zoom_lod_spec.md.
    /// Chips render only at `.inspect`; at `.scan` and `.context` this
    /// overlay is silent (Scan's short-tick rail and Context's density
    /// lane + landmarks land in follow-up components). Default `.inspect`
    /// preserves the pre-tier-wiring behavior for callers/tests that
    /// haven't been updated yet.
    var tier: WaveformZoomTier = .inspect

    /// Approximate label width in points. Any two same-category points
    /// closer than this on screen would visually overlap, so we cluster
    /// them. 40pt covers a badge "PVC ×99" at caption2 weight with the
    /// padding the capsule adds.
    private static let labelPitchPx: CGFloat = 40

    var body: some View {
        switch tier {
        case .inspect:
            return AnyView(chipRail)
        case .scan:
            return AnyView(flaggedTickRail)
        case .context:
            // At Context the rail carries only INDIVIDUALLY LOCATABLE
            // landmarks — the rare-flagged-category events. Bulk
            // categories fall out to the density lane BELOW the trace,
            // rendered by AnnotationDensityLane. The partitioning rule
            // lives in AnnotationDensityLane.partition(...) so both
            // sides key off the same math.
            return AnyView(landmarkRail)
        }
    }

    private var chipRail: some View {
        GeometryReader { geo in
            let span = max(1, endSample - startSample)
            let canvasWidth = max(1, geo.size.width)
            let samplesPerPixel = Double(span) / Double(canvasWidth)
            let mergeThresholdSamples = Int64(samplesPerPixel * Double(Self.labelPitchPx))
            let clusters = AnnotationClustering.cluster(
                annotations,
                mergeWithinSamples: mergeThresholdSamples
            )
            // Per-annotation short top-tick UNDER each cluster's chip.
            // Matches the mockup's Inspect rail: every beat gets a small
            // colored anchor extending down from the top of the trace,
            // so the chip above always has a beat it visibly points to.
            // Normals are faint (opacity 0.5, thinner) so flagged beats
            // stand out; per the ratified review-queue attention
            // hierarchy (normal quietest, flagged carry the color).
            ForEach(annotations, id: \.id) { ann in
                if ann.kind == .point {
                    let frac = Double(ann.sampleIndex - startSample) / Double(span)
                    let color = CategoryPalette.swiftUIColor(for: ann.category)
                    let flagged = isFlagged(category: ann.category)
                    Rectangle()
                        .fill(color.opacity(flagged ? 1.0 : 0.5))
                        .frame(width: flagged ? 1.8 : 1.0, height: 8)
                        .position(x: CGFloat(frac) * canvasWidth, y: 3)
                }
            }
            ForEach(clusters) { cluster in
                let anchorSample: Int64 = {
                    switch cluster.representative.kind {
                    case .point: return cluster.sampleIndex
                    case .range:
                        let r = cluster.representative
                        return (r.sampleIndex + r.renderEndSample) / 2
                    }
                }()
                let frac = Double(anchorSample - startSample) / Double(span)
                clusterLabel(cluster: cluster)
                    .position(x: CGFloat(frac) * canvasWidth, y: 15)
            }
        }
        .allowsHitTesting(false)
    }

    /// Scan-tier rail per the mockup at
    /// `~/Documents/Murmur/Planning/design/waveform-zoom-lod.html`:
    ///   - Normal beats become a very faint gray hairline (0.8 pt wide,
    ///     5 pt tall) — the analyst still gets a sense of beat density
    ///     without normals dominating the top.
    ///   - Flagged beats become a bolder colored line (2 pt × 11 pt)
    ///     PLUS a small colored circle marker (radius 2.6) at the
    ///     rail-y — the two marks together form the "beat with a
    ///     verdict" pattern that stays legible even when the trace
    ///     itself has compressed to Scan density.
    private var flaggedTickRail: some View {
        GeometryReader { geo in
            let span = max(1, endSample - startSample)
            let canvasWidth = max(1, geo.size.width)
            ForEach(annotations, id: \.id) { ann in
                if ann.kind == .point {
                    let frac = Double(ann.sampleIndex - startSample) / Double(span)
                    let x = CGFloat(frac) * canvasWidth
                    if isFlagged(category: ann.category) {
                        let color = CategoryPalette.swiftUIColor(for: ann.category)
                        Rectangle()
                            .fill(color)
                            .frame(width: 2, height: 11)
                            .position(x: x, y: 5.5)
                        Circle()
                            .fill(color)
                            .frame(width: 5.2, height: 5.2)
                            .position(x: x, y: 14)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 0.8, height: 5)
                            .position(x: x, y: 2.5)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Approximate short-tick width in points for the Scan rail.
    private static let tickPitchPx: CGFloat = 4

    /// Flag test: the "N" normal-beat class is unflagged; every other
    /// wfdb.atr / producer category is considered flagged for the purpose
    /// of Scan-tier rail rendering. The palette's blue-family entries
    /// include "N", "J" (nodal), etc.; only "N" is unflagged so that
    /// nodal beats or conduction anomalies still surface as ticks.
    private func isFlagged(category: String) -> Bool {
        category != "N"
    }

    /// Context-tier rail per the mockup: RARE flagged categories that
    /// still fit as individually locatable marks show as a short colored
    /// tick + a small rotated square (diamond glyph). Bulk categories
    /// (from `AnnotationDensityLane.partition`) are handled by the
    /// density lane below the trace and never appear here.
    ///
    /// The diamond is a rectangle rotated 45° rather than an SF Symbol
    /// so the shape stays consistent across accent-color themes and
    /// small point sizes; the tinting by CategoryPalette color carries
    /// the classification (color, not shape).
    private var landmarkRail: some View {
        GeometryReader { geo in
            let span = max(1, endSample - startSample)
            let canvasWidth = max(1, geo.size.width)
            let split = AnnotationDensityLane.partition(
                annotations: annotations,
                plotWidthPoints: canvasWidth
            )
            ForEach(split.landmarks) { ann in
                let frac = Double(ann.sampleIndex - startSample) / Double(span)
                let x = CGFloat(frac) * canvasWidth
                let color = CategoryPalette.swiftUIColor(for: ann.category)
                Rectangle()
                    .fill(color)
                    .frame(width: 1.6, height: 9)
                    .position(x: x, y: 4.5)
                Rectangle()
                    .fill(color)
                    .frame(width: 4.4, height: 4.4)
                    .rotationEffect(.degrees(45))
                    .position(x: x, y: 12)
            }
        }
        .allowsHitTesting(false)
    }

    /// (Retained placeholder — old SF-Symbol map is unused after the
    /// mockup-aligned refactor. Left here as a stub to preserve the
    /// site if we later want per-category glyph variants.)
    private static func landmarkSymbol(for category: String) -> String {
        switch category {
        case "V", "PVC", "VT", "VF", "VF_onset", "E":
            return "triangle.fill"
        case "A", "APC", "AFib", "S":
            return "diamond.fill"
        case "F":
            return "circle.grid.cross.fill"
        case "L", "R", "J":
            return "square.fill"
        case "/":
            return "bolt.fill"
        case "Noise", "NoiseGap", "~":
            return "sparkles"
        case "Q", "?":
            return "questionmark.circle.fill"
        default:
            return "circle.fill"           // producer-defined; neutral
        }
    }

    @ViewBuilder
    private func clusterLabel(cluster: ClusteredAnnotation) -> some View {
        let color = CategoryPalette.swiftUIColor(for: cluster.category)
        if cluster.count > 1 {
            HStack(spacing: 3) {
                Text(cluster.representative.displayLabel)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.white)
                Text("×\(cluster.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(color.opacity(0.85))
            )
            .overlay(
                Capsule().stroke(color, lineWidth: 0.5)
            )
        } else {
            Text(cluster.representative.displayLabel)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(color)
        }
    }
}
