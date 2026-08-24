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
