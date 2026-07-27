//
//  WFDBAnnotationWriter.swift
//  Murmur
//
//  Writes PhysioNet WFDB annotation files — the export side of the reader in
//  WFDBAnnotation.swift. Used to hand an analyst's adjudicated findings to a
//  peer in an interoperable format.
//
//  Format (MIT-BIH), mirroring exactly what the reference `wfdb-python`
//  (v4.3.1) emits so its `rdann` reads our files back losslessly:
//
//    • Each "type frame" is a 2-byte little-endian word:
//          word = (typeCode << 10) | delta
//      where `delta` is the sample-index gap from the previous annotation
//      (0…1023) and `typeCode` is the 6-bit WFDB annotation code.
//    • delta > 1023 (won't fit in 10 bits): emit a SKIP frame (code 59, low
//      bits 0) followed by a signed 32-bit delta as two little-endian 16-bit
//      words, HIGH word first; the following type frame then carries delta 0.
//    • Aux text: an AUX frame (code 63) whose 10-bit field is the byte length,
//      immediately followed by the UTF-8 bytes, plus one 0x00 pad byte iff the
//      length is odd. Empty aux emits no AUX frame. (No NUL terminator — the
//      length field alone bounds the string, matching wfdb-python output.)
//    • End of stream: a zero word (0x0000).
//
//  We only ever write NOTE (comment) annotations — see the export design note
//  in WFDBAnnotationExport.swift for why a finding's span is flattened to an
//  onset comment rather than a rhythm-state onset/offset pair.
//

import Foundation

enum WFDBAnnotationWriter {

    /// WFDB code for a NOTE (comment) annotation — symbol `"`. Its aux string
    /// carries the analyst's own words. A comment asserts nothing about the
    /// rhythm before or after it, which is why it is the RUO-safe carrier for
    /// an exported finding.
    static let noteCode: UInt8 = 22

    /// One annotation to serialise. `sampleIndex` is absolute (the encoder
    /// converts to deltas); `aux` may be empty.
    struct Event: Equatable, Sendable {
        let sampleIndex: Int64
        let code: UInt8
        let aux: String

        init(sampleIndex: Int64, code: UInt8 = WFDBAnnotationWriter.noteCode, aux: String) {
            self.sampleIndex = sampleIndex
            self.code = code
            self.aux = aux
        }
    }

    /// Longest aux string the 10-bit AUX length field can express.
    static let maxAuxBytes = 0x3FF

    /// Encodes `events` into `.atr`-format annotation bytes. Events are sorted
    /// ascending by sample index first; equal samples keep their given order
    /// (delta 0). The output is byte-identical to `wfdb-python`'s `wrann` for
    /// the same inputs.
    static func encode(_ events: [Event]) -> Data {
        var data = Data()
        var previousSample: Int64 = 0

        for event in events.sorted(by: { $0.sampleIndex < $1.sampleIndex }) {
            let delta = event.sampleIndex - previousSample
            appendTypeFrame(code: event.code, delta: delta, to: &data)
            previousSample = event.sampleIndex
            appendAuxFrame(event.aux, to: &data)
        }

        // End-of-stream marker.
        appendWord(0, to: &data)
        return data
    }

    // MARK: - Frame writers

    private static func appendTypeFrame(code: UInt8, delta: Int64, to data: inout Data) {
        if delta >= 0 && delta <= 0x3FF {
            appendWord((UInt16(code) << 10) | UInt16(delta), to: &data)
            return
        }
        // SKIP frame: code 59, low bits zero, then a signed 32-bit delta as
        // (high word, low word), each little-endian; the type frame that
        // follows carries delta 0.
        appendWord(UInt16(WFDBAnnotationParser.skip) << 10, to: &data)
        let unsigned = UInt32(bitPattern: Int32(delta))
        appendWord(UInt16(unsigned >> 16), to: &data)
        appendWord(UInt16(unsigned & 0xFFFF), to: &data)
        appendWord(UInt16(code) << 10, to: &data)
    }

    private static func appendAuxFrame(_ aux: String, to data: inout Data) {
        guard !aux.isEmpty else { return }
        var bytes = Array(aux.utf8)
        if bytes.count > maxAuxBytes { bytes = Array(bytes.prefix(maxAuxBytes)) }
        appendWord((UInt16(WFDBAnnotationParser.aux) << 10) | UInt16(bytes.count), to: &data)
        data.append(contentsOf: bytes)
        if bytes.count % 2 == 1 { data.append(0) }  // pad to even
    }

    private static func appendWord(_ word: UInt16, to data: inout Data) {
        data.append(UInt8(word & 0xFF))
        data.append(UInt8(word >> 8))
    }

    // MARK: - File output

    /// The annotator suffix Murmur writes its own findings under —
    /// `<record>.mur`. Deliberately distinct from `.atr` so an export never
    /// touches the reference annotation set.
    static let defaultAnnotator = "mur"

    /// Annotator suffixes Murmur must never write. `.atr` is the reference
    /// annotation set — for PhysioNet records it is the published ground truth
    /// the analyst is working against; overwriting it destroys that.
    static let reservedAnnotators: Set<String> = ["atr"]

    enum WriteError: LocalizedError, Equatable {
        /// Refused to write a reserved annotator (e.g. `.atr`).
        case reservedAnnotator(String)
        /// The target annotator file already exists; the caller must confirm
        /// an overwrite rather than silently clobbering it.
        case annotatorExists(URL)

        var errorDescription: String? {
            switch self {
            case .reservedAnnotator(let suffix):
                return "Refusing to overwrite the reserved \".\(suffix)\" annotation set. Murmur writes findings to a separate annotator."
            case .annotatorExists(let url):
                return "An annotation file already exists at \(url.lastPathComponent). Confirm before overwriting it."
            }
        }
    }

    /// Serialises `events` and writes `<recordName>.<annotator>` into
    /// `directory`. Refuses reserved annotators (`.atr`) outright, and refuses
    /// to overwrite an existing file unless `overwrite` is set — the caller
    /// surfaces that as a prompt (never a silent clobber). Returns the URL
    /// written.
    @discardableResult
    static func write(
        _ events: [Event],
        recordName: String,
        annotator: String = defaultAnnotator,
        in directory: URL,
        overwrite: Bool = false
    ) throws -> URL {
        let suffix = annotator.lowercased()
        guard !reservedAnnotators.contains(suffix) else {
            throw WriteError.reservedAnnotator(suffix)
        }
        let url = directory.appendingPathComponent("\(recordName).\(suffix)")
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw WriteError.annotatorExists(url)
        }
        try encode(events).write(to: url, options: .atomic)
        return url
    }

    /// Serialises `events` to an explicit destination `fileURL` — used when the
    /// user picks the location through a save panel (which already handles the
    /// replace-existing prompt, so there's no clobber check here). Still refuses
    /// a reserved annotator extension (`.atr`). Returns the URL written.
    @discardableResult
    static func write(_ events: [Event], to fileURL: URL) throws -> URL {
        let suffix = fileURL.pathExtension.lowercased()
        guard !reservedAnnotators.contains(suffix) else {
            throw WriteError.reservedAnnotator(suffix)
        }
        try encode(events).write(to: fileURL, options: .atomic)
        return fileURL
    }
}
