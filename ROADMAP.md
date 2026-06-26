# Murmur — Roadmap

A macOS SwiftUI app for analyst review of clinical findings produced upstream
by a cluster of analysis machines (VF/VT onset, AFib, PVCs, disease vectors).
The PhysioNet WFDB record (`.hea` + `.dat`) is the *context* the analyst
needs to interpret each finding; the findings themselves are the primary
data surface.

## Current state (updated 2026-06-18)

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

**Tests** — 194 total (190 unit + 4 UI). All five Near-term roadmap
items are now done; suite went 135 → 190 over the App-Store-rejection
fix, coverage hardening, and the near-term feature work.

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

**Phase 1 — make existing patterns testable (1 session)**
- [ ] Launch arg `--ui-test-zoomed-sample` that opens the synthetic
      fixture with a 1-second viewport, so drag pans actually have
      somewhere to move to and a "drag changes viewport" test is
      meaningful
- [ ] Launch arg `--ui-test-hover-at=x,y` that calls the same
      `hoverLocation` / `hoverIsActive` update closure the
      `HoverTrackingView` does — bypasses the `XCUICoordinate.hover()`
      flakiness on macOS so the crosshair render path is testable
- [ ] Refactor key SwiftUI containers to expose nested elements
      through `.accessibilityElement(children: .contain)` so XCUI can
      find Text elements like the time-window-label (the test we had
      to drop yesterday)
- [ ] Write 6-8 XCUI tests against the new hooks: drag pans the
      viewport, hover renders the crosshair, click finding row jumps
      viewport, attach-findings flow end-to-end, window resize honors
      the new minimum, lock toolbar gates editing

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
- [ ] **Deferred to next session: `FindingProducer` protocol design**
      + refactoring `SyntheticRecording` into the first concrete
      conformance. Worth a focused session — this is the contract
      that ML inference plugs into, deserves deliberate thought rather
      than a stub at the end of a long refactor session.
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
- [ ] Annotation authoring inside the app (manual marker placement)
- [ ] Export imported recordings to a portable bundle
- [ ] HDR/wide-color-gamut Metal canvas
- [ ] Two-finger trackpad swipe → pan via an NSScrollView bridge

## Paid features roadmap (In-App Purchases)

Two planned IAPs that turn Murmur Studio from a free analyst review tool
into a research-oriented platform. The base review experience stays free
and unchanged — these layer additional compute on top, gated by
entitlements. Both will be added in *future* versions; nothing here
applies to the v1.0 build currently in App Store review.

### Strategic framing

- **Silver Layer Metrics IAP** — calculates the Cardiopulmonary Telemetry
  Silver-Layer metrics from the user's paper *"Modular Feature
  Architecture for Mechanical Ventilation and Cardiopulmonary
  Telemetry."* Pure Swift port (Accelerate / vDSP where it helps).
  Deterministic, reviewable, no regulatory exposure — surfaces
  engineered features, not diagnoses. Lower technical risk; ship first
  to validate StoreKit wiring and willingness-to-pay.
- **VT/VF Detection IAP** — runs the SE-ResLSTM model from the user's
  paper *"Automated Detection of Malignant Ventricular Arrhythmias in
  Noisy ICU Telemetry using SE-ResLSTM,"* converted PyTorch → Core ML.
  Continuously improved off-app (not from customer data) and delivered
  to paid users via remote model updates. **All UI must frame this as
  research-use-only — no language implying clinical decision support.**
- **Pricing direction** (open):
  - Silver Metrics → non-consumable one-time purchase.
  - VT Detection → annual auto-renewing subscription, because users are
    paying for the *ongoing* model improvement pipeline, not a frozen
    artifact. Alternative: lifetime non-consumable at a higher price
    point for buyers who want it.

### Layering

Three independent layers, each owning one concern:

```
Feature surfaces (SwiftUI views)
  ↓ asks "can the user use this?" then "give me an answer"
Compute Services (SilverMetricsService, VTDetectionService)
  ↓ consults                       ↓ loads
PurchaseStore (StoreKit 2)     ModelRegistry (VT only)
                                   ↓ talks to
                                Server: signed manifest + .mlpackage CDN
```

Feature surfaces never call StoreKit, network, or Core ML directly —
they go through Compute Services, which gates on `PurchaseStore` and
loads weights from `ModelRegistry`.

### Phase 1 — StoreKit foundation + Silver Metrics IAP

- [ ] `PurchaseStore` — `@MainActor @Observable` actor. Loads
      `Product.products(for:)` on launch, listens forever to
      `Transaction.updates`, exposes `owns(_:) -> Bool`, `purchase(_:)`,
      and `restore()`. Refuses unverified transactions.
- [ ] Two product IDs registered in App Store Connect:
      `com.kevinlong.murmur.silvermetrics` (non-consumable) and
      `com.kevinlong.murmur.vtdetection` (subscription or non-consumable,
      TBD).
- [ ] Restore Purchases UI surface (Apple-mandated).
- [ ] Silver Layer pipeline ported to Swift (`SilverMetricsService`),
      output schema versioned independently of the implementation.
- [ ] `SilverMetricsPanel` view, gated; locked variant sells the feature
      with bullet list + price + Buy / Restore actions.
- [ ] StoreKit testing — local `.storekit` config file for offline
      development; App Store sandbox tester accounts for end-to-end
      verification before submission.

### Phase 2 — VT Detection with bundled model

- [ ] PyTorch → Core ML conversion of SE-ResLSTM via `coremltools`.
      Verify LSTM ops convert cleanly; document any custom layers.
- [ ] `VTDetectionService` — sliding-window inference over a `Channel`,
      output aligned to recording time. Same gate pattern as Silver.
- [ ] Findings produced by the model surface in the existing
      `FindingsPanel` with `source = "murmur.vtdetect"` so the analyst
      disposition workflow (confirm / dismiss / reset) applies
      uniformly.
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

### Phase 3 — Remote model updates

- [ ] `ModelRegistry` — `@Observable` actor. On launch and once per day:
      fetch a signed `manifest.json`; if a newer compatible version
      exists and the user holds the VT entitlement, download the
      `.mlpackage` to a temp location, verify sha256 + Ed25519
      signature, compile via `MLModel.compileModel(at:)`, atomically
      move into Application Support, hot-swap on next inference call.
- [ ] Storage layout under
      `~/Library/Application Support/MurmurStudio/Models/vt/`:
      keep N=2 previous versions for rollback; `current` symlink points
      to the active one.
- [ ] Manifest schema: `{ version, url, sha256, signature,
      schema_version, min_app_version, released_at, notes }`. Signature
      verified against a long-lived Ed25519 public key baked into the
      binary.
- [ ] Fallback chain on any failure (network, signature, compile):
      silently fall back to the previous downloaded model, then to the
      bundled baseline. Never block inference.
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
- **Schema migrations:** Silver Metrics output and VT Detection
  output each get their own `schema_version`. Old findings re-loaded
  against new app versions must still render.

### Sequencing rationale

Phases are ordered to stagger App Store re-review risk. Phase 1 adds
a paywall to a known feature class. Phase 2 adds an ML capability —
Apple's medical-app reviewers will scrutinize wording here; framing
must be locked in before submission. Phase 3 is invisible to Apple
once Phase 2 is approved — it just upgrades weights of an existing
capability without changing app behavior at review time.
