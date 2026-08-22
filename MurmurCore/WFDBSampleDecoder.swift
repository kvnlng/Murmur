//
//  WFDBSampleDecoder.swift
//  Murmur
//
//  Decodes PhysioNet WFDB format-16 and format-212 (.dat) binary data into
//  physical Float32 samples.
//
//  Format 16:
//    • Each sample is a 16-bit signed integer in little-endian byte order.
//    • Samples are interleaved across signals: frame[sig0, sig1, …]
//    • Total bytes = signalCount × sampleCount × 2
//
//  Format 212:
//    • Two adjacent 12-bit samples share 3 bytes.
//    • Byte layout for a pair (A, B):
//        byte[0] = A[7:0]
//        byte[1] = B[3:0]<<4 | A[11:8]
//        byte[2] = B[11:4]
//    • Samples are laid out sequentially across the entire file (interleaved by
//      frame), then packed 2-at-a-time. For N signals × S frames the flat
//      sequence is [f0s0, f0s1, …, f0sN-1, f1s0, …] with length N×S.
//    • Total bytes = ceil(N × S / 2) × 3
//
//  Physical conversion: physicalValue = (adcSample − signal.baseline) / signal.gain
//

import Foundation

enum WFDBDecodeError: LocalizedError {
    case unreadable(URL)
    case truncatedFile(expectedBytes: Int, actualBytes: Int)
    case mixedFormatsInFile(URL)
    case mixedSamplesPerFrameInFile(URL)
    case mixedByteOffsetsInFile(URL)
    // Preamble disagreements (#327) — raised only when the preamble is a
    // recognized MATLAB Level 4 header. See WFDBPreamble.swift for the
    // published definitions each of these is derived from.
    case preambleLengthMismatch(declaredOffset: Int, matHeaderBytes: Int, nameLength: Int)
    case preambleByteOrder(matOrder: String, format: Int)
    case preamblePrecision(matPrecision: String, format: Int)
    case preambleMatrixKind(matKind: String)
    case preambleShapeTransposed(rows: Int, cols: Int, signals: Int, samples: Int)
    case preambleShapeMismatch(rows: Int, cols: Int, signals: Int, samples: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read sample file: \(url.lastPathComponent)."
        case .truncatedFile(let expected, let actual):
            return "Sample file is truncated: expected \(expected) bytes, found \(actual)."
        case .mixedFormatsInFile(let url):
            return "Signals sharing \(url.lastPathComponent) must use the same storage format."
        case .mixedSamplesPerFrameInFile(let url):
            return "Signals sharing \(url.lastPathComponent) must use the same samples-per-frame (spf)."
        case .mixedByteOffsetsInFile(let url):
            return "Signals sharing \(url.lastPathComponent) must declare the same byte offset."
        case .preambleLengthMismatch(let declared, let matBytes, let namlen):
            return "Header declares a \(declared)-byte preamble but the MAT header is "
                 + "\(matBytes) bytes (20 + namlen \(namlen))."
        case .preambleByteOrder(let order, let format):
            return "MAT data is \(order)-ordered; WFDB format \(format) requires little-endian."
        case .preamblePrecision(let precision, let format):
            return "MAT precision is \(precision); WFDB format \(format) requires int16."
        case .preambleMatrixKind(let kind):
            return "MAT matrix is \(kind); WFDB needs a full real numeric matrix."
        case .preambleShapeTransposed(let rows, let cols, let signals, let samples):
            return "MAT matrix is \(rows)×\(cols) (samples×signals); WFDB format 16 requires "
                 + "signals×samples (\(signals)×\(samples))."
        case .preambleShapeMismatch(let rows, let cols, let signals, let samples):
            return "MAT matrix \(rows)×\(cols) does not match header "
                 + "(\(signals) signals × \(samples) samples)."
        }
    }
}

enum WFDBSampleDecoder {

    /// Decodes every signal in `header` into per-signal Float arrays.
    ///
    /// Signals are grouped by their `.hea`-declared filename — single-file
    /// records (every signal sharing one `.dat`) decode in one pass, while
    /// multi-file records (e.g. ECG and 1-min vital trends in separate
    /// `.dat` files) decode file-by-file and stitch results back into the
    /// header's original signal order.
    ///
    /// `datURL` is treated as the path to the *first* signal's file; its
    /// parent directory is the search root for the other files.
    static func decode(datURL: URL, header: WFDBHeader) throws -> [[Float]] {
        let parentDir = datURL.deletingLastPathComponent()
        var output = [[Float]](repeating: [], count: header.signals.count)

        // Group signal indices by filename so each file is opened exactly
        // once even when several signals share it.
        var indicesByFilename: [(filename: String, indices: [Int])] = []
        var seen: [String: Int] = [:]
        for (idx, signal) in header.signals.enumerated() {
            if let groupIdx = seen[signal.filename] {
                indicesByFilename[groupIdx].indices.append(idx)
            } else {
                seen[signal.filename] = indicesByFilename.count
                indicesByFilename.append((signal.filename, [idx]))
            }
        }

        for group in indicesByFilename {
            let fileURL = parentDir.appendingPathComponent(group.filename)
            let signalsInFile = group.indices.map { header.signals[$0] }

            // Within a single file, every signal must agree on format + spf.
            let formats = Set(signalsInFile.map(\.format))
            guard formats.count == 1 else {
                throw WFDBDecodeError.mixedFormatsInFile(fileURL)
            }
            let spfs = Set(signalsInFile.map(\.samplesPerFrame))
            guard spfs.count == 1 else {
                throw WFDBDecodeError.mixedSamplesPerFrameInFile(fileURL)
            }
            let spf = spfs.first ?? 1
            // The preamble is a property of the FILE, so every signal sharing
            // it must declare the same offset (#327).
            let offsets = Set(signalsInFile.map(\.byteOffset))
            guard offsets.count == 1 else {
                throw WFDBDecodeError.mixedByteOffsetsInFile(fileURL)
            }

            let needsScope = fileURL.startAccessingSecurityScopedResource()
            defer { if needsScope { fileURL.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
                throw WFDBDecodeError.unreadable(fileURL)
            }

            let perSignalSampleCount = header.sampleCount * Int64(spf)
            let decoded: [[Float]]
            let format = signalsInFile.first?.format ?? 16
            if format == 212 {
                decoded = try decodeFormat212(
                    data: data,
                    signals: signalsInFile,
                    declaredSampleCount: perSignalSampleCount
                )
            } else {
                decoded = try decodeFormat16(
                    data: data,
                    signals: signalsInFile,
                    declaredSampleCount: perSignalSampleCount
                )
            }

            // Re-map into the header's original signal order.
            for (localIdx, originalIdx) in group.indices.enumerated() {
                output[originalIdx] = decoded[localIdx]
            }
        }

        return output
    }

    // MARK: - Preamble geometry

    /// Where a signal file's samples actually start, and how many bytes follow
    /// (#327).
    ///
    /// The offset comes from the `.hea`'s `+N` suffix and is honored
    /// unconditionally — `header(5)` defines it as the preamble's length and
    /// says nothing about its contents, so it is authoritative and is never
    /// inferred from the bytes. Every length check in the decoders is measured
    /// against `available` rather than the raw file size, so a file that is
    /// long enough only by counting its preamble still reports as truncated.
    private static func sampleRegion(
        in data: Data,
        signals: [WFDBSignal]
    ) throws -> (byteOffset: Int, available: Int) {
        let byteOffset = signals.first?.byteOffset ?? 0
        guard byteOffset >= 0, byteOffset <= data.count else {
            throw WFDBDecodeError.truncatedFile(
                expectedBytes: byteOffset, actualBytes: data.count
            )
        }
        return (byteOffset, data.count - byteOffset)
    }

    // MARK: - Format 16

    /// Pure-data variant used by tests — no file I/O. Every signal in `signals`
    /// is assumed to share the same format and spf (i.e., to come from the
    /// same `.dat` file). For multi-file decodes use `decode(datURL:header:)`.
    static func decode(
        data: Data,
        signals: [WFDBSignal],
        declaredSampleCount: Int64
    ) throws -> [[Float]] {
        let formats = Set(signals.map(\.format))
        guard formats.count <= 1 else { throw WFDBDecodeError.mixedFormatsInFile(URL(fileURLWithPath: "<test>")) }
        let format = signals.first?.format ?? 16
        if format == 212 {
            return try decodeFormat212(data: data, signals: signals, declaredSampleCount: declaredSampleCount)
        } else {
            return try decodeFormat16(data: data, signals: signals, declaredSampleCount: declaredSampleCount)
        }
    }

    static func decodeFormat16(
        data: Data,
        signals: [WFDBSignal],
        declaredSampleCount: Int64
    ) throws -> [[Float]] {
        let signalCount = signals.count
        guard signalCount > 0 else { return [] }

        let frameSize = signalCount * 2

        let (byteOffset, available) = try sampleRegion(in: data, signals: signals)

        let sampleCount: Int
        if declaredSampleCount > 0 {
            let expectedBytes = Int(declaredSampleCount) * frameSize
            guard available >= expectedBytes else {
                throw WFDBDecodeError.truncatedFile(expectedBytes: expectedBytes, actualBytes: available)
            }
            sampleCount = Int(declaredSampleCount)
        } else {
            sampleCount = available / frameSize
        }

        // Additional check, only when the preamble is a recognized MATLAB
        // Level 4 header — it then makes claims we can compare with the `.hea`.
        if byteOffset > 0 {
            try WFDBPreamble.validateIfRecognized(
                in: data,
                declaredOffset: byteOffset,
                wfdbFormat: 16,
                signalCount: signalCount,
                sampleCount: sampleCount
            )
        }

        var output = [[Float]](
            repeating: [Float](repeating: 0, count: sampleCount),
            count: signalCount
        )

        data.withUnsafeBytes { rawBuffer in
            for sampleIdx in 0..<sampleCount {
                for signalIdx in 0..<signalCount {
                    let frameOffset = sampleIdx * signalCount + signalIdx
                    // loadUnaligned, not a bound Int16 pointer: an odd byte
                    // offset would make the bound-pointer form undefined.
                    let raw = rawBuffer.loadUnaligned(
                        fromByteOffset: byteOffset + frameOffset * 2,
                        as: Int16.self
                    )
                    let adcValue = Int(Int16(littleEndian: raw))
                    let signal = signals[signalIdx]
                    output[signalIdx][sampleIdx] = Float(adcValue - signal.baseline) / Float(signal.gain)
                }
            }
        }

        return output
    }

    // MARK: - Format 212

    static func decodeFormat212(
        data: Data,
        signals: [WFDBSignal],
        declaredSampleCount: Int64
    ) throws -> [[Float]] {
        let signalCount = signals.count
        guard signalCount > 0 else { return [] }

        let (byteOffset, available) = try sampleRegion(in: data, signals: signals)

        // Total samples in the interleaved flat sequence = signalCount × sampleCount.
        let sampleCount: Int
        if declaredSampleCount > 0 {
            sampleCount = Int(declaredSampleCount)
        } else {
            // Each group of 3 bytes holds 2 12-bit samples.
            sampleCount = (available / 3 * 2) / signalCount
        }

        let totalFlat     = signalCount * sampleCount
        let requiredBytes = (totalFlat + 1) / 2 * 3    // ceil(totalFlat / 2) × 3
        guard available >= requiredBytes else {
            throw WFDBDecodeError.truncatedFile(expectedBytes: requiredBytes, actualBytes: available)
        }

        if byteOffset > 0 {
            try WFDBPreamble.validateIfRecognized(
                in: data,
                declaredOffset: byteOffset,
                wfdbFormat: 212,
                signalCount: signalCount,
                sampleCount: sampleCount
            )
        }

        // Unpack the entire flat sequence of 12-bit two's-complement integers.
        var flat = [Int32](repeating: 0, count: totalFlat)
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var flatIdx = 0
            var byteIdx = byteOffset
            while flatIdx + 1 <= totalFlat - 1 {
                let b0 = UInt16(bytes[byteIdx])
                let b1 = UInt16(bytes[byteIdx + 1])
                let b2 = UInt16(bytes[byteIdx + 2])

                // WFDB 212 packs two 12-bit samples per 3 bytes:
                //   s0 = byte0 | (byte1 & 0x0F) << 8   (low nibble of byte1 = s0 high bits)
                //   s1 = byte2 | (byte1 & 0xF0) << 4   (high nibble of byte1 = s1 high bits)
                let rawA = b0 | ((b1 & 0x0F) << 8)      // A: byte[0] + low nibble of byte[1]
                let rawB = b2 | ((b1 & 0xF0) << 4)      // B: byte[2] + high nibble of byte[1]

                // Sign-extend from 12 bits to 16 bits using arithmetic right shift.
                flat[flatIdx]     = Int32(Int16(bitPattern: rawA << 4) >> 4)
                flat[flatIdx + 1] = Int32(Int16(bitPattern: rawB << 4) >> 4)

                flatIdx  += 2
                byteIdx  += 3
            }
            // Odd trailing sample.
            if flatIdx < totalFlat {
                let b0 = UInt16(bytes[byteIdx])
                let b1 = UInt16(bytes[byteIdx + 1])
                let rawA = b0 | ((b1 & 0x0F) << 8)
                flat[flatIdx] = Int32(Int16(bitPattern: rawA << 4) >> 4)
            }
        }

        // Re-arrange from interleaved flat layout into per-signal arrays.
        var output = [[Float]](
            repeating: [Float](repeating: 0, count: sampleCount),
            count: signalCount
        )
        for sampleIdx in 0..<sampleCount {
            for signalIdx in 0..<signalCount {
                let signal = signals[signalIdx]
                let adcValue = Int(flat[sampleIdx * signalCount + signalIdx])
                output[signalIdx][sampleIdx] = Float(adcValue - signal.baseline) / Float(signal.gain)
            }
        }
        return output
    }
}
