---
title: Architecture
layout: default
nav_order: 3
---

# Architecture

Three layers, all independently testable.

## 1. Data Engine

Owns disk → memory → GPU.

| Component | Role |
|---|---|
| `BinaryRecordingFile` | Float32-packed channel file format. Header v2 (64 bytes) + Float32 sample body, little-endian. |
| `MappedSampleAccess` | mmap-backed reader. `Data(contentsOf:options:.mappedIfSafe)`. |
| `PyramidBuilder` | Single-pass cascading min/max bins. Stride 10, up to 6 levels. |
| `PyramidLevelFile` | (min, max) Float64 pair binary format with its own mmap reader. |
| `ChannelView` | LOD-aware reader. `selectLevel(samplesPerPixel:)` returns the deepest level that fits. |
| `RecordingViewport` | `@Observable @MainActor` shared time window for every channel in a Recording. |

### Why a pyramid

Drawing the trace from raw samples is fine at high zoom (10 s @ 250 Hz =
2500 vertices) but ruinous at low zoom (30 min @ 360 Hz = 650 000). The
pyramid pre-computes min/max envelopes at 10×, 100×, 1000×, … strides at
import time. At render time the LOD selector picks the deepest level
whose `binSamples ≤ samplesPerPixel`, then renders ~one quad per pixel
regardless of recording length.

### Viewport invariants

`RecordingViewport` is the single mutable time-window state. Every
channel in a recording observes it. All mutators (`pan`, `setStart`,
`setWidth`, `jump`) clamp to recording bounds and respect a 100 ms
minimum window so the user can't accidentally zoom into a 1-sample slice.

## 2. Waveform Canvas

Pure Metal, no Swift Charts.

| Component | Role |
|---|---|
| `WaveformCanvas` | `NSViewRepresentable` over `MTKView`. |
| `WaveformRenderer` | `MTKViewDelegate`. Owns pipelines, buffers, draw loop. |
| `WaveformShaders.metal` | Vertex/fragment functions. |

### Per-frame render

1. **Clear** to paper color.
2. **Range annotations** — translucent quads, one bucket per category.
3. **Grid minor** — line list, salmon @ 65% alpha.
4. **Grid major** — line list, red-pink @ 55% alpha.
5. **Trace OR envelope** — line strip OR instanced quads.
6. **Point annotations** — line list per category, severity-modulated alpha.

### Trace vertex strategy

The trace shader reads `samples[vertex_id]` directly. The sample buffer
is uploaded once at channel load (zero-copy mmap → GPU). Pan/zoom
updates only a 16-byte uniforms block. No vertex-buffer rebuild ever
happens at interactive rates.

Out-of-range samples (outside ±5 mV) emit a NaN clip-space position so
the line strip gaps cleanly at off-scale events. A SwiftUI overlay marks
each gap with a ▲/▼ chevron at the chart edge.

### Buffer lifecycle

| Buffer | Built when | Size |
|---|---|---|
| Sample (Float32) | Channel load | `sampleCount × 4` bytes |
| Pyramid (Float32 pairs) | Pyramid-level change | `binCount × 8` bytes |
| Grid minor / major | Viewport change | hundreds of vertices |
| Annotation buckets | Viewport change | per-category |
| Uniforms | Every frame | 16-32 bytes inline (`setVertexBytes`) |

## 3. Control Overlay

Pure SwiftUI on top of the Metal layer.

| Component | Role |
|---|---|
| `BedsideView` | Stack of `ChannelPanel`s sharing one `RecordingViewport`. |
| `WaveformTimeAxis` / `WaveformVoltageAxis` | Tick labels positioned by viewport math. |
| `WaveformAnnotationOverlay` | Category-colored symbol labels at the top of each canvas. |
| `WaveformClippingOverlay` | ▲/▼ chevrons at off-scale events. |
| `OverviewRibbon` | Whole-recording envelope (Swift Charts — small fixed widget). |
| `FindingsPanel` | Right-side inspector with filter chips and clickable rows. |

The overview ribbon is the one piece still using Swift Charts. It's a
tiny widget, the click-scrub interaction already works, and replacing it
wouldn't move the needle.

## Invariants worth knowing

- All channels in a Recording share one `RecordingViewport` — leads
  scroll and zoom in lock-step like a clinical monitor.
- The app is sandboxed. File picker selects a *folder*; security scope
  covers all child files.
- Internal storage is Float32 (`BinaryRecordingHeader.currentVersion = 2`).
- WFDB baseline defaults to `adcZero` when not explicitly written in the
  gain field (matters for MIT-BIH where `adcZero = 1024`).
- ECG is the only domain. The CSV plotter and vent pipeline were both
  removed during the 2026-06-14 pivot.
