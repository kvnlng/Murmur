---
title: Reviewing a Holter database
layout: default
nav_order: 8
---

# Reviewing a Holter database

[Reviewing a PhysioNet corpus]({{ site.baseurl }}/reviewing-a-corpus) walks
one dataset end to end: 45,152 ten-second 12-lead records, `#Key: value`
metadata, a nested `RECORDS` index. Every feature it shows is generic, but a
reader only ever sees them on that one shape of data.

This page runs the same loop on the other shape — Murmur's original one.
Half-hour two-channel records, free-text header comments, and the reference
beats already there in an `.atr` file. The section numbers match the corpus
guide so you can hold the two side by side; each section says what is
**different here** rather than repeating the other page.

The worked example is PhysioNet's
[**MIT-BIH Arrhythmia Database** v1.0.0](https://physionet.org/content/mitdb/1.0.0/)
— 48 records, 30 minutes each, 360 Hz, two channels, every beat annotated
by two cardiologists. It is the set Murmur was built against, and the
[requirements]({{ site.baseurl }}/getting-started) call it the canonical
test set.

---

## 1. Get the data

```bash
wget -r -N -c -np https://physionet.org/files/mitdb/1.0.0/
```

About **100 MB**. Licensed **ODC-By 1.0** — attribution required, as with
the corpus guide's dataset, but a different licence with its own text; cite
the database, not the licence.

What you get is one flat directory:

```
mitdb/1.0.0/
├── RECORDS        # 48 lines: 100, 101, 102, …
├── 100.hea        # header: 2 signals, 360 Hz, 650000 samples
├── 100.dat        # format 212, both channels interleaved
├── 100.atr        # reference beat annotations
└── …
```

No buckets, no per-directory indexes, no container format. Everything that
the corpus guide's §1 said about not reading meaning into the folder tree
is moot — there is no tree.

---

## 2. Check your loader

The corpus guide's §2 is about a MATLAB preamble and the `+offset` field
that skips it. **That does not apply here.** `.dat` is WFDB format **212**:
two 12-bit samples packed into three bytes, both channels interleaved, no
header, no offset.

What to verify instead is the unpack. Sample 0 of `100.dat` must decode to
**995** on MLII and **1011** on V5 — the header's checksum line says so
(`100.dat 212 200 11 1024 995 -22131 0 MLII`). A loader that unpacks the
nibbles in the wrong order still produces a plausible-looking trace; the
initial-value check is the one that catches it in a second.

Murmur's decoder has a unit test for exactly this unpack
(`decodeFormat212` in `MurmurTests`), and the getting-started page's
calibration steps work unchanged on any of these records.

---

## 3. Open the folder

**File ▸ Open Folder…** on `mitdb/1.0.0/`. `RECORDS` is flat, so the scan
reads 48 headers and is done before the progress line has anything to say.
The navigator shows **48 rows**.

That is the same scanner the corpus guide watched count to 45,152 through
452 sub-indexes. There is nothing to configure: a `RECORDS` file lists
records or directories, and the scanner follows whichever it finds.

---

## 4. Find records

There is **no `#Key: value` metadata** in these headers. A record's
comments look like this:

```
# 69 M 1085 1629 x1
# Aldomet, Inderal
```

— age, sex, the original tape and record numbers, and the medications; some
records add a sentence of free text (*"The PVCs are uniform and
late-cycle."*).

With no key–value pairs to show, a row falls back to its **first comment**,
so the navigator reads `100` over `30.1 min · 69 M 1085 1629 x1`. The X56
rule from the corpus guide's §4 has nothing to suppress, because there is
nothing structured to be constant. Both comment lines are in the context
rail's *Clinical notes* once the record is open, verbatim from the `.hea`.

Search is the **same search with less to index**: the record name plus the
raw comment text. Type `Inderal` and the navigator narrows to the patients
on a beta-blocker; `Digoxin` finds the digitalised ones; `multiform` finds
the records whose note says the PVCs are. Murmur is matching strings, not
reading a drug list — it would find `Inderal` in a comment that said
*"no Inderal"* too.

The cohort review export's `declared_placement` and `declared_placement_by`
columns (§8) are the analyst's own assertions about what a channel name
physically means here — never the producer's. An empty pair of columns is
the honest default: MIT-BIH's headers never say what `MLII` was, and Murmur
doesn't guess.

---

## 5. Look at fewer leads

Two channels is already few, so this section is mostly an observation about
how the **presets menu** behaves when a record carries almost none of the
leads the built-ins name.

On record 100 (MLII + V5) the menu reads, as observed:

| Row | Shows | State |
|---|---|---|
| `Limb` | *Limb — none in this record* | disabled |
| `Precordial` | *Precordial — 1 of 6* | enabled — stages V5 alone |
| `Bipolar limb` | *Bipolar limb — none in this record* | disabled |
| `All leads` | *All leads* | enabled |
| `Manage presets…` | | disabled until you have saved one |

Forty of the 48 records pair MLII with V1, so `Precordial — 1 of 6` is
what most of this database sees. The menu is behaving exactly as specified
— a preset is applied by lead **name**, `MLII` is not `II`, and a row says
up front how much of itself the record can satisfy — but on this data the
honesty reads as clutter: three of four built-ins are dead or near-dead,
and the one that is live stages a single lead you could have clicked.

That is awkward, and it is the real finding of this section. It is
recorded as [#351](https://github.com/kvnlng/Murmur/issues/351): the
built-ins should be seeded from what the open record carries rather than a
fixed four. This page does not work around it. Saving your own preset works
as the corpus guide describes — `MLII` alone as `Rhythm strip`, say — and
applies by name to every record here.

There is a second, more direct way to close that gap on this data: tell
Murmur what `MLII` physically *is*. Right-click the `MLII` channel and
choose **Declare placement…**, type `II`, and save it folder-wide. The
sheet writes nothing but that assertion — it does not touch the channel's
recorded name, and no calculation reads it. What changes is disclosure and
preset matching: the header line and any QT citation on that channel now
carry a `(declared: II, by <you>, <date>)` parenthetical alongside the name
`MLII`, and the presets menu on record 100 now reads `Limb — 1 of 6`
instead of *none in this record*, because `LeadPreset.resolve` matches a
preset's lead names against declared placements as well as recorded ones.
Nothing is inferred or backfilled onto records you haven't declared — this
is the analyst's own statement, attributed and dated, not a rule the app
derived from `MLII` being conventional.

The sheet also offers a **this record only** scope, for the rare record
whose wiring genuinely differs from the rest of the folder. One honest
limitation of that scope: a per-record override is keyed by the record's
path in the currently open folder or session. Save a `.mur` session,
reopen it later, and the record is re-keyed by its stored UUID — so an
override declared while folder-browsing does not travel across that
round-trip and the record quietly falls back to the folder-wide baseline
(or to nothing, if there wasn't one). The folder-wide baseline itself is
unaffected; it is only the per-record exception that doesn't survive.

---

## 6. The reference annotations are a producer

Nothing to write here. Murmur reads `100.atr` when it opens `100.hea`, and
every annotation in it becomes a point finding with **source `wfdb.atr`**
and the beat code as its **category** — `N`, `V`, `A`, `/`, and the rest of
the annotator's alphabet, verbatim.

Open record 100 and the review queue shows the annotator's beats grouped by
code. The 2,239 beats the annotator coded `N` are collapsed into one row
that says exactly that — *beats the annotator coded normal* — so the queue
opens on the 34 that are something else: 33 `A` and a single `V`. The collapsed row carries the same
provenance chip as every other group: who said normal is part of the
finding.

Now add a **second** producer. Any beat detector's output is a list of
sample positions; this turns one into the sidecar Murmur reads alongside
the `.atr`:

```python
#!/usr/bin/env python3
import json, pathlib, sys

root, detector = pathlib.Path(sys.argv[1]), sys.argv[2]

for hea in root.glob("*.hea"):
    beats = hea.with_suffix(".beats.csv")        # sample,code  — your detector's output
    if not beats.exists():
        continue
    findings = []
    for line in beats.read_text().splitlines():
        sample, code = line.split(",")
        findings.append({"kind": "point", "sampleIndex": int(sample),
                         "category": code, "source": detector})
    hea.with_suffix(".annotations.json").write_text(
        json.dumps({"schemaVersion": 1, "findings": findings}, indent=2))
```

```bash
python3 make_beats.py .../mitdb/1.0.0 my-detector-v2
```

One finding per beat, `category` = whatever code your detector emits. The
same rule as the corpus guide applies — the code goes in `category`, a
human-readable name in `label` if you have one — and the
[boundary page]({{ site.baseurl }}/what-murmur-asserts) explains why
Murmur never translates either. Both producers render in the same queue,
separately filterable by source; `wfdb.atr` is what the database said,
`my-detector-v2` is what you said.

---

## 7. Adjudicate

Same mechanics as the corpus guide's §7 — one example. Open record 100,
open the review queue, turn on editing, and find the one beat the annotator
coded `V`. **Confirm as…** `A`. The row now reads `V → A`, the disposition
goes to `dispositions.json` in the record's bundle, and the `.atr` on disk
is untouched.

The difference from the corpus guide is scale, not kind: a ten-second
record carries a handful of whole-record labels, a Holter record carries
two thousand beats. Adjudicate the groups the queue surfaces, not the
normals.

---

## 8. Export

**Export ▸ Export review table…** writes one row per annotation across
every record the navigator is showing. Here that is 48 records × roughly
2,300 beats each — 109,494 beats and 3,153 rhythm and noise events in the
`.atr` files — so **about 112,000 rows**, almost all of them
`source = wfdb.atr`, `state = unreviewed`.

That is correct, not excessive. The `.atr` rows are the **denominator** —
the reference beats you could have disagreed with and did not — and your
detector's rows join against them on `start_sample`. A review table of only
the beats you touched would have no way to say how many you looked at.

---

## 9. Figures and citation

**Export ▸ Export snapshot…** for figures, as in the corpus guide's §9.
If Murmur was part of a result, [cite it]({{ site.baseurl }}/citation) and
cite the database separately under its own licence.

---

## What changed between the two guides

Nothing in the app. The scanner, the navigator's search, the presets menu,
the producer contract, the queue, and the export all ran unchanged on data
of a different shape, and where the fit was poor (§5) the page says so and
an issue carries it. That is the test this page exists to run.
