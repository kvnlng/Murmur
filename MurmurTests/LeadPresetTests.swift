//
//  LeadPresetTests.swift
//  MurmurTests
//
//  #332 — named lead presets.
//
//  The load-bearing rule is that a preset stores lead NAMES. `Channel.ID`s are
//  UUIDs minted per import, so an id saved against one record means nothing on
//  the next — which is the only place a preset is ever useful. Everything here
//  is about what happens when a stored name meets a record that may or may not
//  carry it.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("Lead presets (#332) — resolving against a record")
struct LeadPresetResolutionTests {
    private func channel(_ name: String) -> Channel {
        Channel(
            id: UUID(), name: name, unit: "mV", sampleRate: 500,
            startTimeUnixMS: 0, sampleCount: 5000,
            storageFileName: "\(name).bin", pyramid: []
        )
    }

    private var twelveLead: [Channel] {
        ["I", "II", "III", "aVR", "aVL", "aVF", "V1", "V2", "V3", "V4", "V5", "V6"]
            .map(channel)
    }

    private func names(_ selection: LeadSelection, in channels: [Channel]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.name) })
        return selection.ordered.compactMap { byID[$0] }
    }

    @Test("A fully present preset stages its leads in its own order, first primary")
    func resolvesInPresetOrder() throws {
        let channels = twelveLead
        let resolution = try #require(LeadPreset.limb.resolve(in: channels))

        #expect(names(resolution.selection, in: channels) == ["I", "II", "III", "aVR", "aVL", "aVF"])
        #expect(resolution.missing.isEmpty)
        // Order is not cosmetic: the primary is what marks and the inspector
        // follow, and selection order is what assigns trace inks.
        #expect(resolution.selection.primary == channels[0].id)
    }

    @Test("Leads the record lacks are skipped AND reported")
    func reportsMissingLeads() throws {
        // A 2-lead record — the shape a preset built on a 12-lead corpus meets
        // the moment the analyst opens MIT-BIH.
        let channels = [channel("V1"), channel("V5")]
        let resolution = try #require(LeadPreset.precordial.resolve(in: channels))

        #expect(names(resolution.selection, in: channels) == ["V1", "V5"])
        #expect(resolution.missing == ["V2", "V3", "V4", "V6"])
    }

    @Test("A preset with nothing in this record resolves to nothing at all")
    func nilWhenNothingMatches() {
        // Not an empty selection: there is no zero-lead focus mode, so the
        // caller must be told "no" rather than handed something unstageable.
        #expect(LeadPreset.precordial.resolve(in: [channel("MLII"), channel("V")]) == nil)
    }

    @Test("Matching ignores case and surrounding whitespace")
    func matchesCaseInsensitively() throws {
        let channels = [channel("i"), channel("ii"), channel(" AVR ")]
        let preset = LeadPreset(name: "Mixed", leads: ["I", "II", "aVR"])
        let resolution = try #require(preset.resolve(in: channels))

        #expect(resolution.missing.isEmpty)
        #expect(names(resolution.selection, in: channels) == ["i", "ii", " AVR "])
    }

    @Test("`All leads` stages every channel in record order")
    func allLeadsUsesRecordOrder() throws {
        let channels = twelveLead
        let resolution = try #require(LeadPreset.allLeads.resolve(in: channels))

        #expect(resolution.selection.count == 12)
        #expect(names(resolution.selection, in: channels) == channels.map(\.name))
        #expect(resolution.missing.isEmpty)
        // It names no leads — that is what makes it record-relative.
        #expect(LeadPreset.allLeads.isEveryLead)
    }

    @Test("`All leads` on a record with no channels resolves to nothing")
    func allLeadsNeedsChannels() {
        #expect(LeadPreset.allLeads.resolve(in: []) == nil)
    }

    @Test("A duplicated lead name stages the first channel carrying it")
    func duplicateNamesTakeTheFirst() throws {
        // Same rule the session restore uses — a record with two channels
        // called `II` must not stage one lead twice.
        let first = channel("II")
        let channels = [first, channel("II"), channel("I")]
        let resolution = try #require(LeadPreset.bipolarLimb.resolve(in: channels))

        #expect(resolution.selection.count == 2)
        #expect(resolution.selection.contains(first.id))
        #expect(resolution.missing == ["III"])
    }
}

@Suite("Lead presets (#358) — resolving against analyst-declared placements")
struct LeadPresetDeclaredPlacementResolutionTests {
    private func channel(_ name: String) -> Channel {
        Channel(
            id: UUID(), name: name, unit: "mV", sampleRate: 500,
            startTimeUnixMS: 0, sampleCount: 5000,
            storageFileName: "\(name).bin", pyramid: []
        )
    }

    private func names(_ selection: LeadSelection, in channels: [Channel]) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0.name) })
        return selection.ordered.compactMap { byID[$0] }
    }

    @Test("A declared placement lets a preset lead match a channel whose recorded name doesn't say it")
    func declaredPlacementResolvesAPresetLead() throws {
        // MLII names no limb lead by itself — Holter convention, not a
        // recorded `II` — so only the analyst's declaration bridges it.
        let channels = [channel("MLII")]
        let resolution = try #require(
            LeadPreset.limb.resolve(in: channels, declaredPlacements: ["mlii": "II"])
        )

        #expect(names(resolution.selection, in: channels) == ["MLII"])
        #expect(resolution.selection.count == 1)
        #expect(resolution.missing == ["I", "III", "aVR", "aVL", "aVF"])
    }

    @Test("With no declaration, resolution is exactly as it was before #358")
    func noDeclarationResolvesAsBefore() {
        let channels = [channel("MLII")]
        #expect(LeadPreset.limb.resolve(in: channels, declaredPlacements: nil) == nil)
        #expect(LeadPreset.limb.resolve(in: channels) == nil)
    }

    @Test("A declared placement match is exact — `V5, back patch` does not match `V5`")
    func declaredPlacementMatchIsExactNotSubstring() {
        let channels = [channel("CH1")]
        let resolution = LeadPreset.precordial.resolve(
            in: channels, declaredPlacements: ["ch1": "V5, back patch"]
        )
        #expect(resolution == nil)
    }

    @Test("A recorded-name match beats a conflicting declaration for the same lead")
    func recordedNameMatchBeatsDeclaration() throws {
        // Both a channel actually named `II` AND a declaration claiming
        // `MLII` also means `II` — the recorded name must win, not the
        // declared alias, and MLII must not steal `II`'s slot either.
        let recordedII = channel("II")
        let declaredMLII = channel("MLII")
        let channels = [recordedII, declaredMLII]
        let resolution = try #require(
            LeadPreset.bipolarLimb.resolve(in: channels, declaredPlacements: ["mlii": "II"])
        )

        #expect(resolution.selection.contains(recordedII.id))
        #expect(!resolution.selection.contains(declaredMLII.id))
        #expect(resolution.missing == ["I", "III"])
    }
}

@Suite("Lead presets (#332) — the store")
struct LeadPresetStoreTests {
    /// Its own defaults suite: a test must never write into the analyst's
    /// real preferences, and must not see what another test left behind.
    private func makeStore() throws -> LeadPresetStore {
        LeadPresetStore(defaults: try makeDefaults())
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "murmur.tests.\(UUID().uuidString)"))
    }

    @Test("A saved preset survives a reload from the same defaults")
    func persistsAcrossReload() throws {
        let defaults = try makeDefaults()
        LeadPresetStore(defaults: defaults).add(name: "Reduced 3", leads: ["I", "II", "V2"])

        let reloaded = LeadPresetStore(defaults: defaults)
        #expect(reloaded.userPresets.count == 1)
        #expect(reloaded.userPresets[0].name == "Reduced 3")
        #expect(reloaded.userPresets[0].leads == ["I", "II", "V2"])
        #expect(reloaded.userPresets[0].isBuiltIn == false)
    }

    @Test("Built-ins are offered but never stored")
    func builtInsAreNotPersisted() throws {
        let store = try makeStore()
        #expect(store.userPresets.isEmpty)
        #expect(store.allPresets.count == LeadPreset.builtIns.count)
        let nonBuiltIn = store.allPresets.filter { !$0.isBuiltIn }
        #expect(nonBuiltIn.isEmpty)
    }

    @Test("Built-ins lead the menu; saved presets follow alphabetically")
    func orderingIsStable() throws {
        let store = try makeStore()
        store.add(name: "Zebra", leads: ["I"])
        store.add(name: "alpha", leads: ["II"])

        let names = store.allPresets.map(\.name)
        #expect(Array(names.prefix(4)) == LeadPreset.builtIns.map(\.name))
        // Built-ins keep a fixed position the hand can learn — saving a preset
        // must not shuffle them.
        #expect(Array(names.suffix(2)) == ["alpha", "Zebra"])
    }

    @Test("A name that shadows a built-in is suffixed, not rejected")
    func shadowingABuiltInIsDisambiguated() throws {
        let store = try makeStore()
        let saved = store.add(name: "Limb", leads: ["I", "II"])
        #expect(saved?.name == "Limb 2")

        // And again, so the suffix climbs rather than colliding.
        #expect(store.add(name: "Limb", leads: ["III"])?.name == "Limb 3")
    }

    @Test("An unnamed or lead-less preset is refused")
    func refusesEmptyInput() throws {
        let store = try makeStore()
        #expect(store.add(name: "   ", leads: ["I"]) == nil)
        // An empty lead list is the `All leads` built-in's meaning, which a
        // saved preset must not be able to claim.
        #expect(store.add(name: "Nothing", leads: []) == nil)
        #expect(store.add(name: "Blanks", leads: ["  ", ""]) == nil)
        #expect(store.userPresets.isEmpty)
    }

    @Test("Rename, replace and remove round-trip")
    func mutationsRoundTrip() throws {
        let defaults = try makeDefaults()
        let store = LeadPresetStore(defaults: defaults)
        let preset = try #require(store.add(name: "Reduced 3", leads: ["I", "II", "V2"]))

        store.rename(preset.id, to: "Reduced pair")
        store.replace(preset.id, leads: ["I", "V5"])
        #expect(LeadPresetStore(defaults: defaults).userPresets[0].name == "Reduced pair")
        #expect(LeadPresetStore(defaults: defaults).userPresets[0].leads == ["I", "V5"])

        store.remove(preset.id)
        #expect(LeadPresetStore(defaults: defaults).userPresets.isEmpty)
    }

    @Test("Replacing a preset's leads with nothing is refused, not honoured")
    func replaceRefusesEmpty() throws {
        let store = try makeStore()
        let preset = try #require(store.add(name: "Reduced 3", leads: ["I", "II"]))
        store.replace(preset.id, leads: [])
        #expect(store.userPresets[0].leads == ["I", "II"])
    }

    @Test("A built-in that somehow reached storage is dropped on read")
    func storedBuiltInsAreIgnored() throws {
        let defaults = try makeDefaults()
        let data = try JSONEncoder().encode([LeadPreset.limb, LeadPreset(name: "Mine", leads: ["I"])])
        defaults.set(data, forKey: "murmur.leadPresets.v1")

        let store = LeadPresetStore(defaults: defaults)
        #expect(store.userPresets.map(\.name) == ["Mine"])
        // Otherwise the menu would carry two rows called "Limb", one editable.
        let limbRows = store.allPresets.filter { $0.name == "Limb" }
        #expect(limbRows.count == 1)
    }
}
