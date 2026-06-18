# Plotting

A macOS SwiftUI app for analyst review of clinical ECG findings.

Plotting renders PhysioNet WFDB recordings (`.hea` + `.dat`) as the *context*
an analyst needs to interpret findings produced upstream by a cluster of
analysis machines (VF/VT onset, AFib, PVCs, disease vectors). The findings
themselves are the primary data surface — the trace is what makes them
readable.

![Plotting bedside view — record sidebar, Metal-backed ECG paper canvas on the focused MLII lead of MIT-BIH record 107, and the findings inspector.](docs/assets/bedside-overview.png)

## Status

Hobby / research project. Not yet shipping. Built against macOS 14+ with
Swift 6 and Metal.

## Features

- **WFDB ingest** — formats 16 and 212 (MIT-BIH Arrhythmia Database
  decodes out of the box). Folder picker covers `.hea` + sibling `.dat` /
  `.atr` / `.annotations.json` reads.
- **Findings panel** — right-side inspector with category, severity,
  source, and confidence filter chips. Filter is shared with the canvas:
  filtered-out findings stop rendering everywhere.
- **Metal-rendered waveform** — `MTKView` via `NSViewRepresentable`. One
  buffer per channel uploaded once; pan/zoom updates a uniforms block
  only. Out-of-range samples are gapped in the trace shader; ▲/▼ chevrons
  mark off-scale events at the chart edges.
- **ECG paper styling** — adaptive grid density that stays readable from
  a 1-second window up to multi-hour viewports. Black trace, pink paper,
  salmon grid.
- **Min/max pyramid + LOD selection** — single-pass at import time. The
  renderer picks raw samples when zoomed in, an instanced-quad envelope
  when zoomed out. Same byte budget at every zoom.
- **Memory-mapped storage** — Float32 channel files + Float64 pyramid
  bins via `Data(contentsOf:options:.mappedIfSafe)`. Zero-copy from disk
  to GPU buffer.

## Documentation

Full documentation lives at **https://kvnlng.github.io/Plotting** (built
from [`docs/`](docs)).

Quick links:

- [Getting started](docs/getting-started.md) — open a record, jump to a
  finding, scrub the timeline.
- [Architecture](docs/architecture.md) — Data Engine / Waveform Canvas /
  Control Overlay layering, key invariants.
- [Annotation JSON schema](docs/annotation-schema.md) — what the
  producer cluster emits as `<recordName>.annotations.json`.
- [Roadmap](ROADMAP.md) — current state and what's next.

## Quick start

1. Clone and open in Xcode 15+ (`Plotting.xcodeproj`).
2. ⌘R to launch.
3. Click **Open Record Folder** and pick a directory containing a WFDB
   record (e.g. PhysioNet's MIT-BIH Arrhythmia Database). The sidebar
   lists every `.hea` it finds; click one to import and view.
4. Drop a `<recordName>.annotations.json` next to the record's `.hea`
   to overlay your cluster's findings. See the
   [schema](docs/annotation-schema.md) for the wire format.

## Tests

```sh
xcodebuild test -project Plotting.xcodeproj -scheme Plotting
```

126 tests covering: WFDB parsing/decoding (including multi-frequency
records with per-signal `.dat` files), importer end-to-end, pyramid
construction, viewport clamping, grid-density adaptive selection,
annotation JSON round-trip (sample-index + unix-ms), filter matching,
manifest backward compat, the off-scale scanner, the recent-folders
bookmark store, the per-recording annotation summary, the low-rate
trend channel discriminator, the boolean alarm/status range scanner,
and the low-rate channel partitioner (vitals / alarms / state pair /
quality).

## License

MIT. See [`LICENSE`](LICENSE).
