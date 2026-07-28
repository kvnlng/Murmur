//
//  MurSessionCache.swift
//  MurmurCore
//
//  The `.mur` cache/ layer per project_mur_save_format_spec.md — a high-speed,
//  REBUILDABLE store of the derived measurement layer (fiducials, per-beat
//  intervals, per-patient template, RR series, QTc trend bins, VT/VF scan
//  scores) so a saved session reopens instantly without recompute.
//
//  LOAD-BEARING DISCIPLINE (RUO): the cache is an accelerator, NEVER a source
//  of truth. Every blob is STAMPED with the delineator/model version + the
//  parameters it was computed under. On reopen, a blob whose stamp does not
//  match the running app — or that is missing/corrupt — is DROPPED and
//  recomputed. Stale cached numbers are never rendered as if fresh; the source
//  signal + the analyst layer are the truth.
//
//  Blob wire format (compact, little-endian, versioned, length-prefixed):
//      magic   UInt32 LE  = 'MURC'
//      version UInt8      = 1
//      stampLen UInt32 LE
//      stamp   UTF-8 JSON (CacheStamp, sorted keys)
//      payload bytes      (the derived blob, opaque here)
//

import Foundation

/// Identifies exactly what a cache blob was computed under. A blob is only
/// trusted when its stamp equals the one the running app would produce now.
public struct CacheStamp: Codable, Equatable, Sendable {
    /// Which producer wrote it, e.g. "delineator", "vtvf-model", "trend-bins".
    public let producer: String
    /// The producer's version — the delineator/model version string.
    public let version: String
    /// A stable key over the parameters that affect the result (tau, bin width,
    /// QTc formula, ceiling, …). Any parameter change ⇒ a different key ⇒ the
    /// old blob is dropped.
    public let parametersKey: String

    public init(producer: String, version: String, parametersKey: String) {
        self.producer = producer
        self.version = version
        self.parametersKey = parametersKey
    }
}

public enum MurSessionCache {

    private static let magic: UInt32 = 0x4D_55_52_43  // 'M','U','R','C'
    private static let version: UInt8 = 1

    /// Wrap a derived `payload` with its `stamp` into a self-describing blob.
    public static func encode(stamp: CacheStamp, payload: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stampData = try encoder.encode(stamp)

        var out = Data()
        appendLE(magic, to: &out)
        out.append(version)
        appendLE(UInt32(stampData.count), to: &out)
        out.append(stampData)
        out.append(payload)
        return out
    }

    /// Unwrap a blob, returning its payload ONLY when the blob is well-formed
    /// AND its stamp equals `expected`. A mismatch, an unknown magic/version, or
    /// a truncated/corrupt blob all return `nil` — the caller then recomputes.
    /// Never throws: an unreadable cache is simply a cache miss.
    public static func decode(_ data: Data, expected: CacheStamp) -> Data? {
        var offset = 0
        guard let readMagic = readLE32(data, &offset), readMagic == magic else { return nil }
        guard offset < data.count, data[data.startIndex + offset] == version else { return nil }
        offset += 1
        guard let stampLen = readLE32(data, &offset) else { return nil }
        let stampStart = offset
        let stampEnd = offset + Int(stampLen)
        guard stampEnd <= data.count else { return nil }
        let stampData = data.subdata(in: data.startIndex + stampStart ..< data.startIndex + stampEnd)
        guard let stamp = try? JSONDecoder().decode(CacheStamp.self, from: stampData),
              stamp == expected else { return nil }
        return data.subdata(in: data.startIndex + stampEnd ..< data.endIndex)
    }

    // MARK: - Little-endian helpers

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    /// Reads a little-endian UInt32 at `offset` (relative to the data's start),
    /// advancing `offset`. Nil when fewer than 4 bytes remain.
    private static func readLE32(_ data: Data, _ offset: inout Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[base + i]) << (8 * i)
        }
        offset += 4
        return value
    }
}
