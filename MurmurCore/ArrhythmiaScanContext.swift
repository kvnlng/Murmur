//
//  ArrhythmiaScanContext.swift
//  MurmurCore
//
//  The bridge that lets MurmurCore render arrhythmia candidates (A2)
//  without importing the paid `MurmurMetrics` package — the same
//  App-orchestrator ↔ shared-context pattern as `VTVFScanContext`. The
//  App target's `ArrhythmiaScanOrchestrator` owns the entitlement gate
//  and runs `ArrhythmiaScanService`; it publishes results here, and the
//  review queue reads them.
//
//  Candidates are carried as ordinary range `Annotation`s (source
//  `ArrhythmiaCandidateSource.id`, category per kind) so they flow
//  through the existing queue + channel-overlay plumbing. Dispositions
//  are region-keyed (they must survive a rescan) and live in their own
//  sidecar, separate from the VT/VF one — the two detectors' regions
//  overlap freely and must never inherit each other's review calls.
//
//  RUO: rows state facts (kind, span, factual detail like "median 50
//  bpm"), never verdicts. Confidence is the detector's measurement
//  reliability — not a model score.
//

import Foundation
import Observation

/// Conventions for representing an arrhythmia candidate as an
/// `Annotation`. Defined here (not in the App target) so the
/// orchestrator that MINTS candidates and the queue that RENDERS them
/// agree on one vocabulary — and so the mapping is testable from
/// MurmurTests (which cannot link the App target).
public enum ArrhythmiaCandidateSource {
    /// Producer id for every arrhythmia-scan candidate.
    public static let id = "murmur.arrhythmia"

    /// The candidate kinds the scan service emits, mirrored here as the
    /// category vocabulary. Raw values are the annotation categories the
    /// queue and the palette key on.
    public enum Kind: String, CaseIterable, Sendable, Equatable {
        case bradycardia = "BRADY_CANDIDATE"
        case tachycardia = "TACHY_CANDIDATE"
        case pause = "PAUSE_CANDIDATE"
        case atrialFibrillation = "AFIB_CANDIDATE"

        /// Neutral display label — a candidate, never a diagnosis.
        public var displayLabel: String {
            switch self {
            case .bradycardia:        return "Bradycardia candidate"
            case .tachycardia:        return "Tachycardia candidate"
            case .pause:              return "Pause candidate"
            case .atrialFibrillation: return "AFib candidate"
            }
        }
    }

    /// Every category token this source mints — membership test for
    /// consumers that need "is this an arrhythmia candidate?".
    public static let categories: Set<String> = Set(Kind.allCases.map(\.rawValue))

    /// Build a candidate annotation from primitive scan coordinates.
    /// `detail` is the service's factual string ("median 50 bpm",
    /// "2.50 s gap") and rides in `note`; `confidence` is measurement
    /// reliability. The app never composes a conclusion.
    public static func makeAnnotation(
        kind: Kind,
        startSample: Int64,
        endSample: Int64,
        detail: String,
        confidence: Double,
        lead: String? = nil
    ) -> Annotation {
        Annotation(
            kind: .range,
            sampleIndex: startSample,
            endSampleIndex: endSample,
            category: kind.rawValue,
            label: kind.displayLabel,
            confidence: confidence,
            source: id,
            note: detail,
            lead: lead
        )
    }

    /// Sidecar file for the region-keyed dispositions of THESE candidates.
    /// Distinct from the VT/VF `candidate-dispositions.json` — the two
    /// detectors' regions overlap freely (an AFib span can contain a pause)
    /// and a review call on one must never bleed onto the other.
    public static let dispositionFileName = "arrhythmia-dispositions.json"
}

/// Process-wide bridge for the arrhythmia scan flow. `@MainActor`
/// because every consumer (review queue, channel overlays) is on the
/// main actor.
@MainActor
@Observable
public final class ArrhythmiaScanContext {
    public static let shared = ArrhythmiaScanContext()

    /// Candidates from the most recent scan of the current recording,
    /// as range annotations, in time order. Empty when no recording is
    /// loaded, Murmur Studio isn't owned, or the scan found nothing.
    public private(set) var candidates: [Annotation] = []

    /// Human-readable summary of the operating points + per-recording
    /// quality read the candidates were produced under ("lead II ·
    /// 92,384 beats · RR artifact 3.2% · …"). Group subtitle + citation
    /// payload — provenance is not decoration.
    public private(set) var parametersCaption: String?

    /// RUO notice surfaced on the candidate group header (part of the
    /// findings-queue RUO surface).
    public var regulatoryNotice: String = "RESEARCH USE ONLY — not for diagnosis"

    public init() {}

    /// Publish a completed scan's candidates for the queue to render.
    public func setCandidates(_ candidates: [Annotation], parametersCaption: String?) {
        self.candidates = candidates
        self.parametersCaption = parametersCaption
    }

    /// Drop all candidates — recording closed or entitlement lost.
    public func clearCandidates() {
        candidates = []
        parametersCaption = nil
    }

    /// The per-recording quality read, composed from primitives so the
    /// wording is testable without MurmurMetrics. `nil` leadName means the
    /// scan couldn't attribute a single lead (it is omitted, not guessed).
    public nonisolated static func qualityCaption(
        beatCount: Int,
        leadName: String?,
        rrArtifactFraction: Double
    ) -> String {
        var parts: [String] = []
        if let leadName, !leadName.isEmpty { parts.append("lead \(leadName)") }
        parts.append("\(beatCount.formatted()) beats detected")
        parts.append(String(format: "RR artifact %.1f%%", rrArtifactFraction * 100))
        return parts.joined(separator: " · ")
    }
}
