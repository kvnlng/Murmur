//
//  LeadPlacementMap.swift
//  MurmurCore
//
//  #358 — the analyst's declaration of where a recorded channel's
//  electrode was actually placed, when that differs from (or simply
//  isn't implied by) the channel's given name. A folder-wide baseline
//  ("MLII everywhere in this folder means limb lead II") plus optional
//  per-record overrides ("but on THIS record it was a front chest
//  patch").
//
//  ## Jurisdiction (spec §2.3)
//
//  This map feeds disclosure (telling the analyst what a channel's name
//  was declared to mean) and preset resolution only. It has NO reader in
//  analysis-lead resolution or any calculation path — a placement
//  declaration is provenance the analyst attaches to a name, never an
//  input a formula consults. Anything that reads this map to decide what
//  a channel is scored as, or which channel drives a calculation, is out
//  of scope for what this type is for.
//
//  ## Keying
//
//  Both `folder` and each `recordOverrides` inner dictionary are keyed by
//  the NORMALISED recorded name (`matchKey`: trimmed, lowercased — the
//  same discipline `LeadPreset.matchKey` uses), so lookups are exact
//  case/whitespace-insensitive matches without re-deriving the rule at
//  every call site. The recorded name as displayed always comes from the
//  channel itself at render time, so a normalised key loses nothing.
//  `recordOverrides`' OUTER key is the record id (the `.hea` filename),
//  verbatim — that id space is already exact elsewhere in the app
//  (`CarriedSessionStore`, `SessionFlagStore`), so it stays untouched here.
//
//  ## Session context shape
//
//  Same singleton shape as `CurrentRecordingContext` / `CarriedSessionStore`:
//  a `@MainActor @Observable` class with a `static let shared` for runtime
//  use and a public `init()` so callers (including every test) construct
//  their own isolated instance. No SwiftUI Environment injection. Tests
//  must never mutate `.shared` — construct a fresh
//  `LeadPlacementMapContext()` instead, exactly as `CurrentRecordingContext`
//  tests do.
//

import Foundation
import Observation

/// One declaration: an assertion of what a recorded channel name means,
/// as physical lead placement, made by `reviewer` at `declaredAt`.
public struct LeadPlacementDeclaration: Codable, Equatable, Sendable {
    public var placement: String
    public var reviewer: String
    public var declaredAt: Date

    public init(placement: String, reviewer: String, declaredAt: Date) {
        self.placement = placement
        self.reviewer = reviewer
        self.declaredAt = declaredAt
    }
}

/// Persisted shape of a `LeadPlacementMapContext`: a folder-wide baseline
/// declaration per normalised recorded name, plus per-record overrides.
/// Codable so Task 3's persistence layer can write/read it directly; the
/// ISO8601 date strategy belongs at that persistence call site, not here.
public struct LeadPlacementMapSnapshot: Codable, Equatable, Sendable {
    public var folder: [String: LeadPlacementDeclaration]
    public var recordOverrides: [String: [String: LeadPlacementDeclaration]]

    public init(
        folder: [String: LeadPlacementDeclaration] = [:],
        recordOverrides: [String: [String: LeadPlacementDeclaration]] = [:]
    ) {
        self.folder = folder
        self.recordOverrides = recordOverrides
    }
}

/// Live "lead placement map" state for the folder currently open. Process-
/// wide via `.shared`, exactly like `CurrentRecordingContext` and
/// `CarriedSessionStore` — auxiliary surfaces (the disclosure panel, the
/// preset-resolution UI, Task 3's persistence) read and write through this
/// one instance at runtime; tests construct their own.
@MainActor
@Observable
public final class LeadPlacementMapContext {
    /// Shared instance the app uses at runtime. Tests must construct a
    /// fresh `LeadPlacementMapContext()` instead — never mutate `.shared` —
    /// to keep parallel runs isolated from each other and from the app's
    /// live state.
    public static let shared = LeadPlacementMapContext()

    public private(set) var folder: [String: LeadPlacementDeclaration] = [:]
    public private(set) var recordOverrides: [String: [String: LeadPlacementDeclaration]] = [:]

    /// The snapshot as of the last successful save (or `reset()`/fresh
    /// construction). `nil` reads as "never saved" — the same convention
    /// `CurrentRecordingContext.sessionSavedNotes` uses — which compares
    /// equal to an empty snapshot, so a never-touched map is never
    /// reported dirty.
    private var savedSnapshot: LeadPlacementMapSnapshot?

    public init() {}

    /// Resolve what `name` (as recorded on `recordID`, or `nil` for a
    /// folder-wide lookup) has been declared to mean. An override on
    /// `recordID` wins over the folder-wide baseline; name matching is
    /// the case/whitespace-insensitive `matchKey` equality `LeadPreset`
    /// uses for resolving lead names against recorded channel names.
    /// `nil` means nothing has been declared for this name at all.
    public func declaration(
        forRecordedName name: String,
        recordID: String?
    ) -> (declaration: LeadPlacementDeclaration, isOverride: Bool)? {
        let key = Self.matchKey(name)
        if let recordID, let override = recordOverrides[recordID]?[key] {
            return (override, true)
        }
        if let base = folder[key] {
            return (base, false)
        }
        return nil
    }

    /// Declare that `recordedName` means `placement`. `recordID == nil`
    /// writes the folder-wide baseline; a non-nil `recordID` writes an
    /// override scoped to that record. An empty or whitespace-only
    /// `placement` is a programmer error in the caller's UI (there is no
    /// "declare nothing" gesture) and is treated as a delete, matching
    /// `deleteDeclaration`.
    public func declare(
        recordedName: String,
        placement: String,
        recordID: String?,
        reviewer: String = ProcessInfo.processInfo.userName,
        at date: Date = Date()
    ) {
        // Ends trimmed AND interior whitespace runs collapsed to single
        // spaces: the placement text is quoted inline in the disclosure
        // parenthetical ("(declared: …)"), on a single line, so a pasted
        // newline or a double space would break the sentence it lands in.
        let trimmedPlacement = placement.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !trimmedPlacement.isEmpty else {
            deleteDeclaration(recordedName: recordedName, recordID: recordID)
            return
        }
        let key = Self.matchKey(recordedName)
        let entry = LeadPlacementDeclaration(placement: trimmedPlacement, reviewer: reviewer, declaredAt: date)
        if let recordID {
            recordOverrides[recordID, default: [:]][key] = entry
        } else {
            folder[key] = entry
        }
    }

    /// Withdraw a declaration. `recordID == nil` removes the folder-wide
    /// baseline for `recordedName`; a non-nil `recordID` removes only that
    /// record's override, leaving the baseline (if any) in place.
    /// Deleting a declaration that doesn't exist is not an error.
    public func deleteDeclaration(recordedName: String, recordID: String?) {
        let key = Self.matchKey(recordedName)
        if let recordID {
            recordOverrides[recordID]?.removeValue(forKey: key)
            if recordOverrides[recordID]?.isEmpty == true {
                recordOverrides.removeValue(forKey: recordID)
            }
        } else {
            folder.removeValue(forKey: key)
        }
    }

    /// The folder baseline overlaid by `recordID`'s overrides, as normalised
    /// recorded-name key (`matchKey`) → placement text — what
    /// `LeadPreset.resolve(in:declaredPlacements:)` matches preset leads
    /// against. Same precedence as `declaration(forRecordedName:recordID:)`:
    /// an override wins over the folder-wide baseline for any name declared
    /// in both. `recordID == nil` returns just the folder-wide baseline.
    public func declaredPlacements(forRecordID recordID: String?) -> [String: String] {
        var merged = folder.mapValues(\.placement)
        if let recordID, let overrides = recordOverrides[recordID] {
            for (key, declaration) in overrides {
                merged[key] = declaration.placement
            }
        }
        return merged
    }

    /// The current state, in the shape Task 3's persistence layer writes.
    public var snapshot: LeadPlacementMapSnapshot {
        LeadPlacementMapSnapshot(folder: folder, recordOverrides: recordOverrides)
    }

    /// Replace the live state with `snapshot` — e.g. Task 3 loading a
    /// persisted map when a folder opens. Does not itself mark the result
    /// saved: a restore from disk and "this is now the saved baseline" are
    /// separate facts, the same separation `CurrentRecordingContext` keeps
    /// between `pendingSessionRestore` and `sessionSavedNotes`. A caller
    /// restoring a just-loaded (and therefore already-durable) snapshot
    /// should follow with `markSaved()`.
    public func restore(_ snapshot: LeadPlacementMapSnapshot) {
        folder = snapshot.folder
        recordOverrides = snapshot.recordOverrides
    }

    /// Whether the live state differs from what was last saved — the
    /// `CurrentRecordingContext.hasUnsavedAnchoredNotes` pattern: current
    /// state compared against a saved-snapshot baseline, with `nil`
    /// ("never saved") reading the same as an empty baseline.
    public var hasUnsavedDeclarations: Bool {
        snapshot != (savedSnapshot ?? LeadPlacementMapSnapshot())
    }

    /// Record the current state as saved.
    public func markSaved() {
        savedSnapshot = snapshot
    }

    /// No folder-wide declarations and no overrides.
    public var isEmpty: Bool {
        folder.isEmpty && recordOverrides.isEmpty
    }

    /// Clear everything — declarations AND the saved-snapshot baseline —
    /// e.g. when a different folder opens and the previous one's map no
    /// longer applies.
    public func reset() {
        folder = [:]
        recordOverrides = [:]
        savedSnapshot = nil
    }

    /// The `LeadPreset.matchKey` discipline: trimmed, lowercased, so
    /// lookups are exact but case/whitespace-insensitive. Delegates rather
    /// than restating it — `LeadPreset.resolve(in:declaredPlacements:)`
    /// matches its preset leads against keys THIS type produced, so the two
    /// normalisations agreeing is a correctness requirement of the preset
    /// hook, not a coincidence two copies could drift out of.
    static func matchKey(_ name: String) -> String {
        LeadPreset.matchKey(name)
    }
}
