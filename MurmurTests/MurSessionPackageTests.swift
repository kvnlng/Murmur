//
//  MurSessionPackageTests.swift
//  MurmurTests
//
//  Phase-A acceptance for the native `.mur` save format: round-trip (session
//  parts survive), portability (the package reopens with the original bundle
//  gone), and newer-format refusal (never a silent misread).
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("MurSessionPackage — .mur save/open")
struct MurSessionPackageTests {

    private func tempDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mur-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A minimal recording bundle: manifest + one channel binary + two analyst
    /// sidecars. Returns the directory, the recording, and the exact bytes
    /// written (for byte-equality assertions).
    private func makeBundle() throws -> (dir: URL, recording: Recording, files: [String: Data]) {
        let dir = try tempDir("bundle")
        let channel = Channel(name: "II", unit: "mV", sampleRate: 250,
                              startTimeUnixMS: 0, sampleCount: 8, storageFileName: "ch0.bin")
        let recording = Recording(version: 1, id: UUID(), device: "unit-test",
                                  createdAt: Date(timeIntervalSince1970: 1000),
                                  sourceFileName: "rec.hea", channels: [channel])
        var files: [String: Data] = [:]
        files["recording.json"] = try JSONEncoder().encode(recording)
        files["ch0.bin"] = Data([1, 2, 3, 4, 5, 6, 7, 8])
        files["annotations.json"] = Data(#"{"schemaVersion":1,"annotations":[]}"#.utf8)
        files["candidate-dispositions.json"] = Data(#"{"schemaVersion":1,"dispositions":[]}"#.utf8)
        for (name, data) in files {
            try data.write(to: dir.appendingPathComponent(name))
        }
        return (dir, recording, files)
    }

    @Test("Round-trips source, analyst sidecars, provenance, and session")
    func roundTrip() throws {
        let (dir, recording, files) = try makeBundle()
        let pkg = try tempDir("pkg").appendingPathComponent("Session.mur")
        let provenance = Data(#"{"modelIdentifier":"vtvf_seres_lstm"}"#.utf8)
        let session = Data(#"{"viewportStart":0}"#.utf8)

        let manifest = try MurSessionPackage.write(
            recording: recording, recordingDirectory: dir,
            provenanceJSON: provenance, sessionJSON: session, to: pkg
        )
        #expect(manifest.formatVersion == MurSessionManifest.currentFormatVersion)
        #expect(manifest.sourceStorage == .lzfse)
        #expect(manifest.source.recordingID == recording.id)
        #expect(manifest.source.channelCount == 1)

        let out = try tempDir("open")
        let result = try MurSessionPackage.read(packageURL: pkg, into: out)
        for (name, data) in files {
            let readBack = try Data(contentsOf: out.appendingPathComponent(name))
            #expect(readBack == data, "\(name) should round-trip byte-identically")
        }
        #expect(result.provenanceJSON == provenance)
        #expect(result.sessionJSON == session)
    }

    /// X11/X59: the bedside view republishes on every viewport change. If that
    /// republish replaced the whole state, it would wipe the scan dials the
    /// scan sheet owns — the operating point would silently reset the moment
    /// the analyst panned. Only the view-owned fields may move.
    @Test("Republishing view state preserves the fields other surfaces own")
    func viewRepublishPreservesScanDials() {
        let live = MurSessionState(
            viewportStartSample: 0, viewportEndSample: 100,
            focusedChannelName: "V1", windowLockedTo10s: false,
            tau: 0.42, minDurationSeconds: 7, mergeGapSeconds: 9,
            scanScopeWholeRecording: true
        )
        // What the bedside view knows about: viewport / lead / lock only.
        let fromView = MurSessionState(
            viewportStartSample: 500, viewportEndSample: 900,
            focusedChannelName: "MLII", windowLockedTo10s: true
        )

        let merged = live.replacingViewState(with: fromView)

        // View-owned fields move...
        #expect(merged.viewportStartSample == 500)
        #expect(merged.viewportEndSample == 900)
        #expect(merged.focusedChannelName == "MLII")
        #expect(merged.windowLockedTo10s == true)
        // ...and the scan dials survive untouched.
        #expect(merged.tau == 0.42)
        #expect(merged.minDurationSeconds == 7)
        #expect(merged.mergeGapSeconds == 9)
        #expect(merged.scanScopeWholeRecording == true)
    }

    /// X50(b): the saved paper round-trips, and — the part that matters — a
    /// session saved WITHOUT a resolved gain reads back nil, so the open falls
    /// back to Standard View exactly as a raw import does (X50(a) preserved).
    @Test("Saved paper round-trips; absent paper stays absent")
    func calibrationRoundTripsAndAbsenceIsPreserved() throws {
        let (dir, recording, _) = try makeBundle()

        let withPaper = MurSessionState(
            viewportStartSample: 0, viewportEndSample: 2_500,
            gainMillimetersPerMillivolt: 20      // deliberately NOT standard 10
        )
        let pkgA = try tempDir("pkg-paper").appendingPathComponent("Paper.mur")
        _ = try MurSessionPackage.write(
            recording: recording, recordingDirectory: dir,
            sessionJSON: try JSONEncoder().encode(withPaper), to: pkgA
        )
        let a = try MurSessionPackage.read(packageURL: pkgA, into: try tempDir("open-paper"))
        let restoredA = try JSONDecoder().decode(
            MurSessionState.self, from: #require(a.sessionJSON)
        )
        #expect(restoredA.gainMillimetersPerMillivolt == 20)

        // A session captured before any gain resolved carries no paper.
        let noPaper = MurSessionState(viewportStartSample: 0, viewportEndSample: 2_500)
        let pkgB = try tempDir("pkg-nopaper").appendingPathComponent("NoPaper.mur")
        _ = try MurSessionPackage.write(
            recording: recording, recordingDirectory: dir,
            sessionJSON: try JSONEncoder().encode(noPaper), to: pkgB
        )
        let b = try MurSessionPackage.read(packageURL: pkgB, into: try tempDir("open-nopaper"))
        let restoredB = try JSONDecoder().decode(
            MurSessionState.self, from: #require(b.sessionJSON)
        )
        #expect(restoredB.gainMillimetersPerMillivolt == nil,
                "no saved paper must stay absent — the open falls back to Standard View")
    }

    /// X26: the template's provenance — its population, lead, span and formula
    /// — survives the round trip, so a saved measurement stays auditable if the
    /// delineator or the formula default moves in a later version.
    @Test("Template provenance round-trips through provenance.json")
    func templateProvenanceRoundTrips() throws {
        let (dir, recording, _) = try makeBundle()
        let pkg = try tempDir("pkg-prov").appendingPathComponent("Prov.mur")
        let provenance = MurProvenance(normalTemplate: .init(
            beatCount: 1_859,
            excludedBeatCount: 2,
            sourceLead: "MLII",
            spanStartSample: 180,
            spanEndSample: 649_872,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 428.4
        ))

        _ = try MurSessionPackage.write(
            recording: recording, recordingDirectory: dir,
            provenanceJSON: try JSONEncoder().encode(provenance), to: pkg
        )

        let result = try MurSessionPackage.read(
            packageURL: pkg, into: try tempDir("open-prov")
        )
        let restored = try JSONDecoder().decode(
            MurProvenance.self, from: #require(result.provenanceJSON)
        )
        #expect(restored == provenance)
        // The population statement is the point — each part must survive.
        #expect(restored.normalTemplate?.beatCount == 1_859)
        #expect(restored.normalTemplate?.excludedBeatCount == 2)
        #expect(restored.normalTemplate?.sourceLead == "MLII")
        #expect(restored.normalTemplate?.qtcFormulaName == "Fridericia")
    }

    /// X26: no template means no provenance. A zero-beat template would read as
    /// "we measured nothing" rather than "we never measured" — the
    /// absent-not-zero rule (X48 §4c).
    @Test("No template yields no provenance, never a zero-beat one")
    func absentTemplateYieldsNoProvenance() {
        #expect(MurProvenance.NormalTemplate(nil) == nil)
    }

    /// X59 backward compatibility: a package written before session capture
    /// existed carries no `session.json`. Absent must stay ABSENT — the open
    /// path must never fabricate a default viewport for an older `.mur`.
    @Test("A package with no session state reads back nil, never a default")
    func absentSessionStateStaysAbsent() throws {
        let (dir, recording, _) = try makeBundle()
        let pkg = try tempDir("pkg-nostate").appendingPathComponent("Legacy.mur")

        _ = try MurSessionPackage.write(
            recording: recording, recordingDirectory: dir, to: pkg
        )

        let result = try MurSessionPackage.read(
            packageURL: pkg, into: try tempDir("open-nostate")
        )
        #expect(result.sessionJSON == nil)
    }

    @Test("Portable: reopens after the original bundle is deleted")
    func portability() throws {
        let (dir, recording, files) = try makeBundle()
        let pkg = try tempDir("pkg").appendingPathComponent("Session.mur")
        try MurSessionPackage.write(recording: recording, recordingDirectory: dir, to: pkg)

        // The source is embedded, so the original bundle is no longer needed.
        try FileManager.default.removeItem(at: dir)

        let out = try tempDir("open")
        _ = try MurSessionPackage.read(packageURL: pkg, into: out)
        for name in ["recording.json", "ch0.bin"] {
            let readBack = try Data(contentsOf: out.appendingPathComponent(name))
            #expect(readBack == files[name])
        }
    }

    @Test("Embedded source is LZFSE-compressed on disk yet round-trips exactly")
    func sourceIsCompressed() throws {
        let (dir, recording, files) = try makeBundle()
        let pkg = try tempDir("pkg").appendingPathComponent("Session.mur")
        try MurSessionPackage.write(recording: recording, recordingDirectory: dir, to: pkg)

        // The stored source blob is the compressed form, not the raw bytes.
        let storedChannel = try Data(contentsOf: pkg.appendingPathComponent("source/ch0.bin"))
        let rawChannel = try #require(files["ch0.bin"])
        let inflated = try MurSessionPackage.decompress(storedChannel)
        #expect(inflated == rawChannel)

        // And a full open reconstitutes the raw bytes.
        let out = try tempDir("open")
        _ = try MurSessionPackage.read(packageURL: pkg, into: out)
        #expect(try Data(contentsOf: out.appendingPathComponent("ch0.bin")) == rawChannel)
    }

    @Test("Session state round-trips through the package's session.json slot")
    func sessionStateRoundTrips() throws {
        let (dir, recording, _) = try makeBundle()
        let pkg = try tempDir("pkg").appendingPathComponent("Session.mur")
        let state = MurSessionState(
            viewportStartSample: 500, viewportEndSample: 3000,
            focusedChannelName: "II", windowLockedTo10s: true,
            selectedTrendMetric: "QTc", selectedBinPreset: "twoMinutes",
            tau: 0.87, minDurationSeconds: 4, mergeGapSeconds: 5,
            scanScopeWholeRecording: true
        )
        let sessionJSON = try JSONEncoder().encode(state)
        try MurSessionPackage.write(recording: recording, recordingDirectory: dir,
                                    sessionJSON: sessionJSON, to: pkg)

        let out = try tempDir("open")
        let result = try MurSessionPackage.read(packageURL: pkg, into: out)
        let decoded = try JSONDecoder().decode(MurSessionState.self, from: #require(result.sessionJSON))
        #expect(decoded == state)
    }

    @Test("Cache blobs restore and honor the stamp discipline through the package")
    func cacheRoundTripAndInvalidation() throws {
        let (dir, recording, _) = try makeBundle()
        let pkg = try tempDir("pkg").appendingPathComponent("Session.mur")
        let stamp = CacheStamp(producer: "delineator", version: "v2", parametersKey: "qtc=fridericia")
        let payload = Data([0xAA, 0xBB, 0xCC])
        let blob = try MurSessionCache.encode(stamp: stamp, payload: payload)

        try MurSessionPackage.write(recording: recording, recordingDirectory: dir,
                                    cacheBlobs: ["fiducials.blob": blob], to: pkg)

        let out = try tempDir("open")
        let result = try MurSessionPackage.read(packageURL: pkg, into: out)
        let restored = try Data(contentsOf: result.cacheDirectory.appendingPathComponent("fiducials.blob"))
        // Same app stamp → cache hit.
        #expect(MurSessionCache.decode(restored, expected: stamp) == payload)
        // Newer delineator → cache miss → recompute.
        let newer = CacheStamp(producer: "delineator", version: "v3", parametersKey: "qtc=fridericia")
        #expect(MurSessionCache.decode(restored, expected: newer) == nil)
    }

    @Test("Refuses a newer format version rather than misreading it")
    func refusesNewerVersion() throws {
        // Hand-build a package whose manifest claims a future format.
        let pkg = try tempDir("pkg").appendingPathComponent("Future.mur")
        let future = """
        {"formatVersion": 999, "appVersion": "x", "createdAt": "2026-07-28T00:00:00Z",
         "modifiedAt": "2026-07-28T00:00:00Z", "sourceStorage": "none", "contents": [],
         "source": {"recordingID": "\(UUID().uuidString)", "sourceFileName": "r",
         "sampleRate": 250, "channelCount": 1, "sampleCount": 8}}
        """
        let root = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: Data(future.utf8))
        ])
        try root.write(to: pkg, options: .atomic, originalContentsURL: nil)

        #expect(throws: MurSessionError.unsupportedFormatVersion(999)) {
            _ = try MurSessionPackage.read(packageURL: pkg, into: try tempDir("open"))
        }
    }

    @Test("Absent analyst sidecars are simply omitted, not errors")
    func omitsMissingSidecars() throws {
        let dir = try tempDir("bare")
        let channel = Channel(name: "II", unit: "mV", sampleRate: 250,
                              startTimeUnixMS: 0, sampleCount: 4, storageFileName: "ch0.bin")
        let recording = Recording(version: 1, id: UUID(), device: "t",
                                  createdAt: .init(timeIntervalSince1970: 0),
                                  sourceFileName: "r.hea", channels: [channel])
        try JSONEncoder().encode(recording).write(to: dir.appendingPathComponent("recording.json"))
        try Data([9, 9]).write(to: dir.appendingPathComponent("ch0.bin"))

        let pkg = try tempDir("pkg").appendingPathComponent("Bare.mur")
        try MurSessionPackage.write(recording: recording, recordingDirectory: dir, to: pkg)
        let out = try tempDir("open")
        _ = try MurSessionPackage.read(packageURL: pkg, into: out)
        #expect(try Data(contentsOf: out.appendingPathComponent("ch0.bin")) == Data([9, 9]))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("annotations.json").path))
    }
}
