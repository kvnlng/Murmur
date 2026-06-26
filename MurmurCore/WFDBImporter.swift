//
//  WFDBImporter.swift
//  Murmur
//
//  Converts a PhysioNet WFDB record (.hea + .dat) into the internal Recording bundle:
//    <recordingID>/
//      recording.json              — manifest
//      channel_<label>.bin         — packed Float32 raw samples per signal
//      pyramid_<label>_L<n>.bin    — min/max pyramid files
//

import Foundation

enum WFDBImportError: LocalizedError {
    case noSignals
    case missingDatFile(URL)

    var errorDescription: String? {
        switch self {
        case .noSignals:
            return "The header describes no signals."
        case .missingDatFile(let url):
            return "Could not find sample file: \(url.lastPathComponent). It must be in the same folder as the .hea file."
        }
    }
}

enum WFDBImporter {

    /// Imports the WFDB record whose header lives at `heaURL`. The companion .dat file
    /// must be in the same directory. Writes the Recording bundle into a new UUID
    /// subdirectory of `outputDirectory` and returns a summary.
    ///
    /// All CPU work runs synchronously; callers should dispatch to a background task
    /// if calling from the main actor.
    static func importRecord(
        heaURL: URL,
        outputDirectory: URL,
        progress: ImportProgressHandler? = nil
    ) throws -> ImportSummary {
        let needsScope = heaURL.startAccessingSecurityScopedResource()
        defer { if needsScope { heaURL.stopAccessingSecurityScopedResource() } }

        let header = try WFDBHeaderParser.parse(url: heaURL)
        guard !header.signals.isEmpty else { throw WFDBImportError.noSignals }

        // Resolve the location of the first signal's .dat (acts as the
        // search-root hint for the multi-file decoder). Each distinct
        // filename referenced by `header.signals` is opened by the decoder.
        guard let firstFilename = header.signals.first?.filename else { throw WFDBImportError.noSignals }
        let heaDir = heaURL.deletingLastPathComponent()
        let firstDatURL = heaDir.appendingPathComponent(firstFilename)

        // Confirm every distinct sample-file referenced by the header exists
        // before we start decoding — fail fast with a clear missing-file
        // error instead of partway through.
        for filename in Set(header.signals.map(\.filename)) {
            let url = heaDir.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WFDBImportError.missingDatFile(url)
            }
        }

        let allSamples = try WFDBSampleDecoder.decode(datURL: firstDatURL, header: header)

        let startDate = header.startDate ?? Date()
        let startMS = Int64(startDate.timeIntervalSince1970 * 1000)

        let recordingID = UUID()
        let directory = outputDirectory.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var channels: [Channel] = []
        let totalSignals = header.signals.count
        var grandTotalSamples: Int64 = 0

        for (signalIdx, signal) in header.signals.enumerated() {
            let signalSamples = allSamples[signalIdx]
            let sampleCount = Int64(signalSamples.count)
            // Multi-frequency records carry a per-signal sample rate via
            // `samplesPerFrame`. For single-rate records this equals the
            // header's base rate.
            let signalSampleRate = header.sampleRate(for: signal)
            grandTotalSamples += sampleCount

            let storageFileName = "channel_\(safeFileName(signal.label)).bin"
            let storageURL = directory.appendingPathComponent(storageFileName)

            let channelHeader = BinaryRecordingHeader(
                version: BinaryRecordingHeader.currentVersion,
                startTimeUnixMS: startMS,
                sampleRateHz: signalSampleRate,
                sampleCount: sampleCount
            )
            try BinaryRecordingFile.write(samples: signalSamples, header: channelHeader, to: storageURL)

            let builder = try PyramidBuilder(
                channelName: signal.label,
                baseSampleRate: signalSampleRate,
                startTimeUnixMS: startMS,
                directory: directory
            )
            for value in signalSamples { try builder.append(Double(value)) }
            let pyramid = try builder.finalize()

            channels.append(Channel(
                id: UUID(),
                name: signal.label,
                unit: signal.unit,
                sampleRate: signalSampleRate,
                startTimeUnixMS: startMS,
                sampleCount: sampleCount,
                storageFileName: storageFileName,
                pyramid: pyramid
            ))

            // Report progress as fraction of signals processed.
            let done = Int64(signalIdx + 1)
            let total = Int64(totalSignals)
            progress?(ImportProgress(bytesRead: done, totalBytes: total))
        }

        // Annotations resolve unix-millis timestamps via the recording's
        // highest-rate channel — that's the ECG grid the producer (and the
        // analyst) think in. Low-rate trend channels share the same wall
        // clock but at much coarser granularity.
        let primarySampleRate = channels.map(\.sampleRate).max() ?? header.samplingFrequency
        let annotations = loadAnnotations(
            recordName: header.recordName,
            in: heaDir,
            recordingStartUnixMS: startMS,
            sampleRate: primarySampleRate
        )

        let notesFileName = copyNotesIntoBundle(
            recordName: header.recordName,
            sourceFolder: heaDir,
            bundleDirectory: directory
        )

        let recording = Recording(
            version: Recording.currentVersion,
            id: recordingID,
            device: header.recordName,
            createdAt: Date(),
            sourceFileName: heaURL.lastPathComponent,
            channels: channels,
            annotations: annotations,
            headerComments: header.comments,
            notesFileName: notesFileName
        )
        try writeManifest(recording, into: directory)
        // Write the bundle-side annotations sidecar. From here on, this file
        // (not the inline `annotations` in recording.json) is the source of
        // truth for the bundle's findings — RecordingStore.loadManifest
        // overrides recording.annotations with whatever's in this sidecar,
        // and the "Attach findings…" toolbar action rewrites this file when
        // the analyst attaches new findings. Re-running the producer can
        // therefore refresh findings without re-importing the .dat samples.
        try? BundleAnnotationsFile.write(annotations, to: directory)

        return ImportSummary(
            recording: recording,
            directory: directory,
            signalsImported: channels.count,
            totalSamples: grandTotalSamples
        )
    }

    // MARK: - Helpers

    private static func writeManifest(_ recording: Recording, into directory: URL) throws {
        let manifestURL = directory.appendingPathComponent("recording.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(recording).write(to: manifestURL, options: .atomic)
    }

    private static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : Character("_") }
            .reduce("") { "\($0)\($1)" }
    }

    /// Scans the record's folder for annotations from two sources, in order:
    ///   1. `<recordName>.annotations.json` — rich findings produced by the
    ///      upstream analysis cluster. This is the canonical path.
    ///   2. `<recordName>.atr` / `.qrs` — WFDB beat marks. Legacy / MIT-BIH
    ///      compatibility path; mapped through the WFDB adapter to point events.
    ///
    /// Both sources can coexist — their annotation lists are concatenated. Any
    /// failure to parse a source is silently ignored: annotations are optional
    /// metadata, never a reason to fail the import.
    private static func loadAnnotations(
        recordName: String,
        in folder: URL,
        recordingStartUnixMS: Int64,
        sampleRate: Double
    ) -> [Annotation] {
        var collected: [Annotation] = []

        // 1. Primary: JSON findings file
        let jsonURL = folder.appendingPathComponent("\(recordName).annotations.json")
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            if let parsed = try? AnnotationLoader.load(
                url: jsonURL,
                recordingStartUnixMS: recordingStartUnixMS,
                sampleRate: sampleRate,
                fallbackSource: recordName
            ) {
                collected.append(contentsOf: parsed)
            }
        }

        // 2. Legacy: WFDB binary annotations
        for ext in ["atr", "qrs"] {
            let url = folder.appendingPathComponent("\(recordName).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let parsed = try? WFDBAnnotationParser.parse(url: url), !parsed.isEmpty {
                collected.append(contentsOf: parsed.map(Annotation.init(fromWFDB:)))
                break
            }
        }

        return collected
    }

    /// If `<recordName>.notes.md` exists in the source folder, copy it into the
    /// recording bundle as `notes.md`. Returns the bundle-relative filename
    /// (or nil when no notes file exists). The analyst-editable copy then
    /// lives entirely inside the bundle — edits never touch the source folder.
    private static func copyNotesIntoBundle(
        recordName: String,
        sourceFolder: URL,
        bundleDirectory: URL
    ) -> String? {
        let sourceURL = sourceFolder.appendingPathComponent("\(recordName).notes.md")
        let bundleNotesName = "notes.md"
        let destURL = bundleDirectory.appendingPathComponent(bundleNotesName)

        if FileManager.default.fileExists(atPath: sourceURL.path) {
            if let data = try? Data(contentsOf: sourceURL) {
                try? data.write(to: destURL, options: .atomic)
                return bundleNotesName
            }
        }
        // No source-folder notes; reserve the filename anyway so the editor has
        // a stable place to write to when the analyst starts taking notes.
        return bundleNotesName
    }
}
