//
//  SourceFingerprint.swift
//  MurmurCore
//
//  Identity of the SOURCE files a recording bundle was imported from — the
//  key that lets a folder re-open reuse the existing bundle instead of paying
//  the import again.
//
//  Why this exists: every folder open used to import into a fresh UUID
//  bundle. For a 25-hour record that is a full packed-12-bit decode plus the
//  pyramid build per OPEN, and the abandoned bundles accumulate in
//  Application Support (16 GB / 938 bundles observed before this landed).
//  Reuse turns that leak into a cache, and — because the bundle keeps its
//  `recording.json` — makes `Recording.id` STABLE across opens of unchanged
//  source data, which is what per-bundle derived caches key on.
//
//  The fingerprint covers every file the importer reads, by (name, byte
//  size, mtime): the .hea, every distinct signal file it references, and the
//  optional sidecars (`<name>.annotations.json`, `.atr`, `.qrs`,
//  `<name>.notes.md`). Absent optional files are recorded as absent — an
//  .atr appearing next to a previously-imported record must invalidate, or
//  the bundle would keep serving beat-less annotations.
//
//  Size+mtime, not a content hash, on purpose: the check runs on every
//  folder open against research databases that reach hundreds of megabytes,
//  and hashing them would reintroduce a scan of the very bytes reuse exists
//  to avoid reading. A tool that rewrites bytes while forging an identical
//  mtime defeats it; that is the accepted trade, same as make/ninja.
//

import CryptoKit
import Foundation

public struct SourceFingerprint: Codable, Equatable, Sendable {

    /// One source file's identity. `modifiedAtMS` in whole milliseconds —
    /// sub-millisecond filesystem timestamp precision differs by volume
    /// format (APFS vs the FAT variants common on external research drives),
    /// and comparing beyond it would make the same files "change" when
    /// copied between volumes.
    public struct FileStamp: Codable, Equatable, Sendable {
        public let name: String
        public let byteSize: Int64
        public let modifiedAtMS: Int64
    }

    /// Present source files, sorted by name for order-independent equality.
    public let files: [FileStamp]

    /// Optional-file slots the importer would read that did NOT exist at
    /// import time, sorted. Absence is part of identity (see header).
    public let absentNames: [String]

    static let bundleFileName = "source_fingerprint.json"

    /// Stable content digest, usable as a filesystem name — the key the
    /// store's fingerprint index (#341) files entries under. SHA-256 over the
    /// canonical (sorted-keys, unformatted) JSON encoding, so equal
    /// fingerprints always digest equally across processes and versions of
    /// this struct that encode the same fields. Collisions are theoretical,
    /// and harmless anyway: every index hit is re-validated against the
    /// bundle's own fingerprint file before it is served.
    public var stableDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a Codable struct of plain values cannot fail; an empty
        // digest would only ever mean that assumption broke, and reads as
        // "no entry" — a fresh import, never a wrong bundle.
        guard let data = try? encoder.encode(self) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Compute

    /// Stat every file the importer would read for the record at `heaURL`.
    /// Throws only when the .hea itself is unreadable — it is the one file
    /// that must exist for `heaURL` to name a record at all.
    public static func compute(heaURL: URL) throws -> SourceFingerprint {
        let folder = heaURL.deletingLastPathComponent()
        let recordName = heaURL.deletingPathExtension().lastPathComponent

        var names: Set<String> = [heaURL.lastPathComponent]
        // Every distinct signal file the header references.
        let header = try WFDBHeaderParser.parse(url: heaURL)
        for signal in header.signals {
            names.insert(signal.filename)
        }
        // The optional sidecars the importer scans for (loadAnnotations +
        // copyNotesIntoBundle) — tracked whether or not they exist.
        let optionalNames = [
            "\(recordName).annotations.json",
            "\(recordName).atr",
            "\(recordName).qrs",
            "\(recordName).notes.md",
        ]

        var stamps: [FileStamp] = []
        var absent: [String] = []
        for name in names.union(optionalNames).sorted() {
            let url = folder.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64,
                  let modified = attrs[.modificationDate] as? Date else {
                absent.append(name)
                continue
            }
            stamps.append(FileStamp(
                name: name,
                byteSize: size,
                modifiedAtMS: Int64(modified.timeIntervalSince1970 * 1000)
            ))
        }
        // A .hea that stats as absent while parsing fine is a race we don't
        // paper over — but parse already threw if it was unreadable, so
        // `stamps` necessarily carries it here.
        return SourceFingerprint(files: stamps, absentNames: absent)
    }

    // MARK: - Bundle round-trip

    /// Persist into a recording bundle directory.
    public func write(to bundleDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = bundleDirectory.appendingPathComponent(Self.bundleFileName)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Read from a recording bundle directory. Nil on absence or any decode
    /// failure — a malformed fingerprint means "don't reuse", never an error;
    /// the caller falls back to a fresh import.
    public static func read(from bundleDirectory: URL) -> SourceFingerprint? {
        let url = bundleDirectory.appendingPathComponent(bundleFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SourceFingerprint.self, from: data)
    }
}
