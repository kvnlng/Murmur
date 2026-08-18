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
            do {
                let appSupport = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                Self.migrateLegacyAppSupportIfNeeded(parent: appSupport, fileManager: fileManager)
                self.rootURL = appSupport
                    .appendingPathComponent("Murmur", isDirectory: true)
                    .appendingPathComponent("recordings", isDirectory: true)
            } catch {
                self.rootURL = fileManager.temporaryDirectory
                    .appendingPathComponent("Murmur", isDirectory: true)
                    .appendingPathComponent("recordings", isDirectory: true)
            }
        }
        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
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
            // failure to import; the bundle simply won't be reused.
            if let fingerprint = try? SourceFingerprint.compute(heaURL: heaURL) {
                try? fingerprint.write(to: summary.directory)
            }
            return summary
        }.value
    }

    /// Scan `root` for a bundle stamped with `fingerprint` whose manifest
    /// still loads. `nonisolated` — runs inside the detached import task.
    ///
    /// The scan reads one small JSON per bundle; against the observed
    /// worst-case population (~1,000 bundles) that is milliseconds, and it
    /// buys out a multi-minute decode. The manifest re-load is the
    /// gutted-bundle guard: a fingerprint file that outlived its
    /// recording.json must not be served.
    private nonisolated static func reusableSummary(
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
