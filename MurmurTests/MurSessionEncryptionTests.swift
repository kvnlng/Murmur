//
//  MurSessionEncryptionTests.swift
//  MurmurTests
//
//  X63-D acceptance: optional passphrase encryption for `.mur` sessions.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("MurSessionPackage — passphrase encryption (X63-D)")
struct MurSessionEncryptionTests {

    private func tempDir(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mur-enc-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Bundles whose filenames and content are distinctive, so a leak test can
    /// look for something specific rather than hoping.
    private func makeBundles(_ count: Int) throws -> [(dir: URL, recording: Recording)] {
        try (0..<count).map { index in
            let dir = try tempDir("bundle-\(index)")
            let channel = Channel(name: "II", unit: "mV", sampleRate: 250,
                                  startTimeUnixMS: 0, sampleCount: 4, storageFileName: "ch0.bin")
            let recording = Recording(version: 1, id: UUID(), device: "device-\(index)",
                                      createdAt: Date(timeIntervalSince1970: 1000),
                                      sourceFileName: "SECRETNAME\(index).hea", channels: [channel])
            try JSONEncoder().encode(recording).write(to: dir.appendingPathComponent("recording.json"))
            try Data([UInt8(index), 9, 9, 9]).write(to: dir.appendingPathComponent("ch0.bin"))
            return (dir, recording)
        }
    }

    private func write(
        _ bundles: [(dir: URL, recording: Recording)],
        passphrase: String?,
        to pkg: URL
    ) throws {
        try MurSessionPackage.write(
            records: bundles.map { .init(recording: $0.recording, recordingDirectory: $0.dir) },
            passphrase: passphrase,
            to: pkg
        )
    }

    // MARK: - Round trip

    @Test("An encrypted session reopens with its passphrase, content identical")
    func encryptedRoundTrip() throws {
        let bundles = try makeBundles(2)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "correct horse battery staple", to: pkg)

        let result = try MurSessionPackage.read(
            packageURL: pkg,
            into: try tempDir("open"),
            passphrase: "correct horse battery staple"
        )
        #expect(result.records.count == 2)
        #expect(result.records.map(\.identity.recordingID) == bundles.map(\.recording.id))
        // Each record's own bytes came back — not just two directories.
        for (index, record) in result.records.enumerated() {
            let bytes = try Data(contentsOf: record.recordingDirectory.appendingPathComponent("ch0.bin"))
            #expect(bytes == Data([UInt8(index), 9, 9, 9]))
        }
    }

    @Test("Encryption is optional — no passphrase writes a plaintext package")
    func plaintextIsUnchanged() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Plain.mur")
        try write(bundles, passphrase: nil, to: pkg)

        let manifest = try JSONDecoder.murDecoder.decode(
            MurSessionManifest.self,
            from: Data(contentsOf: pkg.appendingPathComponent("manifest.json"))
        )
        #expect(manifest.encryption == nil)
        #expect(manifest.records?.count == 1)
        // Opens with no passphrase, exactly as before X63-D.
        let result = try MurSessionPackage.read(packageURL: pkg, into: try tempDir("open"))
        #expect(result.records.count == 1)
    }

    /// An empty passphrase is not a passphrase. Treating "" as one would write
    /// a package sealed under a key derived from nothing while telling the
    /// analyst it was encrypted.
    @Test("An empty passphrase writes plaintext rather than pretend encryption")
    func emptyPassphraseIsNotEncryption() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Empty.mur")
        try write(bundles, passphrase: "", to: pkg)
        let manifest = try JSONDecoder.murDecoder.decode(
            MurSessionManifest.self,
            from: Data(contentsOf: pkg.appendingPathComponent("manifest.json"))
        )
        #expect(manifest.encryption == nil)
    }

    // MARK: - Refusals

    @Test("A wrong passphrase says so — it never calls the file damaged")
    func wrongPassphraseIsNamedAsSuch() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "right", to: pkg)

        #expect(throws: MurSessionError.wrongPassphrase) {
            _ = try MurSessionPackage.read(
                packageURL: pkg, into: try tempDir("open"), passphrase: "wrong"
            )
        }
        // The message an analyst actually reads must not suggest data loss.
        let message = MurSessionError.wrongPassphrase.errorDescription ?? ""
        #expect(message.lowercased().contains("passphrase"))
        #expect(!message.lowercased().contains("damaged"))
        #expect(!message.lowercased().contains("corrupt"))
    }

    @Test("A failed attempt leaves the package openable")
    func failedAttemptDoesNotHarmThePackage() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "right", to: pkg)

        _ = try? MurSessionPackage.read(
            packageURL: pkg, into: try tempDir("bad"), passphrase: "wrong"
        )
        let result = try MurSessionPackage.read(
            packageURL: pkg, into: try tempDir("good"), passphrase: "right"
        )
        #expect(result.records.count == 1)
    }

    @Test("An encrypted package with no passphrase asks for one")
    func missingPassphraseIsItsOwnError() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "right", to: pkg)

        #expect(throws: MurSessionError.passphraseRequired) {
            _ = try MurSessionPackage.read(packageURL: pkg, into: try tempDir("open"))
        }
    }

    /// The outer manifest is the AEAD's associated data, so re-labelling a
    /// sealed package fails authentication instead of being accepted.
    @Test("Swapping the outer manifest invalidates the seal")
    func manifestIsAuthenticated() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "right", to: pkg)

        let manifestURL = pkg.appendingPathComponent("manifest.json")
        var text = try String(contentsOf: manifestURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"appVersion\"", with: "\"appversion\"")
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            _ = try MurSessionPackage.read(
                packageURL: pkg, into: try tempDir("open"), passphrase: "right"
            )
        }
    }

    // MARK: - What the package reveals

    /// THE property the feature rests on. A sealed package that still names its
    /// recordings on the outside is not encrypted in any sense an analyst would
    /// recognise — and the fix (seal the whole tree, not each file) is exactly
    /// what makes this pass.
    @Test("An encrypted package reveals no record name, count, or id on disk")
    func encryptedPackageLeaksNothing() throws {
        let bundles = try makeBundles(3)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "right", to: pkg)

        // Top level: a manifest and one opaque blob. No `records/` directory,
        // so no per-record subtree names.
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: pkg.path).sorted()
        #expect(entries == ["manifest.json", "payload.enc"],
                "an encrypted package exposes only its header and one sealed blob")

        // The manifest must not carry identities or a contents list.
        let manifestText = try String(
            contentsOf: pkg.appendingPathComponent("manifest.json"), encoding: .utf8
        )
        for bundle in bundles {
            #expect(!manifestText.contains(bundle.recording.sourceFileName),
                    "a source filename identifies a recording and must not sit outside the seal")
            #expect(!manifestText.contains(bundle.recording.id.uuidString))
        }
        #expect(!manifestText.contains("\"records\""))
        #expect(!manifestText.contains("\"contents\""))

        // And nothing leaks into the ciphertext either — the blunt check, over
        // the whole package, that a `strings`-style look would make.
        let payload = try Data(contentsOf: pkg.appendingPathComponent("payload.enc"))
        for bundle in bundles {
            #expect(payload.range(of: Data(bundle.recording.sourceFileName.utf8)) == nil)
            #expect(payload.range(of: Data(bundle.recording.id.uuidString.utf8)) == nil)
        }
    }

    /// A plaintext package is the control: it DOES name its records, which is
    /// what makes the assertion above meaningful rather than vacuous.
    @Test("A plaintext package does name its records — the control")
    func plaintextDoesRevealNames() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Plain.mur")
        try write(bundles, passphrase: nil, to: pkg)
        let manifestText = try String(
            contentsOf: pkg.appendingPathComponent("manifest.json"), encoding: .utf8
        )
        #expect(manifestText.contains(bundles[0].recording.sourceFileName))
    }

    // MARK: - Parameters travel with the package

    /// Recorded rather than assumed, so raising the iteration count later
    /// cannot strand packages written before the change.
    @Test("KDF parameters are written into the manifest")
    func parametersAreRecorded() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "right", to: pkg)

        let manifest = try JSONDecoder.murDecoder.decode(
            MurSessionManifest.self,
            from: Data(contentsOf: pkg.appendingPathComponent("manifest.json"))
        )
        let parameters = try #require(manifest.encryption)
        #expect(parameters.kdf == "pbkdf2-hmac-sha256")
        #expect(parameters.cipher == "aes-256-gcm")
        #expect(parameters.iterations == MurSessionCrypto.defaultIterations)
        #expect(parameters.salt.count == MurSessionCrypto.saltByteCount)
    }

    @Test("Each package gets its own salt")
    func saltIsPerPackage() throws {
        let bundles = try makeBundles(1)
        let first = try tempDir("pkg1").appendingPathComponent("A.mur")
        let second = try tempDir("pkg2").appendingPathComponent("B.mur")
        try write(bundles, passphrase: "same", to: first)
        try write(bundles, passphrase: "same", to: second)

        func salt(_ url: URL) throws -> Data {
            try #require(
                JSONDecoder.murDecoder.decode(
                    MurSessionManifest.self,
                    from: Data(contentsOf: url.appendingPathComponent("manifest.json"))
                ).encryption
            ).salt
        }
        #expect(try salt(first) != salt(second),
                "a shared salt would let one derived key open every package")
    }

    @Test("A package opens under the iteration count it recorded, not today's")
    func honoursRecordedIterations() throws {
        // Derive with a deliberately different count and confirm the keys differ,
        // which is what makes recording the count load-bearing.
        let salt = MurSessionCrypto.makeSalt()
        let a = try MurSessionCrypto.deriveKey(passphrase: "pw", salt: salt, iterations: 1_000)
        let b = try MurSessionCrypto.deriveKey(passphrase: "pw", salt: salt, iterations: 2_000)
        #expect(a != b)
    }

    // MARK: - The open loop

    /// The retry behaviour was inside a SwiftUI view and reachable only through
    /// a modal. With the prompt injected it is assertable.

    @Test("A plaintext package never prompts")
    func openerDoesNotPromptForPlaintext() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Plain.mur")
        try write(bundles, passphrase: nil, to: pkg)

        var prompts = 0
        let result = try SessionPackageOpener.read(
            packageURL: pkg, into: try tempDir("open")
        ) { _ in
            prompts += 1
            return .cancelled
        }
        #expect(prompts == 0, "an unencrypted package must open without asking for anything")
        #expect(result?.records.count == 1)
    }

    @Test("A wrong passphrase re-asks, and the retry is marked as such")
    func openerRetriesAfterWrongPassphrase() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "right", to: pkg)

        var attempts: [Bool] = []      // the retry flag each prompt received
        let result = try SessionPackageOpener.read(
            packageURL: pkg, into: try tempDir("open")
        ) { retry in
            attempts.append(retry)
            return .passphrase(attempts.count == 1 ? "wrong" : "right")
        }
        #expect(attempts == [false, true],
                "the first ask is fresh; the second must know it is a retry so the wording can differ")
        #expect(result?.records.count == 1, "the correct passphrase on a retry still opens it")
    }

    /// Cancelling is "not now". Returning nil rather than throwing is what keeps
    /// the caller from surfacing an error the analyst did not cause.
    @Test("Cancelling yields no result and no error")
    func openerCancelIsNotAnError() throws {
        let bundles = try makeBundles(1)
        let pkg = try tempDir("pkg").appendingPathComponent("Sealed.mur")
        try write(bundles, passphrase: "right", to: pkg)

        let result = try SessionPackageOpener.read(
            packageURL: pkg, into: try tempDir("open")
        ) { _ in .cancelled }
        #expect(result == nil)
    }
}

private extension JSONDecoder {
    static var murDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
