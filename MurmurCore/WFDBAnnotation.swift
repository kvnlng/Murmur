//
//  WFDBAnnotation.swift
//  Murmur
//
//  Parses PhysioNet WFDB annotation (.atr) binary files.
//
//  Format (MIT-BIH):
//    Each "frame word" is 2 bytes little-endian. The 6 high bits hold the
//    annotation type code; the 10 low bits hold a sample-index delta from the
//    previous annotation:
//        word = byte[0] | (byte[1] << 8)
//        type = (word >> 10) & 0x3F
//        delta = word & 0x3FF
//
//  Special type codes:
//    0   NOTQRS   — end-of-stream when the whole word is zero
//    59  SKIP     — next 4 bytes hold a signed 32-bit delta encoded as two
//                   little-endian 16-bit words (high half first). The frame
//                   *after* that carries the actual annotation type.
//    60  NUM      — modifier carrying a `num` value; doesn't emit, doesn't
//    61  SUB        advance time. We skip these — we don't model num/sub/chn yet.
//    62  CHN
//    63  AUX      — the 10-bit field is the length of an aux byte string that
//                   follows (padded to even length). Doesn't advance time.
//
//  We intentionally cover only the cases used by the MIT-BIH Arrhythmia
//  Database. That's enough for >99% of clinical .atr files. AUX, NUM, SUB, CHN
//  payloads are skipped cleanly without breaking the stream.
//

import Foundation

struct WFDBAnnotation: Codable, Equatable, Sendable {
    let sampleIndex: Int64
    let code: UInt8        // raw WFDB type code (1–58 for emitted events)
    let label: String      // single-letter symbol (e.g. "N", "V", "L")
}

enum WFDBAnnotationError: LocalizedError {
    case unreadable(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read annotation file: \(url.lastPathComponent)."
        }
    }
}

enum WFDBAnnotationParser {

    // Special type codes
    static let skip: UInt8 = 59
    static let num:  UInt8 = 60
    static let sub:  UInt8 = 61
    static let chn:  UInt8 = 62
    static let aux:  UInt8 = 63

    /// One-letter symbols for the standard MIT-BIH annotation codes.
    static let symbolForCode: [UInt8: String] = [
        1:  "N",   2:  "L",   3:  "R",   4:  "a",   5:  "V",
        6:  "F",   7:  "J",   8:  "A",   9:  "S",   10: "E",
        11: "j",   12: "/",   13: "Q",   14: "~",   16: "|",
        18: "s",   19: "T",   20: "*",   21: "D",   22: "\"",
        23: "=",   24: "p",   25: "B",   26: "^",   27: "t",
        28: "+",   29: "u",   30: "?",   31: "!",   32: "[",
        33: "]",   34: "e",   35: "n",   36: "@",   37: "x",
        38: "f",   39: "`",   40: "'",   41: "r"
    ]

    static func parse(url: URL) throws -> [WFDBAnnotation] {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw WFDBAnnotationError.unreadable(url)
        }
        return parse(data: data)
    }

    /// Pure-data variant for tests.
    static func parse(data: Data) -> [WFDBAnnotation] {
        var annotations: [WFDBAnnotation] = []
        var sampleIndex: Int64 = 0
        var offset = 0

        data.withUnsafeBytes { raw in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count

            while offset + 2 <= count {
                let word = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                offset += 2
                if word == 0 { break }     // EOF marker

                var typeCode = UInt8((word >> 10) & 0x3F)
                var delta = Int(word & 0x3FF)

                if typeCode == skip {
                    // SKIP: next 4 bytes = signed 32-bit delta as (high-word, low-word),
                    // each stored little-endian. The annotation type comes from the *next* frame.
                    guard offset + 4 <= count else { break }
                    let hi = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                    let lo = UInt32(bytes[offset + 2]) | (UInt32(bytes[offset + 3]) << 8)
                    let combined = Int32(bitPattern: (hi << 16) | lo)
                    delta = Int(combined)
                    offset += 4

                    guard offset + 2 <= count else { break }
                    let nextWord = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                    offset += 2
                    typeCode = UInt8((nextWord >> 10) & 0x3F)
                }

                // Non-emitting metadata codes — don't advance time, don't emit.
                if typeCode == num || typeCode == sub || typeCode == chn {
                    continue
                }
                if typeCode == aux {
                    // The 10-bit field is the byte length of the aux string,
                    // padded to even. Skip those bytes.
                    let length = delta
                    let padded = length + (length & 1)
                    offset += padded
                    continue
                }
                if typeCode == 0 { continue }    // null inside stream

                sampleIndex += Int64(delta)
                let label = symbolForCode[typeCode] ?? "?"
                annotations.append(WFDBAnnotation(
                    sampleIndex: sampleIndex,
                    code: typeCode,
                    label: label
                ))
            }
        }

        return annotations
    }
}
