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
import SwiftUI

struct WaveformCanvas: NSViewRepresentable {
    let channel: Channel
    let directory: URL

    // Viewport snapshot — pass primitives so SwiftUI detects updates.
    let startSample: Int64
    let endSample: Int64

    // Visible annotations only (already filtered by caller).
    let annotations: [Annotation]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly  = true
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
        sync(view: nsView, coordinator: context.coordinator)
        nsView.setNeedsDisplay(nsView.bounds)
    }

    // MARK: - Sync helpers

    private func sync(view: MTKView, coordinator: Coordinator) {
        guard let renderer = coordinator.renderer else { return }
        renderer.uniforms.startSample = Float(startSample)
        renderer.uniforms.endSample   = Float(endSample)

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

/// Annotation labels anchored to the top of the canvas. For point findings the
/// label sits at the finding's sample. For ranges, the label sits at the range
/// midpoint. Color comes from `CategoryPalette` so labels match the rule/fill.
struct WaveformAnnotationOverlay: View {
    let annotations: [Annotation]   // already filtered to viewport
    let startSample: Int64
    let endSample: Int64

    var body: some View {
        GeometryReader { geo in
            let span = max(1, endSample - startSample)
            ForEach(annotations) { ann in
                let anchorSample: Int64 = {
                    switch ann.kind {
                    case .point: return ann.sampleIndex
                    case .range: return (ann.sampleIndex + ann.renderEndSample) / 2
                    }
                }()
                let frac = Double(anchorSample - startSample) / Double(span)
                Text(ann.displayLabel)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(CategoryPalette.swiftUIColor(for: ann.category))
                    .position(x: CGFloat(frac) * geo.size.width, y: 8)
            }
        }
        .allowsHitTesting(false)
    }
}
