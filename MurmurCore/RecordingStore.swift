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
            return try WFDBImporter.importRecord(
                heaURL: heaURL,
                outputDirectory: outputDir,
                progress: progress
            )
        }.value
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
            notesFileName: recording.notesFileName
        )
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
