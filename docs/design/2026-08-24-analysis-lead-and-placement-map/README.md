# Analysis lead & lead placement map — design spec

Tracking issues: [#357](https://github.com/kvnlng/Murmur/issues/357)
(analysis lead), [#358](https://github.com/kvnlng/Murmur/issues/358)
(placement map). [#351](https://github.com/kvnlng/Murmur/issues/351)
(presets) is downstream of #358 and is **not** specified here beyond the
one hook it needs.

Provenance: the 2026-08-23 design conversation produced the two issues;
this spec records the 2026-08-24 scoping decisions and the implementation
design built on them. Where this spec and the issues disagree on a
mechanism, this spec wins (it is later and code-grounded); where this spec
and the shipped code disagree on a fact, the code wins.

**Sequencing: #357 lands completely (its own PR series, tests, docs),
then #358 starts on a main that already has designation and has retired
the X108 name normaliser. No Murmur-Extensions release is required for
either issue.**

---

## The rule both issues serve

A calculation may never be gated on a lead's *name*. The analysis lead is
chosen by measured R-peak quality or by the analyst's direct designation;
what a lead is *called* — and what the analyst declares it to *be* — is
disclosure, carried alongside results, never an input to them.

---

## Scope decisions (2026-08-24)

| # | Decision | Consequence accepted |
|---|---|---|
| 1 | **Scorer is paid-only, via a registration hook.** MurmurCore defines the interface; the App target registers a MurmurMetrics-backed scorer. | Free viewer defaults to first-in-file, *disclosed as such*. No dependency moves; MurmurCore never imports MurmurMetrics. |
| 2 | **Score at import only; never backfill.** The default is stamped once when the bundle is cut and never recomputed. | Pre-feature bundles and free-tier imports opened after a Pro upgrade keep first-in-file until the *source* changes (new bundle) or the analyst designates. A record's default can never change under an analyst mid-review. |
| 3 | **Designation UI = context menu on the lead + read-only header disclosure.** | No picker build; the header line is a fact, not a control. |
| 4 | **Placement map is session-only.** It lives in the live session state, is saved into the `.mur`, restored with it, and torn down on folder switch like the rest of the working set. | Browsing a folder without its session shows *undeclared* (the issue's honest state). #351's placement-resolved presets resolve only when a session map is present. The map survives producer rewrites because the `.mur` is bundle- and folder-independent. |
| 5 | **Sequential arcs**: #357 fully first, then #358, then #351. | #358's boundary text ("the normaliser is retired by the sibling issue") is true by the time #358 starts. |

---

## Part 1 — #357: analysis lead

### 1.1 Model and resolution

`Recording.primaryECGChannel` (first non-trend channel) **stays**, as the
raw file fact — display code and the sample-rate accessor still need it.
What changes is that no *calculation* consumer reads it directly any more.

New resolution, in MurmurCore:

```
analysisLead(for recording, inBundle directory) -> (channel, provenance)
```

Resolution order, first hit wins:

1. **Designation** — the analyst's assertion from the bundle sidecar.
   A designation naming a channel that no longer exists in the recording
   (source changed, channel renamed) is ignored with a header disclosure
   — *"designated lead V9 not in this record — using default"* — falling
   through to 2. Never a crash, never silent.
2. **Stored default** — the import-time score result from the sidecar.
   Same missing-channel rule.
3. **First-in-file** — `primaryECGChannel`, with provenance saying so.

`provenance` is an enum the disclosure line and exports render from:

- `.designated(reviewer, date)`
- `.rPeakScore(score, perLead: [name: score-or-exclusion-summary])`
- `.firstInFile` (no sidecar, free tier, or fallthrough)

### 1.2 Scorer hook

Mirrors the `FindingProducer` registry (MurmurCore protocol; paid
implementations registered at app bootstrap; free path has a baseline):

- MurmurCore: `protocol AnalysisLeadScorer` — given
  `[(name, samples)]` and a sample rate, returns per-lead scores, or nil
  when it declines. A registry singleton holds at most one scorer.
- App target (`bootstrapBaselineProducers`'s neighbourhood): registers a
  scorer that (a) checks the Pro entitlement via `PurchaseStore` and
  returns nil when unentitled, (b) otherwise wraps the already-public
  `QRSDetector.qrsProminence` from MurmurMetrics. **No Murmur-Extensions
  change: `qrsProminence` is public today.**
- Tie-break: highest score wins; equal scores fall to file order, and the
  provenance then *names* the tie-break (issue requirement: first-in-file
  "is named when used").

The scorer contract is deliberately dumb — scores in, no channel choice
out. Choosing (and disclosing) is core's job, so free and paid builds
share one resolution path and one disclosure vocabulary.

### 1.3 Bundle sidecar

`analysis_lead.json`, beside `source_fingerprint.json` — same
"assertions live in the bundle, never the producer's folder" rule as
dispositions. Two independent sections, either may be absent:

```json
{
  "default": {
    "channelName": "MLII",
    "reason": "rPeakScore",
    "perLeadScores": {"MLII": 6.1, "V5": 3.2},
    "scoredAt": "2026-08-24T...",
    "scorerVersion": 1
  },
  "designation": {
    "channelName": "V4",
    "reviewer": "kevin",
    "designatedAt": "2026-08-24T..."
  }
}
```

- `default` is written **once**, by `RecordingStore.importWFDB`, right
  where the fingerprint is stamped (after import succeeds). Scorer absent
  or declining → the file is written with `"reason": "firstInFile"` and no
  scores — the *absence of scoring* is recorded, not inferred. Decision 2:
  nothing ever rewrites it; bundle reuse (#341) serves it unchanged.
- `designation` is written by the UI, reviewer from the `DispositionStore`
  convention (macOS user name, best-effort). Revert-to-default deletes the
  section, not the file.
- Channels are referenced by **name** (names are per-import stable and
  survive re-import of unchanged source; channel IDs do not). Duplicate
  names within one recording resolve to the first match — same rule the
  X96 lead-selection restore already uses (`WFDBImporterDuplicateLabelTests`
  territory; a test pins it).
- Pre-feature bundles have no file → `.firstInFile`. No migration.

### 1.4 Consumer rewiring

The seven `primaryECGChannel` calculation consumers move to
`analysisLead`:

| Consumer | Change |
|---|---|
| `ArrhythmiaScanOrchestrator` | Passes **only the analysis lead's samples** to `ArrhythmiaScanService.scan(leads:)`. The service's internal strongest-QRS pick trivially selects the one lead given; `leadUsed` maps back to the analysis lead. The A3 quality preflight runs on the same lead — unchanged semantics, honest disclosure. |
| `MorphologyOrchestrator` | Analysis lead in place of primary/conventional. |
| `IntervalMarkingsOrchestrator` | **Methods change, called out below (§1.5).** |
| `VTVFScanView` | Analysis lead in place of primary. |
| `ReviewTableBuilder` | Reads the sidecar for the lead + provenance columns (§1.6). |
| `RecordListEntry` | Display-only consumer — keeps `primaryECGChannel` (duration/rate come from the file fact; no calculation is gated). |
| `MurSessionPackage` | Carries the sidecar through save/open like the other bundle assertions. |

`Recording.conventionalQTChannels`, `conventionalQTLeads(inDirectory:)`
and the ML-prefix normaliser are **deleted**. The acceptance grep — no
channel selection by name and no `channels.first` in a calculation path —
gets a standing test that walks the calculation call sites.

### 1.5 The QT methods change (explicit)

Today `IntervalMarkingsOrchestrator` computes a **cross-lead composite**:
`MultiLeadQT.perLeadBeats` over the conventional leads (II, then V5),
`compose`d, with citations naming the multi-lead method. Under #357 QT
runs on **the analysis lead alone** through the same machinery
(`perLeadBeats` over one lead; `compose` of one element is that element).
This changes exported citation wording and, on records where II and V5
disagreed, the numbers. That is the designed intent — the composite was
reachable only through a name gate — but it is a methods change and the
PR must say so.

Disclosure inversion: the QT result carries
*"measured on V4 — not a conventional QT lead (II/V5)"* when the analysis
lead's recorded name does not read as II or V5. "Reads as" is defined
exactly: case- and whitespace-insensitive equality with `II` or `V5`,
**no prefix stripping** — the ML normaliser is gone, so on MIT-BIH the
disclosure honestly fires (*"measured on MLII — not a conventional QT
lead (II/V5)"*) until the analyst declares `MLII → II` in #358 (§2.3).
This is a **name comparison used for disclosure only** — the one
direction the boundary permits. When the analysis lead's recorded name is
II or V5, no annotation is added (standard case, nothing to disclose).

### 1.6 UI, exports, docs

- **Context menu** on a lead in the channel list / overlay picker:
  "Use as analysis lead", and on the current designee "Revert to default
  (MLII — strongest R peaks)". Free tier gets the same menu (designation
  is an assertion, not a paid computation).
- **Metrics header**, read-only line, one of:
  - `analysis lead: V4 — designated by kevin, 2026-08-24`
  - `analysis lead: MLII — strongest R peaks (V5: 18% of beats excluded)`
  - `analysis lead: MLII — first in file`
- **Review table + Markdown report**: two columns per record — analysis
  lead (recorded name) and reason (`r-peak score 0.91` / `analyst
  override — kevin` / `first in file`). `docs/annotation-schema.md`
  documents them.
- `docs/what-murmur-asserts.md` gains one sentence: the app never chooses
  or gates a calculation by a lead's name; lead names appear in
  disclosures only.
- Designating (or reverting) invalidates the derived caches keyed on the
  analysis choice and re-runs the orchestrators, exactly as a lead-focus
  change does today.

### 1.7 Tests (#357)

- Fixture: noisy channel 0, clean channel 1 (SyntheticECG can build
  both) → default is channel 1, provenance `.rPeakScore`, header text
  matches.
- Scorer absent (registry empty) → `.firstInFile` recorded in the
  sidecar, disclosed.
- Designate V4 where MLII exists → all four orchestrator paths receive
  V4's samples (assert via the published contexts), QT carries the
  disclosure, nothing falls back by name.
- Designation naming a missing channel → ignored with report, falls to
  default.
- Re-import unchanged source → reused bundle keeps sidecar (composes with
  #341). Changed source → fresh bundle, fresh score.
- Duplicate lead names → first match, pinned.
- Review-table columns present and correct for: designated, scored,
  first-in-file records.
- The no-name-gate grep guard.

---

## Part 2 — #358: lead placement map

Starts only after #357 is merged.

### 2.1 Model

Session-scoped (decision 4), one map per working session:

```
placementMap: [recordedName: Declaration]
recordOverrides: [recordPath: [recordedName: Declaration]]
Declaration = {placement: String (free text), reviewer, declaredAt}
```

- Folder-level entry covers every record in the session's working set
  whose channel carries that recorded name; a record-level override wins
  and is rendered as an override ("declared: II — record override, …").
- Free text. **No built-in name table.** The declaration sheet may
  *offer* the recorded name's conventional reading as a pre-filled
  suggestion the analyst visibly accepts or edits; it never applies one
  silently.

### 2.2 Storage and lifecycle

- A new session-level shared context (sibling of the scan-dial pattern,
  but session-wide, not per-record — `CarriedSessionStore` is explicitly
  *not* the home). Torn down when the working set is torn down (the X86
  open path: "an open tears down every record's in-memory work").
- Persisted in the `.mur` at session level — a `lead_map.json` member
  beside `manifest.json`, versioned under the manifest's `formatVersion`
  mechanism. Absent member = no map = undeclared (old packages
  unaffected, byte-identical when nothing is declared).
- Restored on `.mur` open with the rest of the session. Not stored in
  bundles, not in the producer's folder, not in Application Support.
- Unsaved declarations ride the existing unsaved-session guards (X77/X78
  family) — a declaration is analyst work like a note.

### 2.3 What it feeds — and what it must never feed

- **Disclosure**: metrics header and export rows append
  `MLII (declared: II, by kevin, 2026-08-24)` after the analysis lead's
  recorded name; the review table gains declared-placement columns; a
  dataset with no map exports the columns empty — *undeclared*, never
  omitted.
- **Preset hook**: `LeadPreset.resolve` gains an optional
  declared-placement lookup so a name that declares `→ II` matches a
  limb-lead preset. The hook lands in #358; every *use* of it (the
  omission rule, seeding) is #351.
- **QT disclosure interaction**: a declaration is allowed to inform the
  §1.5 disclosure, because disclosure is the map's whole jurisdiction.
  A record whose analysis lead declares `→ II` renders
  *"measured on MLII (declared: II, by kevin, 2026-08-24)"* with no
  not-conventional flag; the flag stays for undeclared non-II/V5 names.
  The *measurement* is identical either way — only the sentence changes.
- **Never**: the map has no reader in any calculation path or in
  `analysisLead` resolution. The acceptance test is the issue's own:
  export everything before and after declaring, diff, and assert only the
  placement columns changed. The loophole this closes: declaring
  `V4 → V5` must not be a way to get V4 analysed — designating V4 is, and
  the export then says V4.

### 2.4 UI, docs, tests

- Declaration sheet reachable from the same lead context menu ("Declare
  placement…") and from the header's declared-placement text when
  present. Shows folder-level entries, per-record overrides, reviewer and
  date; deleting a declaration is allowed and dated.
- `docs/reviewing-a-holter-database.md` §4/§5 and
  `docs/annotation-schema.md` updated; `what-murmur-asserts.md` gains its
  sentence (the app asserts no lead-name meanings; declared placements
  are the analyst's statements, carried verbatim).
- Tests: declare on a multi-record session → every record's header/export
  row shows it; record override wins and says so; the before/after export
  diff; `.mur` round-trip (declare → save → reopen → still declared;
  old package → undeclared); teardown on folder switch; preset-resolve
  hook matches by declaration (resolution only — no #351 behaviour).

---

## Out of scope

- #351 entirely (preset seeding/omission on placement-resolved results).
- Any automatic placement inference, any bundled `MLII = II` table.
- Backfilling scores into existing bundles, or any re-scoring trigger
  short of a fresh import.
- Multi-reviewer identity beyond the existing best-effort macOS user
  name convention.
