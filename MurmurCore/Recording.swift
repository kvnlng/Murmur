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

public struct Recording: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let device: String
    public let createdAt: Date
    public let sourceFileName: String
    public let channels: [Channel]
    public let annotations: [Annotation]
    /// `#`-prefixed lines from the source `.hea`. Immutable — they belong to
    /// the WFDB record, not to our analyst-editable notes.
    public let headerComments: [String]
    /// Name of the analyst-editable Markdown file in the recording bundle.
    /// `nil` when there are no notes (neither the source folder shipped one
    /// nor the analyst has saved anything yet).
    public let notesFileName: String?

    /// True only when the SOURCE carried a genuine base date/time (X32).
    /// WFDB headers make the base optional and MIT-BIH omits it, so the
    /// channels' `startTimeUnixMS` is then a synthetic value used purely for
    /// relative sample↔time math — it must NOT be shown as an absolute start.
    /// Defaults false so any constructor that doesn't set it is treated as
    /// "no absolute time base" (conservative — never fabricate a start).
    public let hasAbsoluteStartTime: Bool

    public static let currentVersion = 1

    public init(
        version: Int,
        id: UUID,
        device: String,
        createdAt: Date,
        sourceFileName: String,
        channels: [Channel],
        annotations: [Annotation] = [],
        headerComments: [String] = [],
        notesFileName: String? = nil,
        hasAbsoluteStartTime: Bool = false
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
        self.hasAbsoluteStartTime = hasAbsoluteStartTime
    }

    /// Custom decoder so older manifests still load:
    ///   • Manifest without `annotations` key   → empty array
    ///   • Manifest with `[Annotation]` shape    → decoded as-is (new format)
    ///   • Manifest with `[WFDBAnnotation]` shape → adapted to point-Annotations
    ///   • `headerComments` / `notesFileName` default when absent so pre-context
    ///     manifests keep loading.
    public init(from decoder: Decoder) throws {
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
        // Absent in pre-X32 manifests → false (don't retroactively assert an
        // absolute start for records saved before the distinction existed).
        self.hasAbsoluteStartTime = (try? c.decodeIfPresent(Bool.self, forKey: .hasAbsoluteStartTime)) ?? false
    }
}

public struct Channel: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let unit: String
    public let sampleRate: Double           // Hz
    public let startTimeUnixMS: Int64       // UTC milliseconds since epoch
    public let sampleCount: Int64
    public let storageFileName: String      // Path relative to the recording directory.
    public let pyramid: [PyramidLevel]

    public init(
        id: UUID = UUID(),
        name: String,
        unit: String,
        sampleRate: Double,
        startTimeUnixMS: Int64,
        sampleCount: Int64,
        storageFileName: String,
        pyramid: [PyramidLevel] = []
    ) {
        self.id = id
        self.name = name
        self.unit = unit
        self.sampleRate = sampleRate
        self.startTimeUnixMS = startTimeUnixMS
        self.sampleCount = sampleCount
        self.storageFileName = storageFileName
        self.pyramid = pyramid
    }

    public var startDate: Date {
        Date(timeIntervalSince1970: Double(startTimeUnixMS) / 1000.0)
    }

    public var durationSeconds: Double {
        Double(sampleCount) / sampleRate
    }

    public func sampleIndex(for unixMS: Int64) -> Int64 {
        Int64(Double(unixMS - startTimeUnixMS) * sampleRate / 1000.0)
    }

    /// True for low-rate channels — vital trends, 1-min feature columns,
    /// GMM state probabilities, etc. — that should render as a sparkline
    /// strip instead of on the Metal ECG canvas. The threshold (5 Hz) sits
    /// well above the 1/60 Hz Silver feature store grain and well below
    /// the slowest ECG / pressure waveforms.
    public var isTrendChannel: Bool {
        sampleRate < 5
    }
}

// MARK: - Beat annotations

public extension Recording {

    /// MIT-BIH "N" label — Normal sinus beat. Kept as a named
    /// constant so callers can key against it explicitly rather than
    /// literal-matching a magic string.
    static var normalBeatLabel: String { "N" }

    /// Sorted sample-indices of Normal beats from any WFDB `.atr`
    /// annotations attached to this recording. Empty when no beat
    /// data is present. Filters strictly to the MIT-BIH "N" label —
    /// the classical NN-interval convention for HRV analysis (Task
    /// Force 1996). Other beat classes (V / F / a / …) are excluded
    /// so downstream HRV analytics see only Normal-to-Normal
    /// intervals.
    ///
    /// Data selection only — no arithmetic on measurement values.
    /// The result is a `[Int64]` of raw sample positions; downstream
    /// analytics (e.g. the ECG Metrics paid framework) own the
    /// interval math and everything derived from it.
    func normalBeatSampleIndices() -> [Int64] {
        annotations
            .filter { $0.source.hasPrefix("wfdb.atr") }
            // The WFDB → Annotation adapter (`init(fromWFDB:)`) puts the
            // beat symbol into `category`, not `label`. `label` on WFDB
            // annotations is nil. Filter on `category`.
            .filter { $0.category == Self.normalBeatLabel }
            .map(\.sampleIndex)
            .sorted()
    }

    /// Read the entire sample buffer of the primary ECG channel from
    /// its on-disk file inside `directory`. Returns nil when the
    /// recording has no ECG channels or the file is unreadable.
    ///
    /// Public because the App target's paid-feature orchestrators
    /// (MurmurMetrics-consuming) need whole-recording ECG access to
    /// delineate beats, but the underlying `MappedSampleAccess` and
    /// `BinaryRecordingFile` types remain internal. This helper is
    /// the only sanctioned way across the module boundary.
    func primaryECGSamples(inDirectory directory: URL) -> [Float]? {
        let ecgChannels = channels.filter { !$0.isTrendChannel }
        guard let channel = ecgChannels.first,
              channel.sampleCount > 0 else { return nil }
        let url = directory.appendingPathComponent(channel.storageFileName)
        return try? BinaryRecordingFile.readSamples(
            url: url,
            range: 0..<channel.sampleCount
        )
    }

    /// Primary ECG channel — the delineator needs `sampleRate` to
    /// convert its results to milliseconds. `nil` when no ECG channel
    /// exists.
    var primaryECGChannel: Channel? {
        channels.first { !$0.isTrendChannel }
    }
}

public struct PyramidLevel: Codable, Equatable, Sendable {
    public let binSamples: Int              // Raw samples per bin (10, 100, 1000, …)
    public let binCount: Int64
    public let storageFileName: String      // Packed (min, max) Float64 pairs.

    public init(binSamples: Int, binCount: Int64, storageFileName: String) {
        self.binSamples = binSamples
        self.binCount = binCount
        self.storageFileName = storageFileName
    }
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
