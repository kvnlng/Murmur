//
//  MurSessionPackage.swift
//  MurmurCore
//
//  Read/write engine for the native `.mur` SAVE format. The on-disk CONTRACT
//  — manifest, per-record and session-level state, provenance, errors — lives
//  in MurSessionFormat.swift; this file is the NSFileWrapper plumbing that
//  serialises to it and reconstitutes from it.
//
//  Split at X63-A: multi-record support pushed the single file past 650 lines
//  with three more phases (flagging, open path, encryption) still to land.
//

import Foundation

public enum MurSessionPackage {

    // MARK: - Layout constants

    static let manifestFile = "manifest.json"
    static let sourceDir = "source"
    static let provenanceFile = "provenance.json"
    static let sessionFile = "session.json"
    static let cacheDir = "cache"
    /// #358 — the folder-wide lead placement map plus per-record overrides
    /// (`LeadPlacementMapSnapshot`), written at the package root beside
    /// `session.json`. Present only when the session has at least one
    /// declaration — an undeclared session must write byte-identically to
    /// a pre-#358 one, so this member is omitted rather than written empty.
    static let leadMapFile = "lead_map.json"

    /// Holds one subtree per record, named by `recordingID` (X63-A).
    ///
    /// Keyed by UUID rather than by source filename on purpose: two records in
    /// one directory can share a base name, and — once X63-D lands encryption —
    /// a filename on the outside of the package would identify its contents.
    static let recordsDir = "records"

    /// The sealed blob on an encrypted package — the entire plaintext package,
    /// serialized and encrypted as one unit (X63-D).
    static let payloadFile = "payload.enc"

    /// Analyst-layer sidecars folded into the package by their real filenames,
    /// grouped into spec subdirectories. Reconstitution writes each back to the
    /// working directory root under its original filename, so the subdir is
    /// organisation only.
    static let analystSidecars: [(file: String, subdir: String)] = [
        (BundleAnnotationsFile.filename, "annotations"),
        (DispositionFile.bundleFileName, "dispositions"),
        (RegionDispositionFile.bundleFileName, "dispositions"),
        // Committed VT/VF candidates. Travels with the region dispositions
        // that adjudicate it — a package carrying the verdicts but not what
        // was judged would reopen with the same orphaned-disposition problem
        // this sidecar exists to fix.
        (VTVFCandidateFile.bundleFileName, "annotations"),
        ("interval_guides.json", "guides"),
        // #357 — the analysis-lead sidecar. Not purely an analyst artifact
        // (it can hold only the import-time scored default, no designation
        // at all), so it gets its own subdir rather than "dispositions" —
        // the honest name for a file that may be scorer-written, analyst-
        // written, or both.
        (AnalysisLeadFile.bundleFileName, "analysis_lead"),
    ]

    // MARK: - Write

    /// One record's contribution to a session. `provenanceJSON` / `sessionJSON`
    /// stay opaque to this layer — the caller composes them.
    public struct RecordPayload: Sendable {
        public let recording: Recording
        public let recordingDirectory: URL
        public let provenanceJSON: Data?
        public let sessionJSON: Data?
        public let cacheBlobs: [String: Data]

        public init(
            recording: Recording,
            recordingDirectory: URL,
            provenanceJSON: Data? = nil,
            sessionJSON: Data? = nil,
            cacheBlobs: [String: Data] = [:]
        ) {
            self.recording = recording
            self.recordingDirectory = recordingDirectory
            self.provenanceJSON = provenanceJSON
            self.sessionJSON = sessionJSON
            self.cacheBlobs = cacheBlobs
        }
    }

    /// Serialises a session of one or more records into a `.mur` document
    /// package at `packageURL` (atomic). Each record embeds its own raw source
    /// (so the package reopens with no original files present) plus whatever
    /// analyst sidecars sit beside it.
    ///
    /// `payloads` order is the analyst's order and is preserved in
    /// `manifest.records`.
    @discardableResult
    public static func write(
        records payloads: [RecordPayload],
        collectionJSON: Data? = nil,
        leadMapJSON: Data? = nil,
        passphrase: String? = nil,
        to packageURL: URL,
        now: Date = .now
    ) throws -> MurSessionManifest {
        guard !payloads.isEmpty else { throw MurSessionError.noRecords }

        // Subtrees are keyed by recordingID, so a repeat would silently
        // overwrite rather than produce the set the analyst asked for.
        var seen = Set<UUID>()
        for payload in payloads where !seen.insert(payload.recording.id).inserted {
            throw MurSessionError.duplicateRecordingID(payload.recording.id)
        }

        var recordChildren: [String: FileWrapper] = [:]
        for payload in payloads {
            recordChildren[payload.recording.id.uuidString] = try recordWrapper(for: payload)
        }

        var children: [String: FileWrapper] = [
            recordsDir: FileWrapper(directoryWithFileWrappers: recordChildren),
        ]
        if let collectionJSON {
            children[sessionFile] = FileWrapper(regularFileWithContents: collectionJSON)
        }
        if let leadMapJSON {
            children[leadMapFile] = FileWrapper(regularFileWithContents: leadMapJSON)
        }

        let manifest = MurSessionManifest(
            formatVersion: MurSessionManifest.currentFormatVersion,
            appVersion: appShortVersion,
            createdAt: now,
            modifiedAt: now,
            records: payloads.map { sourceIdentity(for: $0.recording) },
            encryption: nil,
            sourceStorage: .lzfse,
            contents: children.keys.sorted()
        )
        children[manifestFile] = FileWrapper(regularFileWithContents: try encode(manifest))

        guard let passphrase, !passphrase.isEmpty else {
            let root = FileWrapper(directoryWithFileWrappers: children)
            try root.write(to: packageURL, options: .atomic, originalContentsURL: nil)
            return manifest
        }
        return try writeEncrypted(
            plaintextChildren: children, passphrase: passphrase, manifest: manifest,
            to: packageURL, now: now
        )
    }

    /// Seal the ENTIRE plaintext package — its own manifest, `records/`, and
    /// session state — as one blob, and write it beside a minimal manifest.
    ///
    /// Sealing the whole tree rather than each file is deliberate. Per-file
    /// encryption would preserve the directory structure on the outside, so the
    /// record count and every `recordingID` would remain readable — the thing
    /// encryption is here to prevent. The accepted cost is that an encrypted
    /// package is resealed whole on every save and loses `NSFileWrapper`'s
    /// incremental writes.
    private static func writeEncrypted(
        plaintextChildren: [String: FileWrapper],
        passphrase: String,
        manifest: MurSessionManifest,
        to packageURL: URL,
        now: Date
    ) throws -> MurSessionManifest {
        let salt = MurSessionCrypto.makeSalt()
        let parameters = MurSessionManifest.EncryptionParameters(
            kdf: MurSessionCrypto.kdfIdentifier,
            iterations: MurSessionCrypto.defaultIterations,
            salt: salt,
            cipher: MurSessionCrypto.cipherIdentifier
        )
        // The outward-facing manifest says only that this is a Murmur session,
        // that it is sealed, and how to re-derive the key. `records` and
        // `contents` are omitted: a filename identifies a recording and a count
        // is information.
        let outer = MurSessionManifest(
            formatVersion: MurSessionManifest.currentFormatVersion,
            appVersion: manifest.appVersion,
            createdAt: now,
            modifiedAt: now,
            records: nil,
            encryption: parameters,
            sourceStorage: manifest.sourceStorage,
            contents: nil
        )
        let outerData = try encode(outer)

        let plaintextRoot = FileWrapper(directoryWithFileWrappers: plaintextChildren)
        let key = try MurSessionCrypto.deriveKey(
            passphrase: passphrase, salt: salt, iterations: parameters.iterations
        )
        // The outer manifest is the AAD, so swapping it invalidates the seal.
        let sealed = try MurSessionCrypto.seal(
            plaintextRoot.serializedRepresentation ?? Data(),
            key: key,
            authenticating: outerData
        )

        let root = FileWrapper(directoryWithFileWrappers: [
            manifestFile: FileWrapper(regularFileWithContents: outerData),
            payloadFile: FileWrapper(regularFileWithContents: sealed),
        ])
        try root.write(to: packageURL, options: .atomic, originalContentsURL: nil)
        return outer
    }

    private static func encode(_ manifest: MurSessionManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    /// Single-record convenience — the shape of a save with nothing flagged.
    /// The multi-record path is the real one; this just spares every call site
    /// from wrapping a lone payload (X63-B replaces the app's use of it with
    /// the sidebar-flagged set).
    @discardableResult
    public static func write(
        recording: Recording,
        recordingDirectory: URL,
        provenanceJSON: Data? = nil,
        sessionJSON: Data? = nil,
        cacheBlobs: [String: Data] = [:],
        passphrase: String? = nil,
        to packageURL: URL,
        now: Date = .now
    ) throws -> MurSessionManifest {
        try write(
            records: [
                RecordPayload(
                    recording: recording,
                    recordingDirectory: recordingDirectory,
                    provenanceJSON: provenanceJSON,
                    sessionJSON: sessionJSON,
                    cacheBlobs: cacheBlobs
                ),
            ],
            collectionJSON: try? JSONEncoder().encode(
                MurCollectionState(activeRecordingID: recording.id)
            ),
            passphrase: passphrase,
            to: packageURL,
            now: now
        )
    }

    /// Everything belonging to ONE record: `source/`, the analyst sidecars,
    /// `provenance.json`, `session.json`, `cache/`.
    private static func recordWrapper(for payload: RecordPayload) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]

        // source/ — the raw recording files (manifest + channel binaries +
        // pyramids + notes), each LZFSE-compressed so the package stays
        // portable without bloating. The manifest records `sourceStorage` so
        // read knows to inflate.
        var sourceChildren: [String: FileWrapper] = [:]
        for name in rawSourceFileNames(for: payload.recording) {
            let url = payload.recordingDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            sourceChildren[name] = FileWrapper(regularFileWithContents: try compress(data))
        }
        children[sourceDir] = FileWrapper(directoryWithFileWrappers: sourceChildren)

        // Analyst layer — group present sidecars into their spec subdirs.
        var subdirs: [String: [String: FileWrapper]] = [:]
        for sidecar in analystSidecars {
            let url = payload.recordingDirectory.appendingPathComponent(sidecar.file)
            guard let data = try? Data(contentsOf: url) else { continue }
            subdirs[sidecar.subdir, default: [:]][sidecar.file] = FileWrapper(regularFileWithContents: data)
        }
        for (dir, files) in subdirs {
            children[dir] = FileWrapper(directoryWithFileWrappers: files)
        }

        if let provenanceJSON = payload.provenanceJSON {
            children[provenanceFile] = FileWrapper(regularFileWithContents: provenanceJSON)
        }
        if let sessionJSON = payload.sessionJSON {
            children[sessionFile] = FileWrapper(regularFileWithContents: sessionJSON)
        }
        // cache/ — pre-encoded (stamped) blobs from the compute layer. Opaque
        // here; each is a MurSessionCache blob carrying its own version stamp.
        var cacheChildren: [String: FileWrapper] = [:]
        for (key, blob) in payload.cacheBlobs {
            cacheChildren[key] = FileWrapper(regularFileWithContents: blob)
        }
        children[cacheDir] = FileWrapper(directoryWithFileWrappers: cacheChildren)

        return FileWrapper(directoryWithFileWrappers: children)
    }

    // MARK: - Read

    /// One reconstituted record, ready for `RecordingStore.loadManifest`.
    public struct RecordResult: Sendable {
        public let identity: MurSessionManifest.SourceIdentity
        /// A freshly reconstituted recording directory (source + analyst
        /// sidecars written back).
        public let recordingDirectory: URL
        public let provenanceJSON: Data?
        public let sessionJSON: Data?
        /// Directory holding the restored cache blobs (may be empty). Each blob
        /// is validated + inflated via `MurSessionCache.decode(_:expected:)`
        /// against the running app's stamp — a miss just recomputes.
        public let cacheDirectory: URL
    }

    public struct ReadResult: Sendable {
        public let manifest: MurSessionManifest
        /// Every record in the package, in `manifest.records` order.
        /// Never empty — `write` refuses to produce a record-less package and
        /// `read` refuses to return one.
        public let records: [RecordResult]
        /// Session-level state (`MurCollectionState`), opaque here.
        public let collectionJSON: Data?
        /// #358 — the lead placement map (`LeadPlacementMapSnapshot`), opaque
        /// here. `nil` on a session with no declarations or a pre-#358
        /// package — both read the same as "nothing declared".
        public let leadMapJSON: Data?

        /// The record to present first: whatever the analyst had active at
        /// save, else the first in order.
        public var activeRecord: RecordResult {
            guard let json = collectionJSON,
                  let state = try? JSONDecoder().decode(MurCollectionState.self, from: json),
                  let id = state.activeRecordingID,
                  let match = records.first(where: { $0.identity.recordingID == id })
            else { return records[0] }
            return match
        }
    }

    /// Reads a `.mur` package, reconstituting one working directory PER RECORD
    /// under `workingDirectory` (created if needed), each named by its
    /// `recordingID`. Refuses a newer format version rather than misreading it.
    public static func read(
        packageURL: URL,
        into workingDirectory: URL,
        passphrase: String? = nil
    ) throws -> ReadResult {
        let root = try FileWrapper(url: packageURL, options: [])
        guard var children = root.fileWrappers else {
            throw MurSessionError.malformedPackage("not a package directory")
        }
        guard var manifestData = children[manifestFile]?.regularFileContents else {
            throw MurSessionError.missingManifest
        }

        // X63-D: an encrypted package is a minimal manifest plus one sealed
        // blob holding the ENTIRE plaintext package. Unsealing yields exactly
        // the structure the plaintext reader below already understands, so
        // there is one reader rather than two — the encrypted path is a
        // decrypt step in front of it, not a parallel implementation.
        if let parameters = try encryptionParameters(from: manifestData) {
            guard let passphrase, !passphrase.isEmpty else {
                throw MurSessionError.passphraseRequired
            }
            guard let sealed = children[payloadFile]?.regularFileContents else {
                throw MurSessionError.malformedPackage("its encrypted payload is missing")
            }
            let key = try MurSessionCrypto.deriveKey(
                passphrase: passphrase, salt: parameters.salt, iterations: parameters.iterations
            )
            // The outer manifest is the AAD, so a swapped header fails here
            // rather than being silently accepted.
            let plaintext = try MurSessionCrypto.open(
                sealed, key: key, authenticating: manifestData
            )
            let inner = FileWrapper(serializedRepresentation: plaintext)
            guard let innerChildren = inner?.fileWrappers,
                  let innerManifest = innerChildren[manifestFile]?.regularFileContents else {
                // Authentication already passed, so the bytes are ours and
                // intact — a failure here is a real structural problem, not a
                // wrong passphrase, and must not be reported as one.
                throw MurSessionError.malformedPackage("its decrypted contents could not be read")
            }
            children = innerChildren
            manifestData = innerManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // VERSION FIRST, then shape. A newer format is free to change the
        // manifest's shape — that is what a version is for — so decoding the
        // whole manifest before checking the version would report a future
        // package as "damaged" instead of "update to open it". Read only the
        // one field the contract guarantees, and refuse on that.
        if let probe = try? decoder.decode(FormatVersionProbe.self, from: manifestData),
           probe.formatVersion > MurSessionManifest.currentFormatVersion {
            throw MurSessionError.unsupportedFormatVersion(probe.formatVersion)
        }

        // A manifest at OUR version that still won't decode is damage, not a
        // crash. X63-A deliberately ships no compatibility reader (nothing has
        // been released), so a package written before the multi-record layout
        // also lands here — with a message rather than a raw DecodingError.
        let manifest: MurSessionManifest
        do {
            manifest = try decoder.decode(MurSessionManifest.self, from: manifestData)
        } catch {
            throw MurSessionError.malformedPackage("its manifest could not be read")
        }
        // `records` is absent only on an encrypted manifest, and by here the
        // payload has been opened and `manifest` is the INNER one.
        guard let identities = manifest.records, !identities.isEmpty else {
            throw MurSessionError.noRecords
        }

        let fm = FileManager.default
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        guard let recordWrappers = children[recordsDir]?.fileWrappers else {
            throw MurSessionError.malformedPackage("it has no records")
        }

        var results: [RecordResult] = []
        for identity in identities {
            let key = identity.recordingID.uuidString
            guard let recordChildren = recordWrappers[key]?.fileWrappers else {
                throw MurSessionError.malformedPackage("a record listed in its manifest is missing")
            }
            let directory = workingDirectory.appendingPathComponent(key, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            results.append(
                try reconstitute(recordChildren, identity: identity, storage: manifest.sourceStorage, into: directory)
            )
        }

        return ReadResult(
            manifest: manifest,
            records: results,
            collectionJSON: children[sessionFile]?.regularFileContents,
            leadMapJSON: children[leadMapFile]?.regularFileContents
        )
    }

    /// Read only the encryption block from a manifest, without committing to
    /// the rest of its shape — an encrypted manifest deliberately omits fields
    /// the plaintext one requires.
    private static func encryptionParameters(
        from manifestData: Data
    ) throws -> MurSessionManifest.EncryptionParameters? {
        struct Probe: Decodable {
            let encryption: MurSessionManifest.EncryptionParameters?
        }
        return (try? JSONDecoder().decode(Probe.self, from: manifestData))?.encryption
    }

    /// Writes one record's subtree back out into `directory`.
    private static func reconstitute(
        _ children: [String: FileWrapper],
        identity: MurSessionManifest.SourceIdentity,
        storage: MurSessionManifest.SourceStorage,
        into directory: URL
    ) throws -> RecordResult {
        // source/ → record root, inflating per `sourceStorage`.
        if let source = children[sourceDir]?.fileWrappers {
            for (name, wrapper) in source {
                guard let stored = wrapper.regularFileContents else { continue }
                let data = storage == .lzfse ? try decompress(stored) : stored
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        }
        // Analyst sidecars → record root under their original filenames.
        for sidecar in analystSidecars {
            guard let data = children[sidecar.subdir]?.fileWrappers?[sidecar.file]?.regularFileContents
            else { continue }
            try data.write(to: directory.appendingPathComponent(sidecar.file), options: .atomic)
        }

        // cache/ → record cache dir, blobs verbatim (still stamped; the caller
        // validates each stamp on use and recomputes on a miss).
        let cacheDirectoryURL = directory.appendingPathComponent(cacheDir, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        if let cache = children[cacheDir]?.fileWrappers {
            for (key, wrapper) in cache {
                guard let blob = wrapper.regularFileContents else { continue }
                try blob.write(to: cacheDirectoryURL.appendingPathComponent(key), options: .atomic)
            }
        }

        return RecordResult(
            identity: identity,
            recordingDirectory: directory,
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
            // C6 / X32 (same seam): carry the absolute base ONLY when the
            // source genuinely had one. WFDB records without a base date/time
            // stay nil — never the synthetic import-time value.
            absoluteStartUnixMillis: recording.hasAbsoluteStartTime ? primary?.startTimeUnixMS : nil
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
