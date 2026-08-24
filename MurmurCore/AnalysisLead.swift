//
//  AnalysisLead.swift
//  MurmurCore
//
//  #357 — which channel the calculations run on, and why.
//
//  The rule (docs/design/2026-08-24-analysis-lead-and-placement-map,
//  docs/what-murmur-asserts.md): a calculation may never be gated on a
//  lead's NAME. The analysis lead is resolved designation → stored
//  default → first-in-file, every branch carries its provenance for the
//  disclosure line, and the name plays no part in the choice.
//
//  The default is stamped ONCE at import (RecordingStore) and never
//  recomputed — a record's analysis lead must not change under an
//  analyst mid-review. Scoring is provided by whatever registered an
//  AnalysisLeadScorer (the App registers a MurmurMetrics-backed one,
//  entitlement-gated); with none registered the default records
//  firstInFile explicitly — the absence of scoring is a stored fact,
//  never an inference.
//

import Foundation

// MARK: - Scorer registry

/// Scores leads for analysis-lead defaulting. Dumb by contract: scores
/// in, no channel choice out — choosing (and disclosing) stays in core
/// so free and paid builds share one resolution path.
public protocol AnalysisLeadScorer: Sendable {
    /// Per-lead-name scores, higher = better R-peak support. Return nil
    /// to decline (unentitled, degenerate input) — the caller then
    /// records firstInFile.
    func scoreLeads(
        _ leads: [(name: String, samples: [Float])],
        sampleRate: Double
    ) -> [String: Double]?
}

/// Process-wide slot for the one registered scorer. A class with a lock
/// rather than an actor so the synchronous import path can consult it
/// without an await. Tests construct their own instance.
public final class AnalysisLeadScoring: @unchecked Sendable {
    public static let shared = AnalysisLeadScoring()

    private let lock = NSLock()
    private var scorer: (any AnalysisLeadScorer)?

    public init() {}

    public func register(_ scorer: any AnalysisLeadScorer) {
        lock.lock(); defer { lock.unlock() }
        self.scorer = scorer
    }

    public func currentScorer() -> (any AnalysisLeadScorer)? {
        lock.lock(); defer { lock.unlock() }
        return scorer
    }

    public func clearForTesting() {
        lock.lock(); defer { lock.unlock() }
        scorer = nil
    }
}

// MARK: - Bundle sidecar

/// `analysis_lead.json` — beside `source_fingerprint.json`, same rule:
/// assertions live in the bundle, never the producer's folder. Channels
/// are referenced by NAME (names survive re-import of unchanged source;
/// channel IDs do not); duplicates resolve to the first match, X96's rule.
public struct AnalysisLeadFile: Codable, Equatable, Sendable {

    public enum DefaultReason: String, Codable, Sendable {
        case rPeakScore
        case firstInFile
    }

    /// The import-time default. Written once when the bundle is cut;
    /// nothing ever rewrites it (scope decision 2: never backfill).
    public struct DefaultChoice: Codable, Equatable, Sendable {
        public var channelName: String
        public var reason: DefaultReason
        public var perLeadScores: [String: Double]?
        public var scoredAt: Date
        public var scorerVersion: Int

        public init(channelName: String, reason: DefaultReason,
                    perLeadScores: [String: Double]?, scoredAt: Date, scorerVersion: Int) {
            self.channelName = channelName
            self.reason = reason
            self.perLeadScores = perLeadScores
            self.scoredAt = scoredAt
            self.scorerVersion = scorerVersion
        }
    }

    /// The analyst's assertion. Reviewer per the DispositionStore
    /// convention (macOS user name, best-effort).
    public struct Designation: Codable, Equatable, Sendable {
        public var channelName: String
        public var reviewer: String
        public var designatedAt: Date

        public init(channelName: String, reviewer: String, designatedAt: Date) {
            self.channelName = channelName
            self.reviewer = reviewer
            self.designatedAt = designatedAt
        }
    }

    public var defaultChoice: DefaultChoice?
    public var designation: Designation?

    enum CodingKeys: String, CodingKey {
        case defaultChoice = "default"
        case designation
    }

    public init(defaultChoice: DefaultChoice?, designation: Designation?) {
        self.defaultChoice = defaultChoice
        self.designation = designation
    }

    public static let bundleFileName = "analysis_lead.json"

    /// Nil on absence or decode failure — malformed means "no stored
    /// choice", never an error; resolution falls through honestly.
    public static func read(from bundleDirectory: URL) -> AnalysisLeadFile? {
        let url = bundleDirectory.appendingPathComponent(bundleFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AnalysisLeadFile.self, from: data)
    }

    public func write(to bundleDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = bundleDirectory.appendingPathComponent(Self.bundleFileName)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Resolution

/// Why this channel is the analysis lead — the disclosure line and the
/// export columns both render from this, but in two deliberately different
/// vocabularies (header wording via `AnalysisLeadHeaderLine`, export wording
/// via `exportReason` below) — only `firstInFile`'s phrasing coincides.
public enum AnalysisLeadProvenance: Equatable, Sendable {
    case designated(reviewer: String, date: Date)
    case rPeakScore(score: Double, perLead: [String: Double])
    case firstInFile

    /// The `analysis_lead_reason` column in the review table (#330) and
    /// the `.mur` report export — the same three provenances as
    /// `AnalysisLeadHeaderLine.reasonPhrase`, worded for a spreadsheet
    /// cell rather than a sentence: it names the score, not just that
    /// one won, and never a date (exports are batch-scale; a reviewer
    /// name and a score are enough for a consumer to sort/filter on).
    public var exportReason: String {
        switch self {
        case let .designated(reviewer, _):
            return "analyst override — \(reviewer)"
        case let .rPeakScore(score, _):
            return String(format: "r-peak score %.2f", score)
        case .firstInFile:
            return "first in file"
        }
    }
}

public struct AnalysisLeadResolution: Equatable, Sendable {
    public let channel: Channel
    public let provenance: AnalysisLeadProvenance
    /// A designation that named a channel not in this recording — the
    /// header disclosure reports it ("designated lead V9 not in this
    /// record — using default"); resolution fell through.
    public let staleDesignation: String?
}

// MARK: - QT lead disclosure

/// #357 §1.5 — the one permitted direction for lead names: disclosure.
/// "Reads as II/V5" is exact equality after uppercasing and stripping
/// whitespace; NO prefix stripping (the X108 ML normaliser is gone — on
/// MIT-BIH this honestly fires until the analyst declares MLII → II,
/// #358). The comparison never chooses a lead; it only writes a sentence.
public enum QTLeadDisclosure {

    /// The claim in a citation's LEAD slot: the as-recorded name, with
    /// the disclosure clause appended when it fires. Called at RENDER time by
    /// the surfaces that state a QT claim — the QTc repro caption and the
    /// beat inspector's provenance footer — never stored: `sourceLead` holds
    /// the lead's name, so a PR or QRS caption states the same lead without
    /// inheriting a QT-specific sentence.
    ///
    /// `declaredPlacement` is #358's analyst assertion of what `name`
    /// physically is, when one exists — `nil` reproduces #357's behaviour
    /// byte-for-byte (existing callers pass nothing and are unaffected).
    /// When present and its `placement` text reads as II/V5 by the SAME
    /// normalise-and-compare test applied to the recorded name (plan
    /// ruling 4 — `readsAsConventional(_:)` below, so the two paths can
    /// never drift), the "not a conventional QT lead" clause is suppressed
    /// and the declaration's parenthetical is appended instead: the analyst
    /// has said this channel IS II or V5, so the caveat no longer applies.
    /// A declared but non-conventional placement (e.g. "front patch") keeps
    /// the clause — the analyst's assertion is disclosed alongside it, not
    /// in place of it.
    public static func citedLeadName(
        for name: String,
        declaredPlacement: LeadPlacementDeclaration? = nil,
        isOverride: Bool = false
    ) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard let declaredPlacement else {
            return clause(forLeadNamed: name) ?? trimmedName
        }
        let parenthetical = LeadPlacementDisclosure.parenthetical(
            for: declaredPlacement, isOverride: isOverride)
        if readsAsConventional(declaredPlacement.placement) {
            return "\(trimmedName) \(parenthetical)"
        }
        guard let clause = clause(forLeadNamed: name) else {
            // The recorded name itself already reads as II/V5 — no clause
            // to append the parenthetical alongside; state the name plain.
            return "\(trimmedName) \(parenthetical)"
        }
        return "\(clause) \(parenthetical)"
    }

    /// "<name> — not a conventional QT lead (II/V5)", or nil when the name
    /// reads as II/V5. One spelling of the claim, one grammar: Task 7's
    /// header line states the analysis lead and its PROVENANCE (§1.6), not
    /// the QT convention, so the standalone "measured on …" sentence this
    /// also used to build had no caller and is gone. It comes back the day a
    /// surface states the disclosure on its own — built from this clause,
    /// so the two grammars can never word the claim differently.
    private static func clause(forLeadNamed name: String) -> String? {
        guard !readsAsConventional(name) else { return nil }
        return "\(name.trimmingCharacters(in: .whitespaces)) — not a conventional QT lead (II/V5)"
    }

    /// The one normalise-and-compare test for "reads as II or V5" — exact
    /// equality after uppercasing and stripping whitespace, no prefix
    /// stripping. Shared by the recorded-name path (`clause(forLeadNamed:)`)
    /// and the declared-placement path (`citedLeadName`'s suppression check)
    /// so the two can never word the same rule differently (plan ruling 4).
    /// `"V5, back patch"` does not read as V5 — this is exact equality, not
    /// a prefix or substring test.
    static func readsAsConventional(_ text: String) -> Bool {
        let normalized = text.uppercased().filter { !$0.isWhitespace }
        return normalized == "II" || normalized == "V5"
    }
}

// MARK: - Header disclosure line (§1.6)

/// The read-only line the metrics header states: which lead every number in
/// the column was measured on, and why it is that lead. Pure and public so
/// the strings live in ONE place — the header, the menu's revert label, and
/// the tests that pin the spec's wording all render from here.
public enum AnalysisLeadHeaderLine {

    /// The full line. `excludedSummary` is the caller's own per-lead
    /// qualifier (e.g. "V5: 18% of beats excluded") when it has one;
    /// nil renders the reason phrase alone — the app never invents a
    /// number to fill the slot. `declaration` is #358's analyst assertion
    /// of what the resolved channel's name physically means, when one
    /// exists; `nil` (the default) reproduces #357's line byte-for-byte.
    public static func text(
        for resolution: AnalysisLeadResolution,
        excludedSummary: String?,
        declaration: (declaration: LeadPlacementDeclaration, isOverride: Bool)? = nil
    ) -> String {
        var line = "analysis lead: \(label(for: resolution, declaration: declaration))"
        if let excludedSummary, !excludedSummary.isEmpty {
            line += " (\(excludedSummary))"
        }
        // A designation that named a channel this record doesn't have is the
        // first thing the analyst must know — the lead they chose is NOT the
        // one measured — so it leads the line as its own segment.
        if let stale = resolution.staleDesignation {
            line = "\(staleDesignationSentence(named: stale)) · \(line)"
        }
        return line
    }

    /// "<name> — <reason phrase>": the lead and why, without the header's
    /// prefix. The context menu's "Revert to default (…)" slot states this.
    /// Kept as its own single-parameter overload (rather than a defaulted
    /// `declaration` parameter, as `text(for:excludedSummary:declaration:)`
    /// above uses) because `BedsideView` captures this exact signature
    /// point-free (`.map(AnalysisLeadHeaderLine.label(for:))`) — a default
    /// parameter is erased when a method is converted to a function value,
    /// so that capture needs an overload whose full signature really is
    /// one argument.
    public static func label(for resolution: AnalysisLeadResolution) -> String {
        label(for: resolution, declaration: nil)
    }

    /// "<name> (declared: …) — <reason phrase>" when `declaration` is
    /// present; identical to `label(for:)` when it is `nil` (#358).
    public static func label(
        for resolution: AnalysisLeadResolution,
        declaration: (declaration: LeadPlacementDeclaration, isOverride: Bool)?
    ) -> String {
        var name = resolution.channel.name
        if let (declaredPlacement, isOverride) = declaration {
            let parenthetical = LeadPlacementDisclosure.parenthetical(
                for: declaredPlacement, isOverride: isOverride)
            name += " \(parenthetical)"
        }
        return "\(name) — \(reasonPhrase(for: resolution.provenance))"
    }

    /// One vocabulary for the three provenances, everywhere they are read.
    public static func reasonPhrase(for provenance: AnalysisLeadProvenance) -> String {
        switch provenance {
        case let .designated(reviewer, date):
            return "designated by \(reviewer), \(dateString(date))"
        case .rPeakScore:
            return "strongest R peaks"
        case .firstInFile:
            return "first in file"
        }
    }

    public static func staleDesignationSentence(named channelName: String) -> String {
        "designated lead \(channelName) not in this record — using default"
    }

    /// yyyy-MM-dd, UTC, POSIX locale — the same discipline as every other
    /// stamped date in the app: the line must read identically wherever the
    /// bundle is opened, so it never renders in the machine's own zone.
    /// Internal (not private) so `LeadPlacementDisclosure` shares this exact
    /// formatter — one date rendering, never two disciplines that could
    /// silently drift apart.
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Lead placement disclosure (#358)

/// The parenthetical that discloses a #358 `LeadPlacementDeclaration` inline
/// with a channel name — the header line and the QT citation both render
/// through this one function so the two surfaces can never word the same
/// fact differently. Pure, like `AnalysisLeadHeaderLine`: this type never
/// reads `LeadPlacementMapContext` (jurisdiction rule) — callers resolve the
/// declaration and pass it in.
public enum LeadPlacementDisclosure {

    /// `(declared: II, by kevin, 2026-08-24)`, or with `isOverride: true`,
    /// `(declared: II — record override, by kevin, 2026-08-24)` — the
    /// per-record override says so inline, since it is the exception to a
    /// folder-wide baseline the analyst may otherwise assume applies.
    public static func parenthetical(for declaration: LeadPlacementDeclaration,
                                     isOverride: Bool) -> String {
        let overrideSuffix = isOverride ? " — record override" : ""
        return "(declared: \(declaration.placement)\(overrideSuffix), by \(declaration.reviewer), "
            + "\(AnalysisLeadHeaderLine.dateString(declaration.declaredAt)))"
    }
}

// MARK: - The per-lead menu entry

/// What a lead's right-click offers for designation (§1.6). Pure and
/// public so the rule is pinned by tests rather than buried in a menu
/// builder — the two predicates below are easy to get subtly wrong.
public enum AnalysisLeadMenuEntry: Equatable, Sendable {
    /// "Use as analysis lead".
    case designate
    /// "Revert to default (…)" — offered on THE DESIGNEE, which is not the
    /// same question as "is this the lead that resolves". A record with no
    /// designation resolves a lead through the stored default, and that lead
    /// still offers `designate`: pinning the default explicitly is a
    /// legitimate assertion (it says an analyst looked and agreed), and it is
    /// what makes the choice survive a re-scored re-import.
    case revert
    /// Nothing offered.
    case none

    /// `designation` is the sidecar's own section, NOT a resolution — a
    /// designation naming a channel that can't resolve still shows its
    /// revert entry, or the analyst would have no way to withdraw the very
    /// designation the header line is complaining about.
    ///
    /// A channel with no samples is never offered `designate`: resolution
    /// only considers populated channels, so the write would produce a
    /// designation that never resolves and a header line claiming a lead is
    /// "not in this record" while the analyst is looking at its panel.
    public static func resolve(
        for channel: Channel,
        designation: AnalysisLeadFile.Designation?
    ) -> AnalysisLeadMenuEntry {
        if designation?.channelName == channel.name { return .revert }
        guard !channel.isTrendChannel, channel.sampleCount > 0 else { return .none }
        return .designate
    }
}

// MARK: - Designating

/// The analyst's assertion, written to the bundle. Read → set/clear →
/// write; the import-time `default` section is never touched, so a
/// designation (and a revert) can never rewrite what was scored at import.
///
/// The caller bumps `CurrentRecordingContext.analysisLeadRevision` after a
/// successful write — that stamp is what re-runs the orchestrators.
public enum AnalysisLeadDesignator {

    /// Assert that `name` is this record's analysis lead. Reviewer follows
    /// the `DispositionStore` convention (the macOS user name, best-effort);
    /// both it and the date are injectable so tests pin the written record.
    public static func designate(
        channelNamed name: String,
        inBundle directory: URL,
        reviewer: String = ProcessInfo.processInfo.userName,
        at date: Date = Date()
    ) throws {
        var file = AnalysisLeadFile.read(from: directory)
            ?? AnalysisLeadFile(defaultChoice: nil, designation: nil)
        file.designation = AnalysisLeadFile.Designation(
            channelName: name, reviewer: reviewer, designatedAt: date)
        try file.write(to: directory)
    }

    /// Withdraw the assertion: the `designation` section goes, the stored
    /// `default` stays. Reverting a record that was never designated writes
    /// the file back unchanged rather than failing — withdrawing nothing is
    /// not an error.
    public static func revertToDefault(inBundle directory: URL) throws {
        guard var file = AnalysisLeadFile.read(from: directory) else { return }
        file.designation = nil
        try file.write(to: directory)
    }
}

extension Recording {

    /// The channel calculations run on. Resolution order: designation →
    /// stored default → first-in-file; a stored name that no longer
    /// resolves — including one naming a now-empty channel — is skipped
    /// (and, for designations, disclosed). Nil only when the recording has
    /// no POPULATED ECG channel — an empty channel is never a candidate.
    public func analysisLead(inBundle directory: URL) -> AnalysisLeadResolution? {
        resolveAnalysisLead(from: AnalysisLeadFile.read(from: directory))
    }

    /// What resolution WOULD produce with the designation withdrawn: the
    /// stored default, or first-in-file. This is what the context menu's
    /// "Revert to default (…)" names and where a revert lands — read from
    /// the same sidecar, through the same rules, so the label can never
    /// promise a lead the revert doesn't actually select.
    public func analysisLeadDefault(inBundle directory: URL) -> AnalysisLeadResolution? {
        var file = AnalysisLeadFile.read(from: directory)
        file?.designation = nil
        return resolveAnalysisLead(from: file)
    }

    private func resolveAnalysisLead(from file: AnalysisLeadFile?) -> AnalysisLeadResolution? {
        // An empty channel is not analyzable — `samples(of:inDirectory:)`
        // would return `[]`, not nil, so an unfiltered candidate set lets
        // a zero-sample channel win a branch and silently starve the scan.
        // Same filter as `ecgLeadSamples(inDirectory:)` and the import-time
        // default stamp: only a channel with data is a candidate lead.
        let ecg = channels.filter { !$0.isTrendChannel && $0.sampleCount > 0 }
        guard !ecg.isEmpty else { return nil }
        // First match by name — X96's duplicate rule.
        func channel(named name: String) -> Channel? {
            ecg.first { $0.name == name }
        }

        var stale: String?

        if let designation = file?.designation {
            if let channel = channel(named: designation.channelName) {
                return AnalysisLeadResolution(
                    channel: channel,
                    provenance: .designated(reviewer: designation.reviewer,
                                            date: designation.designatedAt),
                    staleDesignation: nil
                )
            }
            stale = designation.channelName
        }

        if let choice = file?.defaultChoice, choice.reason == .rPeakScore,
           let channel = channel(named: choice.channelName) {
            let scores = choice.perLeadScores ?? [:]
            return AnalysisLeadResolution(
                channel: channel,
                provenance: .rPeakScore(score: scores[choice.channelName] ?? 0,
                                        perLead: scores),
                staleDesignation: stale
            )
        }

        // First non-trend channel WITH SAMPLES — `ecg` is already filtered,
        // so this is never `primaryECGChannel` (which admits an empty
        // leading channel); `ecg` is non-empty per the guard above.
        let first = ecg[0]
        return AnalysisLeadResolution(
            channel: first, provenance: .firstInFile, staleDesignation: stale
        )
    }

    /// One channel's full sample buffer — the per-channel read the
    /// analysis-lead consumers use (same `BinaryRecordingFile` call the
    /// deleted `conventionalQTLeads(inDirectory:)` used to make per-channel).
    public func samples(of channel: Channel, inDirectory directory: URL) -> [Float]? {
        let url = directory.appendingPathComponent(channel.storageFileName)
        return try? BinaryRecordingFile.readSamples(url: url, range: 0..<channel.sampleCount)
    }
}
