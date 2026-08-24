# Lead Placement Map (#358) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Session-scoped analyst-declared map from recorded channel name → placement (free text), feeding disclosure surfaces and `LeadPreset.resolve` only — never any calculation.

**Architecture:** A new `@MainActor @Observable` session-level context (`LeadPlacementMapContext`, the scan-dial singleton shape, torn down with the working set) holds folder-level declarations plus per-record overrides. A `Codable` snapshot travels in `.mur` packages as a session-level `lead_map.json` member beside `session.json`. Disclosure surfaces (metrics header, QT clause, review table, Markdown report) render the declaration after the analysis lead's recorded name; `LeadPreset.resolve` gains an optional declared-placement lookup. Resolution (#357) and all calculation paths have no reader of the map — enforced by the before/after export-diff acceptance test.

**Tech Stack:** Swift / SwiftUI, Swift Testing (`#expect`), existing `.mur` package plumbing.

**Spec:** `docs/design/2026-08-24-analysis-lead-and-placement-map/README.md` — Part 2 (§2.1–§2.4) is binding. Out-of-scope list at the spec's end applies verbatim (#351 behaviour, automatic inference, any bundled name table, backfilling).

## Global Constraints

- Branch: `feat/358-lead-placement-map` off current `main`.
- `xcodebuild test` hangs on this machine. MurmurTests run via: `xcodebuild build-for-testing -scheme Murmur -destination 'platform=macOS' -derivedDataPath /tmp/sdd358` → ensure symlink `PackageFrameworks/MurmurCore.framework -> ../MurmurCore.framework` in `Build/Products/Debug` → `xcrun xctest Murmur.app/Contents/PlugIns/MurmurTests.xctest`. `swift test` for MurmurCoreTests. Baseline at branch: 1026 MurmurTests, 84 MurmurCoreTests.
- Release build gate before push: `xcodebuild -scheme Murmur -configuration Release -derivedDataPath /tmp/sdd358-release build` (UITestSupport is DEBUG-only).
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Exact disclosure strings (spec §2.1/§2.3, pinned by tests):
  - folder-level: `MLII (declared: II, by kevin, 2026-08-24)`
  - record override: `MLII (declared: II — record override, by kevin, 2026-08-24)`
  - Date display via the existing `AnalysisLeadHeaderLine` `en_US_POSIX`/UTC `yyyy-MM-dd` formatter (`AnalysisLead.swift:269-275`) — never the machine's zone.
- **The map has no reader in any calculation path or in `analysisLead` resolution.** No task may import/reference `LeadPlacementMapContext` from `RecordingStore`, `AnalysisLead` resolution functions, or any orchestrator's compute/cache-key path. Disclosure call sites only.
- The no-name-gate guard test (`AnalysisLeadTests.swift`, four calculation files) must stay green untouched.
- SourceKit editor diagnostics show stale-index false positives for new types; passing builds/tests are the authority.

## Plan-level rulings (spec ambiguities settled here; executors follow these)

1. **Record-override key**: spec §2.1 sketches `recordOverrides: [recordPath: …]`. The codebase's session-wide per-record key is the record id (`.hea` filename) — `CarriedSessionStore`'s convention. Use record id, not path (paths change when a folder moves; the id is what session restore already keys on).
2. **Deletion "allowed and dated"** (§2.4): deletion removes the entry and marks the session unsaved. No tombstone — the map is session-only with no history mechanism; the "dated" that matters is that surviving entries display reviewer + date, which the sheet shows.
3. **Pre-filled conventional-reading suggestion** (§2.1 "may offer"): NOT built in #358. Offering `MLII → II` requires exactly the name table the spec bans the app from shipping. The sheet pre-fills only an existing declaration when editing; otherwise the field is empty. (A curated suggestion source can be revisited under #351.)
4. **QT clause suppression** (§2.3): the not-conventional clause is suppressed only when the declared placement passes the same case/whitespace-insensitive exact-equality II/V5 test `QTLeadDisclosure` already applies to recorded names. Free text like `V5, back patch` does NOT suppress (declare `V5` to mean V5). The caption grammar stays the repo's `measured in …` (X25), not the spec's illustrative "measured on".
5. **`formatVersion` stays 1**: `lead_map.json` is additive; an old reader never looks for it, a new reader treats absence as undeclared. The version mechanism exists for breaking changes; this is not one. A package with no declarations gets NO `lead_map.json` member (byte-identical output for undeclared sessions, per §2.2).
6. **Export column names**: `declared_placement` and `declared_placement_by`. Values: the free-text placement; and `kevin, 2026-08-24` or `record override — kevin, 2026-08-24`. Empty strings when undeclared (columns always present, per §2.3 "undeclared, never omitted").

---

### Task 1: Model + session context

**Files:**
- Create: `MurmurCore/LeadPlacementMap.swift`
- Test: `MurmurTests/LeadPlacementMapTests.swift` (new)

**Interfaces:**
- Produces: `LeadPlacementDeclaration` (`placement: String`, `reviewer: String`, `declaredAt: Date`), `LeadPlacementMapSnapshot: Codable, Equatable` (`folder: [String: LeadPlacementDeclaration]`, `recordOverrides: [String: [String: LeadPlacementDeclaration]]`), `LeadPlacementMapContext` (`@MainActor @Observable final class`, `static let shared`, `public init()`).
- Context API (all `@MainActor`):
  - `func declaration(forRecordedName name: String, recordID: String?) -> (declaration: LeadPlacementDeclaration, isOverride: Bool)?` — override wins over folder entry; name matching is case/whitespace-insensitive exact equality (the `matchKey` discipline from `LeadPreset.swift:133-135`).
  - `func declare(recordedName: String, placement: String, recordID: String?, reviewer: String = ProcessInfo.processInfo.userName, at date: Date = Date())` — `recordID == nil` writes the folder entry; non-nil writes an override. Empty/whitespace-only placement is a programmer error → treat as delete.
  - `func deleteDeclaration(recordedName: String, recordID: String?)`
  - `var snapshot: LeadPlacementMapSnapshot` (get), `func restore(_ snapshot: LeadPlacementMapSnapshot)`
  - `var hasUnsavedDeclarations: Bool` — current snapshot != last-saved snapshot (the `hasUnsavedAnchoredNotes` pattern, `CurrentRecordingContext.swift:86-88`)
  - `func markSaved()` — records current snapshot as saved
  - `var isEmpty: Bool` — no folder entries and no overrides
  - `func reset()` — clears everything including the saved snapshot

- [ ] **Step 1: Write failing tests** in `MurmurTests/LeadPlacementMapTests.swift` (`@MainActor` suite; fresh `LeadPlacementMapContext()` per test, never `.shared`):

```swift
@Test("Override wins over the folder declaration and says so")
@MainActor func overrideWins() {
    let map = LeadPlacementMapContext()
    map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                reviewer: "kevin", at: fixedDate)
    map.declare(recordedName: "MLII", placement: "front patch", recordID: "100.hea",
                reviewer: "kevin", at: fixedDate)
    let folderHit = map.declaration(forRecordedName: "MLII", recordID: "101.hea")
    #expect(folderHit?.declaration.placement == "II")
    #expect(folderHit?.isOverride == false)
    let overrideHit = map.declaration(forRecordedName: "MLII", recordID: "100.hea")
    #expect(overrideHit?.declaration.placement == "front patch")
    #expect(overrideHit?.isOverride == true)
}

@Test("Name lookup is case- and whitespace-insensitive, like preset matching")
@MainActor func lookupNormalisesNames() { /* declare "MLII", look up " mlii " → hit */ }

@Test("Dirty tracking: declare → unsaved; markSaved → clean; delete → unsaved again")
@MainActor func dirtyTracking() { /* assert hasUnsavedDeclarations at each step */ }

@Test("Snapshot round-trips through Codable and restore()")
@MainActor func snapshotRoundTrip() { /* encode snapshot → decode → restore into fresh context → same lookups */ }

@Test("Empty placement deletes; reset clears everything")
@MainActor func emptyDeletesAndReset() { /* declare then declare("") → nil lookup; reset → isEmpty, not unsaved */ }
```

- [ ] **Step 2: Run to verify failure** (types don't exist).
- [ ] **Step 3: Implement** `MurmurCore/LeadPlacementMap.swift` per the interface block. File header comment states the jurisdiction rule verbatim: the map feeds disclosure and preset resolution only; it has no reader in resolution or any calculation path (spec §2.3). Snapshot Codable uses ISO8601 date strategy at the persistence call site (Task 3), not baked into the type.
- [ ] **Step 4: Run tests to verify pass.** Both suites + no regressions (1026 + new / 84).
- [ ] **Step 5: Commit** `Lead placement map: model and session context (#358)`.

---

### Task 2: `.mur` persistence, teardown, unsaved guards

**Files:**
- Modify: `MurmurCore/MurSessionPackage.swift` (write params ~:93-142, `ReadResult` ~:304-323, read ~:328-426), `Murmur/MurmurApp.swift` (`saveSessionPanel()` ~:393-442; X77 quit guard ~:28-29), `MurmurCore/ContentView.swift` (`openMurPackage` ~:362-433; `adopt(scan:from:)` ~:932-965; X78 guard ~:255-262 and discard handler ~:230-240)
- Test: `MurmurTests/MurSessionPackageTests.swift` (extend), `MurmurTests/LeadPlacementMapTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `LeadPlacementMapContext`, `LeadPlacementMapSnapshot`.
- Produces: `MurSessionPackage.leadMapFile == "lead_map.json"`; `write(records:collectionJSON:leadMapJSON:passphrase:to:now:)` (`leadMapJSON: Data?` — nil ⇒ member absent); `ReadResult.leadMapJSON: Data?`.

- [ ] **Step 1: Failing tests** (extend `MurSessionPackageTests`):

```swift
@Test(".mur round-trip: declare → save → reopen → still declared; old package → undeclared")
func leadMapRoundTrips() throws { /* write with leadMapJSON from an encoded snapshot;
    read back; decode; assert folder entry + override survive.
    Then write with leadMapJSON: nil; assert no lead_map.json member exists in the
    package and ReadResult.leadMapJSON == nil. */ }

@Test("A session with no declarations writes a byte-identical package to pre-#358")
func undeclaredPackageUnchanged() throws { /* write(records:collectionJSON:leadMapJSON: nil)
    output equals write from the pre-change signature path — assert lead_map.json absent
    and manifest contents list unchanged. */ }
```

  Encode/decode with `JSONEncoder`/`Decoder` using `.iso8601` date strategies and `.sortedKeys` output (match `AnalysisLeadFile.write`'s discipline, `AnalysisLead.swift:133-142`).

- [ ] **Step 2: Implement the package member.** `leadMapFile` constant beside `sessionFile` (`MurSessionPackage.swift:20-35`); write it at the root beside `session.json` (~:117-119); list it in manifest `contents` only when present (~:129); populate `ReadResult.leadMapJSON` where `collectionJSON` is populated (~:421-425). `formatVersion` stays 1 (plan ruling 5).
- [ ] **Step 3: Wire the call sites.**
  - Save: `saveSessionPanel()` (`MurmurApp.swift` ~:421-423) — `leadMapJSON = LeadPlacementMapContext.shared.isEmpty ? nil : try? encoder.encode(LeadPlacementMapContext.shared.snapshot)`; after a successful write, `LeadPlacementMapContext.shared.markSaved()` beside the existing `markSaved(recordIDs:)` (~:427-436).
  - Restore: `openMurPackage(_:)` — after the plan build (~:401-414, beside `CarriedSessionStore` population), decode `result.leadMapJSON` if present and `LeadPlacementMapContext.shared.restore(...)`; then `markSaved()` (restored state is not dirty). Do NOT thread through `SessionOpenPlan` (it is per-record).
  - Teardown: `LeadPlacementMapContext.shared.reset()` beside `CarriedSessionStore.shared.reset()` at all three X86 sites — `ContentView.swift` ~:238 (discard), ~:401-402 (mur open, before restore), ~:942 (folder adopt).
  - Guards: add the third disjunct `|| LeadPlacementMapContext.shared.hasUnsavedDeclarations` at BOTH guard sites — `MurmurApp.swift:28-29` (X77 quit) and `ContentView.swift:256-257` (X78 open). Read the surrounding comments and extend the dialog copy only if it currently says "notes" in a way that becomes false — prefer the existing generic wording if it already covers analyst work.
- [ ] **Step 4: Guard/teardown tests** (in `LeadPlacementMapTests`, unit-level): fresh context declare → `hasUnsavedDeclarations`; `reset()` → clean and empty. (The dialog itself is XCUI territory — unrunnable here; the disjunct is one expression, covered by the property tests.)
- [ ] **Step 5: Run both suites + Release build. Commit** `Lead map travels in .mur, tears down with the working set, rides the unsaved guards (#358)`.

---

### Task 3: Disclosure strings — header decoration + QT clause interaction

**Files:**
- Modify: `MurmurCore/AnalysisLead.swift` (`AnalysisLeadHeaderLine` ~:223-276, `QTLeadDisclosure` ~:191-215)
- Test: `MurmurTests/AnalysisLeadTests.swift` (extend), `MurmurTests/AnalysisLeadQTTests.swift` (extend)

**Interfaces:**
- Consumes: `LeadPlacementDeclaration` (Task 1). These are pure functions — callers resolve the declaration and pass it in; `AnalysisLead.swift` never imports the context (jurisdiction rule).
- Produces:
  - `LeadPlacementDisclosure.parenthetical(for declaration: LeadPlacementDeclaration, isOverride: Bool) -> String` → `(declared: II, by kevin, 2026-08-24)` / `(declared: II — record override, by kevin, 2026-08-24)` — new type in `AnalysisLead.swift` beside `AnalysisLeadHeaderLine`, reusing its `dateString` (widen `dateString` from `private` to internal `static`).
  - `AnalysisLeadHeaderLine.text(for:excludedSummary:declaration:)` and `label(for:declaration:)` — optional `(LeadPlacementDeclaration, isOverride: Bool)?` defaulted nil; when present the parenthetical follows the channel name: `MLII (declared: II, by kevin, 2026-08-24) — strongest R peaks`.
  - `QTLeadDisclosure.citedLeadName(for name: String, declaredPlacement: LeadPlacementDeclaration? = nil, isOverride: Bool = false) -> String` — when the declared placement reads as II or V5 (same exact-equality test as recorded names, plan ruling 4), the clause is suppressed and the cited name becomes `MLII (declared: II, by kevin, 2026-08-24)`; when declared but not conventional, the parenthetical is appended AND the clause stays; nil declaration ⇒ existing behaviour byte-for-byte.

- [ ] **Step 1: Failing tests** — pin the exact strings:

```swift
@Test("Header line appends the declaration parenthetical after the recorded name")
func headerShowsDeclaration() { /* label(for: resolution, declaration: (decl, false))
    == "MLII (declared: II, by kevin, 2026-08-24) — strongest R peaks" */ }

@Test("Record override says so in the parenthetical")
func overrideParenthetical() { /* "… (declared: II — record override, by kevin, 2026-08-24) …" */ }

@Test("Declared II suppresses the not-conventional QT clause; the measurement text cites the declaration")
func declaredConventionalSuppressesClause() { /* citedLeadName(for: "MLII", declaredPlacement: declII)
    contains "(declared: II" and NOT "not a conventional QT lead" */ }

@Test("A declared non-conventional placement keeps the clause")
func declaredUnconventionalKeepsClause() { /* declaredPlacement "front patch" → clause present */ }

@Test("Free text 'V5, back patch' does not read as V5 — clause stays")
func freeTextDoesNotMatchConventional() { }

@Test("No declaration: header and clause byte-identical to #357 behaviour")
func nilDeclarationUnchanged() { /* compare against the existing pinned strings */ }
```

- [ ] **Step 2: Implement.** Suppression test reuses the same normalise-and-compare the clause already applies to recorded names (`AnalysisLead.swift:210-214`) — factor the II/V5 check into one private helper both paths call so the two tests can never drift.
- [ ] **Step 3: Run both suites. Commit** `Declared placement in the header line and the QT disclosure (#358)`.

---

### Task 4: Export surfaces — review table columns + Markdown report

**Files:**
- Modify: `MurmurCore/ReviewTableBuilder.swift` (~:80-113), `MurmurCore/ReviewTableCSV.swift` (`Row` ~:30-63, `columns` ~:65-71, rendering ~:113-114), `MurmurCore/MarkdownReport.swift` (~:38, ~:57-67), `docs/annotation-schema.md`
- Test: `MurmurTests/ReviewTableTests.swift` (extend), `MurmurTests/MurmurTests.swift` (MarkdownReport suite, extend)

**Interfaces:**
- Consumes: Task 1 context (ReviewTableBuilder's caller passes a snapshot or lookup — keep the builder pure: it takes `declaredPlacementLookup: (String, String?) -> (LeadPlacementDeclaration, Bool)?` or the snapshot value, resolved per record like `analysisLead` is at ~:80-84), Task 3's `LeadPlacementDisclosure`.
- Produces: CSV columns `declared_placement`, `declared_placement_by` appended after `analysis_lead_reason` (indices 22/23 of 25). Values per plan ruling 6; empty when undeclared. Markdown report line gains the parenthetical after the recorded name (same composition as the header — but keep the export reason vocabulary; only the name gains the parenthetical).

- [ ] **Step 1: Failing tests**: declared folder-level → every record's rows carry `II` / `kevin, 2026-08-24`; override row carries `record override — kevin, 2026-08-24`; undeclared dataset → both columns present and empty in header + all rows; Markdown line reads `- **Analysis lead**: MLII (declared: II, by kevin, 2026-08-24) — r-peak score 6.13`.
- [ ] **Step 2: Implement.** Builder resolves the declaration once per record beside the `analysisLead` resolve; `MurSessionPackage`/callers thread the lookup the same way `analysisLead` is threaded into `MarkdownReport.generate` (caller-resolved, pure function — `MarkdownReport.swift:33-37` comment states the discipline).
- [ ] **Step 3: Update `docs/annotation-schema.md`**: the two new columns (names, value shapes, "empty = undeclared, never omitted", override wording), and note the vocabulary is the analyst's free text carried verbatim.
- [ ] **Step 4: Run both suites. Commit** `Declared placement in the review table, report and schema docs (#358)`.

---

### Task 5: UI — declare/delete sheet + menu + header tap

**Files:**
- Modify: `MurmurCore/ChannelPanel.swift` (`AnalysisLeadHooks` ~:49-59, menu ~:715-740), `MurmurCore/BedsideView.swift` (hooks builder ~:2992-3006, header line call ~:2240 area, sheet wiring near the gain sheet ~:791-797/:2957)
- Create: `MurmurCore/LeadPlacementSheet.swift`
- Test: `MurmurTests/LeadPlacementMapTests.swift` (extend — sheet model logic only; XCUI is unrunnable on this machine, disclose in PR)

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces: `AnalysisLeadHooks` gains `declarePlacement: () -> Void` and `declaredPlacement: (LeadPlacementDeclaration, isOverride: Bool)?`; menu item `"Declare placement…"` (accessibility id `bedside-context-declare-placement`) shown for every non-trend channel (declaring an empty channel's name is legitimate — it is a statement about the folder's wiring, not a computation input; contrast with designation's populated-only rule); `LeadPlacementSheet` (channel name, folder/record scope picker, free-text field pre-filled only when editing an existing declaration — plan ruling 3, reviewer/date display, Delete button when editing); header's declared-placement text opens the sheet for the analysis lead.

- [ ] **Step 1: Sheet-model tests** (pure logic): initial field value (empty vs existing declaration vs override), save routes to `declare(recordedName:placement:recordID:)` with the chosen scope, delete routes to `deleteDeclaration`, whitespace-only save deletes.
- [ ] **Step 2: Implement the sheet** on the `.sheet(item:)` per-channel pattern (the gain sheet exemplar, `BedsideView.swift:791-797`, `@State private var placementSheetChannel: Channel?`). Menu item sits beside designate/revert with the same ungated discipline (declaring is a statement about the record — the comment at `ChannelPanel.swift:715-721` applies verbatim). Wire `BedsideView`'s header-line call to pass the current declaration (from `LeadPlacementMapContext.shared`, looked up with the analysis lead's recorded name + current record id) into `AnalysisLeadHeaderLine.text`.
- [ ] **Step 3: Re-render on change.** The context is `@Observable` and read inside `body` — mutation re-renders the header and menu automatically; verify no `.task(id:)` needs a key (the map must NOT touch any orchestrator key — jurisdiction rule; nothing recomputes).
- [ ] **Step 4: Run both suites + Release. Commit** `Declare-placement sheet, context menu and header wiring (#358)`.

---

### Task 6: `LeadPreset.resolve` hook

**Files:**
- Modify: `MurmurCore/LeadPreset.swift` (`resolve` ~:105-131), `MurmurCore/LeadChipBar.swift` (call sites :128, :177)
- Test: `MurmurTests/MurmurTests.swift` (LeadPreset suite, extend)

**Interfaces:**
- Consumes: nothing from the context directly — the lookup is a plain dictionary parameter.
- Produces: `resolve(in channels: [Channel], declaredPlacements: [String: String]? = nil) -> Resolution?` — for each preset lead name, a channel matches if its recorded name matches (existing rule) OR `declaredPlacements[matchKey(channel.name)]`'s value matches the preset lead by the same `matchKey` equality. Recorded-name match wins ties; first-match-wins duplicate rule preserved. `LeadChipBar` passes the folder+override-merged map for the current record from `LeadPlacementMapContext.shared` (a small `declaredPlacements(forRecordID:)` accessor on the context, added here).

- [ ] **Step 1: Failing tests**: `MLII` channel + declaration `MLII → II` resolves a limb preset (`Limb — 1 of 6` shape: selection found, missing lists the rest); no declaration → unresolved as today; `V5, back patch` does not match `V5`; recorded-name match beats declaration on conflicts.
- [ ] **Step 2: Implement** — hook only; no seeding, no omission behaviour (#351). Update the file-header comment ("no aliasing" ~:14-29) to state the one sanctioned exception: analyst-declared placements, passed in by the caller, never a bundled table.
- [ ] **Step 3: Run both suites. Commit** `LeadPreset.resolve matches analyst-declared placements (#358)`.

---

### Task 7: Acceptance, isolation proof, docs

**Files:**
- Test: `MurmurTests/LeadPlacementMapTests.swift` (extend)
- Modify: `docs/reviewing-a-holter-database.md` (§4/§5), `docs/what-murmur-asserts.md` (rule 4, after the #357 sentence at ~:86-88)

**Interfaces:** consumes everything prior.

- [ ] **Step 1: The isolation acceptance test** (the issue's own gate, spec §2.3):

```swift
@Test("Declaring changes nothing but the placement columns — export before/after diff")
@MainActor func declarationChangesOnlyPlacementColumns() async throws {
    // Import a 2-record fixture via a temp RecordingStore. Build the review-table
    // CSV and the Markdown report for both records BEFORE any declaration.
    // Declare MLII → II folder-wide. Rebuild both exports.
    // CSV: split every row on ','; assert indices 0..<22 identical before/after,
    // and only declared_placement/declared_placement_by changed.
    // Markdown: assert the reports differ ONLY on the analysis-lead line's
    // parenthetical (strip it → byte-identical).
}
```

- [ ] **Step 2: Multi-record propagation + teardown tests**: folder declaration shows on every record's header line; override wins on its record only; `reset()` (the folder-switch path) leaves a fresh context undeclared.
- [ ] **Step 3: Docs.**
  - `what-murmur-asserts.md`, rule 4, one sentence directly after the #357 sentence: "The app asserts no lead-name meanings; a declared placement is the analyst's statement about the recording setup, carried verbatim with its reviewer and date, and it never selects or gates a calculation."
  - `reviewing-a-holter-database.md` §5: after the existing MLII/preset walkthrough, add the declaration flow (right-click MLII → Declare placement… → `II` → presets now resolve `Limb — 1 of 6` on record 100) and note the disclosure wording; §4: one line that declared placements appear in the review table's `declared_placement` columns and are the analyst's assertions, not the producer's.
- [ ] **Step 4: Full gate.** Both suites green via the workaround + `swift test`; Release build. Commit `Acceptance: declarations feed disclosure only; docs (#358)`. Push/PR/merge/close are the controller's finishing flow, not a task step.

---

## Self-review checklist (run after drafting, before executing)

- Spec §2.1→T1/T5 (model, free text, no table, suggestion ruled out), §2.2→T1/T2 (context shape, lead_map.json, teardown ×3, X77/X78, formatVersion ruling), §2.3→T3/T4/T6/T7 (header, QT clause, columns, preset hook, isolation test), §2.4→T5/T7 (sheet, menu, docs). Out-of-scope list respected (no #351 behaviour, no inference, no backfill).
- Names used across tasks: `LeadPlacementMapContext.shared`, `LeadPlacementDeclaration`, `LeadPlacementMapSnapshot`, `LeadPlacementDisclosure.parenthetical(for:isOverride:)`, `leadMapFile`/`leadMapJSON`, `declared_placement`/`declared_placement_by`, `declaredPlacements:` — consistent as written.
- Known adaptation points: exact `write(...)` parameter threading (one caller, `saveSessionPanel`), the guard-dialog copy check (T2 step 3), `dateString` visibility widening (T3), ReviewTableBuilder's lookup shape (T4 — builder purity over convenience). Executor checks, not open design questions.
