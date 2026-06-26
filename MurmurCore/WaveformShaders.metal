//
//  WaveformShaders.metal
//  Murmur
//
//  GPU shaders for the ECG waveform canvas. Three vertex functions:
//
//    traceVertex      — Reads a Float32 sample from a buffer using vertex_id as
//                       the sample index. Used for raw line-strip rendering.
//    lineVertex       — Reads (xData, yData) pairs from a buffer. Used for grid
//                       lines and annotation rules.
//    envelopeVertex   — Instanced quad rendering for pyramid (min, max) bins.
//                       4 vertices per instance, with vid bits selecting
//                       left/right and bottom/top corners.
//
//  One fragment function: colorFragment reads a single float4 color and outputs
//  it directly. Lets us blend translucent passes (grid, envelope, annotation)
//  over the paper background cleared at the start of the render pass.
//

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float startSample;
    float endSample;
    float yMin;
    float yMax;
};

struct EnvelopeUniforms {
    float startSample;
    float endSample;
    float yMin;
    float yMax;
    float binSamples;
};

/// Trace pass needs viewport pixel size and a desired line width because Metal
/// has no built-in `glLineWidth` equivalent — we extrude each sample into a
/// 2-vertex ribbon and render as a triangle strip, with the perpendicular
/// computed in screen-pixel space so the trace looks the same thickness at
/// every zoom.
struct TraceUniforms {
    float startSample;
    float endSample;
    float yMin;
    float yMax;
    float2 viewportSizePx;
    float lineWidthPx;
    uint sampleCount;
};

struct VertexOut {
    float4 position [[position]];
};

static float4 toClipSpace(float xData, float yData, constant Uniforms& u) {
    float xClip = 2.0 * (xData - u.startSample) / (u.endSample - u.startSample) - 1.0;
    float yClip = 2.0 * (yData - u.yMin) / (u.yMax - u.yMin) - 1.0;
    return float4(xClip, yClip, 0.0, 1.0);
}

/// Trace ribbon vertex shader. Each input sample produces two vertices
/// (top + bottom) that the rasterizer joins into a quad with its neighbor —
/// effectively a polyline with a configurable on-screen pixel width.
///
/// The perpendicular at each sample is computed from the screen-space
/// direction to a neighbor (next when available, prev at the buffer end).
/// Out-of-range samples emit NaN positions for both vertices so the ribbon
/// gaps cleanly at off-scale events.
vertex VertexOut traceVertex(uint vid [[vertex_id]],
                              constant float* samples [[buffer(0)]],
                              constant TraceUniforms& u [[buffer(1)]]) {
    VertexOut out;
    uint sampleIdx = vid / 2u;
    float side = (vid & 1u) != 0u ? -1.0 : 1.0;       // +1 above, -1 below

    if (sampleIdx >= u.sampleCount) {
        float nanV = 0.0 / 0.0;
        out.position = float4(nanV, nanV, nanV, nanV);
        return out;
    }

    float yData = samples[sampleIdx];
    if (yData < u.yMin || yData > u.yMax) {
        float nanV = 0.0 / 0.0;
        out.position = float4(nanV, nanV, nanV, nanV);
        return out;
    }

    // Clip-space position of this sample.
    float spanX = u.endSample - u.startSample;
    float spanY = u.yMax - u.yMin;
    float xClip = 2.0 * (float(sampleIdx) - u.startSample) / spanX - 1.0;
    float yClip = 2.0 * (yData - u.yMin) / spanY - 1.0;

    // Pick the neighbor we'll derive direction from. Prefer next; fall back
    // to prev at the last vertex.
    uint neighborIdx;
    if (sampleIdx + 1u < u.sampleCount) {
        neighborIdx = sampleIdx + 1u;
    } else if (sampleIdx > 0u) {
        neighborIdx = sampleIdx - 1u;
    } else {
        // Degenerate: a single sample. No direction → no offset.
        out.position = float4(xClip, yClip, 0.0, 1.0);
        return out;
    }
    float yNeighbor = samples[neighborIdx];

    // Convert to pixel space, take the perpendicular, then convert back.
    float xClipN = 2.0 * (float(neighborIdx) - u.startSample) / spanX - 1.0;
    float yClipN = 2.0 * (yNeighbor - u.yMin) / spanY - 1.0;

    float2 halfViewport = u.viewportSizePx * 0.5;
    float2 thisPx = float2(xClip,  yClip)  * halfViewport;
    float2 neighPx = float2(xClipN, yClipN) * halfViewport;

    float2 dir = neighPx - thisPx;
    float len = max(length(dir), 1e-6);
    dir /= len;

    // Perpendicular (90° rotation). For a `next`-neighbor we want the same
    // sign as `side`; for a `prev`-neighbor we invert because the segment
    // direction flips. Without this, the last vertex's ribbon would be on
    // the wrong side of the trace.
    float orientation = (sampleIdx + 1u < u.sampleCount) ? 1.0 : -1.0;
    float2 perp = float2(-dir.y, dir.x) * side * orientation;

    // Offset by half the requested width in pixels, converted back to clip.
    float2 offsetPx = perp * (u.lineWidthPx * 0.5);
    float2 offsetClip = offsetPx / halfViewport;

    out.position = float4(xClip + offsetClip.x,
                          yClip + offsetClip.y,
                          0.0, 1.0);
    return out;
}

vertex VertexOut lineVertex(uint vid [[vertex_id]],
                            constant float2* points [[buffer(0)]],
                            constant Uniforms& u [[buffer(1)]]) {
    VertexOut out;
    float2 p = points[vid];
    out.position = toClipSpace(p.x, p.y, u);
    return out;
}

vertex VertexOut envelopeVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant float2* bins [[buffer(0)]],
                                constant EnvelopeUniforms& u [[buffer(1)]]) {
    float2 bin = bins[iid];                     // (min, max)
    bool isRight = (vid & 1u) != 0u;            // vid 1 or 3
    bool isTop   = (vid & 2u) != 0u;            // vid 2 or 3
    float xData = (float(iid) + (isRight ? 1.0 : 0.0)) * u.binSamples;
    float yData = isTop ? bin.y : bin.x;

    VertexOut out;
    float xClip = 2.0 * (xData - u.startSample) / (u.endSample - u.startSample) - 1.0;
    float yClip = 2.0 * (yData - u.yMin) / (u.yMax - u.yMin) - 1.0;
    out.position = float4(xClip, yClip, 0.0, 1.0);
    return out;
}

/// Translucent full-height range quad. One instance per annotation; the range
/// buffer holds (startSample, endSample) and we fill the entire vertical extent
/// inside that window. Used to mark VF/VT episodes, AFib runs, noise gaps, etc.
vertex VertexOut rangeVertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant float2* ranges [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]]) {
    float2 r = ranges[iid];                     // (startSample, endSample)
    bool isRight = (vid & 1u) != 0u;
    bool isTop   = (vid & 2u) != 0u;
    float xData = isRight ? r.y : r.x;
    float yData = isTop ? u.yMax : u.yMin;

    VertexOut out;
    out.position = toClipSpace(xData, yData, u);
    return out;
}

fragment float4 colorFragment(VertexOut in [[stage_in]],
                              constant float4& color [[buffer(0)]]) {
    return color;
}
