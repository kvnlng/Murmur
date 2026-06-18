---
title: Annotation JSON schema
layout: default
nav_order: 4
---

# Annotation JSON schema

This page describes the wire format your analysis cluster emits so
Plotting can render its findings. The viewer reads
`<recordName>.annotations.json` next to the WFDB `.hea` and resolves
every finding to a sample index at import time.

## File location

```
some-record-folder/
├─ 100.hea
├─ 100.dat
├─ 100.annotations.json   ← producer findings (this file)
├─ 100.notes.md           ← optional analyst-editable Markdown notes
└─ 100.atr                ← optional legacy WFDB beat marks
```

Both an `.atr` and a JSON file can coexist for the same record. Their
annotations are concatenated; the JSON ones are tagged with the
producer-supplied `source`, the `.atr` ones get `source = "wfdb.atr"`.

A separate **disposition sidecar** lives inside the imported bundle
(not in the producer's folder) — see [Analyst dispositions](#analyst-dispositions)
below.

## Format

```json
{
  "schemaVersion": 1,
  "source": "vf-onset-detector-v2",
  "findings": [
    {
      "kind": "point",
      "startSample": 12345,
      "category": "PVC",
      "confidence": 0.92,
      "severity": "warning"
    },
    {
      "kind": "range",
      "startSample": 50000,
      "endSample":   65000,
      "category": "VF_onset",
      "severity": "critical",
      "note": "Onset preceded by R-on-T",
      "lead": "II",
      "evidenceContextSeconds": 8.0
    },
    {
      "kind": "point",
      "startUnixMS": 1717854312500,
      "category": "AFib",
      "severity": "notice",
      "source": "rhythm-classifier-v1"
    }
  ]
}
```

## Top-level fields

| Field | Required | Type | Meaning |
|---|---|---|---|
| `schemaVersion` | yes | int | Currently `1`. |
| `source` | no | string | Default `source` for findings without their own. |
| `findings` | yes | array | The findings list. |

## Finding fields

| Field | Required | Type | Meaning |
|---|---|---|---|
| `kind` | yes | `"point"` \| `"range"` | Geometry. |
| `startSample` | one of | int64 | Sample index of the event (or start of a range). |
| `endSample` | for range | int64 | End sample, exclusive. |
| `startUnixMS` | one of | int64 | UTC milliseconds since epoch. |
| `endUnixMS` | for range | int64 | End time. |
| `category` | yes | string | Semantic finding category. Drives color. |
| `label` | no | string | Display token. Falls back to `category`. |
| `confidence` | no | float | 0…1. |
| `severity` | no | string | `info` \| `notice` \| `warning` \| `critical`. Defaults to `info`. |
| `source` | no | string | Producer ID. Defaults to file-level `source`. |
| `note` | no | string | Free-form analyst-readable text. |
| `lead` | no | string | Channel/lead label the finding applies to. |
| `evidenceContextSeconds` | no | float | Hint to the viewer for jump-into context. |
| `id` | no | uuid string | Stable id. The viewer mints one if absent. |

## Timestamp rules

Each finding needs *at least one* of `startSample` or `startUnixMS`. For
ranges, supply matching `endSample` / `endUnixMS`.

**Sample-index wins** when both forms are present (no precision loss).

`startUnixMS` is resolved at import using the channel's `startTimeUnixMS`
and `sampleRate`. Useful when the cluster works in absolute time and
doesn't know the WFDB record's sample alignment yet.

## Severity → render alpha

The renderer modulates each bucket's alpha by the *max* severity of its
findings:

| Severity | Multiplier |
|---|---|
| info | 0.85× |
| notice | 1.00× |
| warning | 1.15× |
| critical | 1.30× |

Combined with the base alpha for the kind (0.85 for point rules, 0.22
for range fills) this gives critical findings noticeably more visual
weight without changing color.

## Categories

The renderer's color map is hand-tuned for common clinical categories
(see `CategoryPalette.swift`). Unknown categories get a deterministic
FNV-1a hash → HSV color so the same producer-side category keeps the
same color across runs.

Hand-tuned categories include: `N`, `L`, `R`, `V`, `PVC`, `VT`, `VF`,
`VF_onset`, `F`, `E`, `A`, `APC`, `AFib`, `S`, `J`, `/` (paced), `Noise`,
`NoiseGap`, `Q`, `?`, `~`.

## Validation

```sh
xcodebuild test -project Plotting.xcodeproj -scheme Plotting \
  -only-testing:PlottingTests/AnnotationLoaderTests
```

The `AnnotationLoaderTests` suite covers schema round-trip with both
timestamp forms, sample-index precedence, missing-timestamp errors, and
unsupported schema versions.

## Analyst dispositions

Analyst review state (confirm / dismiss / reset) is stored *inside the
imported bundle*, not in the producer's source folder, so re-running
the producer never overwrites the analyst's work. The file is
`<bundle>/dispositions.json`.

### Format

```json
{
  "schemaVersion": 1,
  "dispositions": [
    {
      "annotationID": "B8A4E2C8-…",
      "state": "confirmed",
      "confirmedKind": "vt",
      "note": "Sustained run, ~160 BPM",
      "reviewedAt": "2026-06-18T17:21:33Z",
      "reviewedBy": "kevin"
    },
    {
      "annotationID": "1D7F4A9C-…",
      "state": "dismissed",
      "note": "Clear motion artifact, not VF",
      "reviewedAt": "2026-06-18T17:22:01Z",
      "reviewedBy": "kevin"
    }
  ]
}
```

### Fields

| Field | Required | Type | Meaning |
|---|---|---|---|
| `annotationID` | yes | uuid string | Must match the corresponding `Annotation.id` from the producer file. |
| `state` | yes | `"confirmed"` \| `"dismissed"` | Three-way conceptually — *unreviewed* is the absence of a record. |
| `confirmedKind` | no | `"vt"` \| `"vf"` \| `"unclassified"` | Only meaningful when `state == "confirmed"`. `null` is acceptable when the analyst can't tell. |
| `note` | no | string | Free-form analyst-readable text. Empty / whitespace-only notes get normalized to `null`. |
| `reviewedAt` | yes | ISO-8601 string | Wall-clock time when the disposition was last changed. |
| `reviewedBy` | no | string | Default = macOS user name. Free-form. |

### Lifecycle

- Reading: the viewer loads the sidecar at recording open and uses
  absence-of-record to mean "unreviewed."
- Writing: every mutation rewrites the whole file (it's small).
- Stale records (`annotationID` no longer in the producer file) survive
  intact — useful if a producer drops and reintroduces a finding.

The `DispositionStoreTests` suite covers round-trip persistence,
state transitions, tally counts, and whitespace-note normalization.
