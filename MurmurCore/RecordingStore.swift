//
//  RecordingStore.swift
//  Murmur
//
//  Owns the on-disk layout for imported Recordings. Each Recording occupies a
//  subdirectory of Application Support / Murmur / recordings / <uuid> /, which
//  contains:
//      recording.json          — manifest
//      channel_<label>.bin     — packed Float32 samples per signal
//      pyramid_<label>_L*.bin  — min/max pyramid level files
//
//  The source .hea/.dat files are left untouched; the store only owns the binary
//  working files it generates from them.
//

import Foundation

@MainActor
final class RecordingStore {
    static let shared = RecordingStore()

    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            if let appSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ) {
                Self.migrateLegacyAppSupportIfNeeded(parent: appSupport, fileManager: fileManager)
            }
            self.rootURL = Self.defaultRootURL(fileManager: fileManager)
        }
        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    /// The default bundles root — Application Support / Murmur / recordings,
    /// with the same tmp fallback `init` has always had. Split out and
    /// `nonisolated` so the launch-time bundle sweeper can resolve the same
    /// path without touching the store (or the main actor). Does NOT run the
    /// legacy migration — that stays an init concern; a sweep before
    /// migration finds an empty root and does nothing, which is correct.
    nonisolated static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let parent = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return parent
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }

    /// First-launch rename: if the user has data under the old `Plotting/`
    /// Application Support directory but nothing under `Murmur/` yet, move
    /// the whole subtree across so existing recordings keep working.
    private static func migrateLegacyAppSupportIfNeeded(parent: URL, fileManager: FileManager) {
        let legacyRoot = parent.appendingPathComponent("Plotting", isDirectory: true)
        let newRoot = parent.appendingPathComponent("Murmur", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyRoot.path),
              !fileManager.fileExists(atPath: newRoot.path) else { return }
        try? fileManager.moveItem(at: legacyRoot, to: newRoot)
    }

    var recordingsDirectory: URL { rootURL }

    /// Imports a WFDB record asynchronously. `folderURL` must be a security-scoped
    /// URL from a folder picker; opening its scope on the worker thread grants the
    /// import access to both the .hea and its sibling .dat file. Heavy work runs
    /// off the main actor.
    func importWFDB(
        folderURL: URL,
        heaFilename: String,
        progress: ImportProgressHandler? = nil
    ) async throws -> ImportSummary {
        let outputDir = rootURL
        return try await Task.detached(priority: .userInitiated) {
            let needsScope = folderURL.startAccessingSecurityScopedResource()
            defer { if needsScope { folderURL.stopAccessingSecurityScopedResource() } }

            let heaURL = folderURL.appendingPathComponent(heaFilename)

            // Reuse before import: an existing bundle whose source
            // fingerprint matches is the same record already decoded —
            // serving it skips the packed-sample decode and pyramid build,
            // keeps `Recording.id` stable across opens (what per-bundle
            // derived caches key on), and stops the abandoned-bundle leak
            // that reached 16 GB before this landed. Any failure on this
            // path falls through to a fresh import; reuse is an
            // optimisation, never a correctness gate.
            if let fingerprint = try? SourceFingerprint.compute(heaURL: heaURL),
               let reused = Self.reusableSummary(matching: fingerprint, in: outputDir) {
                return reused
            }

            let summary = try WFDBImporter.importRecord(
                heaURL: heaURL,
                outputDirectory: outputDir,
                progress: progress
            )
            // Stamp AFTER the import succeeds — a bundle only becomes
            // reusable once it is known complete. Failure to stamp is not
            // failure to import; the bundle simply won't be reused. The
            // index entry rides with the stamp (#341): entry and fingerprint
            // stay in step because they are written from the same value at
            // the same moment.
            if let fingerprint = try? SourceFingerprint.compute(heaURL: heaURL) {
                try? fingerprint.write(to: summary.directory)
                Self.writeIndexEntry(for: fingerprint, bundleName: summary.directory.lastPathComponent, in: outputDir)
            }
            return summary
        }.value
    }

    /// Find a bundle stamped with `fingerprint` whose manifest still loads.
    /// `nonisolated` — runs inside the detached import task.
    ///
    /// #341: the linear bundle scan this used to be was sized against ~1,000
    /// bundles (milliseconds); a corpus navigator (#329) grows the population
    /// to tens of thousands, where the measured per-click cost is ~550 ms at
    /// 20k and ~1.3 s at 45k — paid on EVERY import, and in full whenever the
    /// record is a fresh one. Lookups now go through a fingerprint index:
    /// one tiny file per fingerprint digest under `.fingerprints/`, O(1)
    /// regardless of population.
    ///
    /// The index stays a CACHE, never a source of truth:
    ///   - every hit is validated by re-reading the named bundle's own
    ///     fingerprint file AND re-loading its manifest — the existing
    ///     gutted-bundle guard (a fingerprint that outlived its
    ///     recording.json must not be served, whatever an index says);
    ///   - a stale entry is deleted and the lookup falls back to the full
    ///     linear scan, which re-indexes anything it finds;
    ///   - a store from before the index existed is migrated by one linear
    ///     pass (the same cost as a single pre-#341 click), after which the
    ///     `complete` marker lets a definite miss return without scanning.
    /// Any failure anywhere on this path falls through to a fresh import —
    /// reuse remains an optimisation, never a correctness gate.
    private nonisolated static func reusableSummary(
        matching fingerprint: SourceFingerprint,
        in root: URL
    ) -> ImportSummary? {
        let indexDir = indexDirectory(in: root)
        let digest = fingerprint.stableDigest
        guard !digest.isEmpty else { return linearScan(matching: fingerprint, in: root) }

        let marker = indexDir.appendingPathComponent(indexCompleteMarker)
        guard FileManager.default.fileExists(atPath: marker.path) else {
            // Pre-index store (or an interrupted migration): one linear pass
            // builds the whole index, answering this click along the way.
            return migrateIndexAndScan(matching: fingerprint, digest: digest, in: root)
        }

        let entryURL = indexDir.appendingPathComponent(digest)
        guard let bundleName = try? String(contentsOf: entryURL, encoding: .utf8) else {
            // No entry in a complete index: genuinely new source. This is the
            // corpus-browsing common case, and the whole point — no scan.
            return nil
        }
        if let summary = validatedSummary(bundleName: bundleName, matching: fingerprint, in: root) {
            return summary
        }
        // Stale entry (bundle deleted, gutted, or re-stamped): drop it and
        // fall back to the scan, which re-indexes a live match if one exists.
        try? FileManager.default.removeItem(at: entryURL)
        if let rescued = linearScan(matching: fingerprint, in: root) {
            writeIndexEntry(for: fingerprint, bundleName: rescued.directory.lastPathComponent, in: root)
            return rescued
        }
        return nil
    }

    /// The pre-#341 behaviour, verbatim: read every bundle's fingerprint
    /// until one matches and its manifest loads. Kept as the fallback every
    /// index miss-trust failure degrades to.
    private nonisolated static func linearScan(
        matching fingerprint: SourceFingerprint,
        in root: URL
    ) -> ImportSummary? {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        for child in children {
            // Rebuild from the caller's root rather than returning the
            // enumerated URL: contentsOfDirectory resolves /var -> /private/var,
            // and the fresh-import path returns root-relative URLs — the two
            // spellings must not differ by which path produced the bundle.
            let bundleDir = root.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            guard SourceFingerprint.read(from: bundleDir) == fingerprint else { continue }
            guard let recording = try? Self.loadManifestForReuse(at: bundleDir) else { continue }
            return ImportSummary(
                recording: recording,
                directory: bundleDir,
                signalsImported: recording.channels.count,
                totalSamples: recording.channels.reduce(0) { $0 + $1.sampleCount }
            )
        }
        return nil
    }

    /// One pass over the bundles that both answers `fingerprint` and writes
    /// an index entry for every stamped bundle it walks, finishing with the
    /// `complete` marker. Interruption is safe: without the marker the next
    /// import simply migrates again, and entry writes are idempotent.
    private nonisolated static func migrateIndexAndScan(
        matching fingerprint: SourceFingerprint,
        digest: String,
        in root: URL
    ) -> ImportSummary? {
        let fm = FileManager.default
        let indexDir = indexDirectory(in: root)
        try? fm.createDirectory(at: indexDir, withIntermediateDirectories: true)
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        var match: ImportSummary?
        for child in children {
            let bundleDir = root.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            guard let stamped = SourceFingerprint.read(from: bundleDir) else { continue }
            writeIndexEntry(for: stamped, bundleName: bundleDir.lastPathComponent, in: root)
            // Validate in-loop, exactly like the linear scan: a gutted match
            // is skipped and a later intact duplicate can still serve.
            if match == nil, stamped == fingerprint,
               let recording = try? Self.loadManifestForReuse(at: bundleDir) {
                match = ImportSummary(
                    recording: recording,
                    directory: bundleDir,
                    signalsImported: recording.channels.count,
                    totalSamples: recording.channels.reduce(0) { $0 + $1.sampleCount }
                )
            }
        }
        try? Data().write(to: indexDir.appendingPathComponent(indexCompleteMarker))
        return match
    }

    /// The full index-hit validation: the named bundle must still carry an
    /// EQUAL fingerprint (the digest is only a filename; equality is the
    /// contract) and its manifest must still load (the gutted-bundle guard).
    private nonisolated static func validatedSummary(
        bundleName: String,
        matching fingerprint: SourceFingerprint,
        in root: URL
    ) -> ImportSummary? {
        let bundleDir = root.appendingPathComponent(bundleName, isDirectory: true)
        guard SourceFingerprint.read(from: bundleDir) == fingerprint,
              let recording = try? Self.loadManifestForReuse(at: bundleDir) else { return nil }
        return ImportSummary(
            recording: recording,
            directory: bundleDir,
            signalsImported: recording.channels.count,
            totalSamples: recording.channels.reduce(0) { $0 + $1.sampleCount }
        )
    }

    /// `.fingerprints/` under the store root — hidden, so the bundle scans
    /// (`skipsHiddenFiles` here, in `listRecordingDirectories`, and in the
    /// launch sweeper) never mistake it for a recording bundle.
    private nonisolated static func indexDirectory(in root: URL) -> URL {
        root.appendingPathComponent(".fingerprints", isDirectory: true)
    }

    private nonisolated static let indexCompleteMarker = "complete"

    /// Upsert one digest → bundle-name entry. Best-effort by design: a
    /// missing entry only costs a scan (pre-marker) or a duplicate import
    /// (post-marker) — never a wrong bundle, because hits are validated.
    private nonisolated static func writeIndexEntry(
        for fingerprint: SourceFingerprint,
        bundleName: String,
        in root: URL
    ) {
        let digest = fingerprint.stableDigest
        guard !digest.isEmpty else { return }
        let indexDir = indexDirectory(in: root)
        try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
        try? Data(bundleName.utf8).write(
            to: indexDir.appendingPathComponent(digest), options: .atomic)
    }

    /// The manifest+sidecar load, minus the main-actor isolation of
    /// `loadManifest` — same semantics, callable from the import task.
    private nonisolated static func loadManifestForReuse(at directory: URL) throws -> Recording {
        let manifestURL = directory.appendingPathComponent("recording.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(Recording.self, from: data)
        guard let sidecar = BundleAnnotationsFile.read(from: directory) else {
            return recording
        }
        return Recording(
            version: recording.version,
            id: recording.id,
            device: recording.device,
            createdAt: recording.createdAt,
            sourceFileName: recording.sourceFileName,
            channels: recording.channels,
            annotations: sidecar,
            headerComments: recording.headerComments,
            notesFileName: recording.notesFileName,
            hasAbsoluteStartTime: recording.hasAbsoluteStartTime
        )
    }

    /// Loads the manifest from a recording directory. If a sibling
    /// `annotations.json` sidecar exists, its findings override the manifest's
    /// inline annotations — that's how the "Attach findings…" action and the
    /// importer keep findings in sync with what's actually on disk without
    /// rewriting the (much heavier) recording.json manifest.
    func loadManifest(at directory: URL) throws -> Recording {
        let manifestURL = directory.appendingPathComponent("recording.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(Recording.self, from: data)

        guard let sidecar = BundleAnnotationsFile.read(from: directory) else {
            return recording
        }
        return Recording(
            version: recording.version,
            id: recording.id,
            device: recording.device,
            createdAt: recording.createdAt,
            sourceFileName: recording.sourceFileName,
            channels: recording.channels,
            annotations: sidecar,
            headerComments: recording.headerComments,
            notesFileName: recording.notesFileName,
            // X16 incidental fix: this rebuild silently dropped the X32 flag,
            // so a sidecar-carrying record lost its absolute time base on load.
            hasAbsoluteStartTime: recording.hasAbsoluteStartTime
        )
    }

    /// X16 — persist a mutated manifest back to the bundle. Same encoder
    /// settings as the importer's write, so a rewrite is diff-stable against
    /// the original. The one sanctioned post-import manifest mutation is the
    /// analyst's per-channel gain reinterpretation; annotations keep flowing
    /// through their sidecar, never through this.
    ///
    /// NOTE: `loadManifest` overrides inline annotations with the sidecar
    /// when one exists — encode the recording as loaded and the sidecar
    /// simply wins again on the next load, so no annotation state is lost.
    func writeManifest(_ recording: Recording, at directory: URL) throws {
        let manifestURL = directory.appendingPathComponent("recording.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(recording).write(to: manifestURL, options: .atomic)
    }

    /// Lists every recording directory currently in the store.
    func listRecordingDirectories() throws -> [URL] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// Removes a recording directory from the store.
    func remove(at directory: URL) throws {
        try fileManager.removeItem(at: directory)
    }
}
