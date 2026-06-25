---
title: Getting started
layout: default
nav_order: 2
---

# Getting started

## Requirements

- macOS 14 (Sonoma) or later
- A folder containing a WFDB record (`.hea` + `.dat`) you want to view —
  PhysioNet's [MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/)
  is the canonical test set.

## Install

Murmur Studio is distributed through the Mac App Store. Install it via
[the App Store listing](https://www.apple.com/search/Murmur-Studio?src=globalnav)
<!-- TODO: replace with the canonical product URL once known -->
and launch it from Applications or Spotlight. The welcome screen offers
four entry points.

## Loading a record

The welcome screen on first launch gives you four ways in:

- **Open Record Folder** opens the system file picker.
- **Try a sample recording** generates a small 8-lead 10 s WFDB fixture
  on the fly — useful for kicking the tires before downloading real data.
- **Recent** — folders you've opened before are listed under the card
  and reopen with one click. Sandbox-safe: each row stores a
  security-scoped bookmark, not a raw path.
- **Drag a folder onto the window** — drop either the record folder
  itself, or any file inside it, and the app opens the enclosing folder.

Once a folder is open:

1. The left sidebar lists every record found — record name, signal count,
   sample rate, and duration.
2. Click a record to import. The first import on a record runs the WFDB
   decoder + min/max pyramid + manifest writer. Subsequent visits load
   instantly from the cache.

The app is sandboxed (`ENABLE_APP_SANDBOX = YES`), so the file picker
deliberately asks for a *folder* rather than a single file — that way the
security scope covers both the `.hea` and its sibling `.dat`.

## Reading the bedside view

Above the canvas, two recording-level surfaces answer "what's in here?"
before you ever scrub:

- **Summary chip row** — one chip per category in the recording (e.g.
  `PVC 47 (12 critical)`, `AFib 38s`). Click a chip to toggle the filter
  for that category — same effect as clicking the chip in the findings
  panel.
- **Finding density timeline** — one thin lane per surviving category
  spanning the full recording. Points show as ticks, ranges as bars
  proportional to their duration. Click anywhere on a lane to jump the
  viewport to that fraction of the recording.

If the record carries low-rate signals — Murmur treats anything below
5 Hz as a "trend" channel: HR, SpO₂, etCO₂, tidal volume, GMM state
probabilities, alarm flags, and so on — they render in their own strips
below the ECG canvas, time-locked to the same viewport:

- **Vitals sparkline strip.** Continuous-valued trend channels (HR, SpO₂,
  etCO₂, tidal volume) appear as small line plots with a side label
  showing the value at the middle of the visible window.
- **Alarm strip.** Boolean alarm / status channels — anything whose name
  ends in `_alarm`, `_status`, or `_silenced` — get one lane each.
  Active runs render as colored bars; click any bar to jump the viewport
  to that minute.
- **State backdrop.** When both `prob_state_spontaneous` and
  `prob_state_assist_control` are present, a one-row colored band shows
  the dominant ventilation state per minute (warm = spontaneous breath,
  cool = assist-control), with opacity tied to certainty.
- **Quality strip.** Channels whose name ends in `_ratio` or contains
  `artifact_ratio` (the Medallion `ecg_artifact_ratio` is the canonical
  case) render as a gray heat band — opacity proportional to the ratio,
  with an orange outline on cells past the 0.1 threshold so problematic
  minutes are scannable at a glance.

WFDB multi-frequency records (per-signal `.dat` files with `format[xspf]`
suffixes on each signal line) feed straight in via the existing folder
picker; no separate ingest step.

Each ECG channel renders as a stacked panel:

| Element | Purpose |
|---|---|
| Header strip | Lead name, unit, current time window, sample rate, off-scale count |
| Main canvas | Metal-rendered ECG paper with the trace |
| Time-axis labels | Major-gridline-aligned, adaptive density |
| Voltage-axis labels | Left edge, mV grid |
| Overview ribbon | Whole-recording envelope + viewport indicator |
| Scale strip | Recording extent and current window in human time |

## Navigation

| Gesture | Action |
|---|---|
| Drag chart left/right | Pan all channels in time-lock |
| Pinch | Zoom around the center |
| Click overview ribbon | Jump to that fraction of the recording |
| Drag overview ribbon | Scrub continuously |
| Click a finding in the panel | Center the viewport on the finding |

## Loading findings

Drop a JSON file named `<recordName>.annotations.json` next to the
record's `.hea` and re-import the record. The cluster's findings appear
as:

- Translucent colored fills on the canvas for `range` findings
- Thin colored rules at the sample index for `point` findings
- A row in the right-side findings panel for every finding

Categories drive color (red = ventricular, purple = atrial, blue =
conduction, slate = noise). Severity drives alpha.

See the [annotation schema]({{ site.baseurl }}/annotation-schema) for
the wire format.

## Reviewing and triaging findings

Unlock editing from the toolbar lock icon, then each row in the findings
panel exposes three inline buttons:

- **Confirm** (✓) — opens a menu so you can record the finding as VT,
  VF, or "confirmed (unsure)." Confirmed rows pick up a green border, a
  ✓ marker, and an outline on their tick in the density timeline.
- **Dismiss** (✗) — marks the finding as a false positive. Dismissed
  rows strikethrough and dim to ~55% opacity; their density-timeline
  tick drops to ~30% alpha.
- **Reset** (↶) — clears the disposition back to unreviewed.

Tally chips at the top of the findings panel and inside the summary
chip row above the canvas show your progress at a glance — confirmed,
dismissed, and unreviewed counts. Dispositions persist to
`dispositions.json` inside the imported bundle, so re-running the
upstream producer (which regenerates `<recordName>.annotations.json`)
never overwrites your work.
