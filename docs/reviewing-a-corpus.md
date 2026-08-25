---
title: Reviewing a PhysioNet corpus
layout: default
nav_order: 7
---

# Reviewing a PhysioNet corpus

This guide walks one large public dataset end to end: open it, find records
by what their headers say, look at fewer leads, bring a model's predictions
in as a producer, adjudicate them, and export the result.

The worked example is PhysioNet's
[**A large scale 12-lead electrocardiogram database for arrhythmia study**
v1.0.0](https://physionet.org/content/ecg-arrhythmia/1.0.0/) — 45,152
ten-second 12-lead records with SNOMED CT codes in their header comments.
It is used because it exercises every step below, not because Murmur knows
anything about it. Every capability here is generic; there is no
dataset-specific code in the app.

The guide describes what Murmur does with a corpus. The science is yours.

---

## 1. Get the data

```bash
wget -r -N -c -np https://physionet.org/files/ecg-arrhythmia/1.0.0/
```

About **5.3 GB** on disk. Licensed **CC BY 4.0** — you may redistribute and
build on it with attribution; cite the dataset in anything you publish.

What you get:

```
ecg-arrhythmia/1.0.0/
├── RECORDS                        # index: 452 leaf directories
├── ConditionNames_SNOMED-CT.csv   # acronym → name → SNOMED code
└── WFDBRecords/
    └── 01/010/                    # buckets of 100 records
        ├── RECORDS                # index: the record names in this bucket
        ├── JS00001.hea            # WFDB header
        └── JS00001.mat            # MATLAB v4 container, format `16+24`
```

Every record is the same shape: 12 signals, 500 Hz, 5,000 samples — ten
seconds.

**The folder tree carries no meaning.** `01/010/` is not a diagnosis, a
patient, a site, or a collection date. The buckets exist so no directory
holds 45,000 entries. Do not read structure into the path, and do not
reorganise the tree hoping to gain any: everything that distinguishes one
record from another is inside its `.hea`, which is what makes step 4 work.

---

## 2. Check your loader against a calibrated viewer

Before you trust *any* pipeline on a new corpus — Murmur's or your own —
open one record in a viewer you trust and compare it against the dataset's
own preview. Start with
[`WFDBRecords/01/010/JS00001`](https://physionet.org/content/ecg-arrhythmia/1.0.0/WFDBRecords/01/010/#files-panel).

This corpus is worth the check because its signal files are not raw WFDB
`.dat`. They are **MATLAB Level 4** containers, and the header says so:

```
JS00001.mat 16+24 1000/mV 16 0 -254 21756 0 I
```

`16+24` is format 16 with a **24-byte offset** — the MAT-file header that
sits in front of the samples. A reader that ignores the `+24` starts
decoding inside that header. The damage is specific and recognisable:

- a spike at *t* = 0 on every lead, often several mV, because the MAT
  header's bytes get read as samples;
- every sample shifted by 2 ms at 500 Hz;
- the last frame of the record dropped.

None of that looks like a crash. It looks like a recording with an artifact
at the start, which is exactly why it survives into published results. If
you are writing your own loader, this is the first thing to check, and the
`.hea`'s own `firstval` field (`-254` above, for lead I) is a free
cross-check: decode sample 0 and see whether it matches.

Murmur reads the offset ([#327](https://github.com/kvnlng/Murmur/issues/327)).

---

## 3. Open the corpus

**File ▸ Open Record… (⌘O)** and pick the **dataset root** —
`.../ecg-arrhythmia/1.0.0/`, not a leaf folder.

Murmur follows the `RECORDS` index down the tree and lists the whole corpus
in the navigator, each row identified by its path relative to the folder you
picked. A scan of this size takes a few seconds and reports its progress in
the window; a folder with no `RECORDS` index is scanned flat, exactly as a
MIT-BIH directory always was.

You will see **45,150 records, and a note that 2 index entries had no
readable `.hea`** — naming them. That is not a Murmur limitation, it is the
corpus: `WFDBRecords/01/019/JS01052` and `WFDBRecords/23/236/JS23074` ship
with their record line and their first signal line merged by a lost
newline, so each declares 12 signals and carries 11. Murmur will not
reconstruct a record from a file that does not state it. It skips those two,
names them, and opens the rest.

Import is **lazy and per record**: opening the corpus reads 45,150 headers,
not 45,150 signal files. A record is decoded the first time you click it and
cached after that.

---

## 4. Find records by what their headers say

This dataset puts its metadata in `.hea` comment lines:

```
#Age: 85
#Sex: Male
#Dx: 164889003,59118001,164934002
#Rx: Unknown
#Hx: Unknown
#Sx: Unknown
```

Murmur parses `#Key: value` comments into the navigator row and into its
search index, so the navigator's search field matches record names, every
metadata key and value, and every raw comment line, case-insensitively
([#328](https://github.com/kvnlng/Murmur/issues/328)).

That makes the corpus navigable by label:

| Type this | To get |
|---|---|
| `164889003` | records labelled atrial fibrillation |
| `Sex: Female` | records from female patients |
| `Age: 8` | ages 8, 80–89 — it is a substring match, not a range query |

### The codes

The ten most common `#Dx` codes, counted across all 45,152 records:

| Count | Code | SNOMED CT term | This dataset's CSV calls it |
|---:|---|---|---|
| 16,559 | `426177001` | ECG: sinus bradycardia | Sinus Bradycardia |
| 8,125 | `426783006` | ECG: sinus rhythm | Sinus Rhythm |
| 8,060 | `164890007` | EKG: atrial **flutter** | Atrial Flutter |
| 7,255 | `427084000` | ECG: sinus tachycardia | Sinus Tachycardia |
| 7,043 | `164934002` | EKG: T wave abnormal | T wave Change |
| 5,401 | `55827005` | Left ventricular hypertrophy | *(no entry)* |
| 4,232 | `55930002` | EKG ST segment changes | *(no entry)* |
| 2,877 | `59931005` | Inverted T wave | T wave opposite |
| 2,550 | `427393009` | ECG: sinus arrhythmia | Sinus Irregularity |
| 1,780 | `164889003` | ECG: atrial **fibrillation** | Atrial Fibrillation |

(SNOMED CT International Edition, 2026-08-01.)

Three traps worth knowing before you filter on anything.

**The abbreviations are not what you expect.** In this dataset's own
`ConditionNames_SNOMED-CT.csv`, `AF` means atrial **flutter**
(`164890007`) and `AFIB` means atrial **fibrillation** (`164889003`). Read
that twice. Flutter is also four and a half times more common here than
fibrillation, so a pipeline that quietly swapped them would still produce
plausible-looking numbers. **Filter on codes, never on the acronyms.**

**The bundled code map is incomplete.** The headers use **94 distinct
codes**; the CSV maps **55**, four of which never appear. So **43 codes have
no entry in the dataset's own map — 19.3% of all label occurrences**,
including the sixth and seventh most common codes in the corpus
(`55827005` and `55930002`, both absent). Resolve codes against
[SNOMED CT](https://browser.ihtsdotools.org/) itself and treat the CSV as a
convenience, not the vocabulary — its names diverge from SNOMED's own terms
even where it does have an entry, as the right-hand column above shows.

**Search is string matching, not subsumption.** In SNOMED, sinus
bradycardia, sinus tachycardia and sinus arrhythmia are all *children of*
sinus rhythm (`426783006`). Searching `426783006` finds the records that
literally carry that code, not the 26,000-odd that carry one of its
descendants. If you want a concept and everything under it, expand the
hierarchy on your side and search the codes it gives you. Murmur will not
do that for you, and should not: which descendants belong in your cohort is
a judgement about your study.

Murmur does not decode any of this. It shows you the code the record
carries, verbatim, and leaves the vocabulary to you — see
[What Murmur asserts]({{ site.baseurl }}/what-murmur-asserts) for why that
boundary is deliberate.

---

## 5. Look at fewer leads

Twelve overlaid leads is rarely what you want while adjudicating. The chip
bar's **presets menu** applies a named set in one click: `Limb`,
`Precordial`, `Bipolar limb`, `All leads`, plus anything you save
([#332](https://github.com/kvnlng/Murmur/issues/332)).

Stage the leads you want, then **Save current selection as preset…** —
`I · II · V2`, say. Presets are stored by lead **name**, so the set you
build here applies to any record carrying those leads, in this corpus or the
next one. Each menu row tells you up front how much of itself the open
record can satisfy (`Precordial — 3 of 6`). A built-in that resolves
nothing on the open record is omitted from the menu; your saved presets
are always listed, disabled rather than silently doing nothing
([#351](https://github.com/kvnlng/Murmur/issues/351)).

**An exercise.** Find a record labelled left bundle branch block
(`164909002`), apply `Limb`, then drop to `I · II` and look again. What you
are asking is how much of the evidence for that label survives the lead
subset — the question every reduced-lead device, from a telemetry patch to
a wearable, is quietly asking of the same label, and one you can only
answer by looking.

---

## 6. Bring your own predictions

Your model is a **producer**. Murmur reads
`<recordName>.annotations.json` next to each `.hea` and renders exactly what
it finds — see the [annotation schema]({{ site.baseurl }}/annotation-schema)
for the wire format and a validator.

This script turns a `record,code,probability` table into producer files,
carrying **both** your model's predictions and the dataset's own `#Dx`
labels as separate sources, so both show up as filterable provenance in the
review queue:

```python
#!/usr/bin/env python3
import csv, json, pathlib, sys, collections

root, table, model = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]

predictions = collections.defaultdict(list)
with table.open(newline="") as handle:
    for row in csv.DictReader(handle):          # record,code,probability
        predictions[row["record"]].append((row["code"], float(row["probability"])))

for hea in root.rglob("*.hea"):
    lines = hea.read_text().splitlines()
    n_samples = int(lines[0].split()[3])        # <name> <n_signals> <fs> <n_samples>
    findings = [
        {"kind": "range", "startSample": 0, "endSample": n_samples,
         "category": code, "confidence": probability, "source": model}
        for code, probability in predictions[hea.stem]
    ]
    findings += [
        {"kind": "range", "startSample": 0, "endSample": n_samples,
         "category": code.strip(), "confidence": 1.0, "source": "physionet-dx"}
        for line in lines if line.startswith("#Dx:")
        for code in line[len("#Dx:"):].split(",") if code.strip()
    ]
    if findings:
        hea.with_suffix(".annotations.json").write_text(
            json.dumps({"schemaVersion": 1, "findings": findings}, indent=2))
```

```bash
python3 make_annotations.py .../ecg-arrhythmia/1.0.0 predictions.csv my-classifier-v3
```

Both label sets span the whole record because that is what this dataset's
labels *are* — a ten-second strip carries one set of codes, not a set of
timed events. If your model localises, emit the samples it localised to
instead; nothing here requires whole-record ranges.

**Put the code in `category` and the human-readable name in `label`.**
`category` is what downstream tooling joins on; `label` is what the row
reads as. Murmur will not translate one into the other — the vocabulary is
yours, and
[What Murmur asserts]({{ site.baseurl }}/what-murmur-asserts) explains why
the viewer never decodes it.

Only one sidecar per record is read automatically, which is why the script
above writes both sources into one file. A one-off second file can be merged
into an open record with **Attach findings…**.

Validate before you generate 45,000 of them:

```bash
pip install jsonschema
python3 -c "import json,jsonschema; jsonschema.validate(
  json.load(open('WFDBRecords/01/010/JS00001.annotations.json')),
  json.load(open('annotations.schema.json')))"
```

---

## 7. Adjudicate

Open a record, open the **review queue**, and turn on **editing**. Each
finding offers:

- **Confirm as `<its own category>`** — you agree with the label.
- **Confirm as…** — you say it is something else. Type the code or name you
  mean; the queue then shows `→ <what you said>` beside the producer's
  label, and both survive to every export
  ([#331](https://github.com/kvnlng/Murmur/issues/331)).
- **Dismiss** — a false positive. Add a note saying why.
- **Confirm (unsure)** — you looked, you accept it, you are not narrowing it.

The disagreements are the point. A confirmed finding whose category differs
from the one it arrived with is the row your relabelling step wants, and
after a few hundred records that list is the actual output of the review.

**Your work lives in Murmur's bundle, not in the producer's folder.**
Dispositions go to `dispositions.json` inside the imported record bundle.
Re-run your model, overwrite every `.annotations.json` in the corpus, and
re-import: your confirmations, categories and notes are untouched. That
separation is a rule, not a convenience — the
[boundary page]({{ site.baseurl }}/what-murmur-asserts) states it as one.

---

## 8. Export the review table

**Export ▸ Export review table…** writes one CSV row per annotation across
**every record the navigator is showing**, with your disposition attached
([#330](https://github.com/kvnlng/Murmur/issues/330)).

Twenty-one columns — `record`, `record_path`, `annotation_id`, `kind`,
`start_sample`, `end_sample`, `start_seconds`, `end_seconds`, `lead`,
`category`, `label`, `source`, `confidence`, `state`, `confirmed_kind`,
`confirmed_category`, `note`, `reviewed_by`, `reviewed_at`, `flagged`,
`header_comments`. The full list is on the
[schema page]({{ site.baseurl }}/annotation-schema#review-table-export).

Three rows, abridged to eight of the twenty-one columns:

```csv
record,record_path,category,source,confidence,state,confirmed_category,note
JS00001,WFDBRecords/01/010/JS00001.hea,164889003,my-classifier-v3,0.9100,confirmed,164889003,
JS00001,WFDBRecords/01/010/JS00001.hea,426177001,my-classifier-v3,0.4200,dismissed,,"sinus, rate 78"
JS00002,WFDBRecords/01/010/JS00002.hea,426783006,physionet-dx,1.0000,confirmed,164890007,"sawtooth in II"
```

Read those three rows as a review: the first is agreement, the second is a
false positive with the reason recorded, and the third is a **label
correction** — the dataset says sinus rhythm, the analyst says flutter, and
both statements are in the row. Join on `category` vs `confirmed_category`
and you have your relabel-or-exclude list.

**Unreviewed rows are included**, deliberately. A review table needs its
denominator: what you looked at and left alone is as much a result as what
you confirmed. Records you never opened have no bundle, so they contribute
no rows — they are counted, and the completion message names the count, so
the export never quietly covers less than you think.

---

## 9. Figures and citation

**Export ▸ Export snapshot…** writes a PNG of the current bedside view for a
write-up, carrying its own provenance — which lead, which window, which
configuration produced what you are showing.

If Murmur was part of how you got a result, please
[cite it]({{ site.baseurl }}/citation), and cite the dataset separately: it
is a distinct piece of work under its own licence.

---

## What this guide did not do

It did not tell you what any of these codes mean clinically, whether your
model is good, or which disagreements are real. Murmur showed you the record
and recorded what you said about it. Everything else was yours.
