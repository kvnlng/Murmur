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

**Current score:** 19 ✅ automated · 9 🟡 manual-only · 1 ⬜ uncovered out of 29 total.
That's **66% automated**, **97% covered by some gate** (automated + smoke).

The North Star: convert 🟡 → ✅ over time, especially for flows where the
bug class would silently degrade the analyst experience without crashing.
Update this table whenever a new interaction is added, a flow becomes
automated, or one moves between buckets.

---

## Welcome / first-run

| Interaction | Test | Notes |
| --- | --- | --- |
| Empty-state prompt visible on cold launch | ✅ `MurmurUITests/testEmptyStateIsVisible` | |
| Toolbar **Open** button exists on cold launch | ✅ `MurmurUITests/testToolbarOpenButtonExists` | |
| Click "Try a sample recording" → synthetic fixture loads, bedside renders | ✅ `MurmurUITests/testSyntheticFixtureRendersBedsideView` | Asserts `bedside-view`, `lead-chip-bar`, `channel-panel-I` present and `empty-state-prompt` gone |
| Click "Open Record Folder" → fileImporter opens, folder selection loads | 🟡 RELEASE.md smoke | `fileImporter` flows are XCUI-hostile on macOS — modal sheet escapes the test runner |
| Click a recent-folder row → folder re-opens | ✅ `MurmurUITests/testClickingRecentFolderReopensRecording` | `--ui-test-seed-recent` materialises a synthetic WFDB folder and seeds it as a recents entry; the row click runs the full scanFolder → import → bedside flow |
| Drag-and-drop a folder onto the welcome view → opens | 🟡 RELEASE.md smoke | `DropDelegate` invocation can't be synthesised by XCUI |
| Click PhysioNet link → opens browser | ⬜ Uncovered | URL launch leaves the test runner; low-value to automate |

## Canvas / waveform interaction

| Interaction | Test | Notes |
| --- | --- | --- |
| Drag pan canvas → viewport advances by translation distance | 🟡 RELEASE.md smoke | XCUI `press(forDuration:thenDragTo:)` doesn't emit `NSEvent.mouseDragged`, so `DragGesture` never fires. Viewport pan math covered by `RecordingViewportTests/panClampsLeft` and siblings. |
| Pinch zoom canvas → viewport width scales | 🟡 RELEASE.md smoke | `MagnifyGesture` not synthesisable from XCUI on macOS. Zoom math covered by `RecordingViewportTests/setWidth*` |
| Hover canvas → crosshair appears at cursor | 🟡 RELEASE.md smoke | Hover state doesn't appear in XCUI accessibility tree even with `--ui-test-hover-at=X,Y` injection. Hit-test math covered by unit tests |
| Click finding row → viewport animates to finding | ✅ `MurmurUITests/testClickingFindingRowChangesViewport` | Uses `ui-test-viewport-state` accessibility element to read pre/post state |
| Click overview ribbon → viewport scrubs to clicked position | ✅ `MurmurUITests/testClickingOverviewRibbonScrubsViewport` | DragGesture(minimumDistance: 0) fires `onChanged` on a single click |
| Click on density-timeline lane → viewport jumps to fraction | ✅ `MurmurUITests/testClickingDensityLaneJumpsViewport` | |
| Renderer produces non-blank output | ✅ `WaveformRendererDrawSceneTests/clearsToPaperPink` + `drawsTraceWhenSamplesLoaded` | Offscreen MTLTexture readback — catches the bundle-lookup / shader-compile / pipeline-state class of bug |

## Layout controls

| Interaction | Test | Notes |
| --- | --- | --- |
| Click lead chip → focus mode shifts to that lead | ✅ `MurmurUITests/testClickingLeadChipShiftsFocus` | |
| Toggle Focus / Strips layout mode | ✅ `MurmurUITests/testLayoutModeToggleShowsAllChannels` | |

## Toolbar

| Interaction | Test | Notes |
| --- | --- | --- |
| Toolbar **Open** button → fileImporter opens | 🟡 RELEASE.md smoke | See "Open Record Folder" — same modal-sheet limit |
| Toolbar **Findings** toggle → side panel shows/hides | ✅ `MurmurUITests/testFindingsPanelTogglesViaToolbar` | Toggles `findings-toggle`, verifies `finding-row-*` appears/disappears |
| Toolbar **Edit mode** latch → unlocks editing surfaces | ✅ `MurmurUITests/testEditModeLatchTogglesDispositionTrio` | Asserts the disposition trio appears/disappears in lock-step with the latch |
| Toolbar **Attach findings…** → file picker for sidecar JSON | 🟡 RELEASE.md smoke | Identifier `attach-findings`. Modal-sheet limit again |

## Findings ops (lock-gated)

| Interaction | Test | Notes |
| --- | --- | --- |
| Filter by category via summary chip | ✅ `MurmurUITests/testClickingSummaryChipFiltersFindings` | Filter math also covered by `FindingFilterTests` |
| Confirm a finding (with edit-mode latch) | ✅ `MurmurUITests/testConfirmFindingViaMenuExposesResetButton` | Disposition state also covered by `DispositionStoreTests` |
| Dismiss a finding (with edit-mode latch) | ✅ `MurmurUITests/testDismissingFindingExposesResetButton` | |
| Reset a finding to unreviewed (with edit-mode latch) | ✅ `MurmurUITests/testResetReturnsFindingToUnreviewed` | |
| Edit a finding's note in context panel | 🟡 RELEASE.md smoke | Identifier `context-notes-editor` exists |

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
| Help → Murmur Studio Help → opens `kvnlng.github.io/Murmur` | 🟡 RELEASE.md smoke | `NSWorkspace.shared.open` leaves the runner |
| Help → Getting Started | 🟡 RELEASE.md smoke | |
| Help → Annotation Schema | 🟡 RELEASE.md smoke | |
| Help → Privacy Policy | 🟡 RELEASE.md smoke | |
| Help → Contact Support… | 🟡 RELEASE.md smoke | `mailto:` link |

---

## Gaps to close (priority order)

1. **Note editor round-trip.** Requires a synthetic-fixture change —
   `RecordContextPanel` only renders when the recording has header
   comments or a notes file, and the fixture has neither. Add either
   to the synthetic record, then type into `context-notes-editor`,
   assert the text persists across editor close/reopen.

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
