//
//  VTVFCandidateStore.swift
//  MurmurCore
//
//  Bundle-sidecar persistence for a committed VT/VF scan's candidates.
//
//  Exists because the candidates and their DISPOSITIONS had opposite
//  lifetimes. `VTVFCandidateDispositionStore` writes the analyst's
//  confirm/dismiss decisions to `candidate-dispositions.json` and reloads them
//  on open; the candidates themselves lived only in the in-memory
//  `VTVFScanContext` and were dropped the moment the recording changed. Open
//  another record and come back and the queue was empty — while the
//  adjudications sat on disk, bound to regions nothing was displaying.
//
//  Rescanning did re-attach them (region-keyed dispositions are designed to
//  survive a rescan), but that is not a recovery an analyst can be expected to
//  discover, and it is not equivalent: a rescan runs whatever model is
//  installed NOW at whatever τ is set NOW. If either has moved, the regions
//  differ, and the persisted dispositions silently bind to a different set of
//  candidates than the ones that were reviewed. For a research tool that is a
//  provenance failure, not a refresh.
//
//  So the candidates persist with the operating point that produced them.
//  Reopening a scanned record shows exactly what was found, at the τ and model
//  it was found with, regardless of what has been installed since.
//

import Foundation

/// On-disk shape. The provenance fields are stored flat rather than as a
/// nested `ModelProvenance` so this file format stays independent of a type
/// that belongs to the scan-flow bridge.
struct VTVFCandidateFile: Codable {
    static let bundleFileName = "vtvf-candidates.json"
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let parametersCaption: String?
    let modelIdentifier: String?
    let modelVersion: String?
    let tau: Double?
    let candidates: [Annotation]
}

/// Reads and writes the committed-candidate sidecar beside a recording.
///
/// A value type, unlike the disposition stores: there is no observable state
/// to hold. The live candidate set is `VTVFScanContext`'s; this only moves it
/// to and from disk.
public struct VTVFCandidateStore: Sendable {

    private let bundleDirectory: URL

    public init(bundleDirectory: URL) {
        self.bundleDirectory = bundleDirectory
    }

    /// A restored scan: the candidates plus the operating point they were
    /// produced at.
    public struct Saved: Sendable, Equatable {
        public let candidates: [Annotation]
        public let parametersCaption: String?
        public let modelIdentifier: String?
        public let modelVersion: String?
        public let tau: Double?
    }

    /// The stored scan for this recording, or nil when none was ever committed
    /// (or the file is unreadable / from a future schema). Never throws: a
    /// missing or unparseable sidecar means "no saved scan", which is exactly
    /// how the app behaved before this existed.
    public func load() -> Saved? {
        let url = Self.fileURL(in: bundleDirectory)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(VTVFCandidateFile.self, from: data),
              file.schemaVersion == VTVFCandidateFile.currentSchemaVersion,
              !file.candidates.isEmpty else {
            return nil
        }
        return Saved(
            candidates: file.candidates,
            parametersCaption: file.parametersCaption,
            modelIdentifier: file.modelIdentifier,
            modelVersion: file.modelVersion,
            tau: file.tau
        )
    }

    /// Write a committed scan. An empty candidate set removes the sidecar
    /// rather than writing an empty one — a scan that found nothing and a
    /// record that was never scanned read the same to the queue, and leaving a
    /// stale file behind would resurrect the previous scan on the next open.
    public func save(
        candidates: [Annotation],
        parametersCaption: String?,
        modelIdentifier: String?,
        modelVersion: String?,
        tau: Double?
    ) {
        let url = Self.fileURL(in: bundleDirectory)
        guard !candidates.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let file = VTVFCandidateFile(
            schemaVersion: VTVFCandidateFile.currentSchemaVersion,
            parametersCaption: parametersCaption,
            modelIdentifier: modelIdentifier,
            modelVersion: modelVersion,
            tau: tau,
            candidates: candidates.sorted { $0.sampleIndex < $1.sampleIndex }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func fileURL(in bundleDirectory: URL) -> URL {
        bundleDirectory.appendingPathComponent(VTVFCandidateFile.bundleFileName)
    }
}
