---
title: Getting started
layout: default
nav_order: 2
---

# Getting started

## Requirements

- macOS 26.5 or later
- A folder containing a WFDB record (`.hea` + `.dat`) you want to view —
  PhysioNet's [MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/)
  is the canonical test set.

## Install

Murmur Studio is distributed through the Mac App Store. Install it via
[the App Store listing](https://apps.apple.com/us/app/murmur-studio/id6782092325)
and launch it from Applications or Spotlight.

## Loading a record

On launch the window shows the full bedside shell in its idle state —
every surface present, waiting for a record. Two ways in, both in the
File menu:

- **File ▸ Open Record… (⌘O)** opens the system file picker. The same
  action is inline in the empty window ("Open Record Folder…") and in
  the toolbar's `⋯` menu.
- **File ▸ Open Recent** — folders you've opened before reopen with one
  click. Sandbox-safe: each entry stores a security-scoped bookmark,
  not a raw path.

Once a folder is open:

1. The left sidebar lists every record found — record name, signal count,
   sample rate, and duration.
2. Click a record to import. The first import on a record runs the WFDB
   decoder + min/max pyramid + manifest writer. Subsequent visits load
   instantly from the cache.

The app is sandboxed, so the file picker deliberately asks for a
*folder* rather than a single file — that way the security scope covers
the `.hea`, its sibling `.dat`, and any annotation files. WFDB
multi-frequency records (per-signal `.dat` files with `format[xspf]`
suffixes) feed straight in; no separate ingest step.

## Reading the bedside view

The stage reads top to bottom in the order you navigate: whole record →
hour → window.

- **Variability metrics strip** *(Murmur Pro)* — time- and
  frequency-domain HRV and QT variability for the whole record, the
  current window, or the hour, with a scope picker. Every number states
  its provenance.
- **Overview and hour bands** — the full recording's envelope with the
  viewport marked, and a 60-minute band beneath it. Click either to
  jump; drag to scrub.
- **The paper** — a Metal-rendered ECG grid with the trace and its
  annotation layers. **Standard View** pins the clinical calibration
  (25 mm/s · 10 mm/mV); gain and speed presets (5/10/20 mm/mV,
  25/50 mm/s) are one click away, and the seam beneath them always
  discloses the *actual* on-screen scale. A lock holds calibration
  across zoom gestures so paging a long record can't drift the paper.
- **The docked inspector** — the calibration readout and the beat card.
  Hover the trace to focus a beat; click to pin it. With Murmur Pro the
  card reads per-beat PR, QRS, QT, and QTc (selectable correction
  formula) against the patient's own normal template, with calibrated
  uncertainty stated on every QT.
- **Lead chips** — one chip per lead above the stage. Click to focus a
  lead; ⌘-click to overlay it on the primary for comparison. Overlaid
  reads carry a "Measured on …" attribution so a number is never
  ambiguous about its source lead.

If the record carries low-rate trend channels — anything below 5 Hz:
HR, SpO₂, etCO₂, tidal volume, state probabilities, alarm flags — they
render in their own strips below the ECG canvas, time-locked to the same
viewport: vitals sparklines, one lane per boolean alarm channel, a
ventilation-state backdrop, and a signal-quality heat band.

With Murmur Pro, the **trend stack** below the stage adds computed
whole-record lanes — beat-derived heart rate, RMSSD, LF/HF, and the QTc
interval trend — on one shared time axis. Click a lane to move the trace
to that moment. Lanes toggle from **View ▸ Trend Lanes**.

The **context drawer** under the stage carries the record's documents:
comments from the `.hea` header, your anchored notes, and (with Murmur
Pro) the morphology section — whole-record beat clustering with
representative shapes, where the algorithm clusters and the analyst
classifies.

## Navigation

| Gesture | Action |
|---|---|
| Drag chart left/right | Pan all channels in time-lock |
| Pinch / ⌘-scroll | Zoom around the center |
| Zoom presets (24 h … 2 s) | Set the window width directly |
| Click overview or hour band | Jump to that point |
| `J` / `K` | Next / previous finding |
| `←` `→` | Pan one window |
| Click a finding or queue row | Center the viewport on it |

## Findings and annotation layers

Findings reach the canvas three ways:

- **The record's own annotator layer** (e.g. a WFDB `.atr` file) renders
  automatically — beat badges on the trace, categories in the review
  queue.
- **The in-app arrhythmia scan** *(Murmur Pro)* proposes ranked VT/VF
  candidate episodes and rhythm-event candidates (AF, pauses), each with
  its score, span, and model provenance.
- **External producers** can drop a JSON file named
  `<recordName>.annotations.json` next to the record's `.hea` — see the
  [annotation schema]({{ site.baseurl }}/annotation-schema) for the wire
  format. Range findings render as translucent fills, point findings as
  thin rules at the sample index.

## Reviewing and triaging

The **review queue** (toolbar toggle, or **View ▸ Show Review Queue**)
lists every finding and candidate, grouped and filterable by category
and confidence. Unlock editing from the toolbar lock icon, then each
row exposes the disposition controls:

- **Confirm** (✓) — record the finding as VT, VF, or "confirmed
  (unsure)."
- **Dismiss** (✗) — mark it a false positive.
- **Reset** (↶) — clear the disposition back to unreviewed.

Tally chips track confirmed / dismissed / to-review counts. Dispositions
persist inside the imported bundle, so re-running an upstream producer
never overwrites your review. Notes, endorsements, and authored findings
*(Murmur Pro)* save into a portable session document (⌘S), and confirmed
findings can be exported as WFDB annotations or a citable report from
the Export menu.

## Murmur Pro

One in-app purchase (Settings ▸ Purchases) unlocks every instrument
above marked *(Murmur Pro)*, current and future: beat calipers,
variability metrics, computed trend lanes, the arrhythmia scan,
morphology clustering, and annotation authoring. The viewer — import,
calibrated paper, annotation layers, review dispositions, exports —
stays free.
