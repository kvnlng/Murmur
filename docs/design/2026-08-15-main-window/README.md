# Handoff: Murmur main window — layout, density, and navigation for long multi-lead records

## Overview

Murmur is a macOS SwiftUI app for examining ECG waveform data. This handoff covers a redesign of its
**main window**: the record navigator, the waveform stage, the context region beneath it (free-text
Context notes + variability metrics), the review queue, and the window toolbar.

The redesign targets three problems observed in the shipped build:

1. **Toolbar** — nine equal-weight icon+label buttons in one undifferentiated row.
2. **Density** — seven stacked context lanes below a pinned stage, most of them below the fold; a
   210 pt column of mostly-placeholder cards beside the trace; a solid-blue overview bar carrying no
   information; whole-record metrics rendered at footnote size.
3. **Scale** — the target recording profile is **12 leads at 250 Hz for up to 72 hours**
   (~65 M samples per lead). A single "record → 10 s window" jump is not a usable navigation model at
   that scale, and the QTc trend — one of the main things an analyst navigates by — was collapsed to a
   one-line row.

The canonical design is **option `11a`** in the design file. Earlier options are kept as history and
explicitly superseded (see *Reading the design file*).

## About the design files

The files in this bundle are **design references created in HTML** — prototypes that show intended
layout, hierarchy, and behavior. They are **not production code to copy**. The task is to recreate the
designs in the existing app: **SwiftUI, macOS, in the `MurmurCore` package**, using the app's current
view structure, view modifiers, and idioms. No HTML, CSS, or web tooling should enter the codebase.

Where the design and the shipped code disagree about a *fact* (a control's name, a persistence path, a
policy), the code wins — please raise it rather than implementing the wireframe literally.

## Fidelity

**Low fidelity (wireframes).** Greyscale + one accent, system type, placeholder waveforms. Sizes,
proportions, ordering, grouping, and copy are intentional. Colors are **not** final: use the app's
existing SwiftUI materials, `.secondary`/`.tertiary` styles, `Color.accentColor`, and the existing
`CategoryPalette` / `LeadPalette` for category and lead colors. Do not lift the hex values from the
HTML except where this document says a value is semantic (see *Design tokens*).

## Target codebase

Repo layout as read during design (`/Users/kevin/Documents/Murmur`):

| Area | File |
| --- | --- |
| App shell, record navigator, open/import | `Plotting/MurmurCore/ContentView.swift` |
| Main detail view — stage, lanes, toolbar contributions, key commands | `Plotting/MurmurCore/BedsideView.swift` |
| Review queue | `Plotting/MurmurCore/FindingsPanel.swift` |
| Free-text context + notes | `Plotting/MurmurCore/RecordContextPanel.swift` |
| QTc / interval trend lane + its settings | `Plotting/MurmurCore/IntervalTrendLane.swift`, `IntervalTrendLaneContext.swift` |
| Analyst reference lines on that lane | `Plotting/MurmurCore/IntervalTrendGuideStore.swift` |
| Rolling HRV lane | `Plotting/MurmurCore/VariabilityLane.swift` |
| Whole-record HRV block | `Plotting/MurmurCore/VariabilityMetricsStrip.swift` |
| Vital trend sparklines / alarms / quality | `ChannelTrendStrip.swift`, `AlarmStrip.swift`, `QualityStrip.swift` |
| Record-wide density map | `Plotting/MurmurCore/OverviewMap.swift` |
| Toolbar identity + SF Symbol vocabulary | `MurmurToolbar.swift`, `ToolbarGlyphs.swift` |
| Zoom tiers, level-of-detail pyramid | `WaveformZoomTier.swift`, `PyramidBuilder.swift`, `PyramidLevelFile.swift` |
| Report export | `MarkdownReport.swift` |

## Reading the design file

`ECG Analyst Wireframes.dc.html` is a stack of dated option sets, **newest at the top**. Each option has
a stable id badge. Open it in a browser; it needs no server.

| id | What it is | Status |
| --- | --- | --- |
| `11a` | **Canonical.** Full window: toolbar, navigator, lead chips, **pinned Variability metrics band**, three-tier ladder, trace, collapsed Context bar, five-lane trend stack, review queue, info bar | Build this |
| `12a` | **Launch state.** Empty window, panes closed, flatline viewer | Build this |
| `13a` | **Trend stack, canonical rendering.** Filled p25–p75 ribbon + dashed p5/p95 + median line for rolling lanes, dot-and-range per bin for QTc, y-axes, accent rails, window box | Build this (supersedes the lanes in `10a`) |
| `14a`, `14c` | Alternative statistical renditions considered (box-and-whisker per bin; stepped median) | Historical — `14b` was chosen and folded into `13a` |
| `10a` | Earlier trend stack — read for caption and provenance wording only | Superseded by `13a`; do not build its lanes |
| `9a` | Full window with the Context drawer **open** — read for the notes anatomy in place | Build this (drawer state of `11a`) |
| `8a` | Context drawer in detail: list, stepper, anchored editor, autosave footer | Build this (detail of `9a`) |
| `7a`, `6a`, `6b` | Earlier notes explorations | Superseded by `8a` / `9a` |
| `5a` | First 12-lead / 72 h window; introduced the ladder and info bar | Superseded by `11a` |
| `3a`, `3b`, `4a` | Improvements drawn against the shipped screenshot's 2-signal 128 Hz record | Historical; the toolbar in `4a` is superseded by `11a` |
| `1a`–`2c` | Generic ECG-review explorations before the codebase was read | Historical only — do not implement |

## Screens / views

There is one window. It has five regions, described below in the order they appear.

### Region 1 — Window toolbar (`NSToolbar` via `.toolbar`, id `murmur.main.toolbar`)

Height ~46 pt (standard unified toolbar). Left to right:

- Traffic lights (system).
- **Sidebar toggle** — `sidebar.leading`, icon-only, shown in "on" state when the navigator is visible.
  Already exists as `sidebarToggleToolbarItem` in `ContentView`; keep it in the **leading** placement.
- **Window title** — the record name only (e.g. `16265`), centered, `.headline`-ish weight.
  **Remove** the metadata subtitle (`2 sig · 128 Hz · …`) from the title area — it moves to Region 5.
- Trailing action cluster, all **icon-only, borderless, ~28 pt hit targets**, in this order, using the
  exact symbols already declared in `ToolbarGlyphs`:
  1. Notes / Context toggle — `⌘⇧N` (see *New capabilities*; no glyph exists yet, propose `note.text`)
  2. Editing latch — `lock.open.fill` / `lock.fill`
  3. 10 s window hold — `pin.fill` / `pin`
  4. Scan for VT/VF candidates — `waveform.badge.magnifyingglass` (only when `scanContext.isScanAvailable`)
  5. Attach findings… — `square.and.arrow.down`
  6. *divider*
  7. Export report — `square.and.arrow.up`, as a **menu** carrying Export report / Export snapshot
     (`camera`) / Export WFDB annotations… (`doc.badge.arrow.up`)
  8. More — `ellipsis.circle`: Open Record Folder (`folder.badge.plus`), Customize Toolbar…, plus any
     future rare actions
  9. *divider*
  10. **Review queue toggle** — `sidebar.trailing`, trailing-most, replacing `stethoscope.circle`
- Labels are **not** drawn under the icons. Every action keeps its menu-bar equivalent, so discoverability
  does not depend on the toolbar. Note the known macOS 26 issue that `.help()` renders nothing — that is
  why grouping and symbol uniqueness matter more than tooltips.

### Region 2 — Record navigator (leading sidebar, `NavigationSplitView` sidebar column)

Width 230 pt (existing column constraints `min 160 / ideal 240 / max 320` are fine).

- Header block: a rounded **search field** filtering the record list, then a section header row —
  disclosure triangle, `RECORDS`, count right-aligned, `.caption2` secondary.
- Rows: record name (`.callout`, semibold) over one metadata line (`.caption2`, secondary):
  `12 lead · 250 Hz · 72.4 h · 32 M`. One line only — the shipped two-line block with duplicated units
  is what makes the list hard to scan. Keep the existing flag affordance and import/failed states.

### Region 3 — Waveform stage (pinned, never scrolls)

Three stacked bands, all sharing one horizontal time mapping, each with a draggable window box:

0. **Variability metrics band** (~86 pt, pinned) — sits directly under the lead chip bar and above the
   record band. `Variability metrics`, then `6,441,208 beats · 72.4 h · measured in II`, then a **Scope**
   segmented control (`Whole record / Window / Hour`) and a `Lanes ⌄` menu. Below, three labelled clusters
   side by side — TIME DOMAIN (Mean RR, SDNN, RMSSD, pNN50, Mean HR, Beats), FREQUENCY DOMAIN (VLF, LF, HF,
   LF/HF, LF/HF n.u.), QT VARIABILITY (QTVi, SDQT, QT SDNN, Mean NN). Values ~13.5 pt semibold over ~9.5 pt
   secondary labels; **method text and caveats live behind an ⓘ affordance**, not as footnote paragraphs.
1. **Lead chip bar + zoom ladder** (~34 pt). Left: Focus/Strips segmented control, then lead chips
   (`I … V6`) — ⌘-click still adds an overlay lead, primary keeps the marks. Right: a zoom ladder
   segmented control — `72 h / 1 h / 5 min / 10 s / 2 s` — reflecting and setting the viewport width.
2. **Record band** (~26 pt) — the whole recording (72 h) as per-category density, i.e. `OverviewMap`
   widened, plus **note ticks** along the bottom edge. Current window drawn as a box.
3. **Hour band** (~32 pt) — the enclosing hour as a min/max envelope, with the window box inside it.
4. **Trace** (~250 pt at this window height) — the Metal canvas, full width of the center column, with
   a lead badge and mV span top-left, candidate/finding ranges shaded, and an anchored-note marker.
5. **Right of the trace, 186 pt**: gain (5/10/20) and speed (25/50) segmented controls, Standard View,
   Layers ⌄, then the **focus-beat readout** (RR, QT/QTc, QRS, departure) and a one-line keyboard hint.
   The shipped four separate cards (viewport, paper, focus-beat placeholder, layers chip) collapse into
   this one column, and the beat readout shows **only when a beat is focused** — no
   "Hover the trace to focus a beat" placeholder holding layout.

Time axis labels sit under the trace, `.caption2` monospaced-digit, secondary.

### Region 4 — Context region (scrolls; the only scrolling area of the center column)

One `ScrollView` containing, in order (the metrics band is **not** here — it is pinned in Region 3):

1. **Context / notes drawer** — collapsible, `⌘⇧N`. Collapsed: a one-line bar
   `Context · notes.md · 4 entries · last edited 2 min ago`. Expanded (`9a`, `8a`): a header row, then a
   two-column body ~214 pt tall:
   - Header: disclosure chevron, `Context`, `notes.md · N entries · saved`, a **prev/next stepper** with
     an `N of M` readout (`⌥J` / `⌥K`), then `New note at <current window>`, the Editing latch, `⌘⇧N`.
   - **List column, 288 pt**: search field + sort (`Time ⌄`); first row is the **read-only `.hea`
     comment block** (monospaced, labelled `read-only`); then one row per note — anchor time, first line
     truncated, anchor duration right-aligned, category dot. Selected row uses the accent selection style.
     Footer hint: selecting a row moves the trace to that note's anchor.
   - **Editor column, flexible**: anchor chip (`21:40:25–21:40:35`), "anchored to a 10 s range in lead II",
     `Jump to anchor`, `Re-anchor to current window`; then the Markdown text body; then a footer:
     `Saved · 2 s ago`, and the real persistence sentence — 0.6 s debounced write to
     `<bundle>/notes.md`, flushed immediately when Editing re-locks — and `Delete note`.
   - **There is no Submit button.** This matches `RecordContextPanel` as shipped.
2. **Trend stack** — five lanes in one bordered container, sharing **one 72 h axis**. Each lane row is
   `[4 pt accent rail | label column 114 pt | y-axis gutter 30 pt | plot | current value 66 pt]`, rows 86 pt (104 pt for the interval trend, 26 pt for quality). Mark type follows the aggregation: **rolling** windows (RMSSD, LF/HF) draw one continuous median polyline inside a filled p25–p75 ribbon with dashed p5/p95 outlines; **binned** metrics (QTc) draw one dot-and-range mark per bin (dot = median, thick = IQR, thin = range); HR draws a per-bin min–max envelope. Never thin per-column dashes, never a continuous path across an excluded bin. Each lane draws three y-axis ticks with matching gridlines, monospaced digits:

   | Lane | Label / sublabel | Notes |
   | --- | --- | --- |
   | HR · beat-derived | `bpm · min–max per 10 s` | Computed from detected beats — **not** the device trend channel; drawn as a min–max envelope per 10 s bin, no median line |
   | RMSSD | `ms · rolling 5 min / 30 s · IQR filled, p5–p95 dashed` | `VariabilityLane` as shipped. Rolling windows overlap, so draw one continuous median polyline inside a filled p25–p75 ribbon, with p5 and p95 as dashed outlines — never discrete bars |
   | Interval trend | `ms · 2 min bins · dot = median, thick = IQR, thin = range`; control chips `QTc ⌄`, `Fridericia ⌄`, `2 min ⌄`, `+ your guide ⌄` | The shipped `IntervalTrendLane` control set, unchanged. Bins are independent, so each bin draws its own mark: a dot at the bin median on a thick IQR segment and a thin full-range segment. Baseline labelled `normal 386 — this patient's template`; the elevated colour needs a legend key stating the count. An **excluded** bin draws a short grey stub with no median and no range — never a range without a median. **No built-in clinical cutoffs**; reference lines are analyst-placed only, empty by default (`IntervalTrendGuideStore`) |
   | LF / HF **NEW** | `ratio · Lomb–Scargle · rolling 5 min / 1 min · IQR filled, p5–p95 dashed` | New computation (today it is one whole-record number) — see *New capabilities*. Same treatment as RMSSD |
   | Quality | `artifact ratio · outline @ 60%` | `QualityStrip` semantics; only when quality channels exist |

   One **window box** spans all five lanes; **low-quality stretches shade every lane** so the analyst can
   see which parts of every trend to distrust. Under the stack: the axis (day/time labels) and one
   caption line carrying the shipped provenance string —
   `QTc · Fridericia · 2-min bins · normal template = 83,110 annotator-coded normal beats · spanning 0:00.4–72:24:10.0 · measured in II · 505 beats excluded (0.5%)`
   — plus the interaction hint: click a lane to move the trace, ⌥drag to zoom.

### Region 5 — Info bar (bottom, ~28 pt)

Replaces the metadata that used to sit in the title. Leading: record name, then
`12 leads · 250 Hz · 72.4 h · 65.1 M samples/lead`, then the absolute start instant (or nothing when the
record has none — `recording.hasAbsoluteStartTime`). Trailing, right-aligned: current window range, the
**zoom tier** from `WaveformZoomTier` (`inspect` / `scan` / `context`) with its `pointsPerBeat` reading,
the **LOD level** actually being drawn (`L1 · 10 samples/bin`, from `PyramidBuilder`'s 10×-per-level
cascade), and note count. All `.caption2`, secondary, monospaced digits.

### Region 6 — Review queue (trailing inspector)

Width 340 pt (existing `min 260 / ideal 340 / max 500`). Unchanged in principle from `FindingsPanel`, with
three changes:

- Header: `Review queue`, count, a `⋯` options menu; a **segmented disposition filter**
  (`To review N / Confirmed N / Dismissed N`); the ectopy burden line stays factual.
- **Categories lead.** Groups render first as one row each (disclosure chevron, category dot, name,
  subtitle, count). The candidate group renders **collapsed to its top 5** with `Show N more` — in the
  shipped build 25 near-identical candidate rows push every category off-screen.
- Collapsed normals row stays at the bottom (`N beats coded normal — show all`).

### Launch state — no record open

Option `12a`. **The frame never moves.** Every region above is present at its final size with axes, lane
rows, labels and controls drawn; only values are blank (em-dash) and marks absent. Specifically:

- Both side panes are **closed** at launch; their toolbar toggles render in the off state.
- All toolbar items are present with their real SF Symbols, disabled at ~32% opacity. `ellipsis.circle`
  stays enabled (Open Record Folder…, Customize Toolbar…). No item appears or disappears on load.
- The waveform viewer shows an **unhooked flatline** — a near-zero baseline with faint mains noise. Beneath
  it sits one quiet inline line, no card, border or shadow: *No record open · Open Record Folder… ⌘O*. The
  same action is reachable from File ▸ Open Record Folder, the `ellipsis.circle` toolbar menu, and the
  record navigator when the sidebar is shown.
- The trend stack renders all five lane rows with their accent rails, label columns, y-axis ticks and
  gridlines; plots are empty and values are em-dashes. The context region scrolls exactly as it does when
  loaded.
- **Import progress** is one global progress bar in the info bar — record name, bar, `N of M records · P%`.
  This is the only chrome that changes state between empty and loaded.

## Interactions & behavior

- **Pan / zoom** — drag pans all channels in lock-step, pinch/⌘-wheel and `+`/`-` zoom, arrows pan one
  viewport (existing `BedsideView` handlers). New: the zoom ladder sets the viewport width directly, and
  clicking any band or trend lane recenters the trace at that time; ⌥drag on a band or lane zooms to the
  dragged range.
- **Window hold** (`pin.fill`) keeps the viewport at 10 s so finding jumps recenter without re-zooming;
  a manual zoom releases it. Unchanged.
- **Findings navigation** — `J`/`K` next/previous filtered finding, `[`/`]` by departure, disposition
  shortcuts gated on the Editing latch. Unchanged.
- **Notes** — `⌘⇧N` toggles the drawer; `⌥J`/`⌥K` step between notes; row click moves the trace to the
  note's anchor; `New note` seeds the current window as the anchor. Typing autosaves (0.6 s debounce);
  re-locking Editing flushes. Notes are editable only while Editing is unlocked.
- **Scope switch** on the metrics block recomputes the stat clusters for whole record / visible window /
  hovered-or-selected hour. The trend lanes always show the whole record regardless of scope.
- **Empty and unavailable states** — keep the shipped ones: `Interval trend unavailable — no fiducials in
  this recording`, `No metric samples in this window`, `no data` for trend channels,
  `No analyst notes yet. Unlock the toolbar lock to add some.`, `Select a record`. A lane with no data
  collapses to a one-line row rather than drawing an empty chart.

## State

Existing state to reuse: `RecordingViewport`, `Calibration`, `FindingFilter`, `DispositionStore`,
`VTVFCandidateDispositionStore`, `IntervalMarkingsContext`, `IntervalTrendLaneContext`,
`IntervalTrendGuideStore`, `VariabilityLaneContext`, `VariabilityMetricsContext`, `QualifyingWindowContext`,
`SessionFlagStore`, `TimeDisplayContext`, `isEditing`, `windowLockedTo10s`, `layoutMode`,
`navigatorVisibility`, `showFindings`.

New state this design implies:

- `notesDrawerExpanded: Bool` (persisted per app, not per record).
- `selectedNoteID` + a note collection with anchors (see below).
- `metricsScope: .wholeRecord | .visibleWindow | .hour(Int)`.
- `zoomLadderStep` — derived from the viewport, not a second source of truth.
- `visibleTrendLanes: Set<LaneID>` for the `Lanes ⌄` menu.

## New capabilities (need a decision before implementation)

The design draws these; they do **not** exist today and are badged `NEW` in the file:

1. **Time-anchored notes.** `RecordContextPanel` today stores exactly one Markdown document per record at
   `<bundle>/notes.md`. The list, search, stepper, per-note anchors and durations all require a storage
   change — either YAML front-matter/heading convention inside `notes.md`, or a sidecar
   `notes.json` alongside the existing dispositions files. Recommendation: sidecar JSON keyed on sample
   range (same pattern as `VTVFCandidateDispositionStore`, which keys on time region so it survives a
   rescan), with `notes.md` kept as the record-level document.
2. **Notes in exports.** `MarkdownReport` carries findings and dispositions only; notes are not included,
   and `notes.md` does not travel in the `.mur` session package. The "Include in exported report"
   checkbox and any session round-trip are new work.
3. **Rolling LF/HF lane.** Today LF/HF is one whole-record number from a single Lomb–Scargle window.
   A per-5-min series is a new computation, and it belongs to the paid measurement layer — check
   `PurchaseStore` gating and the RUO notice policy before surfacing it.
4. **Note ticks on the record band** — `OverviewMap` needs a second tick layer.
5. **A Notes toolbar glyph** — must be unique per the `ToolbarGlyph.all` uniqueness test.

## Policy constraints (do not violate)

- **No built-in clinical cutoffs.** Reference lines on the interval trend lane are analyst-placed only
  and empty by default. The `normal 386` baseline is *this patient's* template, derived from
  annotator-coded normal beats — label it as such, never as a threshold.
- **Facts, not verdicts.** Burden lines, counts and bin values are stated plainly. No "abnormal",
  "drifting", "concerning" wording anywhere.
- **RUO surfaces stay.** Model candidates keep `RESEARCH USE ONLY — not for diagnosis` and their
  operating-point caption; candidate ranking never merges into departure ranking.
- **Provenance is not decoration.** The lane captions (template size, span, measured-in lead, exclusion
  counts) are part of the design; do not trim them to save space.
- **Glyph uniqueness.** Every toolbar symbol stays distinct — see the X60 notes in `ToolbarGlyphs.swift`.

## Design tokens

Wireframe values are placeholders except where noted as semantic.

- **Layout**: navigator 230 pt · inspector 340 pt · stage right column 186 pt · trend-lane accent rail 4 pt ·
  trend-lane label column 114 pt · y-axis gutter 30 pt · trend-lane value column 66 pt · toolbar 46 pt ·
  info bar 28 pt · notes drawer body 214 pt · lane heights 86 / 86 / 104 / 86 / 26 pt.
- **Spacing**: 4 / 6 / 8 / 10 / 14 pt. Region padding 14 pt horizontal, 8–10 pt vertical.
- **Radii**: 6 pt for controls and cards, 5 pt for chips, 11 pt for pills, 13 pt for the search field.
- **Type**: system only. ~13.5 pt semibold section titles, 12 pt body, 11 pt controls, 10.5 pt secondary,
  9.5 pt captions/labels. Numeric readouts use monospaced digits. Nothing below 9.5 pt.
- **Semantic colors** (map to the existing palettes, keep the meanings): accent = current window /
  selection / active preset; ventricular = existing `CategoryPalette` V hue; candidate/model = the
  existing candidate hue; grey = excluded bins and low-quality stretches; the `NEW` badge tint is a
  design-file annotation only and must not ship.

## Assets

None. All glyphs are SF Symbols already named in `ToolbarGlyphs.swift` (plus one new Notes symbol to
choose). Waveforms in the design file are placeholder paths — the real trace is the existing Metal
renderer.

## Files in this bundle

- `ECG Analyst Wireframes.dc.html` — all design options; `11a` is canonical. Open in a browser.
- `support.js` — runtime the HTML file loads; keep it beside the HTML.
- `README.md` — this document.
- `screenshots/11a-main-window.png` — the canonical window.
- `screenshots/12a-launch-state.png` — launch state, no record open.
- `screenshots/13a-trend-stack.png` — canonical trend-stack rendering.
- `screenshots/10a-trend-stack.png` — earlier trend stack, superseded; caption wording only.
- `screenshots/9a-window-notes-open.png` — the window with the Context drawer expanded.
- `screenshots/8a-notes-drawer.png` — Context drawer detail (list, stepper, anchored editor, autosave).
