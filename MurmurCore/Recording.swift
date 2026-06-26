//
//  Recording.swift
//  Murmur
//
//  Core domain model. A Recording corresponds to one imported WFDB record (one
//  .hea/.dat pair, optionally accompanied by .atr beat marks and/or a richer
//  `<recordName>.annotations.json` produced by the analysis cluster).
//

import Foundation

// MARK: - Manifest model

struct Recording: Codable, Equatable, Sendable {
    let version: Int
    let id: UUID
    let device: String
    let createdAt: Date
    let sourceFileName: String
    let channels: [Channel]
    let annotations: [Annotation]
    /// `#`-prefixed lines from the source `.hea`. Immutable — they belong to
    /// the WFDB record, not to our analyst-editable notes.
    let headerComments: [String]
    /// Name of the analyst-editable Markdown file in the recording bundle.
    /// `nil` when there are no notes (neither the source folder shipped one
    /// nor the analyst has saved anything yet).
    let notesFileName: String?

    static let currentVersion = 1

    init(
        version: Int,
        id: UUID,
        device: String,
        createdAt: Date,
        sourceFileName: String,
        channels: [Channel],
        annotations: [Annotation] = [],
        headerComments: [String] = [],
        notesFileName: String? = nil
    ) {
        self.version = version
        self.id = id
        self.device = device
        self.createdAt = createdAt
        self.sourceFileName = sourceFileName
        self.channels = channels
        self.annotations = annotations
        self.headerComments = headerComments
        self.notesFileName = notesFileName
    }

    /// Custom decoder so older manifests still load:
    ///   • Manifest without `annotations` key   → empty array
    ///   • Manifest with `[Annotation]` shape    → decoded as-is (new format)
    ///   • Manifest with `[WFDBAnnotation]` shape → adapted to point-Annotations
    ///   • `headerComments` / `notesFileName` default when absent so pre-context
    ///     manifests keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decode(Int.self, forKey: .version)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.device = try c.decode(String.self, forKey: .device)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.sourceFileName = try c.decode(String.self, forKey: .sourceFileName)
        self.channels = try c.decode([Channel].self, forKey: .channels)

        if let modern = try? c.decode([Annotation].self, forKey: .annotations) {
            self.annotations = modern
        } else if let legacy = try? c.decode([WFDBAnnotation].self, forKey: .annotations) {
            self.annotations = legacy.map(Annotation.init(fromWFDB:))
        } else {
            self.annotations = []
        }

        self.headerComments = (try? c.decodeIfPresent([String].self, forKey: .headerComments)) ?? []
        self.notesFileName  = try? c.decodeIfPresent(String.self,    forKey: .notesFileName)
    }
}

struct Channel: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let unit: String
    let sampleRate: Double           // Hz
    let startTimeUnixMS: Int64       // UTC milliseconds since epoch
    let sampleCount: Int64
    let storageFileName: String      // Path relative to the recording directory.
    let pyramid: [PyramidLevel]

    var startDate: Date {
        Date(timeIntervalSince1970: Double(startTimeUnixMS) / 1000.0)
    }

    var durationSeconds: Double {
        Double(sampleCount) / sampleRate
    }

    func sampleIndex(for unixMS: Int64) -> Int64 {
        Int64(Double(unixMS - startTimeUnixMS) * sampleRate / 1000.0)
    }

    /// True for low-rate channels — vital trends, 1-min feature columns,
    /// GMM state probabilities, etc. — that should render as a sparkline
    /// strip instead of on the Metal ECG canvas. The threshold (5 Hz) sits
    /// well above the 1/60 Hz Silver feature store grain and well below
    /// the slowest ECG / pressure waveforms.
    var isTrendChannel: Bool {
        sampleRate < 5
    }
}

struct PyramidLevel: Codable, Equatable, Sendable {
    let binSamples: Int              // Raw samples per bin (10, 100, 1000, …)
    let binCount: Int64
    let storageFileName: String      // Packed (min, max) Float64 pairs.
}

// MARK: - Import result types

struct ImportSummary: Equatable, Sendable {
    let recording: Recording
    let directory: URL
    let signalsImported: Int
    let totalSamples: Int64
}

struct ImportProgress: Sendable, Equatable {
    let bytesRead: Int64
    let totalBytes: Int64

    var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesRead) / Double(totalBytes))
    }
}

typealias ImportProgressHandler = @Sendable (ImportProgress) -> Void
