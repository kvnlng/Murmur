//
//  DispositionStore.swift
//  Murmur
//
//  Owns the analyst's review state for one recording. Reads the sidecar
//  `dispositions.json` at init, exposes `state(for:)` for read paths, and
//  writes the whole sidecar back on every mutation. Files are tiny — a
//  handful of bytes per disposition — so there's no batching or debounce.
//
//  `BedsideView` holds the store in `@State`; SwiftUI views observe it
//  via `@Observable` so the findings panel, density timeline, and summary
//  chip count all redraw the moment the analyst toggles a row.
//

import Foundation

@Observable
final class DispositionStore {
    /// Bundle directory that owns the sidecar.
    private let bundleDirectory: URL
    /// Best-effort default reviewer name — currently the macOS user name.
    let defaultReviewerName: String

    /// `annotationID → record`. Absence means "unreviewed."
    private(set) var records: [UUID: AnnotationDisposition] = [:]

    init(bundleDirectory: URL, defaultReviewerName: String = ProcessInfo.processInfo.userName) {
        self.bundleDirectory = bundleDirectory
        self.defaultReviewerName = defaultReviewerName
        self.records = Self.loadFromDisk(at: Self.fileURL(in: bundleDirectory))
    }

    // MARK: - Read

    /// Returns the disposition for an annotation, or `nil` for unreviewed.
    func record(for annotationID: UUID) -> AnnotationDisposition? {
        records[annotationID]
    }

    func state(for annotationID: UUID) -> AnnotationDisposition.State? {
        records[annotationID]?.state
    }

    /// Counts of each state across the supplied annotation list.
    /// Returns `(confirmed, dismissed, unreviewed)`.
    func tally(for annotations: [Annotation]) -> Tally {
        var confirmed = 0
        var dismissed = 0
        for ann in annotations {
            switch records[ann.id]?.state {
            case .confirmed: confirmed += 1
            case .dismissed: dismissed += 1
            case nil:        break
            }
        }
        let unreviewed = max(0, annotations.count - confirmed - dismissed)
        return Tally(confirmed: confirmed, dismissed: dismissed, unreviewed: unreviewed)
    }

    struct Tally: Equatable, Sendable {
        let confirmed: Int
        let dismissed: Int
        let unreviewed: Int
        var total: Int { confirmed + dismissed + unreviewed }
    }

    // MARK: - Mutate

    /// Mark an annotation as `confirmed`. `kind` may narrow the VT/VF call
    /// (or be `nil` if the analyst can't tell).
    func confirm(_ annotationID: UUID, kind: AnnotationDisposition.ConfirmedKind?, note: String? = nil) {
        records[annotationID] = AnnotationDisposition(
            annotationID: annotationID,
            state: .confirmed,
            confirmedKind: kind,
            note: note?.nilIfEmpty,
            reviewedAt: .now,
            reviewedBy: defaultReviewerName
        )
        persist()
    }

    /// Mark an annotation as `dismissed` (analyst-judged false positive).
    func dismiss(_ annotationID: UUID, note: String? = nil) {
        records[annotationID] = AnnotationDisposition(
            annotationID: annotationID,
            state: .dismissed,
            confirmedKind: nil,
            note: note?.nilIfEmpty,
            reviewedAt: .now,
            reviewedBy: defaultReviewerName
        )
        persist()
    }

    /// Wipe a single annotation's disposition — returns it to "unreviewed."
    func reset(_ annotationID: UUID) {
        guard records.removeValue(forKey: annotationID) != nil else { return }
        persist()
    }

    /// Wipe every disposition for this recording.
    func clear() {
        guard !records.isEmpty else { return }
        records = [:]
        persist()
    }

    // MARK: - Persistence

    private static func fileURL(in bundleDirectory: URL) -> URL {
        bundleDirectory.appendingPathComponent(DispositionFile.bundleFileName)
    }

    private static func loadFromDisk(at url: URL) -> [UUID: AnnotationDisposition] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(DispositionFile.self, from: data),
              file.schemaVersion == DispositionFile.currentSchemaVersion else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: file.dispositions.map { ($0.annotationID, $0) })
    }

    private func persist() {
        let file = DispositionFile(
            schemaVersion: DispositionFile.currentSchemaVersion,
            dispositions: Array(records.values).sorted { $0.reviewedAt < $1.reviewedAt }
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
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
