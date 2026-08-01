//
//  VTVFScanContext.swift
//  MurmurCore
//
//  The bridge that lets MurmurCore render VT/VF candidates without
//  importing the paid `MurmurInference` framework — the same
//  App-orchestrator ↔ shared-context pattern used by the variability and
//  interval lanes. The App target's `VTVFScanOrchestrator` owns the model
//  and the entitlement gate; it publishes results here, and `BedsideView`
//  reads them.
//
//  Candidates are carried as ordinary `Annotation` values (range, source
//  `VTVFCandidateSource.id`) so they flow through the existing review
//  queue. Their DISPOSITIONS, however, live in the separate time-region
//  store (`VTVFCandidateDispositionStore`) — never the annotation
//  UUID-keyed one — so they survive a rescan.
//

import Foundation
import Observation

/// Conventions for representing a VT/VF candidate as an `Annotation`.
/// Defined here (not in the App target) so the orchestrator that MINTS
/// candidates and the queue that RENDERS them agree on one vocabulary.
public enum VTVFCandidateSource {
    /// Producer id. Matches `PurchaseStore.requiredProduct` → `.studio`
    /// so entitlement gating is consistent with the rest of the app.
    public static let id = "murmur.vtdetect"
    /// Category token the review queue keys on to render the candidate group.
    public static let category = "VTVF_CANDIDATE"
    public static let displayLabel = "VT/VF candidate"

    /// Build a candidate annotation from primitive scan coordinates. The
    /// model's aggregate score rides in `confidence`; the coordinate span
    /// rides in the sample range. The app NEVER composes a conclusion —
    /// the label is a neutral "candidate", per RUO discipline.
    public static func makeAnnotation(
        startSample: Int64,
        endSample: Int64,
        score: Double,
        lead: String? = nil
    ) -> Annotation {
        Annotation(
            kind: .range,
            sampleIndex: startSample,
            endSampleIndex: endSample,
            category: category,
            label: displayLabel,
            confidence: score,
            source: id,
            lead: lead
        )
    }
}

/// Process-wide bridge for the VT/VF scan flow. `@MainActor` because
/// every consumer (BedsideView toolbar, the orchestrator's sheet, the
/// review queue) is on the main actor.
@MainActor
@Observable
public final class VTVFScanContext {
    public static let shared = VTVFScanContext()

    /// True when a scan can be started right now — the VT/VF IAP is owned
    /// and a recording is loaded. Set by the orchestrator; drives the
    /// toolbar affordance in BedsideView.
    public var isScanAvailable: Bool = false

    /// Toolbar → orchestrator request latch. BedsideView flips this true;
    /// the orchestrator presents the scan dialog and flips it back.
    public var showScanDialog: Bool = false

    /// Current viewport span (native-rate sample indices) captured when
    /// the scan dialog is requested. The dialog previews on this span —
    /// "preview always runs on the current view" — since the viewport
    /// itself lives in BedsideView, not the App-target orchestrator.
    public private(set) var currentViewStartSample: Int64 = 0
    public private(set) var currentViewEndSample: Int64 = 0

    /// Candidates from the most recent committed scan, as range
    /// annotations. Empty until a scan is applied to the recording.
    public private(set) var candidates: [Annotation] = []

    /// Human-readable summary of the operating point the current
    /// candidates were produced at (τ / min-duration / merge-gap / model).
    /// Shown as the candidate group's subtitle and used in the citation.
    public private(set) var parametersCaption: String?

    /// RUO notice surfaced on the candidate group header. Sourced from the
    /// model metadata by the orchestrator; falls back to the standard text.
    public var regulatoryNotice: String = "RESEARCH USE ONLY — not for diagnosis"

    /// Structured model provenance for the current candidate set — recorded
    /// onto a disposition when the analyst CONFIRMS a candidate, so the sidecar
    /// remembers which model at which operating point proposed the region. Kept
    /// structured (not just folded into `parametersCaption`) because the
    /// disposition store persists the fields individually.
    public struct ModelProvenance: Equatable, Sendable {
        public let modelIdentifier: String?
        public let modelVersion: String?
        public let tau: Double?

        public init(modelIdentifier: String?, modelVersion: String? = nil, tau: Double?) {
            self.modelIdentifier = modelIdentifier
            self.modelVersion = modelVersion
            self.tau = tau
        }
    }

    /// Provenance of the current candidate set. Nil until a scan is committed
    /// (or under the XCUI candidate-injection bypass, which has no live model).
    public private(set) var candidateProvenance: ModelProvenance?

    public init() {}

    /// Publish a committed scan's candidates for the queue to render.
    public func setCandidates(
        _ candidates: [Annotation],
        parametersCaption: String?,
        provenance: ModelProvenance? = nil
    ) {
        self.candidates = candidates
        self.parametersCaption = parametersCaption
        self.candidateProvenance = provenance
    }

    /// Drop all candidates — e.g. when the recording closes.
    public func clearCandidates() {
        candidates = []
        parametersCaption = nil
        candidateProvenance = nil
    }

    /// Request the scan dialog, capturing the viewport span to preview on.
    public func requestScanDialog(viewStartSample: Int64, viewEndSample: Int64) {
        currentViewStartSample = viewStartSample
        currentViewEndSample = viewEndSample
        showScanDialog = true
    }
}
