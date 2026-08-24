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

        #expect(model.initialText(in: map).isEmpty)
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
        #expect(model.initialText(in: map) == "II")
        #expect(model.initialScope(in: map) == .folder)
        #expect(model.existingDeclaration(in: map, scope: .folder)?.placement == "II")
        // The folder baseline is not reported as this record's own — Delete
        // at record scope must not offer to withdraw something else's.
        #expect(model.existingDeclaration(in: map, scope: .record) == nil)

        // Plan ruling 3: an undeclared name pre-fills NOTHING, however
        // conventional a reading of it might be.
        let v5 = LeadPlacementSheetModel(recordedName: "V5", recordID: model.recordID)
        #expect(v5.initialText(in: map).isEmpty)
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
        #expect(model.initialText(in: map) == "front patch")
        #expect(model.existingDeclaration(in: map, scope: .record)?.placement == "front patch")
        #expect(model.existingDeclaration(in: map, scope: .folder)?.placement == "II")
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
}
