# Murmur — Roadmap

A macOS SwiftUI app for a cardiologist/researcher investigating a large,
suspect physiologic recording — hours to days of high-frequency signal
they open precisely because they have high suspicion it contains
irregularities they want to understand. Murmur supports that
investigation: load large waveforms, learn the patient's own "normal,"
surface and navigate deviations from it, and mark up findings toward
observation and publication. NOT a bedside monitor; NOT an autonomous
diagnostic system — the analyst adjudicates; the tool measures, proposes,
and supports.

The PhysioNet WFDB record (`.hea` + `.dat`) is the substrate. Findings —
whether upstream-producer output or analyst-authored — are the primary
data surface; the waveform is the context that gives each finding meaning.

## Current state (updated 2026-08-19)

**Live on the Mac App Store (2026-08-19)** — version 1.3 went
READY_FOR_SALE with the **Murmur Pro** in-app purchase approved
alongside it ($299.99, non-consumable,
`com.kevinlong.murmur.studio`). Store metadata (six screenshots,
promotional text, description, keywords) and the docs site were
refreshed to match the shipped product the same day.

**Single-IAP pivot** — the three per-module IAPs planned below
(Annotation Authoring / ECG Metrics / VT-VF Detection) were collapsed
into one all-inclusive **Murmur Pro** purchase before launch. The
three private frameworks still exist and still conform to the same
seams; they unlock together behind the one entitlement
(`PurchaseStore.hasStudio`). The per-module product IDs were retired
in App Store Connect. Sections below that describe three separate
IAPs are historical record of the plan, not the shipped model.

**Shipped since the 2026-07-04 entry** (each landed with its own PR
write-up — the provenance chain lives in the merged PRs):

- **Calibrated paper (X40)** — Standard View (25 mm/s · 10 mm/mV),
  gain/speed preset ladder, honest actual-scale seam, calibration
  lock across zoom.
- **Arrhythmia scan** — in-app VT/VF candidate episodes plus
  rhythm-event candidates (AF, pauses); recall-biased, user-adjustable
  τ dial persisted per session; "candidates, not detections" framing
  with RUO badges throughout.
- **Morphology (X112)** — whole-record beat clustering with
  representative shapes, analyst endorsement as the only path to a
  baseline ("the algorithm clusters; the analyst classifies"),
  endorsements persisted in the session document.
- **Annotation authoring** — right-click note/finding authoring and
  drag-to-author range findings under the Editing latch, persisted
  with the session.
- **Session documents + exports** — portable `.mur` session (⌘S),
  WFDB annotation export, citable report export.
- **QT uncertainty wire-up** — calibrated per-beat CI half-widths on
  QT/QTc (calipers show `±X ms`; censored T-offsets render as lower
  bounds), quality gates echoed as chips on the QTc trend lane.
- **Performance overhaul (task list #8–#18, PRs #310–#318)** — scroll
  stalls on 100k-beat records went from multi-second to sub-frame:
  FindingsPanel Equatable isolation, hover quantization, derivation
  memoization, LZFSE-compressed derived caches (13× smaller), launch
  sweep of unreusable recording bundles.
- **Launch shell** — the persistent bedside shell replaced the
  welcome card; every surface exists idle at launch ("Try a sample
  recording" is now DEBUG-only, #242).

Test suite at launch: **1012 unit + 187 UI**. Remaining open
workstreams: remote model updates (IAP Phase 4 below — not started),
citation routing Phases B–D, and the PhysioNet directory listing.

---

## Historical state (2026-07-04 entry and earlier)

**Persistent-stage redesign (2026-07-04)** — the ECG canvas + docked
beat inspector + one-map overview now pin at the top of the center
column; findings review queue + variability lane + interval trend
lane scroll around them. `FindingsPanel` is a deviation-ranked review
queue (Departure sort default; groups with human labels + provenance;
collapsed normals row; rhythm-context banner). `OverviewMap`
supersedes the old `OverviewRibbon` + `FindingDensityTimeline`.
`IntervalTrendLane` + `IntervalTrendComputer` + `IntervalTrendGuideStore`
land the third view of the one fiducial store (QTc/Fridericia 2-min
bins by default; median + IQR ribbon; user-set threshold guides;
event overlay from analyst-authored point annotations). Annotation
severity removed from the model — app-asserted severity is a
clinical verdict that breaks the RUO stance; the wire format still
decodes-and-drops `severity` for back-compat.

**Project rename (2026-06-18)** — `Plotting` → `Murmur` across Xcode
project, sources, docs, and GitHub repo. First-launch migration in
`RecentFoldersStore` and `RecordingStore` carries the legacy
UserDefaults key and Application Support recordings subtree forward
so existing analyst data stays intact.

**Analyst disposition workflow**
- `AnnotationDisposition` + `DispositionFile` schema-versioned sidecar at
  `<bundle>/dispositions.json`. Three logical states — `unreviewed`
  (implicit by absence), `confirmed` (with optional VT/VF sub-kind), and
  `dismissed`. Re-running the producer never overwrites analyst work.
- `DispositionStore` is the `@Observable` source of truth: reads the
  sidecar at recording load, writes on every `confirm` / `dismiss` /
  `reset`. Mutations require the toolbar's `Editing` latch (same lock
  semantics as notes editing).
- `FindingsPanel` exemplar rows show inline confirm/dismiss/reset
  controls when unlocked; dismissed rows dim to ~55% opacity. The
  panel header shows a `To review · Confirmed · Dismissed` triage
  tally.
- `FindingsSummaryHeader` total chip (rendered in the scrolling
  context under the pinned stage) carries the same tally so analyst
  progress is visible even when the inspector is hidden.
- `OverviewMap`'s expanded per-category lanes dim dismissed events
  to ~30% and outline confirmed events with a green ring, so triage
  state is scannable at the full-recording level.

**Quality shading**
- `QualityStrip` — one heat band per quality / artifact-ratio channel
  (the Medallion `ecg_artifact_ratio` is the canonical case). Each
  1-min cell renders as gray with opacity proportional to the ratio;
  cells over the configurable threshold (default 0.1, per Medallion's
  suggested floor) gain a thin orange outline for quick scan.
- Routed via `LowRatePartition` by name pattern (`_ratio` suffix or
  `artifact_ratio` substring), so future quality channels (PPG, etc.)
  surface without code changes.

**Alarm & ventilation state strips**
- `BooleanChannelScanner` — pure utility that turns a boolean-ish trend
  channel (alarm flag, status indicator) into `[ClosedRange<Int64>]`
  active spans. NaN is inactive; threshold is configurable.
- `AlarmStrip` — one thin lane per alarm channel (`had_high_priority_alarm`,
  `had_suction_alarm`, `nebulizer_status`, `had_alarm_silenced`, …)
  spanning the full recording. Active runs render as colored bars at the
  appropriate fractional position; tapping any bar jumps the viewport.
- `StateBackdropStrip` — one-row colored band driven by the Medallion GMM
  state probability pair (`prob_state_spontaneous` +
  `prob_state_assist_control`). Each 1-min cell colored by the dominant
  state with opacity tracking certainty. Tap to jump.
- `BedsideView.LowRatePartition` routes low-rate channels by name into
  vitals (sparkline trend strip), alarms (alarm strip), and the state
  pair (backdrop strip). Each strip renders only when its inputs exist —
  plain ECG records show none of the new chrome.

**Multi-frequency WFDB + low-rate trends**
- `WFDBHeaderParser` honors the per-signal `format[xspf]` suffix, so a
  record can mix 250 Hz ECG signals (`16x250`) with 1 Hz feature signals
  (`16x1`) at one base frame rate. `WFDBHeader.sampleRate(for:)` /
  `sampleCount(for:)` expose per-signal values.
- `WFDBSampleDecoder` groups signals by `.dat` filename and opens each
  file exactly once. Each file may hold one signal (per-signal files —
  the path the Medallion feature store will use) or several at the same
  rate (legacy single-file records).
- `Channel.isTrendChannel` (`sampleRate < 5 Hz`) lets `BedsideView`
  partition channels: ECG goes on the Metal canvas, low-rate trends go
  to `ChannelTrendStrip` — stacked Swift Charts sparklines below the
  canvas, time-locked to the shared `RecordingViewport`. The strip is
  hidden entirely when the recording has no trend channels.
- `SyntheticRecording.makeMultiFrequencyRecord(into:)` builds a per-
  signal-file fixture (8 ECG + fake HR + fake SpO₂) so the welcome
  screen demo exercises the new path.

**Triage surfaces**
- `AnnotationSummary` — pure aggregation over `[Annotation]` that rolls
  each category up into counts and total range extent. Sorted by count.
- `FindingsSummaryHeader` — compact horizontal chip row above the
  canvas: `PVC 47 · AFib 38s · VT 3`. Click a chip to toggle the shared
  `FindingFilter` for that category.
- `OverviewMap` (retired `OverviewRibbon` + `FindingDensityTimeline`
  2026-07-04) — one compact density strip pinned with the trace,
  colored ticks per annotation + viewport indicator + click-to-scrub.
  Expand chevron reveals per-category lanes underneath for the
  category-drill navigation the old timeline provided.

**Welcome screen**
- `WelcomeView` is the first-launch experience: a centered card on a
  faint ECG-paper backdrop with the app name, a one-line tagline, three
  feature bullets, and primary / secondary actions.
- **Open Record Folder** opens the file picker (same as the toolbar
  action). **Try a sample recording** synthesizes a small 8-lead WFDB
  fixture on demand via `SyntheticRecording.makeFixture()` so a
  first-launch user has an instant on-ramp.
- **Recent folders** — `RecentFoldersStore` persists up to ten
  security-scoped bookmarks to `UserDefaults` and exposes them as
  clickable rows under the card; remove (✕) drops a single entry.
- **Drop a folder** anywhere on the welcome view to open it (or any
  file in a record folder — the welcome view promotes a file drop to
  its enclosing folder).

**Bedside layout**
- `LeadChipBar` across the top of `BedsideView` with a per-lead color chip
  and a Focus / Strips segmented control. Focus mode shows a single tall
  panel for the selected lead; Strips mode stacks every lead vertically.
- `RecordContextPanel` — top-of-view summary block that surfaces `.hea`
  header comments (recovered from the original WFDB file) and a Markdown
  `notes.md` editor that lives next to the recording bundle.
- Read/write latch toolbar toggle (lock / lock.open) gates notes editing
  and is wired to gate future annotation create/edit/delete affordances.
- Window adaptability: narrower sidebar (160 pt min), narrower inspector
  (220 pt min), wrapped summary text, and a reduced canvas minimum so the
  app collapses cleanly to a small window.

**Annotation model (the wow factor)**
- `Annotation` — `kind` (point/range), `category`, optional `label`,
  `confidence`, `source`, optional `note`, `lead`,
  `evidenceContextSeconds`. (Severity was removed 2026-07-04 — an
  app-asserted severity is a clinical verdict that breaks the RUO
  stance; the wire format still decodes-and-drops `severity` for
  back-compat.)
- `AnnotationFile` JSON wire format (`schemaVersion: 1`) is the canonical
  ingest path. Timestamps accept either `startSample`/`endSample` (already
  aligned) or `startUnixMS`/`endUnixMS` (viewer resolves at import).
- WFDB `.atr` is a legacy adapter — beat letters become point annotations
  tagged `source = "wfdb.atr"`.
- Importer scans `<recordName>.annotations.json` first, then `.atr`/`.qrs`,
  concatenating both.
- `Recording` decode is back-compat: legacy manifests with
  `[WFDBAnnotation]` arrays still load and get adapted on the fly.

**Findings UI (review queue, 2026-07-04)**
- Right-side `inspector` rail = `FindingsPanel`, a deviation-ranked
  review queue. Default sort is Departure (magnitude of QTc / QRS /
  QT vs `IntervalMarkingsContext.template`); Time / Confidence /
  Category available via the sort menu chip.
- Rows are grouped by category with a human label
  (V → "Ventricular ectopy", A → "Atrial premature", `"` →
  "Annotator comment", etc.) + provenance (`source`). Each group is
  collapsed by default; click to reveal up to 6 exemplar rows,
  sorted by departure. `--ui-test-expand-all-findings-groups`
  launch arg auto-expands for XCUI tests.
- Categories mapping to N / NORMAL / SINUS collapse into a single
  dashed "beats within template" row at the bottom — the mass the
  analyst opened the tool to escape.
- Rhythm-context banner at the top surfaces
  `recording.headerComments` verbatim as the session frame.
- Filter chips: Category (multiselect menu) + Confidence (≥ 0 / 50 /
  75 / 90). The same filter narrows the pinned `OverviewMap`.
- `CategoryPalette` — hand-tuned colors for common clinical categories
  (reds = ventricular, purples = atrial, blues = conduction, slate =
  noise), with deterministic FNV-1a → HSV fallback for unknown categories.

**Waveform Canvas — Metal**
- `MTKView` via `NSViewRepresentable`. Per-frame: clear paper → range fills
  (one bucket per category) → grid minor → grid major → grid landmark →
  trace OR pyramid envelope → point rules (one bucket per category).
- Shaders: `traceVertex`, `lineVertex`, `envelopeVertex`, `rangeVertex`,
  `colorFragment`. Trace is now a triangle-strip polyline — each sample
  extrudes to a 2-vertex ribbon and the vertex shader computes the
  perpendicular in screen-pixel space, so line width stays constant in
  points regardless of zoom (Metal has no `glLineWidth` equivalent).
- Annotation buckets group by `(category, kind)` so each category gets its
  own color in a single instanced draw call. Alpha is constant per kind
  (0.85 for point rules, 0.45 for range fills).
- SwiftUI overlays for axis tick labels (time + mV), annotation symbol
  text, and an off-scale chevron overlay driven by `ClippedRangeScanner`
  (▲/▼ markers at the canvas edge where the signal clipped above/below).
- Overview ribbon stays Swift Charts — tiny widget, click/drag scrub.

**Data engine**
- `BinaryRecordingFile` v2 — 64-byte header + packed Float32 body.
- `MappedSampleAccess` + `PyramidLevelFile` — mmap-backed reads.
- `PyramidBuilder` — single-pass cascading min/max bins (stride 10, up to
  6 levels).
- `ChannelView` — LOD-aware reader; `selectLevel(samplesPerPixel:)` returns
  raw or the deepest fitting pyramid level.
- `RecordingViewport` (`@Observable @MainActor`) — shared time window for
  every lead, with `pan` / `setStart` / `setWidth` / `jump` clamped to
  bounds and a 100 ms minimum window.

**Ingest + sandbox**
- File picker selects a *folder*; security scope covers all files inside.
- `WFDBHeaderParser` supports format 16 and 212 (MIT-BIH style); baseline
  defaults to `adcZero` per WFDB spec.
- `RecordingStore` async import on background task; per-record import cache
  in `ContentView` so switching records is instant after first import.

**ECG paper grid**
- `ECGGridSpec.forDuration(seconds:)` picks adaptive minor / major /
  landmark spacings per zoom level so the grid stays readable from 1 s to
  multi-hour windows. Landmark is always 5× the major — the "1 s / 2.5 mV"
  reference line on standard ECG paper.

**Ingest extras**
- `WFDBHeaderParser` preserves `#`-prefixed comment lines verbatim and
  threads them through the importer onto `Recording.headerComments`.
- `WFDBImporter` copies any sibling `notes.md` from the source folder into
  the imported bundle and records its filename on the manifest so the
  context panel can read/write it.

**Tests** — 346 total (287 unit + 59 UI) as of this 2026-07-04 entry;
**1012 unit + 187 UI at the 1.3 launch.** Suite has grown ~135 → 346
across the App-Store-rejection fix, the open-core architecture work
in `758b040`, the producer-pipeline coverage, and the bypass-test
push to 100% interaction coverage.

## Architecture

Three layers as agreed; all three now built:

1. **Data Engine** — mmap + pyramid + LOD selector + viewport.
2. **Waveform Canvas** — Metal (MTKView) rendering paper, grid, trace,
   envelope, point + range annotations.
3. **Control Overlay** — SwiftUI for axes, annotation symbols, gestures,
   findings panel, filter chips, toolbar.

## Next goals

### Near-term (next session)
- [x] "Attach findings…" toolbar action — pick a JSON from anywhere and
      merge into the current recording's annotations (was: folder-scan
      only). New ToolbarItem invokes a fileImporter; on pick,
      `AnnotationLoader.parse` validates and resolves timestamps, the
      findings join `attachedAnnotations`, and the union is persisted to
      the bundle's `annotations.json`.
- [x] Persist annotations separately from `recording.json` as
      `annotations.json` so re-running the analysis cluster doesn't require
      re-importing the .dat samples. New `BundleAnnotationsFile`
      sidecar (schemaVersion 1 + annotations array) written by the
      importer at import time and re-read by
      `RecordingStore.loadManifest`, which overrides
      `recording.annotations` with the sidecar when present.
- [x] Schema versioning — delivered as `docs/annotations.schema.json`
      (a JSON Schema Draft 2020-12 document) plus an updated
      `docs/annotation-schema.md` with validator recipes for Python,
      Node, and Swift. Published at
      `https://kvnlng.github.io/Murmur/annotations.schema.json` so
      producers can validate output against the canonical contract.
- [x] Mini-timeline ticks under each channel overview ribbon — colored
      ticks for every finding at its fractional sample position, drawn
      between the envelope and the viewport indicator. Points are
      minTickPx wide; ranges scale proportionally. Color from
      CategoryPalette so the ribbon and canvas share the visual story.
- [x] Hover tooltips on the canvas — `.onContinuousHover` hit-tests for
      the nearest finding (ranges that strictly contain the hover sample
      first, then point findings within a 6pt tolerance) and floats a
      small panel with the category, time, confidence, source, and the
      producer's note.

### Canvas polish (deferred from the Metal upgrade pass)
- [x] MSAA 4× on the waveform canvas. First attempt crashed at first
      open with the Metal validation error
      `resolveTexture must have storeAction of .multisampleResolve`.
      Root cause: when `MTKView.sampleCount > 1`,
      `currentRenderPassDescriptor` comes back with a `resolveTexture`
      pointing at the drawable and a store action of
      `.multisampleResolve`, but the renderer's `draw(in:)` was
      overriding `storeAction = .store` unconditionally. Fix: pick the
      store action based on whether the descriptor has a
      `resolveTexture` (`.multisampleResolve` if yes, `.store` if no).
      That preserves the non-MSAA path and unlocks MSAA in one branch.
      `framebufferOnly` stays `true` (only the drawable is affected,
      and the resolve target only needs the renderTarget usage flag).
      Pipeline state's `rasterSampleCount = 4` must match the view's
      `sampleCount` or Metal validation rejects the pipeline.
- [x] LOD crossfade — `WaveformRenderer.beginLODTransition()` snapshots
      the current state (useEnvelope + sample buffer + pyramid buffer +
      binSamples), stores a `lodTransitionStart` timestamp, and for
      ~150 ms `draw(in:)` renders both the previous and the current
      paths with complementary alphas. No shader changes needed —
      `colorFragment` already takes its alpha from a uniform color set
      via `setFragmentBytes`, so modulating that per draw call is
      sufficient. The renderer asks for redraws via
      `view.setNeedsDisplay(view.bounds)` during the window since the
      MTKView is `enableSetNeedsDisplay`-driven. Coordinator.selectLOD
      kicks off a transition any time `useEnvelope` flips or
      `loadedPyramidIndex` changes.

### Quality infrastructure
Driven by yesterday's canvas-polish back-and-forth: events were firing
correctly the whole time but the visual symptom only manifested at
runtime, so we burned cycles on round-trip diagnostics. Better tests
would have caught the regressions in CI.

See `docs/interaction-coverage.md` for the catalog of every analyst-facing
interaction with its test status. **Current score: 29 ✅ automated /
0 🟡 manual-only / 0 ⬜ uncovered out of 29 (100% automated)** as of
2026-06-27, achieved via bypass tests in `MurmurUIBypassTests` that
exercise post-system-modal code paths via launch args.

**Phase 1 — make existing patterns testable (✅ DONE)**
- [x] Launch arg `--ui-test-zoomed-sample` that opens the synthetic
      fixture with a 1-second viewport. Implemented in
      `UITestSupport.swift` + consumed by `BedsideView`.
- [x] Launch arg `--ui-test-hover-at=x,y` that drives the same
      `hoverLocation` update closure `HoverTrackingView` uses,
      bypassing macOS `XCUICoordinate.hover()` flakiness.
- [x] Accessibility-element refactor across key SwiftUI containers
      so XCUI can address nested Text elements like the time-window
      label.
- [x] XCUI coverage written against the new hooks — drag pans,
      hover crosshair, finding-row jump, attach-findings flow,
      window-resize minimum, lock toolbar gating, plus the bypass
      suite that pushed total coverage to 100%.

**Phase 2 — Xcode Cloud workflow (1 session)**
- [x] Setup walkthrough captured in `XCODE_CLOUD.md` at the repo root.
      Two workflows specced:
      - `Test on main` — runs on every push, matrixed across the
        macOS versions our deployment target supports
      - `Archive on tag` — runs on `v*` tags, ships to TestFlight
        Internal Testing automatically
- [x] `RELEASE.md` updated to use `git tag` as the primary release
      entry-point once Xcode Cloud is wired (manual archive/upload
      retained as fallback)
- [x] User-action: Xcode Cloud workflow set up via App Store Connect.
      Both `Test on main` and `Archive on tag` workflows are running.
      Setup gotchas (Package.resolved tracking, plugin trust dance
      before SwiftLint was moved off SPM, re-tag triggers) captured in
      `project_xcode_cloud_setup_quirks` memory.

**Phase 3 — snapshot tests for SwiftUI overlays (✅ DONE)**

Decision recorded: instead of disabling Debug sandbox, we're splitting
Murmur into a slim app target + a MurmurCore framework. Tests link
MurmurCore directly, escape the sandbox permanently, and we get a
modular architecture that's also ready for the upcoming ML/inference
work (separate MurmurInference framework, FindingProducer protocol).
See Phase 4 below.

- [x] `MurmurTests/SnapshotTests.swift` covers the pure-data overlays:
      `AnnotationTooltip` (point + range), `WaveformTimeAxis` (default
      10s + zoomed 60s), `WaveformVoltageAxis`,
      `OverviewMap` (mixed categories; retired
      `FindingDensityTimeline` at the same time),
      `FindingsSummaryHeader` (empty state)
- [x] `swift-snapshot-testing` 1.18.x attached to MurmurTests target
- [x] MurmurCore framework split: tests escape host-app sandbox,
      snapshot reads + writes work end-to-end
- [x] Baselines recorded under `__Snapshots__/SnapshotTests/`. Rendering
      goes via `ImageRenderer` (SwiftUI-native) — NSHostingView leaves
      `GeometryReader`-rooted views blank.
- [x] 7/7 snapshot tests pass clean; full suite 202/202
- [ ] Pin snapshot tests to "Latest Release" only in Xcode Cloud
      matrix — SwiftUI metrics drift across macOS versions.
- [ ] Deferred (separate task): snapshot coverage for `FindingsPanel`,
      `AlarmStrip`, `QualityStrip`, `StateBackdropStrip`. The three
      strips read channel files from a `recordingDirectory: URL`, so
      they need a disk-backed test fixture before they can be
      snapshotted. `FindingsPanel` also needs a `DispositionStore`
      stand-in.
- [ ] Deferred: `FindingsSummaryHeader` mixed-findings (chip row)
      snapshot. The chip row lives inside a horizontal `ScrollView`
      and `ImageRenderer` measures ScrollView intrinsic size as zero
      → blank output. Would need a non-Scroll test variant or a
      different render strategy. Density-timeline snapshot exercises
      chip color rendering as a proxy.
- [x] Skip the Metal canvas itself — pixel diffs across GPUs/MSAA are
      unreliable; rely on the surrounding SwiftUI for visual
      regression coverage

**Phase 4 — MurmurCore framework split + FindingProducer protocol**

Memory file `project_murmurcore_architecture.md` has the full rationale.

Target layout after this phase:
- **Murmur (app)** — slim launcher: `MurmurApp.swift`, Help menu,
  Info.plist, Assets.xcassets (AppIcon). Sandboxed.
- **MurmurCore (framework)** — everything else: views, models, file
  I/O, viewport, render, `FindingProducer` protocol. Pure-Swift, no
  heavy deps. Linked by both the Murmur app and MurmurTests.
- **MurmurInference (framework, future, NOT in this phase)** —
  concrete `FindingProducer` impls wrapping LibTorch / CoreML. Added
  when ML work begins.

Tasks:
- [x] MurmurCore framework target created
- [x] All Swift files except `MurmurApp.swift` moved to MurmurCore
      target membership. `Assets.xcassets` and `Info.plist` stay in
      the Murmur app target.
- [x] MurmurCore embedded in the Murmur app target
- [x] `ContentView` made `public` (struct + `init()` + `body`) so
      MurmurApp can construct it across the framework boundary
- [x] MurmurTests links `MurmurCore.framework` directly; `TEST_HOST`
      and `BUNDLE_LOADER` cleared. Test process runs as standalone
      xctest binary — no sandbox.
- [x] Test imports updated to `@testable import MurmurCore`
- [x] Build clean + all 202 tests pass (including the 7 snapshot
      tests that were previously skipped behind `RUN_SNAPSHOT_TESTS=1`)
- [x] `RecentFoldersStoreTests/resolvesBookmark()` fix:
      `resolvingSymlinksInPath()` on both sides — needed because the
      bookmark API now returns the canonical `/private/var/folders/`
      form once the test process escapes the sandboxed host.
- [x] **`FindingProducer` protocol design + `SyntheticFindingProducer`
      first conformance.** Landed in commit `758b040`. Final shape:

  ```swift
  protocol FindingProducer: Sendable {
      var id: String { get }
      var displayName: String { get }
      func analyze(_ recording: Recording) -> AsyncThrowingStream<ProducerEvent, Error>
  }

  enum ProducerEvent: Sendable {
      case progress(ProgressUpdate)
      case findings([Annotation])
      case warning(message: String, underlying: Error?)
  }
  ```

  Design decisions resolved (recorded in `FindingProducer.swift`):
  - **Async** — `AsyncThrowingStream<ProducerEvent>` rather than
    sync-returning `[Annotation]`.
  - **Streaming** — events interleave progress + finding batches
    + per-window warnings, so the UI shows partial results as
    scanning advances.
  - **Cancellation** — consumer cancels the `Task`; producers
    MUST call `try Task.checkCancellation()` on window boundaries.
  - **Error semantics** — per-window failures emit `.warning`
    events and the run continues; only fully-irrecoverable
    errors throw and terminate the stream.
  - **Confidence calibration** — producer's responsibility;
    `Annotation.confidence` is documented as already calibrated.
  - **Registry** — `ProducerRegistry` actor (entitlement-unaware);
    IAP gating filters at the call site against `PurchaseStore`.
  - **Synthetic producer** — single `SyntheticFindingProducer`
    with `seed` parameter; doubles as demo + deterministic test
    fixture.

  Still TODO: protocol + supporting types are currently `internal`;
  promote to `public` (alongside `Annotation`, `Recording`, `Channel`)
  when the paid framework targets land so out-of-module conformers
  can construct findings against them.

  Remaining implementation tasks:
  - [x] Define protocol + ProgressUpdate + ProducerRegistry in MurmurCore
  - [x] `SyntheticFindingProducer` first conformance
  - [x] `ProducersPanel` UI consumes the stream (progress + findings)
  - [ ] Wire producer-emitted findings into the existing
        `FindingsPanel` alongside sidecar annotations (same UI path —
        just different `source` field on each annotation)
  - [ ] Test coverage: producer registry roundtrip, cancellation,
        progress emission, deterministic synthetic output
  - [ ] Update memory `project_murmurcore_architecture.md` to
        reference the shipped protocol shape
- [x] Cleanup: `MurmurCore/MurmurCore.swift` stub deleted;
      `MurmurCoreTests/MurmurCoreTests.swift` slimmed to imports +
      header comment (target reserved for future MurmurInference-style
      isolated unit tests).

### Medium-term
- [x] Lead-specific findings — `Annotation.matchesChannel(_:)` +
      `BedsideView.annotationsForChannel(_:)` route lead-tagged
      findings only to matching channels; lead-less findings show
      everywhere.
- [x] Finding sorting modes — deviation-ranked review queue exposes
      Departure (default), Time, Confidence, Category via the sort
      menu chip in the queue rail.
- [x] Keyboard navigation — arrows pan by one viewport width, `=`/`+`
      and `-` zoom around centre, J/K step through filtered findings,
      `[`/`]` step through deviation-ranked beats, C/D/X apply
      confirm/dismiss/reset dispositions (all in `BedsideView.onKeyPress`).
- [x] Per-channel y-axis autoscale — `autoscaleY` toggle on
      `ChannelPanel` derives the display range from the scanned
      `sampleRange` with 10% headroom; falls back to ±5 mV clinical
      reference when off.
- [ ] Beat clustering at low zoom — collapse adjacent points of the same
      category into a single hit-counter mark when they overlap
- [x] Snapshot export — `SnapshotExporter.swift` + toolbar action
      capture the current bedside as PNG with grid + findings.

### Deferred
- [ ] Multi-file WFDB records (per-signal `.dat`)
- [ ] Additional WFDB sample formats (8, 16+, 24, 32, 310, 311, 80)
- [ ] Export imported recordings to a portable bundle
- [ ] HDR/wide-color-gamut Metal canvas
- [ ] Two-finger trackpad swipe → pan via an NSScrollView bridge

*(Annotation authoring moved out of Deferred 2026-06-28 — now a paid
IAP under the open-core split below.)*

## Paid features roadmap (open-core + IAPs)

> **Status 2026-08-19 — shipped, with one structural change.** The
> open-core model shipped, but as a **single all-inclusive purchase**
> (Murmur Pro, $299.99) rather than three per-module IAPs — renaming
> or splitting product IDs after purchases exist would orphan buyers,
> so the pivot happened before launch. Phase 0 ✅, Phase 1 (metrics)
> ✅, Phase 2 (authoring) ✅, Phase 3 (VT/VF scan) ✅ — all live under
> the one entitlement. **Phase 4 (remote model updates) is not
> started** and is the main open item in this section. The phase
> descriptions below are kept as the historical plan; per-phase
> status notes mark what shipped differently.

Strategic pivot recorded 2026-06-28: the app becomes an **open-core
product**. The viewer is a free, MIT-licensed, open-source native
macOS WFDB tool; three paid IAPs ride on top as research/commercial
extensions. The base v1.0 review experience stays free and unchanged
after the IAPs land — paywalls are *additive*, never gate anything
users already had. None of this applies to the v1.0 build currently
in App Store review.

### Open-core distribution model

- **Murmur Studio (free, open source, MIT)** — read-only viewer:
  WFDB import, finding display, filter chips, viewport, disposition
  workflow (confirm/dismiss/reset of upstream findings is
  *consumption*, stays free), all rendering and UI chrome.
- **Annotation Authoring IAP (paid)** — manual annotation create /
  edit / delete. *Consuming* upstream findings is free; *creating*
  new findings is where research labor concentrates and where
  labs/PIs will pay.
- **ECG Metrics IAP (paid)** — Standard ECG analytic measures over
  any recording, presented as TIME-RESOLVED rolling trajectories
  aligned under the waveform, not single whole-recording numbers
  (direction pivot 2026-07-03 — supersedes the shipped recording-wide
  summary approach; see planning design specs). Default rolling RMSSD
  over a 5-min window; RR-interval statistics; interval measurements
  (PR/QRS/QT/QTc, Fridericia default); frequency-domain HRV. Pure Swift
  (Accelerate / vDSP where it helps). Deterministic, reviewable, no
  regulatory exposure — surfaces engineered measurements, not
  diagnoses. Ships first per stagger-risk.
- **VT/VF Detection IAP (paid)** — SE-ResLSTM Core ML model for
  detecting malignant ventricular arrhythmias in noisy ICU
  telemetry. Continuously improved off-app (not from customer data)
  and delivered to paid users via remote model updates. **All UI
  must frame this as research-use-only — no language implying
  clinical decision support.**

**Repo layout:**

- Public: `kvnlng/Murmur` — the viewer source. Re-public the
  existing repo before Phase 0 work; the paid framework code isn't
  there yet anyway.
- Private: `kvnlng/Murmur-Extensions` — the three paid frameworks:
  `MurmurAnnotation`, `MurmurMetrics`, `MurmurInference`.
- The App Store ships **one binary** that links both. IAPs unlock
  the paid frameworks at runtime via entitlement checks. The split
  is *source distribution*, not *binary distribution*.

**Pricing direction** — RESOLVED 2026-08: one all-inclusive
non-consumable, **Murmur Pro at $299.99** (`com.kevinlong.murmur.studio`),
covering every instrument current and future. The per-module SKUs
below were retired in App Store Connect before launch; Small Business
Program enrollment completed before first sale. *(Historical plan:
per-module non-consumables — Annotation Authoring, ECG Metrics, VT
Detection lifetime — with a possible bundle SKU later.)*

### Layering

Three independent layers, each owning one concern:

```
Feature surfaces (SwiftUI views in MurmurCore or paid frameworks)
  ↓ asks "can the user use this?" then "give me an answer"
Compute Services (AnnotationAuthoringService, ECGMetricsService, VTDetectionService)
  ↓ consults                       ↓ loads
PurchaseStore (StoreKit 2)     ModelRegistry (VT only)
                                   ↓ talks to
                                Server: signed manifest + .mlpackage CDN
```

Every paid framework implements the `FindingProducer` protocol
(promoted out of Deferred — it's now the runtime contract between
the open viewer and the paid extensions). Feature surfaces never call
StoreKit, network, or Core ML directly — they go through Compute
Services, which gates on `PurchaseStore` and loads weights from
`ModelRegistry`.

### Phase 0 — Open-core split prep (no Apple submission)

Local engineering + repo work; no App Store interaction. Should
complete *before* Phase 1 begins so StoreKit foundation lands in
the right architectural shape.

- [x] Re-public the GitHub repo. `kvnlng/Murmur` is PUBLIC; the
      docs-site Pages workflow runs cleanly.
- [x] Promote the `FindingProducer` protocol design out of "Phase 4
      Deferred" — defined in `MurmurCore/FindingProducer.swift`
      with the registry + bootstrap helper. (See Phase 4 above for
      the full decision log.)
- [x] Phase 0 stub `PurchaseStore` shipped in `MurmurCore/PurchaseStore.swift`:
      `ProductID` enum + `owns(_:)` + `canRun(producerID:)`. StoreKit 2
      wiring lands in Phase 1.
- [x] Rewrite `README.md` to reflect the open-core posture (free
      MIT viewer + three paid IAP extensions; App Store listing
      "Murmur Studio").
- [x] Update `docs/architecture.md` to show MurmurCore + 3 paid
      framework targets and the FindingProducer seam.
- [x] Stand up Phase A scaffolding for Citation infrastructure —
      `CITATION.cff` + `.zenodo.json` committed at repo root,
      `CitationBuilder.swift` groundwork in MurmurCore.
- [x] Set up the private `Murmur-Extensions` repo and confirm SPM
      resolution from the app target into it via Xcode Cloud. The
      three paid frameworks ship as SPM library products
      (`MurmurAnnotation`, `MurmurMetrics`, `MurmurInference`) from
      `kvnlng/Murmur-Extensions` v0.2.0 — supersedes the earlier
      plan to extract them as in-project framework targets.
- [x] Enable the GitHub→Zenodo OAuth integration and cut the first
      GitHub Release so Zenodo mints the canonical DOI. Concept DOI
      `10.5281/zenodo.21077528`, v1.2.1 version DOI
      `10.5281/zenodo.21077529`, minted 2026-06-30.

### Phase 1 — StoreKit foundation + ECG Metrics IAP

First paid submission. ECG Metrics is the lowest-scrutiny option (no
ML, deterministic output, standard analytic measures) so it
validates the StoreKit wiring before higher-risk IAPs follow.

- [x] `PurchaseStore` — `@MainActor @Observable` actor. Loads
      `Product.products(for:)` on launch, listens forever to
      `Transaction.updates`, exposes `owns(_:) -> Bool`, `purchase(_:)`,
      and `restore()`. Refuses unverified transactions.
- [x] Product registration in App Store Connect — SUPERSEDED by the
      single-IAP pivot: one product, `com.kevinlong.murmur.studio`
      ("Murmur Pro"), registered and approved with the 1.3
      submission. The per-module IDs (`…murmur.metrics`,
      `…murmur.annotationauthoring`, `…murmur.vtdetection`) were
      retired unused.
- [x] Restore Purchases UI surface (Apple-mandated).
- [x] ECG Metrics pipeline ported to Swift inside `MurmurMetrics`
      framework — `ECGMetricsService.compute(fromRRIntervalsMs:)`
      + `ECGMetricsExtractor.rrIntervalsMs(...)` +
      `ECGMetricsReport` value type. Not conforming to
      `FindingProducer` — metrics are recording-wide summaries, not
      per-sample findings on the waveform, so the FindingProducer
      contract wasn't the right seam.
- [x] `ECGMetricsView` + `ECGMetricsLockedView` views ship in
      `MurmurMetrics`; the App target's `ECGMetricsSurface`
      orchestrates entitlement gating and reads live recording data
      via `CurrentRecordingContext`. Window opens via Window menu
      → "ECG Metrics" (⌘⇧M). Includes Task Force adequacy advisory
      (< 256 beats warning) and a Copy-to-clipboard button.
- [x] StoreKit testing — local `.storekit` config file at
      `Murmur/Murmur.storekit`, excluded from the release bundle
      via pbxproj `membershipExceptions`. App Store sandbox tester
      verification pending IAP product-ID registration in ASC.

**Phase 1 status (2026-07-01): substantially complete.** The only
open item is the App Store Connect side — registering the three
IAP product IDs and configuring a sandbox tester. Everything
buildable/testable in code is done. First TestFlight distribution
kicked off 2026-07-01 to gather tester feedback on the ECG Metrics
UX; the paid path shows the locked variant until IAP registration
lands (Buy will error with `productNotLoaded` — expected).

**Direction pivot 2026-07-03: time-resolved trajectories.** The shipped
`ECGMetricsReport` recording-wide-summary approach is SUPERSEDED. A
single "overall" number collapses a non-stationary signal into one
point estimate — the same failure mode the user's own waveform-vs-EHR
work documents for ventilator parameters, and the reason the ventilation
Silver layer computes on 1-minute grids. ECG Metrics is being reframed
as TIME-RESOLVED rolling trajectories aligned under the waveform (see
"Phase 1 extensions" below). The app is pre-users (solo tester), so the
pivot supersedes rather than augments — no regression cost. The
currently-shipped summary UI stays as historical record until the
rolling lane subsumes it; all new metric development is against the
rolling-lane spec.

### Phase 1 extensions — time-resolved measurement layer

Three linked additions to the ECG Metrics IAP, all reading the same
per-recording fiducial store. Consumption of these measurements stays
free in the viewer; computing them is the ECG Metrics IAP; authoring a
range/finding on top of them is the Annotation IAP. Engineered
measurement throughout — no RUO badges (RUO language stays reserved for
ML inference output in the VT module).

**Variability lane (rolling HRV under the waveform) — SHIPPED**

- [x] Shared-axis rolling metric lane under the ECG (`VariabilityLane`
      + `VariabilityLaneContext`; App target's
      `VariabilityLaneOrchestrator` publishes samples from
      MurmurMetrics). Pan/zoom/scrub locked to the pinned trace.
- [x] Default rolling RMSSD; alternates (pNN50, mean-RR / HR) selectable
      by the App-target orchestrator via the shared context.
- [x] SDNN deliberately NOT offered as a rolling line.
- [x] Window-length presets (1 / 5 / 10 min + custom) + step control,
      persisted via `VariabilityLaneContext` (UserDefaults). Caption
      echoes the choice for citation.
- [x] Window-on-signal linkage — lane hover publishes to
      `VariabilityLaneContext.hoveredTimeSeconds`, ECG canvas overlays
      a translucent band over the contributing beats; ECG-side hover
      pops the metric value on the lane.
- [x] RR-artifact quality floor renders ineligible windows as dimmed
      `PointMark`s (not silently dropped).
- [ ] Range-drag on the lane → an annotation carrying metric + window +
      values ("HRV drop, 03:11–03:20") — reproducible, citable, into
      the observation→publication path. Authoring routes through the
      Annotation IAP.

**Interval markings & delineation (on-waveform P/QRS/T + intervals) — SHIPPED**

Anchored on a per-patient **normal template** (median morphology +
interval baselines built from high-confidence normal complexes). The
analyst reads everything as deviation from THIS patient's own normal —
not against a population cutoff.

- [x] Delineation pass populates the fiducial store
      (`IntervalMarkingsContext.beats` + `.template`). Same store
      feeds the variability lane, the on-beat markings, and the
      interval trend lanes — **one pass, three views.**
- [x] Per-patient normal template drives caliper delta columns
      (`BeatCalipers` "+X ms vs template"), ghost-overlay on the
      Metal canvas, and deviation-ranked navigation
      (`IntervalMarkingsContext.beatsRankedByDeviation` + the
      `[`/`]` keyboard shortcuts).
- [x] Zoom LOD markings — `MarkingsDetailLevel.level(forViewportSeconds:)`
      switches between R-ticks-only / QRS-only / full-fiducials at
      3 s and 30 s viewport thresholds.
- [x] Focus-beat calipers — hover a beat → docked `BeatCalipers`
      readout beside the pinned trace with PR/QRS/QT/QTc + deltas.
      Click a beat to PIN the card open (#225); hover still previews any
      other beat and the pinned one returns when the pointer leaves.
- [ ] Toggleable layers (P / QRS / T / ST / intervals) so a QT study
      and a conduction study each show only what's relevant.
- [x] QTc formula is a user-set parameter (Fridericia default;
      Bazett / Framingham / Hodges available), persisted via
      `IntervalMarkingsContext.qtcFormula` and echoed on the caliper
      QTc row + trend-lane repro caption.
- [ ] Fiducials are confidence-flagged and **EDITABLE** (nudge to
      recompute; the correction is a finding routed through the
      Annotation IAP). Confidence flags exist on
      `MarkingsFiducial.confidence`; nudge-to-edit still pending.
- [x] Architecture guardrail — dense fiducials live only on
      `IntervalMarkingsContext.beats`; nothing writes them into
      `annotations.json`. Beat-class labels route through
      `DispositionStore` / `confirmedKind`.
- [x] Compute in MurmurCore surfaces the geometry as unlabeled
      deviation + confidence via `MarkingsBeat` / `MarkingsTemplate`;
      the paid MurmurMetrics framework owns the arithmetic.

**Interval trend lanes (QTc-over-time, third view of the fiducial store) — SHIPPED**

Trend an interval metric over the WHOLE recording, reusing the
variability-lane mechanism. Named use case: catching **drug-induced QT
prolongation across hours**.

- [x] `IntervalTrendLane` — shared-axis lane under the ECG at whole-
      recording zoom, pan/zoom/scrub locked to the viewport.
- [x] Default QTc/Fridericia with 2-min bins; PR and QRS-width
      switchable via the metric picker chip.
- [x] Median line + IQR ribbon (default), per-beat scatter and
      median-only alternates via the show-mode chip.
- [x] Baseline band from `MarkingsTemplate.medianQTcMs ± IQR/2`.
- [x] Quality dimming — bins failing the T-offset confidence floor
      render as dimmed `PointMark`s (see
      `IntervalTrendComputer.hasFragileFiducialsHighConfidence`).
- [x] Threshold guides are USER-SET only — `IntervalTrendGuideStore`
      persists per-recording to `interval_guides.json`; the `+ guide`
      caption chip adds them, right-click a label removes them; every
      rendered label carries "(user-set)".
- [x] Event overlay — point annotations whose category matches an
      event-worthy token (WFDB `"`, `comment`, `event`, `note`,
      `drug`, `dose`, `drug_admin`) render as vertical purple
      markers on the trend axis. Analyst-authored events; app never
      imports EHR claims.
- [x] Click-through — click a trend bin → `IntervalMarkingsContext`
      requests a jump to the nearest beat, which focuses the caliper
      readout beside the pinned trace.
- [x] Bin length is a visible control (`IntervalTrendLaneContext.binPreset`);
      repro caption echoes formula + bin + template N verbatim for
      the citation copy path.

**Build order (historical):** shared-axis variability lane → on-beat
delineation + template + calipers + deviation-ranked navigation →
interval trend lanes (median+IQR + baseline band + quality dimming +
threshold guides + event overlay + click-through). All three views of
the one fiducial store are now on-screen. Remaining polish is
authoring-dependent (range-drag → finding needs the Annotation IAP)
and fiducial-edit UX (nudge-to-recompute).

### Phase 2 — Annotation Authoring IAP

> **Status 2026-08-19: shipped under Murmur Pro.** Authoring landed
> as right-click note/finding creation and drag-to-author range
> findings (X84), gated behind the Editing latch + the Pro
> entitlement; authored work persists with the session document, so
> re-running producers never collides with it. Reading and
> disposition stayed free, as planned.

Second paid submission. Lower scrutiny than VT (no ML, no medical
claims) but introduces user-generated content workflows.

- [x] Authoring UI: right-click to author a note or point/range
      finding on the trace; drag-to-author range findings.
- [x] Wired into the existing `Editing` toolbar latch — author mode
      requires the latch unlocked, matching the notes-edit gating
      pattern.
- [x] Authored work persists with the session (`.mur` document),
      separate from producer output.
- [x] Entitlement gate on authoring entry points; reading and
      disposition stay free.
- [x] StoreKit purchase + restore flow (shared Murmur Pro
      entitlement).
- [ ] Update `docs/annotation-schema.md` to document the
      analyst-authored source value.

### Phase 3 — VT Detection with bundled model

> **Status 2026-08-19: shipped under Murmur Pro.** The in-app
> arrhythmia scan ships the on-device model with a recall-biased,
> user-adjustable τ dial persisted per session, "candidates, not
> detections" copy, RUO badges on the group headers and rows, and
> operating-point provenance echoed in the queue header — every
> starred design decision below landed as specced. Still open:
> `docs/vtdetect-schema.md` (the stable I/O schema document was
> never written).

- [ ] PyTorch → Core ML conversion of SE-ResLSTM via `coremltools`.
      Verify LSTM ops convert cleanly; document any custom layers.
- [ ] `VTDetectionService` inside `MurmurInference` framework —
      sliding-window inference over a `Channel`, output aligned to
      recording time. Conforms to `FindingProducer`. Same gate
      pattern as ECG Metrics and Annotation.
- [ ] **Operating point — recall-biased, user-adjustable, documented.**
      The SE-ResLSTM paper's tau = 0.85 is precision-tuned for
      autonomous / bedside use with no human reviewer; at that point
      the reported F1 is ~0.65 and real events are left on the table.
      Murmur is human-in-the-loop review-triage: dismissing a false
      positive is one keystroke, a missed true event is invisible and
      uncorrectable. Default operating point moves DOWN the
      precision-recall curve; expose the threshold as a visible,
      documented, user-adjustable parameter — feeds the citation moat
      (researchers cite the model version AND the operating point they
      reviewed at). Do NOT inherit the paper's literal as a silent
      default; pick deliberately and document the choice.
- [ ] **Framing — "candidates," not "detections."** Output copy
      throughout ("candidate events for review", "N candidates in
      window") — correct for the recall-triage UX AND for RUO
      discipline from a second angle.
- [ ] **Two-pass whole-recording normalization sets the min-spec.**
      Inference-time normalization uses whole-recording global
      mu / sigma, forcing a two-pass design: pass 1 scans the full
      recording for statistics; pass 2 windows and infers. Nothing
      shows until pass 1 completes. For the multi-hour recordings
      Murmur targets, the real constraint is RAM + streaming I/O, not
      GPU (the 2.97M-param model is trivial for the Neural Engine).
      Stream, don't load-all; "high-end Mac" in the system requirements
      means memory / throughput headroom for large recordings, not
      neural compute.
- [ ] Findings produced by the model surface in the existing
      `FindingsPanel` with `source = "murmur.vtdetect"` so the
      disposition workflow applies uniformly.
- [ ] Research-use-only disclaimer in:
      - the IAP product description on App Store Connect
      - the locked feature card
      - a first-run modal the very first time a user invokes inference
      - the findings rows themselves (small "RUO" badge)
- [ ] Bundled baseline `.mlpackage` for the v2.x app — first launch
      works offline before any remote update.
- [ ] Stable I/O schema captured in `docs/vtdetect-schema.md`: input
      sample rate, window length, channels, normalization; output
      logits, calibrated confidence, time alignment. Bumped only on
      breaking changes (treated like database migrations).

### Phase 4 — Remote model updates (and the reproducibility moat)

> **Status 2026-08-19: not started.** The shipped scan runs the
> bundled on-device model only — no `ModelRegistry`, no manifest
> fetch, no network entitlement. This is the main open engineering
> workstream in this section, and Citation Phase C (freeze toggle,
> per-version DOIs) depends on it. Until it lands, reproducibility
> is simpler than the moat design assumed: the model is pinned to
> the app version, which is itself DOI-addressable.

Invisible to Apple once Phase 3 is approved — just upgrades weights
of an existing capability. Tightly coupled to Citation Phase C below
(per-version DOIs); design the manifest scheme to carry the DOI from
day one.

- [ ] `ModelRegistry` — `@Observable` actor. On launch and once per
      day: fetch a signed `manifest.json`; if a newer compatible
      version exists and the user holds the VT entitlement, download
      the `.mlpackage` to a temp location, verify sha256 + Ed25519
      signature, compile via `MLModel.compileModel(at:)`, atomically
      move into Application Support, hot-swap on next inference call.
- [ ] Storage layout under
      `~/Library/Application Support/MurmurStudio/Models/vt/`: keep
      N=2 previous versions for rollback; `current` symlink points
      to the active one.
- [ ] Manifest schema: `{ version, url, sha256, signature, doi,
      schema_version, min_app_version, released_at, notes }`.
      Signature verified against a long-lived Ed25519 public key
      baked into the binary. The `doi` field is load-bearing for
      Citation Phase C — every published version stays
      DOI-addressable forever.
- [ ] "Freeze model version" toggle in settings (per Citation
      Phase C) — when set, the app pins inference to the chosen
      version and refuses silent upgrades. Surfaces prominently
      after Copy Citation has been invoked recently (heuristic for
      paper-in-progress).
- [ ] Per-finding badge showing the model version that generated
      it, so paper screenshots self-document model provenance.
- [ ] Fallback chain on any failure (network, signature, compile):
      silently fall back to the previous downloaded model, then to
      the bundled baseline. Never block inference.
- [ ] Entitlements diff: add `com.apple.security.network.client = YES`
      to the sandbox (minor expansion). Application Support write
      access is already available within the sandbox container.
- [ ] Server side: pick CDN host (Cloudflare R2 leaning), publish
      signed manifest, document the release process so model bumps
      don't require app submissions.
- [ ] App Store guideline alignment: 3.2.2 / 2.5.2 — Core ML weights
      are data, not executable code; we are updating an existing
      approved capability, not adding new functionality after review.

### Cross-cutting concerns

- **Subscription mechanics (if VT goes subscription):** grace period
  handling, introductory pricing, subscription group config in App
  Store Connect, "Manage Subscription" deep-link in settings, refund
  webhooks (optional — local verification is sufficient for v1).
- **Family Sharing toggle** per product in App Store Connect — usually
  on for non-consumables, off for subscriptions in research tools.
- **Receipt persistence:** StoreKit 2 handles this transparently; do
  not roll our own.
- **Analytics:** stay off-device. Customer-side telemetry is
  explicitly out of scope — it would void the privacy-policy claim of
  "no data collection."
- **Schema migrations:** ECG Metrics output, Annotation Authoring
  output, and VT Detection output each get their own `schema_version`.
  Old findings re-loaded against new app versions must still render.
- **Community contributions:** the public viewer repo will start
  receiving issues and PRs once it's listed in the PhysioNet directory
  and on Zenodo. Triage policy + contributor guidelines need to land
  alongside Phase 0.

### Sequencing rationale

Phases are ordered to stagger App Store re-review risk. Phase 0 is
local/repo only — no Apple interaction. Phase 1 adds a paywall to a
deterministic feature (low scrutiny). Phase 2 adds user-authoring
flows (low-medium scrutiny — no medical or ML claims). Phase 3 adds
an ML capability — Apple's medical-app reviewers will scrutinize
wording here; RUO framing must be locked in before submission. Phase 4
is invisible to Apple once Phase 3 is approved — it just upgrades
weights of an existing capability without changing app behavior at
review time.

## Citation infrastructure

Surfaced from the PhysioNet software-catalog audit (2026-06-28): the
catalog has zero native-macOS apps and zero viewer+on-device-ML tools,
which makes Murmur the natural home for that intersection — but only
if it's *citable, reproducible*, and discoverable through the same
channels MATLAB toolboxes use. This section is a separate workstream
from the IAPs but is sequenced around them.

The open-core distribution split above structurally unblocks both
Zenodo and JOSS — the public viewer is exactly the kind of artifact
both venues are designed for. Phase A below assumes Phase 0 of the
IAP roadmap (repo re-publication) is complete.

### Strategic framing

- **Citation target — Zenodo first, JOSS later.** Zenodo +
  GitHub-release integration auto-mints a DOI for every tagged
  release; no peer review, but a permanent citation anchor. Stand
  this up immediately after v1.0 ships. JOSS (Journal of Open Source
  Software) paper comes later, once ECG Metrics IAP is live — paper
  covers MurmurCore (the free, open framework); IAPs noted as App
  Store extensions. SoftwareX is a fallback if JOSS rejects a
  partially-paid tool.
- **Reproducibility moat.** VT IAP's remote model updates would
  normally break "we used VT model v1.3.2" citations. Murmur commits
  to: every published model version stays DOI-addressable forever;
  the app surfaces a "freeze model version" toggle; the model version
  is encoded into the citation output. Cloud-inference competitors
  structurally cannot match this — on-device + versioned manifest is
  the differentiator.
- **Continuous-with-the-field narrative.** Position Murmur as the
  "first native macOS implementation of community-standard PhysioNet
  algorithms, extended with the author's modular-feature and
  SE-ResLSTM research" — not "viewer + author's papers." Lean on the
  Vest 2018 PhysioNet CV Signal Toolbox as a baseline parity
  reference.

### Citation routing

Each product tier carries a distinct citation pattern. The "Copy
citation" menu (below) enforces the routing — researchers cite what
the tool hands them, so handing them the right combination
automatically fixes attribution at the source.

| Surface | Citation type | What gets cited |
|---|---|---|
| **MurmurCore** (free, open source) | Tool only | Murmur Studio + Zenodo release DOI |
| **Annotation Authoring IAP** | Tool only | Murmur Studio + release DOI (no method paper — IAP wraps editing UX, not a published algorithm) |
| **ECG Metrics IAP** | Tool only | Murmur Studio release DOI (no separate method paper — measures are community-standard) |
| **VT IAP** | Method + production implementation | Murmur Studio + the specific VT model version DOI |

### Phase A — Zenodo DOIs for MurmurCore (✅ DONE)

- [x] GitHub-to-Zenodo integration enabled; `.zenodo.json` configured.
- [x] `CITATION.cff` at the repo root.
- [x] Concept DOI `10.5281/zenodo.21077528` minted 2026-06-30; DOI
      badge pinned in the README.
- [x] `docs/citation.md` carries copy-pasteable BibTeX/RIS entries
      (refreshed 2026-08-19 for the single-purchase model).

### Phase B — "Copy citation" menu item (partially shipped)

- [x] **Help ▸ Copy Citation (BibTeX)** and **(RIS)** shipped — emit
      the viewer entry for the running version to the clipboard via
      `CitationBuilder`.
- [ ] Context-aware generation — largely mooted by the single-IAP
      pivot (one tool entry covers viewer + instruments; see the
      refreshed routing table in `docs/citation.md`). The remaining
      real case is appending scan operating-point provenance
      (model, τ, ranking basis) to the emitted entry instead of
      leaving it in the queue header alone.
- [x] Generation tied to the Phase A DOI.

### Phase C — Versioned VT model manifests (reproducibility)

> **Status 2026-08-19: blocked on IAP Phase 4** (remote model
> updates, not started). Until then the model version is pinned to
> the app version, which is DOI-addressable via Phase A — so
> reproducibility holds today by a simpler mechanism than the one
> designed here.

Tightly coupled to the IAP Phase 4 (Remote model updates) above —
build this *into* the manifest scheme from day one, not bolted on
after.

- [ ] Every model version gets its own Zenodo DOI at publish time.
      Never overwrite, never delete.
- [ ] Manifest schema extended with `doi` field per version; old
      manifests stay addressable by URL forever.
- [ ] "Freeze model version" toggle in settings — when set, the app
      pins inference to the chosen version and refuses silent
      upgrades. Surfaced prominently when a paper-in-progress is
      detected (heuristic: user has invoked Copy Citation recently).
- [ ] Per-finding badge in the UI showing which model version
      generated it; screenshots in papers self-document the model
      provenance.
- [ ] Public-facing model lifecycle policy in `docs/` describing how
      versions are minted, retired (never), and addressed.

### Phase D — JOSS paper (later)

- [ ] Draft a JOSS submission for MurmurCore once ECG Metrics IAP is in
      the wild and at least one external user has cited Murmur via
      Phase B's menu. Use real adoption data as a "Statement of
      Need."
- [ ] Acknowledge the IAPs as App Store extensions; do not include
      them in the open-source review scope.
- [ ] If JOSS rejects on the partial-paid posture, retarget SoftwareX.

### PhysioNet directory listing

> **Status 2026-08-19: unblocked.** Both preconditions are met — the
> app is live on the store and the DOI exists. This is now the
> highest-leverage open item in the citation workstream.

Submit Murmur Studio to `https://physionet.org/about/software/`.
That catalog is the *de facto* discovery channel for the target
audience; inclusion puts us in the same surface as PhysioNet CVST
and ECG-Kit. Keep submission copy consistent with the RUO framing.
