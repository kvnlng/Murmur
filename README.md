# Murmur Studio

A free, open-source native macOS viewer for PhysioNet WFDB recordings,
with optional paid research extensions on the App Store.

Murmur renders WFDB ECG + multi-rate telemetry on a Metal-backed paper
canvas alongside upstream-produced clinical findings (VF/VT onset,
AFib, PVCs, disease vectors). The findings are the primary surface;
the waveform is the *context* an analyst needs to interpret them. The
analyst disposition workflow — confirm / dismiss / reset — is part of
the free viewer, so triage stays free even when paid extensions are
producing findings.

![Murmur bedside view — record sidebar, Metal-backed ECG paper canvas on the focused MLII lead of MIT-BIH record 107, and the findings inspector.](docs/assets/bedside-overview.png)

## Open-core distribution

Murmur Studio ships as a single binary on the App Store. The viewer is
free, MIT-licensed, and open-source. Three optional in-app purchases
add research/commercial capabilities on top — never gating anything
the free viewer already does.

| Tier | What it does | Source |
|---|---|---|
| **Murmur Studio** (free, MIT) | WFDB import, finding display, filter chips, viewport, disposition workflow | This repo |
| **Annotation Authoring IAP** (paid) | Manual finding create / edit / delete | Private framework (paid users only) |
| **Silver Layer Metrics IAP** (paid) | Cardiopulmonary feature extraction (modular Silver-layer features from author's paper) | Private framework |
| **VT/VF Detection IAP** (paid) | On-device SE-ResLSTM inference, RUO — research use only | Private framework + remote model updates |

The split is *source distribution*, not *binary distribution*: the App
Store ships one app, and IAP entitlement checks unlock the paid
frameworks at runtime. See [ROADMAP](ROADMAP.md) for sequencing.

## Status

App Store release approved (v1.0). Open-source pivot scheduled around
the same timeline; see [Roadmap](ROADMAP.md) for the next-session work
queue.

The free viewer targets macOS 26+ with Swift 6 and Metal.

## Features

- **WFDB ingest** — formats 16 and 212 (MIT-BIH decodes out of the
  box) plus multi-frequency records with per-signal `.dat` files.
  Folder picker covers `.hea` + sibling `.dat` / `.atr` /
  `.annotations.json`.
- **Findings panel** — right-side inspector with category, severity,
  source, and confidence filter chips. Filter is shared with the
  canvas: filtered-out findings stop rendering everywhere.
- **Analyst disposition workflow** — confirm / dismiss / reset on
  each finding, persisted to a versioned sidecar at
  `<bundle>/dispositions.json` so re-running upstream analysis never
  overwrites analyst work.
- **Metal-rendered waveform** — `MTKView` via `NSViewRepresentable`.
  Buffer-per-channel uploaded once; pan/zoom updates a uniforms
  block only. 4× MSAA, LOD crossfade, hover crosshair with live
  cursor tracking and rubber-band overscroll at recording
  boundaries.
- **ECG paper styling** — adaptive grid density that stays readable
  from a 1-second window up to multi-hour viewports.
- **Min/max pyramid + LOD selection** — single-pass at import time.
  The renderer picks raw samples when zoomed in, an instanced-quad
  envelope when zoomed out.
- **Memory-mapped storage** — Float32 channel files + Float64
  pyramid bins via `Data(contentsOf:options:.mappedIfSafe)`.
- **Triage surfaces** — finding-density timeline lanes, summary
  chip row, alarm/state/quality strips for multi-rate records.
- **Configurable haptic feedback** — opt-in `.alignment` ticks
  during pan when annotations enter the viewport. Two modes (every
  finding vs. category transitions only). Force Touch trackpad
  required.

## Documentation

Full documentation lives at **https://kvnlng.github.io/Murmur** (built
from [`docs/`](docs)).

Quick links:

- [Getting started](docs/getting-started.md) — open a record, jump to
  a finding, scrub the timeline.
- [Architecture](docs/architecture.md) — MurmurCore + planned paid
  extension frameworks, the `FindingProducer` contract, layering.
- [Annotation JSON schema](docs/annotation-schema.md) — what
  producers emit as `<recordName>.annotations.json`.
- [Citation](docs/citation.md) — how to cite Murmur Studio + its
  paid tiers in research.
- [Roadmap](ROADMAP.md) — current state and what's next, including
  the open-core split, IAP phases, and citation infrastructure.

## Quick start

1. Clone and open in Xcode 26+ (`Murmur.xcodeproj`).
2. ⌘R to launch.
3. Click **Open Record Folder** and pick a directory containing a
   WFDB record (e.g. PhysioNet's MIT-BIH Arrhythmia Database).
4. Drop a `<recordName>.annotations.json` next to the record's `.hea`
   to overlay your cluster's findings. See the
   [schema](docs/annotation-schema.md) for the wire format.

If you don't have a WFDB record handy, click **Try a sample recording**
on the welcome screen — it synthesises a small 8-lead fixture on
demand.

## Tests

```sh
xcodebuild test -project Murmur.xcodeproj -scheme Murmur
```

~210 tests covering: WFDB parsing/decoding (single + multi-frequency),
importer end-to-end, pyramid construction, viewport clamping, grid
adaptive selection, annotation JSON round-trip, filter matching,
manifest backward compat, off-scale scanner, recents bookmark store,
per-recording annotation summary, low-rate channel partitioner,
disposition store, SwiftUI snapshot tests for overlays, the
`FindingProducer` protocol + registry, and UI performance baselines.

## Contributing

The repo is open for issues and PRs. The free viewer surface
(MurmurCore) is the contribution scope; paid extension frameworks
live in a separate private repo and are not subject to community PRs.
Contributor guidelines + triage policy will land alongside the
open-core split (see [ROADMAP Phase 0](ROADMAP.md)).

## Citing

If you use Murmur Studio in research, please cite it. See
[`docs/citation.md`](docs/citation.md) for BibTeX/RIS entries and the
tier-aware citation routing for the paid extensions.

## License

The free viewer is MIT. See [`LICENSE`](LICENSE).

The paid extension frameworks (Annotation Authoring, Silver Layer
Metrics, VT Detection) are proprietary and distributed exclusively
via the App Store. Their licenses are part of the App Store EULA;
the source is not public.
