//
//  LeadPlacementMapTests.swift
//  MurmurTests
//
//  #358: the lead-placement-map model and session context. Every test
//  constructs a fresh `LeadPlacementMapContext()` — never `.shared` — so
//  parallel test runs stay isolated from each other and from live state.
//

import Foundation
@testable import MurmurCore
import Testing

@MainActor
@Suite("Lead placement map — model and session context")
struct LeadPlacementMapTests {
    private var fixedDate: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    @Test("Override wins over the folder declaration and says so")
    func overrideWins() {
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
    func lookupNormalisesNames() {
        let map = LeadPlacementMapContext()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)

        let hit = map.declaration(forRecordedName: " mlii ", recordID: nil)
        #expect(hit?.declaration.placement == "II")
        #expect(hit?.isOverride == false)

        // Same normalisation applies to an override lookup.
        map.declare(recordedName: "V5", placement: "front patch", recordID: "100.hea",
                    reviewer: "kevin", at: fixedDate)
        let overrideHit = map.declaration(forRecordedName: " V5\n", recordID: "100.hea")
        #expect(overrideHit?.declaration.placement == "front patch")
        #expect(overrideHit?.isOverride == true)
    }

    @Test("Dirty tracking: declare → unsaved; markSaved → clean; delete → unsaved again")
    func dirtyTracking() {
        let map = LeadPlacementMapContext()
        #expect(map.hasUnsavedDeclarations == false)

        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        #expect(map.hasUnsavedDeclarations == true)

        map.markSaved()
        #expect(map.hasUnsavedDeclarations == false)

        map.deleteDeclaration(recordedName: "MLII", recordID: nil)
        #expect(map.hasUnsavedDeclarations == true)
    }

    @Test("Snapshot round-trips through Codable and restore()")
    func snapshotRoundTrip() throws {
        let map = LeadPlacementMapContext()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "MLII", placement: "front patch", recordID: "100.hea",
                    reviewer: "kevin", at: fixedDate)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(map.snapshot)
        let decoded = try decoder.decode(LeadPlacementMapSnapshot.self, from: data)
        #expect(decoded == map.snapshot)

        let restored = LeadPlacementMapContext()
        restored.restore(decoded)

        let folderHit = restored.declaration(forRecordedName: "MLII", recordID: "101.hea")
        #expect(folderHit?.declaration.placement == "II")
        #expect(folderHit?.isOverride == false)

        let overrideHit = restored.declaration(forRecordedName: "MLII", recordID: "100.hea")
        #expect(overrideHit?.declaration.placement == "front patch")
        #expect(overrideHit?.isOverride == true)
    }

    /// #358: the property the X77/X78 unsaved-work guards' third disjunct
    /// reads, and the property `reset()` (fired at every X86 teardown site —
    /// discard, `.mur` open, folder adopt) must clear. The dialogs
    /// themselves are XCUI territory and unrunnable here; this is the one
    /// expression the disjunct evaluates.
    @Test("Guard/teardown: declare flags unsaved; reset() clears and marks clean")
    func guardAndTeardown() {
        let map = LeadPlacementMapContext()
        #expect(map.hasUnsavedDeclarations == false)

        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        #expect(map.hasUnsavedDeclarations == true)

        map.reset()
        #expect(map.isEmpty == true)
        #expect(map.hasUnsavedDeclarations == false)
    }

    // MARK: - Declare-placement sheet model (#358 Task 5)
    //
    // The sheet's VIEW is XCUI territory and unrunnable on this machine; these
    // pin everything the view delegates: what the field opens on, which scope
    // a save lands on, and what Delete withdraws.

    private func sheetModel(recordID: String? = "WFDBRecords/01/010/JS00001.hea")
    -> LeadPlacementSheetModel {
        LeadPlacementSheetModel(recordedName: "MLII", recordID: recordID)
    }

    @Test("Sheet opens empty when nothing is declared, on folder scope")
    func sheetInitialStateUndeclared() {
        let map = LeadPlacementMapContext()
        let model = sheetModel()

        #expect(model.text(in: map, scope: .folder).isEmpty)
        #expect(model.text(in: map, scope: .record).isEmpty)
        #expect(model.initialScope(in: map) == .folder)
        #expect(model.existingDeclaration(in: map, scope: .folder) == nil)
        #expect(model.existingDeclaration(in: map, scope: .record) == nil)
    }

    @Test("Sheet pre-fills the folder declaration — and only ever a declaration")
    func sheetInitialStateFolderDeclaration() {
        let map = LeadPlacementMapContext()
        let model = sheetModel()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)

        // Opened from a record that has no override of its own: the FOLDER
        // text is what's in view, on folder scope.
        #expect(model.text(in: map, scope: model.initialScope(in: map)) == "II")
        #expect(model.initialScope(in: map) == .folder)
        #expect(model.existingDeclaration(in: map, scope: .folder)?.placement == "II")
        // The folder baseline is not reported as this record's own — Delete
        // at record scope must not offer to withdraw something else's.
        #expect(model.existingDeclaration(in: map, scope: .record) == nil)

        // Plan ruling 3: an undeclared name pre-fills NOTHING, however
        // conventional a reading of it might be.
        let v5 = LeadPlacementSheetModel(recordedName: "V5", recordID: model.recordID)
        #expect(v5.text(in: map, scope: .folder).isEmpty)
        #expect(v5.text(in: map, scope: .record).isEmpty)
    }

    @Test("Sheet opens on record scope, showing the override, when one exists")
    func sheetInitialStateOverride() {
        let map = LeadPlacementMapContext()
        let model = sheetModel()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "MLII", placement: "front patch",
                    recordID: model.recordID, reviewer: "kevin", at: fixedDate)

        #expect(model.initialScope(in: map) == .record)
        #expect(model.text(in: map, scope: model.initialScope(in: map)) == "front patch")
        #expect(model.existingDeclaration(in: map, scope: .record)?.placement == "front patch")
        #expect(model.existingDeclaration(in: map, scope: .folder)?.placement == "II")
    }

    /// The contract the sheet's `.onChange(of: scope)` re-derivation rests on:
    /// the field is PER SCOPE. Without it the picker moved while the field
    /// kept the previous scope's wording, and Declare wrote a record's
    /// exception over the folder baseline (or the reverse). The view calls
    /// exactly this helper, on open and on every picker move.
    @Test("The field is re-derived per scope — the two scopes never share text")
    func sheetTextIsPerScope() {
        let map = LeadPlacementMapContext()
        let model = sheetModel()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "MLII", placement: "front patch",
                    recordID: model.recordID, reviewer: "kevin", at: fixedDate)

        #expect(model.text(in: map, scope: .record) == "front patch")
        #expect(model.text(in: map, scope: .folder) == "II")

        // With no override of this record's own, record scope offers the
        // declaration in force here — the baseline — which is what makes
        // "amend the folder wording, save as this record only" work. Folder
        // scope is never fed an override's wording, which is the direction
        // that could silently overwrite a baseline.
        let fresh = LeadPlacementMapContext()
        fresh.declare(recordedName: "MLII", placement: "II", recordID: nil,
                      reviewer: "kevin", at: fixedDate)
        #expect(model.text(in: fresh, scope: .record) == "II")
        #expect(model.text(in: fresh, scope: .folder) == "II")

        // An override with no baseline behind it: folder scope is empty, not
        // the override's text.
        let overrideOnly = LeadPlacementMapContext()
        overrideOnly.declare(recordedName: "MLII", placement: "front patch",
                             recordID: model.recordID, reviewer: "kevin", at: fixedDate)
        #expect(overrideOnly.declaration(forRecordedName: "MLII", recordID: model.recordID)?
            .isOverride == true)
        #expect(model.text(in: overrideOnly, scope: .record) == "front patch")
        #expect(model.text(in: overrideOnly, scope: .folder).isEmpty)
    }

    @Test("Save routes to the chosen scope — record scope writes an override")
    func sheetSaveRoutesByScope() {
        let map = LeadPlacementMapContext()
        let model = sheetModel()

        model.save("II", scope: .folder, in: map)
        #expect(map.declaration(forRecordedName: "MLII", recordID: nil)?
            .declaration.placement == "II")

        // Editing the folder wording and saving "this record only" leaves the
        // baseline standing and writes an exception over it.
        model.save("front patch", scope: .record, in: map)
        let hit = map.declaration(forRecordedName: "MLII", recordID: model.recordID)
        #expect(hit?.declaration.placement == "front patch")
        #expect(hit?.isOverride == true)
        #expect(map.declaration(forRecordedName: "MLII", recordID: nil)?
            .declaration.placement == "II")
    }

    @Test("Delete withdraws at the scope shown; the override goes, the baseline stays")
    func sheetDeleteRoutesByScope() {
        let map = LeadPlacementMapContext()
        let model = sheetModel()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "MLII", placement: "front patch",
                    recordID: model.recordID, reviewer: "kevin", at: fixedDate)

        model.delete(scope: .record, in: map)
        let afterRecordDelete = map.declaration(forRecordedName: "MLII", recordID: model.recordID)
        #expect(afterRecordDelete?.declaration.placement == "II")
        #expect(afterRecordDelete?.isOverride == false)

        model.delete(scope: .folder, in: map)
        #expect(map.declaration(forRecordedName: "MLII", recordID: model.recordID) == nil)
        #expect(map.isEmpty == true)
    }

    @Test("Saving whitespace only is a withdrawal, at either scope")
    func sheetWhitespaceSaveDeletes() {
        let map = LeadPlacementMapContext()
        let model = sheetModel()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "MLII", placement: "front patch",
                    recordID: model.recordID, reviewer: "kevin", at: fixedDate)

        model.save("   ", scope: .record, in: map)
        #expect(map.declaration(forRecordedName: "MLII", recordID: model.recordID)?
            .isOverride == false)

        model.save("\n ", scope: .folder, in: map)
        #expect(map.declaration(forRecordedName: "MLII", recordID: model.recordID) == nil)
        #expect(map.isEmpty == true)
    }

    @Test("With no record id the record scope is neither offered nor writable")
    func sheetWithoutRecordID() {
        let map = LeadPlacementMapContext()
        let model = sheetModel(recordID: nil)
        #expect(model.canScopeToRecord == false)
        #expect(sheetModel().canScopeToRecord == true)

        // A record-scoped call with no id must write NOTHING — declaring
        // folder-wide instead would be a far broader assertion than the one
        // that was asked for.
        model.save("front patch", scope: .record, in: map)
        #expect(map.isEmpty == true)

        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        model.delete(scope: .record, in: map)
        #expect(map.declaration(forRecordedName: "MLII", recordID: nil)?
            .declaration.placement == "II")
        #expect(model.initialScope(in: map) == .folder)
    }

    /// The ledgered seam: the sheet writes under the NAVIGATOR's record id
    /// (root-relative path), which is the id both export paths look up with.
    /// The bare `.hea` filename — `Recording.sourceFileName`, which
    /// `BedsideView`'s Markdown export used to pass — is a different string
    /// on a nested corpus, and an override written under one is invisible
    /// under the other. This is that failure, pinned.
    @Test("Nested corpus: the override is keyed by the navigator id, not the bare filename")
    func sheetWritesUnderTheNavigatorRecordID() {
        let map = LeadPlacementMapContext()
        let navigatorID = "WFDBRecords/01/010/JS00001.hea"
        let bareFilename = "JS00001.hea"
        let model = LeadPlacementSheetModel(recordedName: "MLII", recordID: navigatorID)

        model.save("front patch", scope: .record, in: map)

        let byNavigatorID = map.declaration(forRecordedName: "MLII", recordID: navigatorID)
        #expect(byNavigatorID?.declaration.placement == "front patch")
        #expect(byNavigatorID?.isOverride == true)
        // The old export lookup, on the same map: nothing.
        #expect(map.declaration(forRecordedName: "MLII", recordID: bareFilename) == nil)
    }

    @Test("Empty placement deletes; reset clears everything")
    func emptyDeletesAndReset() {
        let map = LeadPlacementMapContext()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        #expect(map.declaration(forRecordedName: "MLII", recordID: nil) != nil)

        map.declare(recordedName: "MLII", placement: "", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        #expect(map.declaration(forRecordedName: "MLII", recordID: nil) == nil)

        map.declare(recordedName: "V5", placement: "front patch", recordID: "100.hea",
                    reviewer: "kevin", at: fixedDate)
        map.markSaved()
        #expect(map.isEmpty == false)

        map.reset()
        #expect(map.isEmpty == true)
        #expect(map.hasUnsavedDeclarations == false)
    }

    // MARK: - #358 Task 7: header-line propagation and teardown

    private func mliiChannel() -> Channel {
        Channel(
            id: UUID(), name: "MLII", unit: "mV", sampleRate: 360,
            startTimeUnixMS: 0, sampleCount: 3600, storageFileName: "ch.bin", pyramid: []
        )
    }

    /// The propagation half of the issue's gate: a folder-wide declaration
    /// must reach every record's header line unchanged, and an override on
    /// one record must never leak onto another's. Both facts are read
    /// through `AnalysisLeadHeaderLine`'s declaration-aware overload — the
    /// same function `BedsideView`'s header renders through — with the
    /// declaration looked up per record from a LOCAL context, exactly as a
    /// real caller would.
    @Test("Header-line propagation: folder declaration reaches every record; an override stays local")
    func headerLinePropagatesFolderWideOverrideStaysLocal() {
        let map = LeadPlacementMapContext()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)

        let resolution = AnalysisLeadResolution(
            channel: mliiChannel(), provenance: .firstInFile, staleDesignation: nil)
        let expectedDate = AnalysisLeadHeaderLine.dateString(fixedDate)

        let decl100 = map.declaration(forRecordedName: "MLII", recordID: "100.hea")
        let decl101 = map.declaration(forRecordedName: "MLII", recordID: "101.hea")
        #expect(decl100?.isOverride == false)
        #expect(decl101?.isOverride == false)

        let line100 = AnalysisLeadHeaderLine.text(for: resolution, excludedSummary: nil, declaration: decl100)
        let line101 = AnalysisLeadHeaderLine.text(for: resolution, excludedSummary: nil, declaration: decl101)
        // The folder baseline reaches both records, worded identically.
        #expect(line100 == line101)
        #expect(line100.contains("(declared: II, by kevin, \(expectedDate))"))

        // An override on 100 changes ONLY 100's line — 101 keeps reading
        // the folder baseline, byte-identical to before the override.
        map.declare(recordedName: "MLII", placement: "front patch", recordID: "100.hea",
                    reviewer: "kevin", at: fixedDate)
        let decl100Override = map.declaration(forRecordedName: "MLII", recordID: "100.hea")
        let decl101Unchanged = map.declaration(forRecordedName: "MLII", recordID: "101.hea")
        #expect(decl100Override?.isOverride == true)
        #expect(decl101Unchanged?.isOverride == false)

        let line100Override = AnalysisLeadHeaderLine.text(
            for: resolution, excludedSummary: nil, declaration: decl100Override)
        let line101Unchanged = AnalysisLeadHeaderLine.text(
            for: resolution, excludedSummary: nil, declaration: decl101Unchanged)
        #expect(line100Override.contains("(declared: front patch — record override, by kevin, \(expectedDate))"))
        #expect(line100Override != line100)
        #expect(line101Unchanged == line101)
    }

    /// The teardown half: `reset()` — fired at every X86 teardown site
    /// (discard, `.mur` open, folder adopt) — must leave every record's
    /// header line reading exactly as it would in a context that was never
    /// declared into at all, not merely "no longer dirty".
    @Test("reset() clears propagation: every record's header line reverts to the undeclared line")
    func resetClearsHeaderLinePropagation() {
        let map = LeadPlacementMapContext()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "MLII", placement: "front patch", recordID: "100.hea",
                    reviewer: "kevin", at: fixedDate)
        #expect(map.declaration(forRecordedName: "MLII", recordID: "100.hea") != nil)
        #expect(map.declaration(forRecordedName: "MLII", recordID: "101.hea") != nil)

        map.reset()

        #expect(map.declaration(forRecordedName: "MLII", recordID: "100.hea") == nil)
        #expect(map.declaration(forRecordedName: "MLII", recordID: "101.hea") == nil)
        #expect(map.isEmpty == true)

        let resolution = AnalysisLeadResolution(
            channel: mliiChannel(), provenance: .firstInFile, staleDesignation: nil)
        let neverDeclared = LeadPlacementMapContext()
        let baseline = AnalysisLeadHeaderLine.text(
            for: resolution, excludedSummary: nil,
            declaration: neverDeclared.declaration(forRecordedName: "MLII", recordID: "100.hea"))
        let afterReset = AnalysisLeadHeaderLine.text(
            for: resolution, excludedSummary: nil,
            declaration: map.declaration(forRecordedName: "MLII", recordID: "100.hea"))

        #expect(afterReset == baseline)
        #expect(!afterReset.contains("declared:"))
    }

    // MARK: - #358 Task 7: the isolation acceptance test (spec §2.3, the issue's own gate)

    /// The end-to-end acceptance test the issue itself gates on: declaring
    /// a placement must change nothing in either export except the two
    /// placement columns / the analysis-lead line's parenthetical. A real
    /// two-record fixture goes through a real `RecordingStore` import (the
    /// #357 acceptance test's WFDBRecordWriter → temp-store pattern), so
    /// the "before" and "after" exports are built from real bundle
    /// directories, not synthetic `Recording` values — the closest this
    /// suite comes to driving the actual declare-and-export path without
    /// XCUI.
    @Test("Declaring changes nothing but the placement columns — export before/after diff")
    @MainActor func declarationChangesOnlyPlacementColumns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lead-placement-map-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("lead-placement-map-acceptance-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }

        // Two single-channel records, both recorded as "MLII" — the name
        // the folder-wide declaration below targets. Content is immaterial
        // (no scorer is registered; a single-channel record resolves to
        // its only channel regardless of provenance).
        let samples1 = (0..<360).map { Int32($0 % 20 == 0 ? 200 : 0) }
        let samples2 = (0..<360).map { Int32($0 % 25 == 0 ? 150 : 0) }
        try WFDBRecordWriter.write(
            recordName: "rec1", channelSamples: [samples1], sampleRateHz: 360,
            leadNames: ["MLII"], calibration: .init(gain: 200, baseline: 0, unit: "mV"),
            in: source
        )
        try WFDBRecordWriter.write(
            recordName: "rec2", channelSamples: [samples2], sampleRateHz: 360,
            leadNames: ["MLII"], calibration: .init(gain: 200, baseline: 0, unit: "mV"),
            in: source
        )

        let summary1 = try await store.importWFDB(folderURL: source, heaFilename: "rec1.hea")
        let summary2 = try await store.importWFDB(folderURL: source, heaFilename: "rec2.hea")

        // `WFDBRecordWriter` has no annotation-file path, and a review
        // table needs at least one row per record to have anything to
        // diff — so annotations are attached here, on copies that keep
        // every other field (channels, device, source filename, and
        // critically the REAL bundle directory) straight from the import.
        func withAnnotations(_ recording: Recording, _ annotations: [Annotation]) -> Recording {
            Recording(
                version: recording.version, id: recording.id, device: recording.device,
                createdAt: recording.createdAt, sourceFileName: recording.sourceFileName,
                channels: recording.channels, annotations: annotations,
                headerComments: recording.headerComments, notesFileName: recording.notesFileName,
                hasAbsoluteStartTime: recording.hasAbsoluteStartTime
            )
        }
        let recording1 = withAnnotations(summary1.recording, [
            Annotation(kind: .range, sampleIndex: 10, endSampleIndex: 60, category: "AFib", source: "physionet-dx"),
        ])
        let recording2 = withAnnotations(summary2.recording, [
            Annotation(kind: .point, sampleIndex: 200, category: "PVC", source: "physionet-dx"),
        ])

        let sources = [
            ReviewTableBuilder.Source(recordPath: "rec1.hea", imported: .init(
                recording: recording1, dispositions: [:], headerComments: recording1.headerComments,
                bundleDirectory: summary1.directory)),
            ReviewTableBuilder.Source(recordPath: "rec2.hea", imported: .init(
                recording: recording2, dispositions: [:], headerComments: recording2.headerComments,
                bundleDirectory: summary2.directory)),
        ]

        let resolution1 = try #require(recording1.analysisLead(inBundle: summary1.directory))
        let resolution2 = try #require(recording2.analysisLead(inBundle: summary2.directory))
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let tally = DispositionStore.Tally(confirmed: 0, dismissed: 0, unreviewed: 1)

        // -- BEFORE: nothing declared.
        let csvBefore = ReviewTableBuilder.build(sources: sources, flaggedIDs: []).csv
        let mdBefore1 = MarkdownReport.generate(
            recording: recording1, annotations: recording1.annotations, dispositions: [:],
            tally: tally, analysisLead: resolution1, now: now)
        let mdBefore2 = MarkdownReport.generate(
            recording: recording2, annotations: recording2.annotations, dispositions: [:],
            tally: tally, analysisLead: resolution2, now: now)

        // -- Declare MLII → II, folder-wide.
        let map = LeadPlacementMapContext()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)

        // -- AFTER: both exports rebuilt from the SAME sources, with a
        // lookup built from the local context (never `.shared`).
        let csvAfter = ReviewTableBuilder.build(
            sources: sources, flaggedIDs: [],
            declaredPlacementLookup: { name, recordID in
                map.declaration(forRecordedName: name, recordID: recordID)
            }
        ).csv
        let declaration1 = map.declaration(forRecordedName: "MLII", recordID: "rec1.hea")
        let declaration2 = map.declaration(forRecordedName: "MLII", recordID: "rec2.hea")
        let mdAfter1 = MarkdownReport.generate(
            recording: recording1, annotations: recording1.annotations, dispositions: [:],
            tally: tally, analysisLead: resolution1, declaredPlacement: declaration1, now: now)
        let mdAfter2 = MarkdownReport.generate(
            recording: recording2, annotations: recording2.annotations, dispositions: [:],
            tally: tally, analysisLead: resolution2, declaredPlacement: declaration2, now: now)

        // -- CSV diff: every column up to (not including) `declared_placement`
        // is byte-identical before/after; only the last two columns change.
        let linesBefore = csvBefore.split(separator: "\n")
        let linesAfter = csvAfter.split(separator: "\n")
        #expect(linesBefore.count == linesAfter.count)
        #expect(linesBefore.count == 3) // header + 2 data rows
        #expect(linesBefore[0] == linesAfter[0]) // column names untouched

        let unaffectedColumnCount = ReviewTableCSV.columns.count - 2 // declared_placement, declared_placement_by
        for rowIndex in 1..<linesBefore.count {
            let beforeFields = linesBefore[rowIndex].split(separator: ",", omittingEmptySubsequences: false)
            let afterFields = linesAfter[rowIndex].split(separator: ",", omittingEmptySubsequences: false)
            #expect(Array(beforeFields.prefix(unaffectedColumnCount))
                == Array(afterFields.prefix(unaffectedColumnCount)))
            // declared_placement itself: empty before, "II" after.
            #expect(beforeFields[unaffectedColumnCount] == "")
            #expect(afterFields[unaffectedColumnCount] == "II")
        }
        // declared_placement_by: present nowhere before, present (and
        // unquoted-comma-free — a folder baseline, not an override) after.
        #expect(!csvBefore.contains("kevin, "))
        #expect(csvAfter.contains(",II,\"kevin, "))
        #expect(!csvAfter.contains("record override"))

        // -- Markdown diff: the reports differ ONLY on the analysis-lead
        // line's declared-placement parenthetical — strip it and the two
        // reports must be byte-identical.
        func strippingDeclaredParenthetical(_ report: String) -> String {
            guard let openRange = report.range(of: " (declared: "),
                  let closeRange = report.range(of: ")", range: openRange.upperBound..<report.endIndex)
            else { return report }
            var result = report
            result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            return result
        }
        #expect(mdBefore1 != mdAfter1)
        #expect(mdBefore2 != mdAfter2)
        #expect(strippingDeclaredParenthetical(mdAfter1) == mdBefore1)
        #expect(strippingDeclaredParenthetical(mdAfter2) == mdBefore2)
    }

    // MARK: - #358 review wave: accessor, normalisation, caliper card

    /// `declaredPlacements(forRecordID:)` is what `LeadPreset.resolve` is
    /// handed, so its merge precedence is load-bearing for preset
    /// resolution — pinned directly rather than only through the preset hook.
    @Test("declaredPlacements merges folder + overrides, override shadowing; nil id is folder-only")
    func declaredPlacementsMergesOverridesOverFolder() {
        let map = LeadPlacementMapContext()
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "V1", placement: "V1", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "MLII", placement: "front patch", recordID: "100.hea",
                    reviewer: "kevin", at: fixedDate)
        map.declare(recordedName: "V5", placement: "V5", recordID: "100.hea",
                    reviewer: "kevin", at: fixedDate)

        // Keys are the normalised recorded names, values the placement text.
        let onRecord = map.declaredPlacements(forRecordID: "100.hea")
        #expect(onRecord["mlii"] == "front patch")   // override shadows folder
        #expect(onRecord["v1"] == "V1")              // folder baseline survives
        #expect(onRecord["v5"] == "V5")              // override-only name is present
        #expect(onRecord.count == 3)

        // A record with no overrides sees the folder baseline unchanged.
        let otherRecord = map.declaredPlacements(forRecordID: "101.hea")
        #expect(otherRecord == ["mlii": "II", "v1": "V1"])

        // `nil` is the folder-wide question: no override may leak into it.
        let folderOnly = map.declaredPlacements(forRecordID: nil)
        #expect(folderOnly == ["mlii": "II", "v1": "V1"])
    }

    @Test("Interior whitespace in a placement collapses to single spaces")
    func placementInteriorWhitespaceCollapses() {
        let map = LeadPlacementMapContext()
        map.declare(recordedName: "MLII", placement: "  front\n\tchest   patch \n", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        #expect(map.declaration(forRecordedName: "MLII", recordID: nil)?.declaration.placement
                == "front chest patch")
    }

    private func templateOnLead(_ lead: String?) -> MarkingsTemplate {
        MarkingsTemplate(
            sampleCount: 214,
            medianPRMs: nil, iqrPRMs: nil,
            medianQRSMs: nil, iqrQRSMs: nil,
            medianQTMs: nil, iqrQTMs: nil,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 410, iqrQTcMs: 12,
            sourceLead: lead
        )
    }

    /// The caliper card's provenance footer, through the SAME entry point
    /// the view renders through (`templateProvenanceText(_:sampleRate:
    /// placementMap:recordID:)`) — so declaring MLII → II reaches the QT
    /// surface, which is the whole point of §2.3.
    @Test("Caliper footer: a declared II retires the QT clause and states the assertion")
    func caliperFooterHonoursDeclaration() {
        let clause = "not a conventional QT lead (II/V5)"
        let map = LeadPlacementMapContext()
        let template = templateOnLead("MLII")

        // Undeclared: #357's behaviour, unchanged.
        let before = BeatCalipers.templateProvenanceText(
            template, sampleRate: 360, placementMap: map, recordID: "100.hea")
        #expect(before.contains("lead MLII — \(clause)"))
        #expect(!before.contains("declared:"))

        // Declared as II: the clause goes, the assertion is stated inline.
        map.declare(recordedName: "MLII", placement: "II", recordID: nil,
                    reviewer: "kevin", at: fixedDate)
        let declaredII = BeatCalipers.templateProvenanceText(
            template, sampleRate: 360, placementMap: map, recordID: "100.hea")
        #expect(!declaredII.contains(clause))
        #expect(declaredII.contains(
            "lead MLII (declared: II, by kevin, \(AnalysisLeadHeaderLine.dateString(fixedDate)))"))

        // A declared but non-conventional placement keeps the clause AND
        // discloses the assertion — and a record override says so.
        map.declare(recordedName: "MLII", placement: "front patch", recordID: "100.hea",
                    reviewer: "kevin", at: fixedDate)
        let declaredPatch = BeatCalipers.templateProvenanceText(
            template, sampleRate: 360, placementMap: map, recordID: "100.hea")
        #expect(declaredPatch.contains(clause))
        #expect(declaredPatch.contains("(declared: front patch — record override, by kevin, "))

        // The override is scoped: another record still reads the II baseline.
        let elsewhere = BeatCalipers.templateProvenanceText(
            template, sampleRate: 360, placementMap: map, recordID: "101.hea")
        #expect(!elsewhere.contains(clause))
        #expect(elsewhere.contains("(declared: II, by kevin, "))
    }
}
