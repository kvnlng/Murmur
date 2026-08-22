---
layout: page
title: Interaction coverage
permalink: /interaction-coverage/
---

# Interaction coverage

A catalog of every analyst-facing interaction Murmur Studio supports, with
its test status. Treat this as the source of truth for "have we proven this
flow works?" — code coverage tells us we exercised the lines, but only this
tells us we exercised the *meaningful actions*.

The smoke-test checklist in `RELEASE.md` is a manual subset of this list,
covering the highest-risk flows before each public submission.

**Legend**
- ✅ Automated test in `MurmurUITests/` or `MurmurTests/`
- 🟡 Manual gate via the `RELEASE.md` smoke pass
- ⬜ Uncovered — no automated test, not in smoke pass

**Current score:** 31 ✅ automated · 0 🟡 manual-only · 0 ⬜ uncovered out of 31 total.
That's **100% automated**.

Several entries below are covered by *bypass* tests that exercise the
post-system-modal code path via launch arg (Open Folder, Drag-and-Drop,
Attach Findings, Drag Pan, Pinch Zoom, all Help menu URLs). The bypass
tests live in `MurmurUIBypassTests`; the natural-interaction tests
live in `MurmurUITests`. See "Bypass strategy" at the bottom of this
file for what each bypass does and doesn't cover.

The North Star: convert 🟡 → ✅ over time, especially for flows where the
bug class would silently degrade the analyst experience without crashing.
Update this table whenever a new interaction is added, a flow becomes
automated, or one moves between buckets.

---

## Launch shell (no record open)

The welcome card, its sample-recording button, drag-drop target, recents
rows, and PhysioNet link were deleted in #242 (design 12a). Their
surviving routes and coverage:

| Interaction | Test | Notes |
| --- | --- | --- |
| "No record open" line + inline open action on cold launch | ✅ `MurmurUITests/testEmptyStateIsVisible` | Same identifiers as the old card (`empty-state-prompt` / `empty-state-open-button`), new chrome |
| Open Record Folder reachable from the toolbar `⋯` menu on cold launch | ✅ `MurmurUITests/testOpenRecordFolderIsReachableFromTheOverflowMenu` | X68 moved it into the overflow menu |
| Synthetic fixture loads, bedside renders | ✅ `MurmurUITests/testSyntheticFixtureRendersBedsideView` | Via `--ui-test-sample` (DEBUG hook — the user-facing sample button was removed deliberately); asserts `empty-state-prompt` gone once loaded |
| Open Record Folder → fileImporter opens, folder selection loads | ✅ `MurmurUIBypassTests/testLaunchArgOpenFolderLoadsRecording` | Bypasses `NSOpenPanel` via `--ui-test-open-folder`; the inline line, ⌘O, and the toolbar `⋯` item all converge on `openFolder(_:)` |
| File ▸ Open Recent → folder re-opens | ✅ `MurmurUITests/testOpeningARecentFolderReopensRecording` | `--ui-test-seed-recent` seeds the store; the menu item runs the full bookmark-resolve → scanFolder → import → bedside flow. The menu is the only recents surface since #242 |
| Open a corpus root with a `RECORDS` index (nested folders) | ✅ `MurmurTests/WFDBCorpusScannerTests` (11 fixture cases) + `WFDBCorpusScannerRealDataTests` against ecg-arrhythmia 1.0.0 | #329. Unit-level, not XCUI: the interaction is `openFolder(_:)` behind `NSOpenPanel`, already bypassed above, and the thing worth proving is which 45,152 rows the index resolves to |
| Corpus scan progress line replaces the "No record open" prompt while a scan runs | ✅ `MurmurTests/CorpusScanContextTests` | #329. The sentence is composed in `CorpusScanContext.summary` precisely so it is testable rather than assembled inline in the view; the `corpus-scan-status` element itself is manual-smoke |
| Where do I get data? | ✅ `MurmurUIBypassTests/testHelpGettingStartedTargetsDocsGettingStarted` | Help ▸ Getting Started opens the docs page whose Requirements carry the MIT-BIH link — the welcome card's PhysioNet link deliberately has no in-window replacement |

## Canvas / waveform interaction

| Interaction | Test | Notes |
| --- | --- | --- |
| Drag pan canvas → viewport advances by translation distance | ✅ `MurmurUIBypassTests/testLaunchArgPanByShiftsViewport` | Bypasses the gesture; `--ui-test-pan-by=<dx>` calls the same `viewport.setStart` mutation. Native `DragGesture` recognition stays manual-smoke (XCUI can't synthesise `NSEvent.mouseDragged`) |
| Pinch zoom canvas → viewport width scales | ✅ `MurmurUIBypassTests/testLaunchArgZoomToScalesViewportWidth` | Bypasses the gesture; `--ui-test-zoom-to=<seconds>` calls the same `viewport.setWidth` mutation. Native `MagnifyGesture` recognition stays manual-smoke |
| Hover canvas → crosshair appears at cursor | ✅ `MurmurUIBypassTests/testLaunchArgHoverInjectionRendersCrosshair` | `--ui-test-hover-at=X,Y` injection fires the hover-update closure. Hover state itself doesn't reach the accessibility tree, so the assertion is a smoke check that the injection doesn't crash. Hit-test math covered by unit tests |
| Click finding row → viewport animates to finding | ✅ `MurmurUITests/testClickingFindingRowChangesViewport` | Uses `ui-test-viewport-state` accessibility element to read pre/post state |
| Click `OverviewMap` compact strip → viewport scrubs to clicked position | ✅ `MurmurUITests/testClickingOverviewRibbonScrubsViewport` | Legacy `overview-ribbon-<lead>` accessibility id preserved on the new `OverviewMap` strip; DragGesture(minimumDistance: 0) fires `onChanged` on a single click |
| Expand `OverviewMap` + click a per-category lane → viewport jumps to fraction | ✅ `MurmurUITests/testClickingDensityLaneJumpsViewport` | Test clicks the `overview-map-expand-toggle` first, then a `density-lane-<category>` row |
| Deviation-ranked review queue: groups collapse by default | ✅ `MurmurUIBypassTests/testReviewQueueGroupsCollapseByDefault` | `finding-group-VF` present; `finding-row-VF` hidden until expansion |
| Deviation-ranked review queue: click group → exemplars appear, click again → collapse | ✅ `MurmurUIBypassTests/testReviewQueueGroupExpandRevealsExemplars` | |
| Rhythm-context banner renders from `recording.headerComments` | ✅ `MurmurUIBypassTests/testReviewQueueRhythmContextBannerRendersFromHeader` | Probes via `app.staticTexts["Rhythm context"]` — XCUI on macOS finds inner text more reliably than HStack container ids |
| Renderer produces non-blank output | ✅ `WaveformRendererDrawSceneTests/clearsToPaperPink` + `drawsTraceWhenSamplesLoaded` | Offscreen MTLTexture readback — catches the bundle-lookup / shader-compile / pipeline-state class of bug |

## Layout controls

| Interaction | Test | Notes |
| --- | --- | --- |
| Click lead chip → focus mode shifts to that lead | ✅ `MurmurUITests/testClickingLeadChipShiftsFocus` | |
| Toggle Focus / Strips layout mode | ✅ `MurmurUITests/testLayoutModeToggleShowsAllChannels` | |

## Toolbar

| Interaction | Test | Notes |
| --- | --- | --- |
| Toolbar **Open** button → fileImporter opens | ✅ `MurmurUIBypassTests/testLaunchArgOpenFolderLoadsRecording` | Shares the `--ui-test-open-folder` bypass with the launch shell's inline action (same `openFolder(_:)` path) |
| Toolbar **Findings** toggle → side panel shows/hides | ✅ `MurmurUITests/testFindingsPanelTogglesViaToolbar` | Toggles `findings-toggle`, verifies `finding-row-*` appears/disappears |
| Toolbar **Edit mode** latch → unlocks editing surfaces | ✅ `MurmurUITests/testEditModeLatchTogglesDispositionTrio` | Asserts the disposition trio appears/disappears in lock-step with the latch |
| Toolbar **Attach findings…** → file picker for sidecar JSON | ✅ `MurmurUIBypassTests/testLaunchArgAttachFindingsMergesIntoPanel` | Bypasses the JSON picker via `--ui-test-attach-findings`; the synthetic sidecar lands as `finding-row-ATTACH` |

## Findings ops (lock-gated)

| Interaction | Test | Notes |
| --- | --- | --- |
| Filter by category via summary chip | ✅ `MurmurUITests/testClickingSummaryChipFiltersFindings` | Filter math also covered by `FindingFilterTests` |
| Confirm a finding (with edit-mode latch) | ✅ `MurmurUITests/testConfirmFindingViaMenuExposesResetButton` | Disposition state also covered by `DispositionStoreTests` |
| Dismiss a finding (with edit-mode latch) | ✅ `MurmurUITests/testDismissingFindingExposesResetButton` | |
| Reset a finding to unreviewed (with edit-mode latch) | ✅ `MurmurUITests/testResetReturnsFindingToUnreviewed` | |
| Edit a finding's note in context panel | ✅ `MurmurUITests/testContextNotesEditorAppearsInEditMode` | Editor mounts only in edit-mode; the actual text round-trip is exercised in `RecordContextPanel`'s save path (debounced write to `<bundle>/notes.md`) |

## Strips (low-rate trends)

| Interaction | Test | Notes |
| --- | --- | --- |
| Click alarm-strip lane → viewport jumps to occurrence | ✅ `MurmurUITests/testClickingAlarmLaneJumpsViewport` | |
| Click quality-strip lane → viewport jumps to occurrence | ✅ `MurmurUITests/testClickingQualityLaneJumpsViewport` | |
| Click state-backdrop-strip lane → viewport jumps | ✅ `MurmurUITests/testClickingStateBackdropStripJumpsViewport` | |

## Window / menu

| Interaction | Test | Notes |
| --- | --- | --- |
| Window respects min 1100×720 bound | ✅ `MurmurUITests/testWindowHonorsMinimumSize` | Catches the App Store Guideline 4 rejection scenario |
| Help → Murmur Studio Help → opens `kvnlng.github.io/Murmur` | ✅ `MurmurUIBypassTests/testHelpMurmurStudioHelpTargetsDocsHome` + `testHelpMenuItemsExist` | URL routed through `URLLauncher`; `--ui-test-record-urls` intercepts and the test asserts the URL |
| Help → Getting Started | ✅ `MurmurUIBypassTests/testHelpGettingStartedTargetsDocsGettingStarted` | |
| Help → Annotation Schema | ✅ `MurmurUIBypassTests/testHelpAnnotationSchemaTargetsDocsAnnotationSchema` | |
| Help → Privacy Policy | ✅ `MurmurUIBypassTests/testHelpPrivacyPolicyTargetsDocsPrivacy` | |
| Help → Contact Support… | ✅ `MurmurUIBypassTests/testHelpContactSupportTargetsMailto` | `mailto:` URL routed through `URLLauncher` |

---

## Bypass strategy

Several interactions involve OS-level mechanisms XCUI on macOS can't
drive directly. We automate them anyway by routing through a hook
that bypasses the unreachable layer while exercising the same
post-mechanism code path. The bypasses are all `#if DEBUG`-gated; the
release build behaves identically to a hook-free version.

| Interaction | Bypass | What stays manual |
| --- | --- | --- |
| `NSOpenPanel` (Open / Drag-and-Drop) | `--ui-test-open-folder` calls `openFolder(_:)` directly | The system file panel UI itself (Apple's code) |
| `NSOpenPanel` (Attach findings) | `--ui-test-attach-findings` materialises a JSON and calls `handleAttachFindings(.success(url))` | Same |
| Drag-pan `DragGesture` | `--ui-test-pan-by=<dx>` calls `viewport.setStart` | Native gesture recognition (drag deltas) |
| Pinch-zoom `MagnifyGesture` | `--ui-test-zoom-to=<seconds>` calls `viewport.setWidth` | Native gesture recognition (multi-touch) |
| Hover crosshair | `--ui-test-hover-at=X,Y` invokes the hover-update closure | The crosshair visual (state not in accessibility tree) |
| `NSWorkspace.open` (Help / PhysioNet) | URLs routed through `URLLauncher`; `--ui-test-record-urls` records instead of opening | None — the URL itself is asserted |

Bypassed interactions still appear in the `RELEASE.md` smoke pass
because the bypass tests don't validate the *native* gesture or
modal — only the wiring on either side of it. The smoke pass is the
final guard on "did the user-visible mechanism actually fire?"

## Counted intentionally NOT in this list

- File-format edge cases (multi-file WFDB, etc.) — those are data
  coverage, not interaction coverage. Tested by `WFDBHeaderParserTests` etc.
- Async / progress UI during recording import — invisible to analyst
  steady-state; covered by `RecordingStoreTests`
- Snapshot-tested visual states (tooltips, axes, density timeline) —
  visual coverage, separate dimension. See `SnapshotTests`.
- Metal canvas pixel-level rendering — visual coverage; intentionally
  not snapshot-tested (GPU diff unreliable). Renderer-level coverage
  via `WaveformRendererDrawSceneTests`.
