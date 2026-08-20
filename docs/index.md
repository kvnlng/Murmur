---
title: Home
layout: default
nav_order: 1
---

# Murmur Studio

A native-Mac scope for physiologic recordings — a microscope and a
telescope for ECG waveform data. **Available on the Mac App Store.**

Open a PhysioNet/WFDB recording and range from the whole record down to
a single heartbeat on calibrated ECG paper. The free viewer renders the
signal with its annotation layers and a confirm/dismiss review workflow;
a single **Murmur Pro** purchase unlocks the analysis instruments — beat
calipers, whole-record trend lanes, variability metrics, a ranked
arrhythmia review queue, and morphology clustering.

## Get the app

Install Murmur Studio from the Mac App Store:
**[Murmur Studio on the App Store](https://apps.apple.com/us/app/murmur-studio/id6782092325)**

Requires macOS 14 (Sonoma) or later. No Xcode or developer tools needed
— this is the documentation site for users of the app, not a build guide.

## What's here

- **[Getting started]({{ site.baseurl }}/getting-started)** — open a
  record, read the bedside view, review findings, and what Murmur Pro
  adds.
- **[Citing Murmur Studio]({{ site.baseurl }}/citation)** — DOI-stable
  citation for published work, straight from the in-app Copy citation
  action.
- **[Architecture]({{ site.baseurl }}/architecture)** — the three-layer
  Data Engine / Waveform Canvas / Control Overlay split and the key
  invariants.
- **[Annotation JSON schema]({{ site.baseurl }}/annotation-schema)** —
  the wire format external producers can emit as
  `<recordName>.annotations.json`.
- **[Performance notes]({{ site.baseurl }}/performance)** — how the
  pyramid + LOD selector + zero-copy GPU buffers keep pan/zoom smooth on
  multi-hour records.

## At a glance

![Murmur Studio — record sidebar on the left, calibrated ECG paper canvas in the middle with annotator badges and the variability metrics strip above, and the ranked arrhythmia review queue on the right.]({{ site.baseurl }}/assets/bedside-overview.png)

Three columns: the record sidebar on the left, the bedside stage in the
middle (variability metrics, whole-record overview and hour bands, and
calibrated ECG paper with the record's annotation layer), and the review
queue on the right with ranked VT/VF candidate episodes and rhythm-event
candidates. Drag the chart to pan; pinch to zoom; click the overview to
scrub. Every surface shares one viewport, so nothing ever falls out of
time-lock.

## For research

Murmur Studio is a tool for research and analysis of physiologic
recordings. It is not a medical device and is not intended for diagnosis
or clinical decision-making.
