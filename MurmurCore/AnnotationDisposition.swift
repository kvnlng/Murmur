//
//  AnnotationDisposition.swift
//  Murmur
//
//  Analyst-side review state for a single annotation. Lives in
//  `<bundle>/dispositions.json`, separate from `recording.json` so that
//  re-running the upstream model (which regenerates the
//  `<recordName>.annotations.json`) doesn't blow away analyst work.
//
//  The three logical states are: `unreviewed` (absence of a disposition
//  for that annotation id), `confirmed` (with an optional VT/VF kind),
//  and `dismissed`. Absence of a record means unreviewed — there's no
//  need to materialize a row per annotation.
//

import Foundation

struct AnnotationDisposition: Codable, Equatable, Sendable {
    /// `Annotation.id` this disposition applies to.
    let annotationID: UUID
    let state: State
    /// Optional sub-classification when the analyst confirmed the event.
    /// `nil` means "confirmed but kind unspecified" (the model's binary
    /// VT/VF output can't tell which one — analyst may not be sure either).
    let confirmedKind: ConfirmedKind?
    let note: String?
    let reviewedAt: Date
    /// Best-effort analyst identifier — defaults to the macOS user name at
    /// review time. Optional so producer-side fixtures don't need to set it.
    let reviewedBy: String?

    enum State: String, Codable, Sendable {
        case confirmed
        case dismissed
    }

    enum ConfirmedKind: String, Codable, Sendable, CaseIterable {
        case vt
        case vf
        case unclassified

        /// Compact uppercase label for chips ("VT", "VF", "—").
        var shortLabel: String {
            switch self {
            case .vt:           return "VT"
            case .vf:           return "VF"
            case .unclassified: return "—"
            }
        }
    }
}

/// On-disk wire format. Schema-versioned so future changes can
/// migrate or refuse to load incompatible files.
struct DispositionFile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let dispositions: [AnnotationDisposition]

    static let currentSchemaVersion = 1

    /// Bundle-relative filename for the sidecar.
    static let bundleFileName = "dispositions.json"

    static var empty: DispositionFile {
        DispositionFile(schemaVersion: currentSchemaVersion, dispositions: [])
    }
}

enum DispositionFileError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v):
            return "Unsupported dispositions schemaVersion \(v) (this viewer understands version \(DispositionFile.currentSchemaVersion))."
        }
    }
}
