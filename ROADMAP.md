# Murmur — Roadmap

A macOS SwiftUI app for analyst review of clinical findings produced upstream
by a cluster of analysis machines (VF/VT onset, AFib, PVCs, disease vectors).
The PhysioNet WFDB record (`.hea` + `.dat`) is the *context* the analyst
needs to interpret each finding; the findings themselves are the primary
data surface.

## Current state (updated 2026-06-29)

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
- `FindingsPanel` rows show inline confirm/dismiss/reset controls when
  unlocked; row chrome reflects state (green border + ✓ for confirmed,
  strikethrough + ✗ for dismissed). The panel header shows a compact
  `confirmed · dismissed · unreviewed` tally.
- `FindingsSummaryHeader` total chip carries the same tally so analyst
  progress is visible even when the inspector is hidden.
- `FindingDensityTimeline` lanes dim dismissed events to ~30% and
  outline confirmed events with a green ring, so triage state is
  scannable at the full-recording level.

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
  each category up into counts, severity breakdowns, and total range
  extent. Sorted critical-first, then by count.
- `FindingsSummaryHeader` — compact horizontal chip row above the
  canvas: `PVC 47 (12 critical) · AFib 38s · VT 3`. Click a chip to
  toggle the shared `FindingFilter` for that category.
- `FindingDensityTimeline` — one thin lane per surviving category
  spanning the full recording. Points render as ticks, ranges as bars.
  Tap anywhere on a lane to jump the viewport. Lets the analyst see
  finding clusters across a multi-hour record at a glance.

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
  `confidence`, `severity` (info/notice/warning/critical, Comparable),
  `source`, optional `note`, `lead`, `evidenceContextSeconds`.
- `AnnotationFile` JSON wire format (`schemaVersion: 1`) is the canonical
  ingest path. Timestamps accept either `startSample`/`endSample` (already
  aligned) or `startUnixMS`/`endUnixMS` (viewer resolves at import).
- WFDB `.atr` is a legacy adapter — beat letters become point annotations
  tagged `source = "wfdb.atr"`.
- Importer scans `<recordName>.annotations.json` first, then `.atr`/`.qrs`,
  concatenating both.
- `Recording` decode is back-compat: legacy manifests with
  `[WFDBAnnotation]` arrays still load and get adapted on the fly.

**Findings UI**
- Right-side `inspector` drawer (`FindingsPanel`) with filter chip bar:
  categories (each with its palette color dot), severities, sources, and
  a confidence-threshold slider.
- Findings list — color-grouped rows with time, severity badge, confidence,
  source, and note preview. Click to jump the viewport; range findings
  widen the viewport to show context around them.
- The filter is shared with the canvas — filtered-out findings stop
  rendering everywhere.
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
  own color in a single instanced draw call. Severity modulates alpha.
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

**Tests** — 346 total (287 unit + 59 UI). Suite has grown ~135 → 346
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
      small panel with the category, severity, time, confidence, source,
      and the producer's note.

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
      `FindingDensityTimeline` (mixed categories),
      `FindingsSummaryHeader` (mixed + empty)
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
      chip color/severity rendering as a proxy.
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
- [ ] Lead-specific findings — render annotations only on the channels
      that match their `lead` field
- [ ] Finding sorting modes (by time, by category, by confidence, by
      severity) in the findings panel
- [ ] Keyboard navigation: J/K through findings, →/← pan one window,
      +/− zoom
- [ ] Per-channel y-axis autoscale (instead of fixed ±5 mV) when the
      signal sits in a narrower band
- [ ] Beat clustering at low zoom — collapse adjacent points of the same
      category into a single hit-counter mark when they overlap
- [ ] Snapshot export — current viewport as PNG with grid + findings, for
      sharing with clinicians

### Deferred
- [ ] Multi-file WFDB records (per-signal `.dat`)
- [ ] Additional WFDB sample formats (8, 16+, 24, 32, 310, 311, 80)
- [ ] Export imported recordings to a portable bundle
- [ ] HDR/wide-color-gamut Metal canvas
- [ ] Two-finger trackpad swipe → pan via an NSScrollView bridge

*(Annotation authoring moved out of Deferred 2026-06-28 — now a paid
IAP under the open-core split below.)*

## Paid features roadmap (open-core + IAPs)

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
- **Silver Layer Metrics IAP (paid)** — Cardiopulmonary Telemetry
  Silver-Layer metrics from the user's paper *"Modular Feature
  Architecture for Mechanical Ventilation and Cardiopulmonary
  Telemetry."* Pure Swift port (Accelerate / vDSP where it helps).
  Deterministic, reviewable, no regulatory exposure — surfaces
  engineered features, not diagnoses. Ships first per stagger-risk.
- **VT/VF Detection IAP (paid)** — SE-ResLSTM model from the user's
  paper *"Automated Detection of Malignant Ventricular Arrhythmias
  in Noisy ICU Telemetry using SE-ResLSTM,"* converted PyTorch →
  Core ML. Continuously improved off-app (not from customer data)
  and delivered to paid users via remote model updates. **All UI
  must frame this as research-use-only — no language implying
  clinical decision support.**

**Repo layout:**

- Public: `kvnlng/Murmur` — the viewer source. Re-public the
  existing repo before Phase 0 work; the paid framework code isn't
  there yet anyway.
- Private: `kvnlng/Murmur-Extensions` (working name) — the three
  paid frameworks: `MurmurAnnotation`, `MurmurSilver`,
  `MurmurInference`.
- The App Store ships **one binary** that links both. IAPs unlock
  the paid frameworks at runtime via entitlement checks. The split
  is *source distribution*, not *binary distribution*.

**Pricing direction** (open, to refine before Phase 1 submission):

- Annotation Authoring → non-consumable one-time purchase.
- Silver Metrics → non-consumable one-time purchase.
- VT Detection → annual auto-renewing subscription, because users
  are paying for the *ongoing* model improvement pipeline, not a
  frozen artifact. Alternative: lifetime non-consumable at a higher
  price point for buyers who want it.
- Possible bundle SKU later once usage data informs the decision.

### Layering

Three independent layers, each owning one concern:

```
Feature surfaces (SwiftUI views in MurmurCore or paid frameworks)
  ↓ asks "can the user use this?" then "give me an answer"
Compute Services (AnnotationAuthoringService, SilverMetricsService, VTDetectionService)
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
- [ ] Subdivide MurmurCore further: extract `MurmurAnnotation`,
      `MurmurSilver`, `MurmurInference` framework targets. Empty
      placeholders are fine until Phases 1–3 fill them in.
- [ ] Set up the private `Murmur-Extensions` repo and confirm SPM
      resolution from the app target into it via Xcode Cloud.
- [ ] Enable the GitHub→Zenodo OAuth integration at
      `zenodo.org/account/settings/github/` and flip the toggle on
      `kvnlng/Murmur`. Then cut the first GitHub Release (from the
      already-pushed `v1.2.0` tag) so Zenodo mints the canonical DOI.

### Phase 1 — StoreKit foundation + Silver Metrics IAP

First paid submission. Silver is the lowest-scrutiny option (no ML,
peer-reviewed methods, deterministic output) so it validates the
StoreKit wiring before higher-risk IAPs follow.

- [ ] `PurchaseStore` — `@MainActor @Observable` actor. Loads
      `Product.products(for:)` on launch, listens forever to
      `Transaction.updates`, exposes `owns(_:) -> Bool`, `purchase(_:)`,
      and `restore()`. Refuses unverified transactions.
- [ ] Product IDs registered in App Store Connect:
      `com.kevinlong.murmur.silvermetrics` (non-consumable),
      `com.kevinlong.murmur.annotationauthoring` (non-consumable),
      `com.kevinlong.murmur.vtdetection` (subscription or
      non-consumable, TBD).
- [ ] Restore Purchases UI surface (Apple-mandated).
- [ ] Silver Layer pipeline ported to Swift inside `MurmurSilver`
      framework as `SilverMetricsService` conforming to
      `FindingProducer`; output schema versioned independently of
      the implementation.
- [ ] `SilverMetricsPanel` view, gated; locked variant sells the
      feature with bullet list + price + Buy / Restore actions.
- [ ] StoreKit testing — local `.storekit` config file for offline
      development; App Store sandbox tester accounts for end-to-end
      verification before submission.

### Phase 2 — Annotation Authoring IAP

Second paid submission. Lower scrutiny than VT (no ML, no medical
claims) but introduces user-generated content workflows.

- [ ] Authoring UI inside `MurmurAnnotation` framework: marker
      placement (click to drop a point, drag to draw a range), edit
      panel (category / severity / label / note), delete affordance.
- [ ] Wires into the existing `Editing` toolbar latch — author mode
      requires the latch unlocked, matching the notes-edit gating
      pattern.
- [ ] Authored annotations persisted to a separate sidecar from
      upstream-produced ones (or same sidecar with `source =
      "murmur.author"`) so re-running the producer cluster never
      collides with user authoring.
- [ ] Locked-variant gate on every authoring entry point (toolbar
      button, context menu, keyboard shortcut). Reading and
      disposition stay free.
- [ ] StoreKit purchase + restore flow for the authoring entitlement.
- [ ] Update `docs/annotation-schema.md` to document the
      `murmur.author` source value.

### Phase 3 — VT Detection with bundled model

Third paid submission. Highest scrutiny (medical-app + ML). Lock
RUO framing before submitting.

- [ ] PyTorch → Core ML conversion of SE-ResLSTM via `coremltools`.
      Verify LSTM ops convert cleanly; document any custom layers.
- [ ] `VTDetectionService` inside `MurmurInference` framework —
      sliding-window inference over a `Channel`, output aligned to
      recording time. Conforms to `FindingProducer`. Same gate
      pattern as Silver and Annotation.
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
- **Schema migrations:** Silver Metrics output, Annotation Authoring
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
  Software) paper comes later, once Silver IAP is live — paper
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
| **Silver IAP** | Tool + method | Murmur Studio release DOI **plus** the modular-feature paper |
| **VT IAP** | Method + production implementation | SE-ResLSTM paper **plus** Murmur Studio + the specific VT model version DOI |

### Phase A — Zenodo DOIs for MurmurCore

- [ ] Enable GitHub-to-Zenodo integration on the repo; configure
      `.zenodo.json` with authors, ORCID, keywords, license.
- [ ] Add `CITATION.cff` at the repo root (GitHub renders a "Cite this
      repository" button from it).
- [ ] First tagged release after v1.0 generates the canonical DOI;
      pin it in the README and the app's About box.
- [ ] Document the citation in `docs/` (probably `docs/citation.md`)
      with copy-pasteable BibTeX/RIS entries.

### Phase B — "Copy citation" menu item

- [ ] Menu item under App / Help / or context menu in the findings
      panel — emits BibTeX (primary) and RIS (secondary) for the
      currently-loaded state.
- [ ] Context-aware generation: inspect what's loaded — MurmurCore
      only? Silver report visible? VT findings present, and at which
      model version? — and emit the corresponding entries per the
      routing table above.
- [ ] Tie generation to the Zenodo DOIs from Phase A; don't ship this
      before the DOIs exist or there'd be nothing valid to emit.
- [ ] Likely ships alongside the Silver IAP (the first version with
      multiple citation entries to merge).

### Phase C — Versioned VT model manifests (reproducibility)

Tightly coupled to the IAP Phase 3 (Remote model updates) above —
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

- [ ] Draft a JOSS submission for MurmurCore once Silver IAP is in
      the wild and at least one external user has cited Murmur via
      Phase B's menu. Use real adoption data as a "Statement of
      Need."
- [ ] Acknowledge the IAPs as App Store extensions; do not include
      them in the open-source review scope.
- [ ] If JOSS rejects on the partial-paid posture, retarget SoftwareX.

### PhysioNet directory listing

Once v1.0 ships and Phase A's DOI exists, submit Murmur Studio to
`https://physionet.org/about/software/`. That catalog is the *de
facto* discovery channel for the target audience; inclusion puts us
in the same surface as PhysioNet CVST and ECG-Kit. Keep submission
copy consistent with the RUO framing.
