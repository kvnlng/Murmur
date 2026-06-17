---
title: Home
layout: default
nav_order: 1
---

# Plotting

A macOS SwiftUI app for analyst review of clinical ECG findings over
PhysioNet WFDB recordings.

Findings come from an upstream cluster of analysis machines (VF/VT onset,
AFib, PVCs, disease vectors). The WFDB trace is the *context* an analyst
needs to interpret each finding — Plotting renders it as a Metal-backed
ECG paper canvas with the cluster's findings overlaid.

## What's here

- **[Getting started]({{ site.baseurl }}/getting-started)** — open a
  record, jump to a finding, scrub the timeline.
- **[Architecture]({{ site.baseurl }}/architecture)** — the three-layer
  Data Engine / Waveform Canvas / Control Overlay split and the key
  invariants.
- **[Annotation JSON schema]({{ site.baseurl }}/annotation-schema)** —
  what the producer cluster emits as `<recordName>.annotations.json`.
- **[Performance notes]({{ site.baseurl }}/performance)** — how the
  pyramid + LOD selector + zero-copy GPU buffers keep pan/zoom smooth on
  multi-hour records.
- **[Roadmap](https://github.com/kvnlng/Plotting/blob/main/ROADMAP.md)**
  — current state and what's next.

## At a glance

```
┌─────────────┬──────────────────────────────────────┬────────────────┐
│  Records    │  Bedside view (Metal canvas)         │  Findings      │
│             │                                      │                │
│  100.hea  ✓ │   ░░░░░░ pink ECG paper ░░░░░░░     │  PVC  18s ▸    │
│  101.hea    │   ─╱╲──╱╲──╱╲──╱╲──╱╲──╱╲──╱─       │  VT   1:24 ▸   │
│  102.hea    │   ▲                                  │  AFib 2:10 ▸   │
│             │                                      │                │
│             │  ▭ overview ribbon ▭ ▭ ▭ ▭ ▭ ▭      │  filters: …    │
└─────────────┴──────────────────────────────────────┴────────────────┘
```

Drag the chart to pan; pinch to zoom; click the ribbon to scrub. All
channels in a record share the viewport so leads stay time-locked.

## Source

Hosted at **[github.com/kvnlng/Plotting](https://github.com/kvnlng/Plotting)**.
