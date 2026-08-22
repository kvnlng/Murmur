//
//  LeadPreset.swift
//  MurmurCore
//
//  Named lead sets for the focus stage (#332) — a few built-ins plus whatever
//  the analyst saves.
//
//  Focus mode overlays an ordered set of leads (`LeadSelection`). Building one
//  is a toggle per lead, every time, on every record — and analysts return to
//  the same subsets constantly: the limb leads, the precordials, a reduced
//  pair. On a 45,000-record corpus (#329) that is six clicks per record for a
//  set the analyst has already chosen a hundred times.
//
//  ## Stored by NAME, never by id
//
//  `Channel.ID`s are UUIDs minted per import (`Recording.swift`), so an id
//  saved against one record means nothing on the next one — which is the only
//  place a preset is ever useful. Names are what survive across records, and
//  the codebase already resolves this way: X96 restores a session's staged
//  overlay through exactly this name → id lookup (`BedsideView.swift`).
//
//  ## Why a preset may resolve partially
//
//  A preset is the analyst's standing intent, not an assertion about any
//  particular record. Applying `Precordial` to a record carrying V1, V2 and V5
//  should stage those three and SAY which two were absent — refusing outright
//  would make presets useless on every non-12-lead corpus, and staging
//  silently would let the analyst believe they are looking at six leads.
//  `resolve(in:)` returns both halves so the caller can do exactly that.
//

import Foundation

public struct LeadPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Lead names in selection order, first = primary. Empty means "every
    /// channel in the record, in record order" — the `All leads` built-in,
    /// which cannot be written as a list because it depends on the record.
    public var leads: [String]
    /// Built-ins are compiled in, never persisted, and never edited. Kept on
    /// the model rather than inferred from the id so a user preset that
    /// happens to match a built-in's leads stays the analyst's own.
    public let isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, leads: [String], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.leads = leads
        self.isBuiltIn = isBuiltIn
    }

    /// True for the `All leads` built-in — see `leads`.
    public var isEveryLead: Bool { leads.isEmpty }

    // MARK: - Built-ins

    /// Fixed ids so a built-in keeps its identity across launches — menus and
    /// accessibility identifiers key on it — without being persisted anywhere.
    /// Built from bytes rather than `UUID(uuidString:)` so there is no string
    /// that could be mistyped into a runtime nil.
    private static func builtInID(_ tag: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, tag))
    }

    public static let limb = LeadPreset(
        id: builtInID(1),
        name: "Limb", leads: ["I", "II", "III", "aVR", "aVL", "aVF"], isBuiltIn: true
    )
    public static let precordial = LeadPreset(
        id: builtInID(2),
        name: "Precordial", leads: ["V1", "V2", "V3", "V4", "V5", "V6"], isBuiltIn: true
    )
    public static let bipolarLimb = LeadPreset(
        id: builtInID(3),
        name: "Bipolar limb", leads: ["I", "II", "III"], isBuiltIn: true
    )
    public static let allLeads = LeadPreset(
        id: builtInID(4),
        name: "All leads", leads: [], isBuiltIn: true
    )

    public static let builtIns: [LeadPreset] = [limb, precordial, bipolarLimb, allLeads]

    // MARK: - Resolution

    /// What applying this preset to a record produces.
    public struct Resolution: Equatable, Sendable {
        public let selection: LeadSelection
        /// Lead names this preset asked for that the record does not carry,
        /// in the preset's own order — the caller reports these.
        public let missing: [String]
    }

    /// Resolves against a record's channels by NAME.
    ///
    /// Case- and whitespace-insensitive, so a corpus writing `v1` matches a
    /// preset written `V1`. Beyond case there is no normalisation and no
    /// aliasing: WFDB sources do not agree on a closed set of lead names, and
    /// a table mapping one spelling to another would be Murmur asserting an
    /// equivalence the record never stated.
    ///
    /// Returns nil when NOTHING matches — there is no zero-lead focus mode,
    /// and a caller that got a selection back should be able to stage it.
    public func resolve(in channels: [Channel]) -> Resolution? {
        guard !isEveryLead else {
            // Record order, which is the order the channels arrived in.
            guard let selection = LeadSelection(ordered: channels.map(\.id)) else { return nil }
            return Resolution(selection: selection, missing: [])
        }

        var idsByKey: [String: Channel.ID] = [:]
        for channel in channels {
            // First wins: a record with two channels named `II` stages the
            // first, the same rule the session restore uses.
            idsByKey[Self.matchKey(channel.name)] = idsByKey[Self.matchKey(channel.name)]
                ?? channel.id
        }

        var ids: [Channel.ID] = []
        var missing: [String] = []
        for lead in leads {
            if let id = idsByKey[Self.matchKey(lead)] {
                ids.append(id)
            } else {
                missing.append(lead)
            }
        }
        guard let selection = LeadSelection(ordered: ids) else { return nil }
        return Resolution(selection: selection, missing: missing)
    }

    static func matchKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
