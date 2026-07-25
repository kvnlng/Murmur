//
//  VTVFCandidateDispositionStore.swift
//  MurmurCore
//
//  Owns the analyst's review state for one recording's VT/VF candidates,
//  keyed on TIME REGION so it survives a rescan (see
//  VTVFCandidateDisposition.swift for why). Reads the sidecar
//  `candidate-dispositions.json` at init, exposes region-overlap lookups
//  for the review queue, and rewrites the whole sidecar on every mutation
//  — the files are tiny.
//
//  Overlap semantics (the rescan-inheritance rule):
//    - When the analyst confirms/dismisses a candidate region, any
//      existing stored region that overlaps it is REPLACED by the new
//      one. One region → one disposition; re-reviewing supersedes.
//    - When the queue asks for a candidate's disposition, it inherits the
//      MOST-overlapping stored region's disposition. So after a rescan a
//      re-derived candidate covering (roughly) the same span shows the
//      analyst's earlier call, even though its id changed.
//

import Foundation
import Observation

@Observable
final class VTVFCandidateDispositionStore {
    private let bundleDirectory: URL
    public let defaultReviewerName: String

    /// All stored region dispositions for this recording.
    public private(set) var records: [RegionDisposition] = []

    public init(bundleDirectory: URL, defaultReviewerName: String = ProcessInfo.processInfo.userName) {
        self.bundleDirectory = bundleDirectory
        self.defaultReviewerName = defaultReviewerName
        self.records = Self.loadFromDisk(at: Self.fileURL(in: bundleDirectory))
    }

    // MARK: - Read

    /// The disposition a candidate spanning `[start, end)` inherits — the
    /// stored region it overlaps most. Returns `nil` (unreviewed) when no
    /// stored region overlaps it.
    public func disposition(forStart start: Int64, end: Int64) -> RegionDisposition? {
        records
            .map { ($0, $0.overlapSamples(withStart: start, end: end)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    public func state(forStart start: Int64, end: Int64) -> AnnotationDisposition.State? {
        disposition(forStart: start, end: end)?.state
    }

    /// Triage counts over a list of candidate regions.
    public func tally(forRegions regions: [(start: Int64, end: Int64)]) -> DispositionStore.Tally {
        var confirmed = 0
        var dismissed = 0
        for region in regions {
            switch state(forStart: region.start, end: region.end) {
            case .confirmed: confirmed += 1
            case .dismissed: dismissed += 1
            case nil:        break
            }
        }
        let unreviewed = max(0, regions.count - confirmed - dismissed)
        return DispositionStore.Tally(confirmed: confirmed, dismissed: dismissed, unreviewed: unreviewed)
    }

    // MARK: - Mutate

    /// Confirm the region `[start, end)`. Any overlapping stored region is
    /// superseded. Confirming authors the analyst's finding — the model
    /// only proposed where to look.
    public func confirm(
        start: Int64,
        end: Int64,
        kind: AnnotationDisposition.ConfirmedKind?,
        note: String? = nil
    ) {
        upsert(RegionDisposition(
            startSample: start,
            endSample: end,
            state: .confirmed,
            confirmedKind: kind,
            note: note?.nilIfBlank,
            reviewedAt: .now,
            reviewedBy: defaultReviewerName
        ))
    }

    /// Dismiss the region `[start, end)` as a false positive.
    public func dismiss(start: Int64, end: Int64, note: String? = nil) {
        upsert(RegionDisposition(
            startSample: start,
            endSample: end,
            state: .dismissed,
            confirmedKind: nil,
            note: note?.nilIfBlank,
            reviewedAt: .now,
            reviewedBy: defaultReviewerName
        ))
    }

    /// Return the region `[start, end)` to unreviewed by removing every
    /// stored region that overlaps it.
    public func reset(start: Int64, end: Int64) {
        let before = records.count
        records.removeAll { $0.overlapSamples(withStart: start, end: end) > 0 }
        if records.count != before { persist() }
    }

    public func clear() {
        guard !records.isEmpty else { return }
        records = []
        persist()
    }

    /// Replace every overlapping stored region with `new` — one region,
    /// one disposition.
    private func upsert(_ new: RegionDisposition) {
        records.removeAll { $0.overlapSamples(withStart: new.startSample, end: new.endSample) > 0 }
        records.append(new)
        persist()
    }

    // MARK: - Persistence

    private static func fileURL(in bundleDirectory: URL) -> URL {
        bundleDirectory.appendingPathComponent(RegionDispositionFile.bundleFileName)
    }

    private static func loadFromDisk(at url: URL) -> [RegionDisposition] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(RegionDispositionFile.self, from: data),
              file.schemaVersion == RegionDispositionFile.currentSchemaVersion else {
            return []
        }
        return file.dispositions
    }

    private func persist() {
        let file = RegionDispositionFile(
            schemaVersion: RegionDispositionFile.currentSchemaVersion,
            dispositions: records.sorted { $0.startSample < $1.startSample }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = Self.fileURL(in: bundleDirectory)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
