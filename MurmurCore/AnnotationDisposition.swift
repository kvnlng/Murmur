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
    /// What the analyst says this finding actually IS (#331).
    ///
    /// `confirmedKind` above is a closed VT/VF enum built for the arrhythmia
    /// scan. Every other producer emits its own category vocabulary — `AFib`,
    /// `PVC`, a SNOMED code — so with the enum alone an analyst reviewing
    /// those could only say "confirmed", never "this is actually X". That
    /// makes label auditing impossible: disagreeing with a label is the whole
    /// point of the review.
    ///
    /// Free-form on purpose. The vocabulary belongs to whoever produced the
    /// annotations, so the app must not constrain it to a list it invented —
    /// same reason the wire format's `category` is a bare string.
    ///
    /// A plain Confirm records the annotation's OWN category, so "confirmed
    /// as labelled" and "confirmed as something else" are distinguishable
    /// downstream rather than both collapsing to bare `confirmed`.
    let confirmedCategory: String?
    let note: String?
    let reviewedAt: Date
    /// Best-effort analyst identifier — defaults to the macOS user name at
    /// review time. Optional so producer-side fixtures don't need to set it.
    let reviewedBy: String?

    /// `confirmedCategory` positioned after `confirmedKind` and defaulted, so
    /// every pre-#331 construction site compiles untouched. Optional fields
    /// decode as nil when absent and are omitted when nil, so a sidecar
    /// written by an earlier build still loads — the schema stays at 1.
    init(
        annotationID: UUID,
        state: State,
        confirmedKind: ConfirmedKind?,
        confirmedCategory: String? = nil,
        note: String?,
        reviewedAt: Date,
        reviewedBy: String? = nil
    ) {
        self.annotationID = annotationID
        self.state = state
        self.confirmedKind = confirmedKind
        // Whitespace-only normalises to nil, matching how `note` is handled at
        // the store — a blank category is the absence of one, not a value.
        let trimmedCategory = confirmedCategory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.confirmedCategory = (trimmedCategory?.isEmpty ?? true) ? nil : trimmedCategory
        self.note = note
        self.reviewedAt = reviewedAt
        self.reviewedBy = reviewedBy
    }

    /// True when the analyst named a category that differs from the one the
    /// producer sent — i.e. they overrode the label rather than agreeing with
    /// it. Drives the queue chip and the report's wording.
    func overridesCategory(of annotation: Annotation) -> Bool {
        guard let confirmedCategory else { return false }
        return confirmedCategory != annotation.category
    }

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
