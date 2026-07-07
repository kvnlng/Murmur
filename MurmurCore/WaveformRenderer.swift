//
//  WaveformRenderer.swift
//  Murmur
//
//  MTKViewDelegate that draws one channel's ECG paper scene per frame:
//    1. clear → paper color
//    2. range annotations (translucent full-height quads, one bucket per category)
//    3. minor grid lines
//    4. major grid lines
//    5. trace (raw line-strip) OR envelope (instanced quads for pyramid bins)
//    6. point annotations (thin vertical rules, one bucket per category)
//
//  Annotations are bucketed by category so each batch can use its own color
//  without per-instance attributes in the shader.
//

import Foundation
import Metal
import MetalKit
import os.log
import os.signpost
import simd

// MARK: - Uniform structs (must match WaveformShaders.metal byte layout)

struct WaveformUniforms {
    var startSample: Float = 0
    var endSample: Float = 1
    var yMin: Float = -5
    var yMax: Float = 5
}

struct EnvelopeUniformsCPU {
    var startSample: Float = 0
    var endSample: Float = 1
    var yMin: Float = -5
    var yMax: Float = 5
    var binSamples: Float = 0
}

/// Matches the `TraceUniforms` struct in `WaveformShaders.metal`. The trace
/// pass needs viewport pixel size and a desired line width because Metal can't
/// rasterize thick line primitives natively — we extrude each sample into a
/// 2-vertex ribbon and pick the perpendicular in screen-pixel space.
struct TraceUniformsCPU {
    var startSample: Float = 0
    var endSample: Float = 1
    var yMin: Float = -5
    var yMax: Float = 5
    var viewportSizePx: SIMD2<Float> = SIMD2<Float>(600, 200)
    var lineWidthPx: Float = 2.5
    var sampleCount: UInt32 = 0
}

// MARK: - Style

struct WaveformStyle {
    var paper:        SIMD4<Float> = SIMD4(1.00, 0.93, 0.93, 1.00)
    var gridMinor:    SIMD4<Float> = SIMD4(0.93, 0.78, 0.78, 0.65)
    var gridMajor:    SIMD4<Float> = SIMD4(0.82, 0.50, 0.50, 0.55)
    /// Every 5th major — the "1 s / 2.5 mV" landmark on standard ECG paper.
    var gridLandmark: SIMD4<Float> = SIMD4(0.65, 0.25, 0.25, 0.85)
    var trace:        SIMD4<Float> = SIMD4(0.00, 0.00, 0.00, 1.00)
    /// On-screen pixel width of the trace ribbon. ECG paper convention is
    /// a thin but visible stroke; 2.5 pt reads as a confident line without
    /// blurring beat-to-beat morphology.
    var traceLineWidthPx: Float = 2.5
    var envelope:     SIMD4<Float> = SIMD4(0.00, 0.00, 0.00, 0.55)
}

// MARK: - Renderer

final class WaveformRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private let tracePipeline:    MTLRenderPipelineState
    private let linePipeline:     MTLRenderPipelineState
    private let envelopePipeline: MTLRenderPipelineState
    private let rangePipeline:    MTLRenderPipelineState

    /// Snapshot of the rendering state at the moment a LOD swap began.
    /// Held for the duration of the ~150 ms crossfade so the previous path
    /// can be redrawn underneath the new one with complementary alpha.
    private struct PreviousLODState {
        var useEnvelope: Bool
        var sampleBuffer: MTLBuffer?
        var sampleCount: Int
        var pyramidBuffer: MTLBuffer?
        var pyramidBinCount: Int
        var pyramidBinSamples: Float
    }
    private var previousLOD: PreviousLODState?
    private var lodTransitionStart: CFTimeInterval?
    /// 150 ms — long enough for the eye to perceive the fade, short enough
    /// that rapid pinch-zooms still feel responsive.
    static let lodTransitionDuration: CFTimeInterval = 0.15

    // Long-lived per-channel data
    var sampleBuffer: MTLBuffer?
    var sampleCount: Int = 0
    var pyramidBuffer: MTLBuffer?
    var pyramidBinCount: Int = 0
    var pyramidBinSamples: Float = 0

    // Frame-by-frame state
    var uniforms = WaveformUniforms()
    var style    = WaveformStyle()
    var useEnvelope = false

    /// Sample rate of the loaded channel — needed to convert grid spacings
    /// from seconds (the spec uses) into samples (what the shader uses).
    var channelSampleRate: Double = 1

    // Rebuilt on viewport change
    var gridMinorBuffer: MTLBuffer?
    var gridMinorVertexCount: Int = 0
    var gridMajorBuffer: MTLBuffer?
    var gridMajorVertexCount: Int = 0
    var gridLandmarkBuffer: MTLBuffer?
    var gridLandmarkVertexCount: Int = 0

    /// One bucket per category, rebuilt when the visible-annotation set or its
    /// category breakdown changes. Each bucket renders with its own color.
    struct AnnotationBucket {
        let buffer: MTLBuffer
        let count: Int               // line-list vertex count for points; instance count for ranges
        let color: SIMD4<Float>
    }
    var pointBuckets: [AnnotationBucket] = []
    var rangeBuckets: [AnnotationBucket] = []

    /// Focused-beat locator per project_waveform_zoom_lod_spec.md Move A —
    /// "full-height line = focus, not existence." Reserves the full-height
    /// vertical rule through the trace for the SELECTED beat only. Every
    /// other beat's identity lives in the SwiftUI top-rail chips
    /// (`WaveformAnnotationOverlay`) plus the FiducialOverlay R-tick — a
    /// full-height line per beat is exactly the clutter this move removes.
    /// Nil when no beat is focused (placeholder inspector state).
    private(set) var focusedSampleIndex: Int64?
    private var focusLocatorBuffer: MTLBuffer?
    private var focusLocatorBakedYMin: Float = 0
    private var focusLocatorBakedYMax: Float = 0

    /// Identity hash of the last annotation set fed into setAnnotations.
    /// During a sustained pan, the visible-annotation set is usually
    /// unchanged tick-to-tick — same findings, same positions. Skipping
    /// the bucket rebuild when the set is identical eliminates several
    /// MTLBuffer allocations per drag event, which adds up at 60-120 Hz
    /// gesture rates. Nil until the first call so we always rebuild once.
    private var lastAnnotationSignature: Int?

    init?(device: MTLDevice? = nil) {
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue

        // `device.makeDefaultLibrary()` looks in the main app bundle, but
        // `WaveformShaders.metal` is compiled into MurmurCore.framework's
        // bundle. Asking the framework's bundle by type-reflection — survives
        // any future renames or moves of this class.
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: WaveformRenderer.self)) else { return nil }
        do {
            self.tracePipeline = try Self.makePipeline(
                device: device, library: library,
                vertexName: "traceVertex", fragmentName: "colorFragment"
            )
            self.linePipeline = try Self.makePipeline(
                device: device, library: library,
                vertexName: "lineVertex", fragmentName: "colorFragment"
            )
            self.envelopePipeline = try Self.makePipeline(
                device: device, library: library,
                vertexName: "envelopeVertex", fragmentName: "colorFragment"
            )
            self.rangePipeline = try Self.makePipeline(
                device: device, library: library,
                vertexName: "rangeVertex", fragmentName: "colorFragment"
            )
        } catch {
            return nil
        }

        super.init()
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        fragmentName: String
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = library.makeFunction(name: vertexName)
        desc.fragmentFunction = library.makeFunction(name: fragmentName)
        // Must match MTKView.sampleCount in WaveformCanvas. 4x MSAA is
        // supported on every Apple Silicon Mac per Apple's MSAA docs.
        desc.rasterSampleCount = 4
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor      = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor    = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - Data uploads

    func loadSamples(_ samples: [Float]) {
        guard !samples.isEmpty else {
            sampleBuffer = nil
            sampleCount = 0
            return
        }
        let cleaned = samples.map { $0.isFinite ? $0 : 0 }
        sampleBuffer = device.makeBuffer(
            bytes: cleaned,
            length: cleaned.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
        sampleCount = cleaned.count
    }

    /// Snapshots the current rendering state and starts a ~150 ms timer.
    /// Until that timer expires, `draw(in:)` will render both the snapshot
    /// (with fading-out alpha) and whatever's current (with fading-in
    /// alpha), so the swap between raw trace and pyramid envelope (or
    /// between envelope levels) crossfades instead of jump-cutting.
    /// Called by Coordinator.selectLOD before flipping `useEnvelope` or
    /// reloading the pyramid buffer.
    func beginLODTransition() {
        previousLOD = PreviousLODState(
            useEnvelope: useEnvelope,
            sampleBuffer: sampleBuffer,
            sampleCount: sampleCount,
            pyramidBuffer: pyramidBuffer,
            pyramidBinCount: pyramidBinCount,
            pyramidBinSamples: pyramidBinSamples
        )
        lodTransitionStart = CACurrentMediaTime()
    }

    /// 0...1 progress through the crossfade. 1 means the transition is
    /// complete (or never started); the new path renders at full alpha.
    private var lodTransitionProgress: Float {
        guard let start = lodTransitionStart else { return 1 }
        let elapsed = CACurrentMediaTime() - start
        return Float(min(1, max(0, elapsed / Self.lodTransitionDuration)))
    }

    func loadPyramid(bins: [PyramidBin], binSamples: Int) {
        guard !bins.isEmpty else {
            pyramidBuffer = nil
            pyramidBinCount = 0
            return
        }
        let pairs = bins.map { bin -> SIMD2<Float> in
            let lo = bin.min.isFinite ? Float(bin.min) : 0
            let hi = bin.max.isFinite ? Float(bin.max) : 0
            return SIMD2<Float>(lo, hi)
        }
        pyramidBuffer = device.makeBuffer(
            bytes: pairs,
            length: pairs.count * MemoryLayout<SIMD2<Float>>.size,
            options: .storageModeShared
        )
        pyramidBinCount = bins.count
        pyramidBinSamples = Float(binSamples)
    }

    // MARK: - Grid + annotation rebuilds

    func setGrid(spec: ECGGridSpec) {
        let startSec = Double(uniforms.startSample) / channelSampleRate
        let endSec   = Double(uniforms.endSample)   / channelSampleRate
        let yLo      = Double(uniforms.yMin)
        let yHi      = Double(uniforms.yMax)

        let xMinor    = makeGridLines(from: startSec, to: endSec, every: spec.xMinor)
        let xMajor    = makeGridLines(from: startSec, to: endSec, every: spec.xMajor)
        let xLandmark = makeGridLines(from: startSec, to: endSec, every: spec.xLandmark)
        let yMinor    = makeGridLines(from: yLo, to: yHi, every: spec.yMinor)
        let yMajor    = makeGridLines(from: yLo, to: yHi, every: spec.yMajor)
        let yLandmark = makeGridLines(from: yLo, to: yHi, every: spec.yLandmark)

        gridMinorBuffer = makeLineBuffer(
            xLines: xMinor, yLines: yMinor,
            xRange: (uniforms.startSample, uniforms.endSample),
            yRange: (Float(yLo), Float(yHi))
        )
        gridMinorVertexCount = (xMinor.count + yMinor.count) * 2

        gridMajorBuffer = makeLineBuffer(
            xLines: xMajor, yLines: yMajor,
            xRange: (uniforms.startSample, uniforms.endSample),
            yRange: (Float(yLo), Float(yHi))
        )
        gridMajorVertexCount = (xMajor.count + yMajor.count) * 2

        gridLandmarkBuffer = makeLineBuffer(
            xLines: xLandmark, yLines: yLandmark,
            xRange: (uniforms.startSample, uniforms.endSample),
            yRange: (Float(yLo), Float(yHi))
        )
        gridLandmarkVertexCount = (xLandmark.count + yLandmark.count) * 2
    }

    /// Replaces the annotation buckets from a list of visible annotations.
    /// Range annotations become translucent full-height quads (rangeBuckets).
    /// Per-beat point annotations do NOT become full-height rules — beat
    /// identity lives in the SwiftUI top-rail chips
    /// (`WaveformAnnotationOverlay`) per
    /// project_waveform_zoom_lod_spec.md Move A. The only full-height point
    /// rule is the focus locator, wired via `setFocusedBeat(_:)`.
    ///
    /// Caches the input set's identity hash and skips the rebuild when
    /// called with the same set — during a pan, the visible findings
    /// rarely change tick-to-tick, so the cache hit eliminates per-frame
    /// buffer allocations.
    func setAnnotations(_ visible: [Annotation]) {
        let signature = annotationSignature(visible)
        if signature == lastAnnotationSignature { return }
        lastAnnotationSignature = signature

        // Point annotations are intentionally NOT bucketed here — Move A
        // (drop full-height rule per beat; keep chips) supersedes the old
        // per-annotation rendering. pointBuckets stays empty; the focus
        // locator draws in its place.
        pointBuckets = []

        guard !visible.isEmpty else {
            rangeBuckets = []
            return
        }

        var rangesByCategory: [String: [(Int64, Int64)]] = [:]
        for ann in visible where ann.kind == .range {
            let endSample = ann.endSampleIndex ?? ann.sampleIndex
            rangesByCategory[ann.category, default: []].append((ann.sampleIndex, endSample))
        }

        // Build range buckets — one (startSample, endSample) per instance.
        // Range fills use 0.45 alpha to match OverviewMap.swift.
        rangeBuckets = rangesByCategory.compactMap { (category, ranges) -> AnnotationBucket? in
            let pairs = ranges.map { SIMD2<Float>(Float($0.0), Float($0.1)) }
            guard let buf = device.makeBuffer(
                bytes: pairs,
                length: pairs.count * MemoryLayout<SIMD2<Float>>.size,
                options: .storageModeShared
            ) else { return nil }
            var color = CategoryPalette.color(for: category)
            color.w = 0.45
            return AnnotationBucket(buffer: buf, count: pairs.count, color: color)
        }
    }

    /// Sets the focused-beat sample index. Rebuilds the focus-locator
    /// vertex buffer when the sample OR the y-range changed. Nil clears
    /// the locator (no beat under focus → no full-height rule at all).
    func setFocusedBeat(_ sampleIndex: Int64?) {
        let yMin = uniforms.yMin
        let yMax = uniforms.yMax
        let unchanged = sampleIndex == focusedSampleIndex
            && yMin == focusLocatorBakedYMin
            && yMax == focusLocatorBakedYMax
        if unchanged { return }
        focusedSampleIndex = sampleIndex
        guard let s = sampleIndex else {
            focusLocatorBuffer = nil
            return
        }
        let xF = Float(s)
        let pts: [SIMD2<Float>] = [
            SIMD2<Float>(xF, yMin),
            SIMD2<Float>(xF, yMax),
        ]
        focusLocatorBuffer = device.makeBuffer(
            bytes: pts,
            length: pts.count * MemoryLayout<SIMD2<Float>>.size,
            options: .storageModeShared
        )
        focusLocatorBakedYMin = yMin
        focusLocatorBakedYMax = yMax
    }

    // MARK: - Draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let signpostID = OSSignpostID(log: waveformRenderLog)
        os_signpost(.begin, log: waveformRenderLog, name: "RendererDraw", signpostID: signpostID)
        defer { os_signpost(.end, log: waveformRenderLog, name: "RendererDraw", signpostID: signpostID) }

        // Acquire the command buffer first — it never blocks. The drawable
        // and its render-pass descriptor are acquired immediately below,
        // since the MTKView guarantees one's ready by the time draw(in:)
        // is called. We keep the encoding window tight (descriptor →
        // configure → drawScene → present + commit) so the drawable's
        // in-flight window is as small as possible — that's what gives
        // the swap chain headroom to recycle and avoids the 7 ms
        // currentDrawable blocking spikes seen in the signpost trace.
        guard let cmdBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red:   Double(style.paper.x),
            green: Double(style.paper.y),
            blue:  Double(style.paper.z),
            alpha: 1.0
        )
        descriptor.colorAttachments[0].loadAction = .clear
        // When the MTKView is configured for MSAA, `currentRenderPassDescriptor`
        // comes back with a `resolveTexture` pointing at the drawable and a
        // store action of `.multisampleResolve`. Setting `.store` in that
        // case fails Metal validation (the resolve target would have no
        // way to receive the final pixels). When MSAA is off, no resolve
        // texture is present and `.store` is the right action.
        descriptor.colorAttachments[0].storeAction =
            descriptor.colorAttachments[0].resolveTexture != nil ? .multisampleResolve : .store

        // drawScene returns a "needs follow-up" hint that mattered when the
        // canvas was setNeedsDisplay-driven (it could go idle mid-fade);
        // now that the canvas runs continuously, the next vsync handles
        // the follow-up automatically, so we discard the return value.
        _ = drawScene(
            commandBuffer: cmdBuffer,
            descriptor: descriptor,
            drawableSize: view.drawableSize
        )

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    /// Renders the full scene (range fills → grid → trace/envelope → point rules)
    /// into whatever the descriptor's color attachment points at. Decoupled from
    /// MTKView so unit tests can drive it against an offscreen texture and read
    /// back pixels — catches the "renderer init succeeds but produces blank
    /// output" class of bugs (bundle lookup failures, shader miscompiles,
    /// pipeline state errors, viewport math regressions).
    ///
    /// - Returns: `true` if the renderer is mid-LOD-transition and a follow-up
    ///   frame should be scheduled. Production callers feed this back to
    ///   `view.setNeedsDisplay`; tests can ignore the result.
    @discardableResult
    func drawScene(
        commandBuffer cmdBuffer: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor,
        drawableSize: CGSize
    ) -> Bool {
        guard let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }

        var u = uniforms

        // 1. Range fills (under everything else but the paper)
        for bucket in rangeBuckets {
            drawRange(encoder: encoder, bucket: bucket, uniforms: &u)
        }

        // 2. Grid — minor → major → landmark (every 5th major). Drawn in that
        // order so heavier lines win at intersections.
        if gridMinorVertexCount > 0, let buf = gridMinorBuffer {
            drawLines(encoder: encoder, buffer: buf, vertexCount: gridMinorVertexCount,
                      color: style.gridMinor, uniforms: &u)
        }
        if gridMajorVertexCount > 0, let buf = gridMajorBuffer {
            drawLines(encoder: encoder, buffer: buf, vertexCount: gridMajorVertexCount,
                      color: style.gridMajor, uniforms: &u)
        }
        if gridLandmarkVertexCount > 0, let buf = gridLandmarkBuffer {
            drawLines(encoder: encoder, buffer: buf, vertexCount: gridLandmarkVertexCount,
                      color: style.gridLandmark, uniforms: &u)
        }

        // 3. Trace OR envelope, with optional crossfade against the
        // previous LOD's snapshot. Fade-out the previous path first
        // (so it's under the new one) — visually the analyst sees the
        // old shape soften out while the new shape strengthens in.
        let progress = lodTransitionProgress
        if progress < 1, let prev = previousLOD {
            let fadeOut = 1 - progress
            if prev.useEnvelope, let prevPyramid = prev.pyramidBuffer, prev.pyramidBinCount > 0 {
                drawEnvelope(
                    encoder: encoder,
                    buffer: prevPyramid,
                    binSamples: prev.pyramidBinSamples,
                    binCount: prev.pyramidBinCount,
                    alphaMultiplier: fadeOut
                )
            } else if let prevSamples = prev.sampleBuffer, prev.sampleCount > 1 {
                drawTrace(
                    encoder: encoder,
                    buffer: prevSamples,
                    samples: prev.sampleCount,
                    drawableSize: drawableSize,
                    uniforms: &u,
                    alphaMultiplier: fadeOut
                )
            }
        }

        if useEnvelope, let pyramid = pyramidBuffer, pyramidBinCount > 0 {
            drawEnvelope(
                encoder: encoder,
                buffer: pyramid,
                binSamples: pyramidBinSamples,
                binCount: pyramidBinCount,
                alphaMultiplier: progress
            )
        } else if let samples = sampleBuffer, sampleCount > 1 {
            drawTrace(
                encoder: encoder,
                buffer: samples,
                samples: sampleCount,
                drawableSize: drawableSize,
                uniforms: &u,
                alphaMultiplier: progress
            )
        }

        // LOD transition is finished — drop the snapshot of the previous LOD
        // so subsequent frames don't keep paying for the crossfade.
        if progress >= 1, previousLOD != nil {
            previousLOD = nil
            lodTransitionStart = nil
        }

        // 4. Point rules
        // Per-beat full-height rules were dropped in Move A of
        // project_waveform_zoom_lod_spec.md; only the focus-locator survives
        // as a full-height point rule (a "you are here" anchor for the
        // selected beat). Beat identity for every other beat lives in the
        // SwiftUI top-rail chips (`WaveformAnnotationOverlay`) plus the
        // FiducialOverlay R-tick.
        for bucket in pointBuckets {
            drawLines(encoder: encoder, buffer: bucket.buffer, vertexCount: bucket.count,
                      color: bucket.color, uniforms: &u)
        }
        if let buf = focusLocatorBuffer {
            // Neutral dark ink, semi-transparent — reads as a location
            // cursor, not a computed judgment (mockup-review B-RUO:
            // app-computed = neutral; amber = analyst findings only).
            let color = SIMD4<Float>(0.20, 0.20, 0.25, 0.40)
            drawLines(encoder: encoder, buffer: buf, vertexCount: 2,
                      color: color, uniforms: &u)
        }

        encoder.endEncoding()
        return progress < 1
    }

    // MARK: - Pass helpers

    private func drawLines(
        encoder: MTLRenderCommandEncoder,
        buffer: MTLBuffer,
        vertexCount: Int,
        color: SIMD4<Float>,
        uniforms: inout WaveformUniforms
    ) {
        encoder.setRenderPipelineState(linePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<WaveformUniforms>.size, index: 1)
        var c = color
        encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertexCount)
    }

    private func drawTrace(
        encoder: MTLRenderCommandEncoder,
        buffer: MTLBuffer,
        samples: Int,
        drawableSize: CGSize,
        uniforms: inout WaveformUniforms,
        alphaMultiplier: Float = 1
    ) {
        // Restrict the draw to the visible range with one sample of overscan
        // on each side so segments don't pop in/out at the chart edges.
        let lo = max(0, Int(uniforms.startSample) - 1)
        let hi = min(samples, Int(uniforms.endSample.rounded(.up)) + 1)
        let count = hi - lo
        guard count > 1 else { return }

        encoder.setRenderPipelineState(tracePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)

        var traceU = TraceUniformsCPU(
            startSample: uniforms.startSample,
            endSample:   uniforms.endSample,
            yMin:        uniforms.yMin,
            yMax:        uniforms.yMax,
            viewportSizePx: SIMD2<Float>(
                Float(max(1, drawableSize.width)),
                Float(max(1, drawableSize.height))
            ),
            lineWidthPx: style.traceLineWidthPx,
            sampleCount: UInt32(samples)
        )
        encoder.setVertexBytes(&traceU, length: MemoryLayout<TraceUniformsCPU>.size, index: 1)

        var c = style.trace
        c.w *= alphaMultiplier
        encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)

        // Two vertices per sample → triangle strip ribbon. vertexStart × 2
        // because the shader recovers the sample index as vid / 2.
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: lo * 2,
            vertexCount: count * 2
        )
    }

    private func drawEnvelope(
        encoder: MTLRenderCommandEncoder,
        buffer: MTLBuffer,
        binSamples: Float,
        binCount: Int,
        alphaMultiplier: Float = 1
    ) {
        encoder.setRenderPipelineState(envelopePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var envU = EnvelopeUniformsCPU(
            startSample: uniforms.startSample,
            endSample:   uniforms.endSample,
            yMin:        uniforms.yMin,
            yMax:        uniforms.yMax,
            binSamples:  binSamples
        )
        encoder.setVertexBytes(&envU, length: MemoryLayout<EnvelopeUniformsCPU>.size, index: 1)
        var c = style.envelope
        c.w *= alphaMultiplier
        encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0, vertexCount: 4,
            instanceCount: binCount
        )
    }

    private func drawRange(
        encoder: MTLRenderCommandEncoder,
        bucket: AnnotationBucket,
        uniforms: inout WaveformUniforms
    ) {
        encoder.setRenderPipelineState(rangePipeline)
        encoder.setVertexBuffer(bucket.buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<WaveformUniforms>.size, index: 1)
        var c = bucket.color
        encoder.setFragmentBytes(&c, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0, vertexCount: 4,
            instanceCount: bucket.count
        )
    }

    // MARK: - Helpers

    /// Cheap identity hash of an annotation set. Order-sensitive so a
    /// re-sort still rebuilds — callers already pass deterministic order.
    private func annotationSignature(_ visible: [Annotation]) -> Int {
        var hasher = Hasher()
        hasher.combine(visible.count)
        for ann in visible {
            hasher.combine(ann.id)
        }
        return hasher.finalize()
    }

    private func makeLineBuffer(
        xLines: [Double],
        yLines: [Double],
        xRange: (Float, Float),
        yRange: (Float, Float)
    ) -> MTLBuffer? {
        guard !xLines.isEmpty || !yLines.isEmpty else { return nil }
        var points: [SIMD2<Float>] = []
        points.reserveCapacity((xLines.count + yLines.count) * 2)
        for xSec in xLines {
            let x = Float(xSec * channelSampleRate)
            points.append(SIMD2<Float>(x, yRange.0))
            points.append(SIMD2<Float>(x, yRange.1))
        }
        for y in yLines {
            let yf = Float(y)
            points.append(SIMD2<Float>(xRange.0, yf))
            points.append(SIMD2<Float>(xRange.1, yf))
        }
        return device.makeBuffer(
            bytes: points,
            length: points.count * MemoryLayout<SIMD2<Float>>.size,
            options: .storageModeShared
        )
    }
}

// MARK: - Grid line generator

func makeGridLines(from start: Double, to end: Double, every spacing: Double) -> [Double] {
    guard spacing > 0, end > start else { return [] }
    let first = (start / spacing).rounded(.up) * spacing
    var lines: [Double] = []
    var x = first
    let stop = end + spacing * 0.0001
    while x <= stop {
        lines.append(x)
        x += spacing
    }
    return lines
}
