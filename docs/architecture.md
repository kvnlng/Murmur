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
| `WFDBHeaderParser` | Reads `.hea` files. Honors the per-signal `format[xspf]` suffix so a record can mix high-rate ECG (`16x250`) with 1-min feature signals (`16x1`) at one base frame rate. |
| `WFDBSampleDecoder` | Format-16 and format-212 decoder. Groups signals by `.dat` filename — single-file records and per-signal-file records both work. |
| `WFDBImporter` | Folder → bundle pipeline. Validates every `.dat`, decodes per signal, builds pyramids, writes manifest. Multi-frequency record support means low-rate trend channels share a record with the ECG signals. |
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
5. **Grid landmark** — line list, deep salmon @ 85% alpha (every 5th major; the standard 1 s / 2.5 mV reference).
6. **Trace OR envelope** — triangle-strip polyline OR instanced quads.
7. **Point annotations** — line list per category, severity-modulated alpha.

### Trace vertex strategy

The trace shader reads `samples[vertex_id / 2]` directly. The sample
buffer is uploaded once at channel load (zero-copy mmap → GPU). Pan/zoom
updates only a 32-byte uniforms block. No vertex-buffer rebuild ever
happens at interactive rates.

The trace is rendered as a triangle strip — each sample produces two
vertices (above + below the centerline). The vertex shader extrudes
both vertices perpendicular to the local segment direction in
screen-pixel space, so line width stays constant in points regardless
of zoom (Metal has no `glLineWidth` equivalent).

Out-of-range samples (outside ±5 mV) emit a NaN clip-space position so
the ribbon gaps cleanly at off-scale events. A SwiftUI overlay marks
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
| `BedsideView` | Top-level shell. Partitions channels into ECG (Metal canvas) and low-rate (context strips). Owns the shared viewport, the filter, and the analyst disposition store. |
| `LeadChipBar` | Focus/Strips mode toggle + one chip per ECG lead. |
| `ChannelPanel` | Per-lead container: header, voltage axis, Metal canvas, time axis, overview ribbon. |
| `WaveformTimeAxis` / `WaveformVoltageAxis` | Tick labels positioned by viewport math. |
| `WaveformAnnotationOverlay` | Category-colored symbol labels at the top of each canvas. |
| `WaveformClippingOverlay` | ▲/▼ chevrons at off-scale events. |
| `OverviewRibbon` | Whole-recording envelope per lead (Swift Charts — small fixed widget). |
| `RecordContextPanel` | `.hea` header comments + Markdown notes editor next to the recording bundle. |
| `FindingsSummaryHeader` | Compact chip row above the canvas — one chip per category with count or duration, plus the analyst's disposition tally. |
| `FindingDensityTimeline` | One thin lane per category spanning the full recording. Confirmed entries get a green ring; dismissed entries dim. |
| `FindingsPanel` | Right-side inspector with filter chips, per-row confirm / dismiss / reset controls, and a triage tally. |

### Low-rate context strips

When a multi-frequency record carries sub-5-Hz channels (the Medallion
feature store's 1-min vitals, alarms, state probabilities, quality
ratios), `BedsideView.LowRatePartition` routes them by name into four
strips stacked below the canvas:

| Strip | Channels | Visual |
|---|---|---|
| `ChannelTrendStrip` | HR, SpO₂, etCO₂, BPM, tidal volume, anything numeric without a routing-suffix | One Swift Charts sparkline per channel, time-locked to the viewport |
| `AlarmStrip` | Anything ending in `_alarm`, `_status`, or `_silenced` | One lane per channel; active runs as colored bars; tap to jump |
| `StateBackdropStrip` | `prob_state_spontaneous` + `prob_state_assist_control` pair | One row of colored cells per minute — warm = spontaneous, cool = assist-control, opacity = certainty |
| `QualityStrip` | Anything ending in `_ratio` or containing `artifact_ratio` (Medallion `ecg_artifact_ratio`) | Gray heat band with threshold-outlined cells past 0.1 |

Each strip renders only when its inputs exist — plain ECG records show
none of the new chrome.

### Disposition workflow

`DispositionStore` (`@Observable`) owns the analyst's review state for
one recording. It reads `<bundle>/dispositions.json` on init, exposes
`record(for:)`, `state(for:)`, `tally(for:)`, and mutates via `confirm`,
`dismiss`, `reset`, `clear`. Every mutation writes the whole sidecar —
files are tiny.

States are three-way: **unreviewed** (implicit by absence from the
map), **confirmed** (with optional VT / VF sub-kind), and **dismissed**.
Re-running the producer (which regenerates
`<recordName>.annotations.json`) never overwrites the sidecar, so
analyst work survives every re-import.

Visual feedback flows from the same store: the findings panel rows
show inline buttons (gated by the toolbar lock), the summary chip row
shows a tally, the density timeline outlines confirmed events and dims
dismissed ones.

### Entry surfaces

| Component | Role |
|---|---|
| `WelcomeView` | First-launch card on a faint ECG-paper backdrop. Recents, Try-a-sample, drop-a-folder, and a PhysioNet link. |
| `RecentFoldersStore` | Persists up to 10 security-scoped bookmarks to `UserDefaults` so a sandboxed app can re-open a folder next launch. |
| `ContentView` | App root. Picks between `WelcomeView` (empty), browsing shell (sidebar + detail), and direct-view shell. |

The overview ribbon is the one piece in the bedside still using Swift
Charts, alongside `ChannelTrendStrip`. Both are tiny widgets; replacing
them wouldn't move the needle.

## Invariants worth knowing

- All channels in a Recording share one `RecordingViewport` — leads
  scroll and zoom in lock-step like a clinical monitor.
- ECG channels go through the Metal canvas; anything sub-5-Hz is a
  trend channel and goes to a context strip below it (`Channel.isTrendChannel`).
  Producers don't need any new metadata — naming + sample rate are the
  routing inputs.
- The app is sandboxed. File picker selects a *folder*; security scope
  covers all child files. Recent folders persist as security-scoped
  bookmarks, not raw paths.
- Internal storage is Float32 (`BinaryRecordingHeader.currentVersion = 2`).
- WFDB baseline defaults to `adcZero` when not explicitly written in the
  gain field (matters for MIT-BIH where `adcZero = 1024`).
- Producer outputs are authoritative; the viewer never re-derives them.
  Analyst-side annotations (disposition + notes) live in their own
  sidecars (`dispositions.json`, `notes.md`) so re-running a producer
  never destroys analyst work.
- ECG is the only domain. The CSV plotter and standalone vent pipeline
  were both removed during the 2026-06-14 pivot, though low-rate vent
  features can ride alongside the ECG in a multi-frequency WFDB.
