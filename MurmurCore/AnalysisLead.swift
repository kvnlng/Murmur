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
/// export columns render from this, one vocabulary everywhere.
public enum AnalysisLeadProvenance: Equatable, Sendable {
    case designated(reviewer: String, date: Date)
    case rPeakScore(score: Double, perLead: [String: Double])
    case firstInFile
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

    /// The standalone sentence, for a surface that states the disclosure on
    /// its own: *"measured on V4 — not a conventional QT lead (II/V5)"*.
    /// Nil when the recorded name reads as II or V5 — the standard case has
    /// nothing to disclose.
    public static func annotation(forLeadNamed name: String) -> String? {
        clause(forLeadNamed: name).map { "measured on \($0)" }
    }

    /// The same claim in a citation's LEAD slot: the as-recorded name, with
    /// the disclosure clause appended when it fires. Called at RENDER time by
    /// the surfaces that state a QT claim — the QTc repro caption and the
    /// beat inspector's provenance footer — never stored: `sourceLead` holds
    /// the lead's name, so a PR or QRS caption states the same lead without
    /// inheriting a QT-specific sentence.
    public static func citedLeadName(for name: String) -> String {
        clause(forLeadNamed: name) ?? name.trimmingCharacters(in: .whitespaces)
    }

    /// "<name> — not a conventional QT lead (II/V5)", or nil when the name
    /// reads as II/V5. One spelling of the claim, two grammars above.
    private static func clause(forLeadNamed name: String) -> String? {
        let normalized = name.uppercased().filter { !$0.isWhitespace }
        guard normalized != "II", normalized != "V5" else { return nil }
        return "\(name.trimmingCharacters(in: .whitespaces)) — not a conventional QT lead (II/V5)"
    }
}

extension Recording {

    /// The channel calculations run on. Resolution order: designation →
    /// stored default → first-in-file; a stored name that no longer
    /// resolves — including one naming a now-empty channel — is skipped
    /// (and, for designations, disclosed). Nil only when the recording has
    /// no POPULATED ECG channel — an empty channel is never a candidate.
    public func analysisLead(inBundle directory: URL) -> AnalysisLeadResolution? {
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

        let file = AnalysisLeadFile.read(from: directory)
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
    /// analysis-lead consumers use (same `BinaryRecordingFile` call
    /// `conventionalQTLeads(inDirectory:)` makes per-channel).
    public func samples(of channel: Channel, inDirectory directory: URL) -> [Float]? {
        let url = directory.appendingPathComponent(channel.storageFileName)
        return try? BinaryRecordingFile.readSamples(url: url, range: 0..<channel.sampleCount)
    }
}
