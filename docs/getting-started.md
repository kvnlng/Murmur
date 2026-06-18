---
title: Getting started
layout: default
nav_order: 2
---

# Getting started

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later
- A folder containing a WFDB record (`.hea` + `.dat`) you want to view —
  PhysioNet's [MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/)
  is the canonical test set.

## Build and run

```sh
git clone https://github.com/kvnlng/Plotting.git
cd Plotting
open Plotting.xcodeproj
```

Press ⌘R. The welcome screen offers four entry points.

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

Each channel renders as a stacked panel:

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
