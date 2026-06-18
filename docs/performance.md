---
title: Performance notes
layout: default
nav_order: 5
---

# Performance notes

How Plotting stays interactive on multi-hour records.

## Static budget per frame

Regardless of zoom level, the renderer encodes the same handful of draw
calls:

| Pass | Vertices / instances | Cost |
|---|---|---|
| Paper clear | — | 0 |
| Range annotations | 4 × (#categories with ranges) | per-category draw call |
| Grid minor | 2 × #minor gridlines (bounded ~few hundred) | one draw |
| Grid major | 2 × #major gridlines (bounded ~few hundred) | one draw |
| Grid landmark | 2 × #landmark gridlines (bounded ~tens) | one draw |
| Trace OR envelope | 2 × viewport-range samples (triangle-strip ribbon) OR 4 × #bins | one draw |
| Point annotations | 2 × #points × (#categories) | per-category draw call |

Total draw calls: typically 6-13. Total vertices: bounded under 20k for
the trace at any zoom (LOD selector keeps the per-pixel sample count
under one, and the triangle strip doubles to two vertices per sample).

## LOD selector

`ChannelView.selectLevel(samplesPerPixel:)` picks the deepest pyramid
level whose `binSamples ≤ samplesPerPixel`. For a 600-pixel chart:

| Window | samplesPerPixel | LOD |
|---|---|---|
| 1 s @ 250 Hz | 0.4 | raw |
| 10 s @ 250 Hz | 4 | raw |
| 30 s @ 250 Hz | 12 | L1 (10 samples/bin) |
| 5 min @ 250 Hz | 125 | L2 (100/bin) |
| 30 min @ 250 Hz | 750 | L3 (1000/bin) |

The renderer never draws more than ~1 vertex per pixel — the visual
density is constant.

## Zero-copy GPU buffers

The whole channel's Float32 samples go into one `MTLBuffer` once at
channel load. The trace vertex shader uses `vertex_id` as the implicit
sample index — each sample produces two vertices (above + below the
centerline) so the shader fetches `samples[vid / 2]` directly without
any attribute decoding:

```metal
vertex VertexOut traceVertex(uint vid [[vertex_id]],
                              constant float* samples [[buffer(0)]],
                              constant TraceUniforms& u [[buffer(1)]]) { … }
```

The shader extrudes each sample perpendicular to the local segment
direction in screen-pixel space, giving the trace a constant
on-screen width at any zoom — without ever moving a vertex buffer.
Pan/zoom updates the 32-byte `TraceUniforms` block via
`setVertexBytes` per frame.

## Pyramid memory

For each channel:

```
raw samples       = sampleCount × 4 bytes
L1 pyramid        = sampleCount / 10  × 16 bytes  ≈ 0.4× raw
L2 pyramid        = sampleCount / 100 × 16 bytes  ≈ 0.04× raw
…
total overhead    ≈ raw × (0.4 + 0.04 + 0.004 + …) ≈ 0.44× raw
```

For a 650 000-sample MIT-BIH lead that's ~2.6 MB raw + ~1.1 MB pyramid
per channel. A 12-lead 1-hour recording at 360 Hz is ~70 MB raw +
~30 MB pyramid total — easily resident.

## Off-scale handling

The trace shader gaps the line at out-of-range samples (`y < -5 mV`
or `y > +5 mV`) by emitting a NaN clip-space position. This is GPU-side
filtering with no CPU pre-scan during rendering.

The CPU does scan once at channel load (`ClippedRangeScanner.scan`) to
populate the off-scale count and the chevron-overlay positions. That's a
single linear pass over the channel's samples — milliseconds for
million-sample channels.

## Annotation buckets

Annotations are pre-bucketed by category at viewport-change time so each
category gets one draw call. With 2272 annotations × ~10 categories,
that's at most ~10 extra draw calls per channel per frame — trivial.

The visible-range filter is currently linear in the annotation count
(O(n) per frame) — adequate at current scales. A binary-search version
is on the roadmap for records with 10× more annotations.

## Where the budget could go next

- Trace shader could short-circuit further by clipping vertices outside
  the viewport entirely (instead of drawing them and letting Metal clip).
- Annotation visible-range filter → binary search (the list is sorted by
  `sampleIndex`).
- Multi-channel records currently render each channel into its own
  `MTKView`; for very high lead counts a single shared command buffer
  would reduce overhead.

None of these are needed today — interactive pan/zoom on MIT-BIH 100
runs at the display's refresh rate on M-series hardware with headroom
left over.
