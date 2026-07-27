//
//  VTVFCandidateDisposition.swift
//  MurmurCore
//
//  Analyst review state for VT/VF candidate episodes — kept SEPARATE
//  from `AnnotationDisposition` because it keys on a TIME REGION, not an
//  annotation id. This is the load-bearing data-model rule from
//  project_vtvf_candidate_review_flow.md:
//
//    A candidate is model output; a disposition is analyst-authored. A
//    rescan may re-derive the candidate list (with fresh ids), but it
//    MUST NOT discard analyst work. Attaching a disposition to a candidate
//    identity would lose the review the moment the model re-runs. Keying
//    on the reviewed time region instead lets a re-derived candidate that
//    OVERLAPS a confirmed/dismissed region inherit that disposition.
//
//  Persisted to `<bundle>/candidate-dispositions.json`, alongside — but
//  independent of — the annotation `dispositions.json`.
//

import Foundation

/// One analyst disposition anchored to a half-open sample region
/// `[startSample, endSample)`. Reuses `AnnotationDisposition`'s state and
/// confirmed-kind vocabularies so the queue's triage affordances behave
/// identically whether the row is an annotation or a candidate.
struct RegionDisposition: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startSample: Int64
    public let endSample: Int64
    public let state: AnnotationDisposition.State
    public let confirmedKind: AnnotationDisposition.ConfirmedKind?
    public let note: String?
    public let reviewedAt: Date
    public let reviewedBy: String?

    /// Model provenance captured AT CONFIRMATION — which model proposed the
    /// candidate the analyst adjudicated, and at what operating point. Sidecar
    /// only; deliberately NOT written to any exported WFDB file (that carries
    /// the analyst's words, never the model's parameters). Optional so older
    /// sidecars and non-candidate confirmations decode cleanly.
    public let modelIdentifier: String?
    public let modelVersion: String?
    public let tauAtConfirmation: Double?

    public init(
        id: UUID = UUID(),
        startSample: Int64,
        endSample: Int64,
        state: AnnotationDisposition.State,
        confirmedKind: AnnotationDisposition.ConfirmedKind?,
        note: String?,
        reviewedAt: Date,
        reviewedBy: String?,
        modelIdentifier: String? = nil,
        modelVersion: String? = nil,
        tauAtConfirmation: Double? = nil
    ) {
        self.id = id
        self.startSample = startSample
        self.endSample = endSample
        self.state = state
        self.confirmedKind = confirmedKind
        self.note = note
        self.reviewedAt = reviewedAt
        self.reviewedBy = reviewedBy
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.tauAtConfirmation = tauAtConfirmation
    }

    /// Number of samples this region and `other` share. Zero when they
    /// don't overlap. Half-open intervals, so touching endpoints (one's
    /// end == the other's start) don't count as overlap.
    public func overlapSamples(withStart otherStart: Int64, end otherEnd: Int64) -> Int64 {
        let lo = max(startSample, otherStart)
        let hi = min(endSample, otherEnd)
        return max(0, hi - lo)
    }
}

/// On-disk wire format. Schema-versioned so future changes can migrate
/// or refuse to load incompatible files.
struct RegionDispositionFile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let dispositions: [RegionDisposition]

    static let currentSchemaVersion = 1
    static let bundleFileName = "candidate-dispositions.json"

    static var empty: RegionDispositionFile {
        RegionDispositionFile(schemaVersion: currentSchemaVersion, dispositions: [])
    }
}
