//
//  LeadPresetStore.swift
//  MurmurCore
//
//  The analyst's saved lead sets (#332). Built-ins are compiled in and never
//  stored; only what the analyst saves goes to `UserDefaults`, under one
//  versioned key, in the same shape as `RecentFoldersStore`.
//
//  Per APP, not per record — that is the entire point. A preset saved while
//  reading one record exists to be applied to the next one.
//

import Foundation
import Observation

@Observable
public final class LeadPresetStore {
    /// Shared so the focus-stage menu and anything else that offers presets
    /// read one live list within a run — the same reason `RecentFoldersStore`
    /// is shared.
    @MainActor public static let shared = LeadPresetStore()

    /// Analyst-saved presets, newest last. Built-ins are NOT in here.
    public private(set) var userPresets: [LeadPreset] = []

    /// Versioned key — bump if `LeadPreset` ever changes incompatibly.
    private let defaultsKey = "murmur.leadPresets.v1"
    private let defaults: UserDefaults

    /// `defaults` is injectable so tests get their own suite instead of
    /// writing into the analyst's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.userPresets = Self.load(from: defaults, key: defaultsKey)
    }

    /// Built-ins first, then the analyst's own alphabetically. Built-ins lead
    /// because they are the same four in every menu, in the same order — a
    /// position the hand learns; interleaving them alphabetically with user
    /// presets would move them every time a preset is saved.
    public var allPresets: [LeadPreset] {
        LeadPreset.builtIns + userPresets.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Mutations

    /// Saves a new preset. Returns it, or nil when the name or the lead list
    /// is empty — an unnamed preset could not be picked out of a menu, and an
    /// empty one is the `All leads` built-in's meaning, which the analyst
    /// cannot claim.
    @discardableResult
    public func add(name: String, leads: [String]) -> LeadPreset? {
        let trimmedLeads = leads
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedLeads.isEmpty else { return nil }
        guard let resolvedName = disambiguated(name) else { return nil }
        let preset = LeadPreset(name: resolvedName, leads: trimmedLeads)
        userPresets.append(preset)
        persist()
        return preset
    }

    /// Renames a user preset. Built-ins are not reachable here — `id` only
    /// matches something in `userPresets`.
    public func rename(_ id: LeadPreset.ID, to name: String) {
        guard let index = userPresets.firstIndex(where: { $0.id == id }),
              let resolvedName = disambiguated(name, excluding: id) else { return }
        userPresets[index].name = resolvedName
        persist()
    }

    /// Replaces a preset's leads with the analyst's current selection.
    public func replace(_ id: LeadPreset.ID, leads: [String]) {
        let trimmedLeads = leads
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedLeads.isEmpty,
              let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[index].leads = trimmedLeads
        persist()
    }

    public func remove(_ id: LeadPreset.ID) {
        guard userPresets.contains(where: { $0.id == id }) else { return }
        userPresets.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Naming

    /// Trims, and appends " 2", " 3"… when the name is already taken by a
    /// built-in or another user preset.
    ///
    /// Shadowing a built-in is the case that actually matters: two rows both
    /// reading "Limb" in the same menu, one of which cannot be edited, is a
    /// menu the analyst cannot reason about. Suffixing keeps the analyst's
    /// chosen word while making the row distinguishable. Nil for a blank name.
    private func disambiguated(_ name: String, excluding id: LeadPreset.ID? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let taken = Set(
            (LeadPreset.builtIns + userPresets.filter { $0.id != id })
                .map { LeadPreset.matchKey($0.name) }
        )
        guard taken.contains(LeadPreset.matchKey(trimmed)) else { return trimmed }
        var suffix = 2
        while taken.contains(LeadPreset.matchKey("\(trimmed) \(suffix)")) { suffix += 1 }
        return "\(trimmed) \(suffix)"
    }

    // MARK: - Persistence

    private static func load(from defaults: UserDefaults, key: String) -> [LeadPreset] {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([LeadPreset].self, from: data) else { return [] }
        // A built-in that somehow reached the store is dropped on read rather
        // than trusted: built-ins are compiled in, so a persisted copy is a
        // stale duplicate of one, not a preset.
        return stored.filter { !$0.isBuiltIn }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(userPresets) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
