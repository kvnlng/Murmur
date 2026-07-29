//
//  MurSessionPackage.swift
//  MurmurCore
//
//  The native Murmur Studio SAVE format — `.mur` — per
//  project_mur_save_format_spec.md. SAVE writes the analyst's whole session at
//  Murmur Studio's OWN detail (a superset of WFDB); EXPORT projects DOWN to a
//  plain WFDB annotator (`.mrm`, see WFDBAnnotationExport). You SAVE to Murmur
//  (up), you EXPORT to WFDB (down).
//
//  `.mur` is an Apple DOCUMENT PACKAGE — a directory Finder presents as one
//  file (LSTypeIsPackage; UTType registration is X14-D). Internally it is a
//  flat NSFileWrapper directory:
//
//      Recording.mur/
//        manifest.json     versioned contract — first thing read
//        source/           embedded copy of the raw recording (reopens with no
//                          original WFDB files present); COMPRESSED in X14-B
//        annotations/      analyst layer — the bundle sidecars, reused as-is
//        dispositions/     annotation + candidate dispositions
//        guides/           interval-trend threshold guides
//        provenance.json   model id/version/tau, app version, analyst labels
//        session.json      UI/session state (viewport, layout, tau, scan scope)
//        cache/            derived, REBUILDABLE, version-stamped (X14-C)
//
//  This file is Phase A: manifest + read/write over NSFileWrapper with the
//  source embedded UNCOMPRESSED. LZFSE compression (X14-B), the cache + session
//  (X14-C), and the UTType/free-viewer wiring (X14-D) layer on without changing
//  the manifest contract (the manifest records what's present + how source is
//  stored).
//

import Foundation

/// The versioned contract at the head of every `.mur` package. Small, human-
/// diffable, and the first thing read — a newer `formatVersion` than the app
/// understands is a clear refusal, never a silent misread.
public struct MurSessionManifest: Codable, Equatable, Sendable {

    /// Bump when the on-disk layout changes incompatibly. Reads gate on this.
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    /// App short version string that wrote the package (best-effort).
    public let appVersion: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let source: SourceIdentity
    /// How the `source/` subtree is stored — `none` in Phase A, `lzfse` after
    /// X14-B. Read uses this to decide whether to inflate.
    public let sourceStorage: SourceStorage
    /// Top-level parts present in this package (`source`, `annotations`,
    /// `dispositions`, `guides`, `provenance.json`, `session.json`, `cache`).
    public let contents: [String]

    public enum SourceStorage: String, Codable, Sendable {
        case none        // raw files copied verbatim
        case lzfse       // AppleArchive/Compression (X14-B)
    }

    /// Enough to identify the recording without inflating the source — shown in
    /// pickers and used to sanity-check a reopen.
    public struct SourceIdentity: Codable, Equatable, Sendable {
        public let recordingID: UUID
        public let sourceFileName: String
        public let sampleRate: Double
        public let channelCount: Int
        public let sampleCount: Int64
        /// Optional absolute time base (Unix ms) for the first sample, present
        /// only when the SOURCE genuinely carries wall-clock time (C6).
        /// MIT-BIH/WFDB and the CSV importer don't, so this stays nil today —
        /// the field exists so the format can carry an absolute base (for the
        /// circadian / encounter-time analysis the ICU-telemetry buyer works
        /// in) the moment a source provides one, without a format-version
        /// bump. Never populated from a synthetic/import-derived timestamp.
        /// Optional so older `.mur` files decode unchanged.
        public let absoluteStartUnixMillis: Int64?
    }
}

/// The `session.json` schema — UI/session state so a reopen lands the analyst
/// back where they were. Plain snapshot; all optional so partial/older sessions
/// decode. The app composes/consumes it (X14-D); this is the shape it round-trips.
public struct MurSessionState: Codable, Equatable, Sendable {
    public var viewportStartSample: Int64?
    public var viewportEndSample: Int64?
    public var focusedChannelName: String?
    public var windowLockedTo10s: Bool?
    public var selectedTrendMetric: String?
    public var selectedBinPreset: String?
    /// VT/VF scan operating point in effect.
    public var tau: Double?
    public var minDurationSeconds: Double?
    public var mergeGapSeconds: Double?
    public var scanScopeWholeRecording: Bool?

    public init(
        viewportStartSample: Int64? = nil,
        viewportEndSample: Int64? = nil,
        focusedChannelName: String? = nil,
        windowLockedTo10s: Bool? = nil,
        selectedTrendMetric: String? = nil,
        selectedBinPreset: String? = nil,
        tau: Double? = nil,
        minDurationSeconds: Double? = nil,
        mergeGapSeconds: Double? = nil,
        scanScopeWholeRecording: Bool? = nil
    ) {
        self.viewportStartSample = viewportStartSample
        self.viewportEndSample = viewportEndSample
        self.focusedChannelName = focusedChannelName
        self.windowLockedTo10s = windowLockedTo10s
        self.selectedTrendMetric = selectedTrendMetric
        self.selectedBinPreset = selectedBinPreset
        self.tau = tau
        self.minDurationSeconds = minDurationSeconds
        self.mergeGapSeconds = mergeGapSeconds
        self.scanScopeWholeRecording = scanScopeWholeRecording
    }
}

public enum MurSessionError: LocalizedError, Equatable {
    case missingManifest
    case unsupportedFormatVersion(Int)
    case malformedPackage(String)

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "This .mur file is missing its manifest and can't be opened."
        case .unsupportedFormatVersion(let v):
            return "This .mur file was written by a newer version of Murmur Studio (format \(v)). Update to open it."
        case .malformedPackage(let detail):
            return "This .mur file is damaged: \(detail)."
        }
    }
}

public enum MurSessionPackage {

    // MARK: - Layout constants

    static let manifestFile = "manifest.json"
    static let sourceDir = "source"
    static let provenanceFile = "provenance.json"
    static let sessionFile = "session.json"
    static let cacheDir = "cache"

    /// Analyst-layer sidecars folded into the package by their real filenames,
    /// grouped into spec subdirectories. Reconstitution writes each back to the
    /// working directory root under its original filename, so the subdir is
    /// organisation only.
    static let analystSidecars: [(file: String, subdir: String)] = [
        (BundleAnnotationsFile.filename, "annotations"),
        (DispositionFile.bundleFileName, "dispositions"),
        (RegionDispositionFile.bundleFileName, "dispositions"),
        ("interval_guides.json", "guides"),
    ]

    // MARK: - Write

    /// Serialises a session into a `.mur` document package at `packageURL`
    /// (atomic). Embeds the raw recording (so the package reopens with no
    /// original files present) and folds in whatever analyst sidecars exist
    /// beside the recording. `provenanceJSON` / `sessionJSON` are opaque to this
    /// layer — the caller composes them.
    @discardableResult
    public static func write(
        recording: Recording,
        recordingDirectory: URL,
        provenanceJSON: Data? = nil,
        sessionJSON: Data? = nil,
        cacheBlobs: [String: Data] = [:],
        to packageURL: URL,
        now: Date = .now
    ) throws -> MurSessionManifest {
        var children: [String: FileWrapper] = [:]

        // source/ — the raw recording files (manifest + channel binaries +
        // pyramids + notes), each LZFSE-compressed so the package stays
        // portable without bloating. The manifest records `sourceStorage` so
        // read knows to inflate.
        var sourceChildren: [String: FileWrapper] = [:]
        for name in rawSourceFileNames(for: recording) {
            let url = recordingDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            sourceChildren[name] = FileWrapper(regularFileWithContents: try compress(data))
        }
        children[sourceDir] = FileWrapper(directoryWithFileWrappers: sourceChildren)

        // Analyst layer — group present sidecars into their spec subdirs.
        var subdirs: [String: [String: FileWrapper]] = [:]
        for sidecar in analystSidecars {
            let url = recordingDirectory.appendingPathComponent(sidecar.file)
            guard let data = try? Data(contentsOf: url) else { continue }
            subdirs[sidecar.subdir, default: [:]][sidecar.file] = FileWrapper(regularFileWithContents: data)
        }
        for (dir, files) in subdirs {
            children[dir] = FileWrapper(directoryWithFileWrappers: files)
        }

        if let provenanceJSON { children[provenanceFile] = FileWrapper(regularFileWithContents: provenanceJSON) }
        if let sessionJSON { children[sessionFile] = FileWrapper(regularFileWithContents: sessionJSON) }
        // cache/ — pre-encoded (stamped) blobs from the compute layer. Opaque
        // here; each is a MurSessionCache blob carrying its own version stamp.
        var cacheChildren: [String: FileWrapper] = [:]
        for (key, blob) in cacheBlobs {
            cacheChildren[key] = FileWrapper(regularFileWithContents: blob)
        }
        children[cacheDir] = FileWrapper(directoryWithFileWrappers: cacheChildren)

        let manifest = MurSessionManifest(
            formatVersion: MurSessionManifest.currentFormatVersion,
            appVersion: appShortVersion,
            createdAt: now,
            modifiedAt: now,
            source: sourceIdentity(for: recording),
            sourceStorage: .lzfse,
            contents: children.keys.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        children[manifestFile] = FileWrapper(regularFileWithContents: try encoder.encode(manifest))

        let root = FileWrapper(directoryWithFileWrappers: children)
        try root.write(to: packageURL, options: .atomic, originalContentsURL: nil)
        return manifest
    }

    // MARK: - Read

    public struct ReadResult: Sendable {
        public let manifest: MurSessionManifest
        /// A freshly reconstituted recording directory (source + analyst
        /// sidecars written back) ready for `RecordingStore.loadManifest`.
        public let recordingDirectory: URL
        public let provenanceJSON: Data?
        public let sessionJSON: Data?
        /// Directory holding the restored cache blobs (may be empty). Each blob
        /// is validated + inflated via `MurSessionCache.decode(_:expected:)`
        /// against the running app's stamp — a miss just recomputes.
        public let cacheDirectory: URL
    }

    /// Reads a `.mur` package, reconstituting a working recording directory
    /// under `workingDirectory` (created if needed). Refuses a newer format
    /// version rather than misreading it.
    public static func read(packageURL: URL, into workingDirectory: URL) throws -> ReadResult {
        let root = try FileWrapper(url: packageURL, options: [])
        guard let children = root.fileWrappers else {
            throw MurSessionError.malformedPackage("not a package directory")
        }
        guard let manifestData = children[manifestFile]?.regularFileContents else {
            throw MurSessionError.missingManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(MurSessionManifest.self, from: manifestData)
        guard manifest.formatVersion <= MurSessionManifest.currentFormatVersion else {
            throw MurSessionError.unsupportedFormatVersion(manifest.formatVersion)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        // source/ → working root, inflating per `sourceStorage`.
        if let source = children[sourceDir]?.fileWrappers {
            for (name, wrapper) in source {
                guard let stored = wrapper.regularFileContents else { continue }
                let data = manifest.sourceStorage == .lzfse ? try decompress(stored) : stored
                try data.write(to: workingDirectory.appendingPathComponent(name), options: .atomic)
            }
        }
        // Analyst sidecars → working root under their original filenames.
        for sidecar in analystSidecars {
            guard let data = children[sidecar.subdir]?.fileWrappers?[sidecar.file]?.regularFileContents
            else { continue }
            try data.write(to: workingDirectory.appendingPathComponent(sidecar.file), options: .atomic)
        }

        // cache/ → working cache dir, blobs verbatim (still stamped; the caller
        // validates each stamp on use and recomputes on a miss).
        let cacheDirectoryURL = workingDirectory.appendingPathComponent(cacheDir, isDirectory: true)
        try fm.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        if let cache = children[cacheDir]?.fileWrappers {
            for (key, wrapper) in cache {
                guard let blob = wrapper.regularFileContents else { continue }
                try blob.write(to: cacheDirectoryURL.appendingPathComponent(key), options: .atomic)
            }
        }

        return ReadResult(
            manifest: manifest,
            recordingDirectory: workingDirectory,
            provenanceJSON: children[provenanceFile]?.regularFileContents,
            sessionJSON: children[sessionFile]?.regularFileContents,
            cacheDirectory: cacheDirectoryURL
        )
    }

    // MARK: - Helpers

    /// The raw recording files that constitute the embedded source: the
    /// manifest, every channel's sample binary, every pyramid level, and the
    /// notes markdown. Path separators are not expected (bundle files are flat);
    /// any nested name is skipped defensively.
    static func rawSourceFileNames(for recording: Recording) -> [String] {
        var names: Set<String> = ["recording.json"]
        for channel in recording.channels {
            names.insert(channel.storageFileName)
            for level in channel.pyramid { names.insert(level.storageFileName) }
        }
        if let notes = recording.notesFileName { names.insert(notes) }
        return names.filter { !$0.contains("/") }.sorted()
    }

    static func sourceIdentity(for recording: Recording) -> MurSessionManifest.SourceIdentity {
        let primary = recording.primaryECGChannel ?? recording.channels.first
        return MurSessionManifest.SourceIdentity(
            recordingID: recording.id,
            sourceFileName: recording.sourceFileName,
            sampleRate: primary?.sampleRate ?? 0,
            channelCount: recording.channels.count,
            sampleCount: primary?.sampleCount ?? 0,
            // No current source carries genuine wall-clock time (C6); reserved
            // for a future source that does. Not derived from the synthetic
            // WFDB start time, which would be misleading.
            absoluteStartUnixMillis: nil
        )
    }

    static var appShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    // MARK: - Compression (Apple-native LZFSE)

    /// LZFSE-compress via Foundation's Compression bridge. An empty input has no
    /// compressed form, so it round-trips as empty.
    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        return try (data as NSData).compressed(using: .lzfse) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        return try (data as NSData).decompressed(using: .lzfse) as Data
    }
}
