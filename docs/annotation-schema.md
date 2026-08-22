---
title: Annotation JSON schema
layout: default
nav_order: 4
---

# Annotation JSON schema

This page describes the wire format your analysis cluster emits so
Murmur Studio can render its findings. The viewer reads
`<recordName>.annotations.json` next to the WFDB `.hea` and resolves
every finding to a sample index at import time.

Your file is authoritative: the viewer renders what you send, never
re-derives it, and never rewrites it. You own your categories, your
display names, your confidence calibration, and your provenance — see
[What Murmur asserts]({{ site.baseurl }}/what-murmur-asserts) for the
boundary that guarantees it, and for where clinical vocabulary decoding
belongs.

**Machine-readable schema:**
[**annotations.schema.json**]({{ site.baseurl }}/annotations.schema.json) —
a JSON Schema (Draft 2020-12) document. Run your producer's output
through any standard JSON Schema validator (see
[Validating your producer output](#validating-your-producer-output)
below).

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
      "confidence": 0.92
    },
    {
      "kind": "range",
      "startSample": 50000,
      "endSample":   65000,
      "category": "VF_onset",
      "note": "Onset preceded by R-on-T",
      "lead": "II",
      "evidenceContextSeconds": 8.0
    },
    {
      "kind": "point",
      "startUnixMS": 1717854312500,
      "category": "AFib",
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

## Categories

The renderer's color map is hand-tuned for common clinical categories
(see `CategoryPalette.swift`). Unknown categories get a deterministic
FNV-1a hash → HSV color so the same producer-side category keeps the
same color across runs.

Hand-tuned categories include: `N`, `L`, `R`, `V`, `PVC`, `VT`, `VF`,
`VF_onset`, `F`, `E`, `A`, `APC`, `AFib`, `S`, `J`, `/` (paced), `Noise`,
`NoiseGap`, `Q`, `?`, `~`.

## Validating your producer output

Before shipping a file to a clinician, validate it locally against the
published [JSON Schema]({{ site.baseurl }}/annotations.schema.json).
This catches missing-field, wrong-type, and out-of-enum bugs in your
analysis pipeline before they surface in the viewer.

Pick whichever validator fits your stack:

### Python

```python
import json, urllib.request
import jsonschema  # pip install jsonschema

schema = json.loads(urllib.request.urlopen(
    "https://kvnlng.github.io/Murmur/annotations.schema.json"
).read())

with open("100.annotations.json") as f:
    instance = json.load(f)

jsonschema.validate(instance=instance, schema=schema)
print("valid")
```

### Node / JavaScript

```sh
npm install -g ajv-cli
curl -O https://kvnlng.github.io/Murmur/annotations.schema.json
ajv validate -s annotations.schema.json -d 100.annotations.json --spec=draft2020
```

### Swift (if your producer is on Apple platforms)

Inside Murmur Studio the canonical decoder is
`AnnotationLoader.parse(data:recordingStartUnixMS:sampleRate:)` —
behaviorally equivalent to schema validation plus timestamp
resolution. The producer side can use any standard JSON Schema
package (e.g. [Vapor's JSONSchema](https://github.com/vapor/vapor-extras),
or just write a `Codable` mirror of the file shape and let
`JSONDecoder` reject malformed input).

### Common validation failures

| Error | Fix |
|---|---|
| `'startSample' is a required property` (or `startUnixMS`) | Every finding needs at least one of `startSample` or `startUnixMS`. The schema enforces this via `anyOf`. |
| `confidence: should be ≤ 1` | Send a fraction, not a percentage. |
| `schemaVersion: should be equal to 1` | Pin to `1`. The viewer rejects unknown versions. |
| Extra fields present | The schema sets `additionalProperties: false` to catch typos. If you have legitimate analysis metadata you want to ship, put it in `note` (free-form string) for now. |

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
      "confirmedCategory": "VT",
      "note": "Sustained run, ~160 BPM",
      "reviewedAt": "2026-06-18T17:21:33Z",
      "reviewedBy": "kevin"
    },
    {
      "annotationID": "9E3C1B02-…",
      "state": "confirmed",
      "confirmedCategory": "AFlutter",
      "reviewedAt": "2026-06-18T17:21:58Z",
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
| `confirmedKind` | no | `"vt"` \| `"vf"` \| `"unclassified"` | Only meaningful when `state == "confirmed"`. `null` is acceptable when the analyst can't tell. A closed enum from the arrhythmia scan — see `confirmedCategory` for everything else. |
| `confirmedCategory` | no | string | What the analyst says the finding **is**. Only meaningful when `state == "confirmed"`. Equal to the annotation's own `category` when they agreed with your label; different when they overrode it. |
| `note` | no | string | Free-form analyst-readable text. Empty / whitespace-only notes get normalized to `null`. |
| `reviewedAt` | yes | ISO-8601 string | Wall-clock time when the disposition was last changed. |
| `reviewedBy` | no | string | Default = macOS user name. Free-form. |

### Agreeing, and disagreeing

`confirmedCategory` is the field that makes a review worth reading back.
Without it, "confirmed" means only that a human looked; with it, a confirmed
row states a claim in the analyst's own voice, and comparing it to the
annotation's `category` tells you in one operation whether they agreed with
you.

It is **free-form on purpose**. The vocabulary belongs to whoever produced the
annotations — `AFib`, `PVC`, a SNOMED code, your own internal token — so
Murmur does not constrain it to any list it invented, and never derives
`confirmedKind` from it. For the reasoning, see
[What Murmur Asserts]({{ site.baseurl }}/what-murmur-asserts).

Consumers should treat the three fields in precedence order — `note`, then
`confirmedCategory`, then `confirmedKind` — which is the order Murmur's own
WFDB annotator export uses when it has to pick one string.

### Lifecycle

- Reading: the viewer loads the sidecar at recording open and uses
  absence-of-record to mean "unreviewed."
- Writing: every mutation rewrites the whole file (it's small).
- Stale records (`annotationID` no longer in the producer file) survive
  intact — useful if a producer drops and reintroduces a finding.

The `DispositionStoreTests` suite covers round-trip persistence,
state transitions, tally counts, and whitespace-note normalization.

## Review table export

Every other export is scoped to one record. The **review table** is the other
direction: one CSV row per annotation across *every* record in the open folder
or session, carrying the analyst's disposition — the file you feed back to
whatever produced the annotations.

Export ▸ **Export review table…** writes `<folder-or-session>-review.csv`.

**Unreviewed rows are included.** This is a review table, not the amber-only
[WFDB annotation export](#analyst-dispositions): the consumer needs the
denominator, because what was looked at and left alone is as much a result as
what was confirmed.

Records you never opened have no imported bundle, so they contribute no rows.
They are counted, and the completion message names them — an export never
quietly covers less than the cohort.

### Columns

| Column | Meaning |
|---|---|
| `record` | The recording's device / record name. |
| `record_path` | Navigator id — the `.hea` path relative to the opened folder. |
| `annotation_id` | `Annotation.id`; joins back to your producer file. |
| `kind` | `point` or `range`. |
| `start_sample` / `end_sample` | Sample indices. `end_sample` is empty for points. |
| `start_seconds` / `end_seconds` | The same positions in seconds, at the record's own rate, to 3 dp. |
| `lead` | Channel label the finding applies to, if any. |
| `category` | The producer's semantic category, verbatim. |
| `label` | The producer's display token, if it sent one. |
| `source` | Producer id. |
| `confidence` | 0…1 as the producer sent it, to 4 dp. Empty when absent. |
| `state` | `unreviewed`, `confirmed`, or `dismissed`. |
| `confirmed_kind` | `vt` / `vf` / `unclassified`, when the analyst set one. |
| `confirmed_category` | What the analyst says the finding is. Compare with `category` to find the rows where they overrode your label. |
| `note` | The analyst's free-form note. |
| `reviewed_by` / `reviewed_at` | Who reviewed it and when (ISO 8601, UTC). |
| `flagged` | Whether the record is flagged for the session. |
| `header_comments` | The record's `.hea` comment lines, joined with ` \| `. |

UTF-8, no BOM, `\n` line endings, RFC 4180 quoting. Rows sort by record path,
then start sample, then annotation id, so the same review exports
byte-identically every time. The header row is always present, even when the
table is empty.
