---
title: What Murmur asserts
layout: default
nav_order: 5
---

# What Murmur asserts

Murmur reads findings produced by other people's tools, shows them
against the waveform, and hands an analyst's judgments back out. All of
that value depends on one boundary being kept:

> **Murmur transmits assertions. It does not author them.**

The exception is the analyst, who authors freely — and whose every
assertion is stamped with who made it and when.

This page states the boundary. Read it if you are writing a producer
(the schema is generous, and this explains where), or if you are
changing the app (this explains which changes are off the table and
why).

## Four voices in one window

| Voice | Speaks through | Murmur's obligation |
|---|---|---|
| **The record** | WFDB `.hea` + `.dat` — what the recording institution captured and wrote down, including `#` header comments | Render verbatim. Header comments are immutable and read-only. |
| **The producer** | `<record>.annotations.json`, or a `FindingProducer` framework | Treat as authoritative. The viewer never re-derives, re-scores, or silently corrects producer output. |
| **The analyst** | Dispositions, notes, authored findings | Attribute (`reviewedBy`) and timestamp (`reviewedAt`). Keep in sidecars the producer can never overwrite. |
| **Murmur** | Geometry, calibration, arithmetic, navigation | Render the other three faithfully and measure what is on screen. **Do not conclude.** |

That last row is the constraint. Everything below follows from it.

The regulatory posture is the same statement in different words — the
first-run notice puts it as: *"It is not a medical device. Nothing it
displays is a diagnosis."* The rules here are how that survives contact
with feature work.

## The rules

### 1. Transcription, not interpretation

Input vocabulary is preserved as written. Murmur strips syntax, never
meaning.

The ratified case is MIT-BIH `.atr` rhythm markers: the AUX payload
`(AFIB` is stored as `AFIB` — only the annotator's syntactic `(` comes
off. It is never expanded into "atrial fibrillation," because that
sentence would be Murmur's, not the annotator's
(`Annotation.swift:329-334`).

This rule is vocabulary-agnostic. It governs `.atr` labels, SNOMED
codes in a `#Dx` line, and any coding system that arrives in the
future.

### 2. Facts, not verdicts

App-computed surfaces state what was measured — kind, span, "median 50
bpm," departure from the patient's own template. They do not rank
clinical importance.

The `Severity` enum was removed on 2026-07-04 for exactly this reason:
an app-assigned "critical" on a beat is a clinical verdict. The review
queue now ranks by objective departure from the per-patient normal
template instead (`Annotation.swift:55-63`,
`ArrhythmiaScanContext.swift:19-21`). Producer `confidence` is the
producer's calibrated reliability, passed through untouched.

### 3. Neutral ink for anything the app computed

Color is reserved. Amber marks what the analyst asserted; neutral ink
carries everything the app measured. A category-hued density map or a
caution-colored interval delta would encode a severity call through the
palette — the same verdict rule 2 forbids in text
(`AnnotationDensityLane.swift:13-17`, `BeatCalipers.swift:411-415`).
Alpha carries *how many*, never *how bad*.

### 4. Provenance travels with every surface

Each computed surface states its own method where you read it: which
lead was measured, which window and formula, what was excluded and why.
Lane headers and queue captions echo the configuration they ran with,
and exports carry the same statements — so a published figure names its
own provenance. See [Citing Murmur Studio]({{ site.baseurl }}/citation).

Murmur never chooses, and never gates, a calculation by a lead's
name; the analysis lead is designated by the analyst or defaulted by
measured R-peak quality, and lead names appear only in disclosures.

### 5. Analyst work is separate and attributed

Dispositions and notes live in the imported bundle
(`dispositions.json`, `notes.md`), never in the producer's folder.
Re-running a producer regenerates its own file and cannot destroy
review work. The label-vs-caption split exists for the same reason:
what an analyst *calls* a finding can evolve without corrupting what
was *measured*.

An analyst may also confirm a finding **as** something other than what
it arrived labelled as (`confirmedCategory`). That disagreement is
recorded beside your label, never over it: both words survive to the
export, so a consumer can see the claim and the counter-claim. The field
is free-form, and Murmur never interprets what an analyst types into it —
the vocabulary is the producer's, not the app's.

### 6. Export only what a human asserted

WFDB annotation export ships analyst-authored and confirmed findings —
"export what is amber." Unconfirmed candidates, model scores, detector
parameters, and computed measurements stay in Murmur's own sidecars.

The span-to-point reduction is the sharpest illustration. A finding is
a span throughout Murmur, but WFDB's native way to write a span is a
rhythm onset/offset pair — and writing an offset asserts that some
*other* rhythm resumes at that sample. Confirming "VT here" is not
confirming "sinus resumes at sample N," so the export refuses to say
it, and writes a NOTE at the onset carrying the analyst's own words
instead (`WFDBAnnotationExport.swift`).

## If you are writing a producer

The boundary is generous on your side of it. You own:

| You own | How it arrives |
|---|---|
| **Your categories** | `category` — any string. Hand-tuned categories get their palette entry; unknown ones get a deterministic hashed color, stable across runs. |
| **Your display names** | `label` — *"Display token. Falls back to `category`."* Whatever you put here is what the analyst reads. |
| **Your confidence** | `confidence` — treated as already calibrated and comparable; the viewer never rescales it. |
| **Your provenance** | `source` — carried on every finding, shown in the panel, exported with the review. |

And your file is never rewritten by the viewer.

**This is where vocabulary decoding belongs.** If you want clinical
names on screen, decode them in your producer and ship both:

```json
{
  "kind": "range",
  "startSample": 0,
  "endSample": 5000,
  "category": "164889003",
  "label": "Atrial fibrillation",
  "source": "physionet-dx + SNOMED CT 2026-01"
}
```

The analyst reads your words; the code stays in `category` so it
remains searchable, sortable, and exportable; and the release you
decoded against is on the record. Three lines in the converter you are
already writing.

See the [Annotation JSON schema]({{ site.baseurl }}/annotation-schema)
for the full field list and a validator.

## Why Murmur does not decode medical vocabularies

A recurring, reasonable request: the app already sees SNOMED CT codes
in `#Dx` header lines, so why not show names? Four reasons, in
increasing order of how hard they are to work around.

**It is your assertion, not ours.** Rule 1. A code transmitted verbatim
is the source's claim; a name rendered beside a waveform is Murmur's
translation of it. If the mapping is wrong or stale, the wrong word is
Murmur's fault, at the moment a human is forming a judgment.

**The mappings are genuinely ambiguous.** Real corpora disagree with
themselves. One published crosswalk maps a single bundle-branch-block
code to three different names, collapses five myocardial-infarction
variants onto one code, and uses an abbreviation for atrial *flutter*
that a companion dataset uses for atrial *fibrillation*. There is no
correct string to show — so any string shown is invented by the app.

**Terminology licensing is incompatible with how Murmur ships.** SNOMED
CT requires an affiliate license, free only in member territories.
Murmur is MIT-licensed source distributed worldwide. LOINC, ICD-10, and
RxNorm each carry their own distinct terms. Bundling any of them puts a
license nobody in this repo controls inside a repo whose license is the
whole distribution story.

**It argues for the label.** Murmur is where an analyst goes to
*distrust* labels — to discover that a corpus's rhythm annotations are
systematically wrong. Rendering those labels in confident clinical
prose quietly takes their side. An opaque code keeps skepticism
switched on, which is the point of the review.

The capability itself is not in dispute — it exists, via `label`, on
the side of the boundary where the person who owns the vocabulary also
owns the claim.

## When it is a judgment call

New features rarely announce which side they are on. The test that
resolves most cases:

> **Whose sentence is it?**

If the app would put a word, a color, or a ranking in front of the
analyst that nobody in the chain actually said, the app has become the
author. That is the line.

A useful corollary when reviewing a change: *would this still be
correct if the input were wrong?* Faithfully rendering bad input is
fine — that is how the analyst finds it. Interpreting bad input
produces a new, confident, wrong claim with Murmur's name on it.
