//
//  BinaryRecordingFile.swift
//  Murmur
//
//  Binary on-disk format for one channel's packed Float32 samples.
//
//  Layout (version 2):
//      [ 0..10 ]  magic     "PLOTTRACE\0"
//      [10..12 ]  uint16    version = 2 (little-endian)
//      [12..16 ]  reserved  (zero)
//      [16..24 ]  int64     start_time_unix_ms (little-endian)
//      [24..32 ]  float64   sample_rate_hz (little-endian)
//      [32..40 ]  int64     sample_count (little-endian)
//      [40..64 ]  reserved  (zero)
//      [64..   ]  float32 × sample_count   (raw samples, little-endian)
//
//  Integers and floats are stored little-endian; no byte swap is needed at
//  runtime on any Apple Silicon or Intel platform.
//

import Foundation

struct BinaryRecordingHeader: Equatable, Sendable {
    // "PLOTTRACE\0"
    static let magic: [UInt8] = [0x50, 0x4C, 0x4F, 0x54, 0x54, 0x52, 0x41, 0x43, 0x45, 0x00]
    static let currentVersion: UInt16 = 2
    static let headerByteSize = 64

    var version: UInt16
    var startTimeUnixMS: Int64
    var sampleRateHz: Double
    var sampleCount: Int64
}

enum BinaryRecordingError: LocalizedError {
    case malformedHeader
    case unsupportedVersion(UInt16)
    case sampleCountMismatch(expected: Int64, actualBytes: Int)

    var errorDescription: String? {
        switch self {
        case .malformedHeader:
            return "The recording file header is malformed."
        case .unsupportedVersion(let version):
            return "Unsupported recording file version \(version)."
        case .sampleCountMismatch(let expected, let actualBytes):
            return "Sample count mismatch: header says \(expected) samples, file body has \(actualBytes) bytes."
        }
    }
}

enum BinaryRecordingFile {

    /// Builds the 64-byte header blob.
    static func encodeHeader(_ header: BinaryRecordingHeader) -> Data {
        var data = Data(count: BinaryRecordingHeader.headerByteSize)
        data.replaceSubrange(0..<10, with: BinaryRecordingHeader.magic)
        var version = header.version.littleEndian
        var startMS = header.startTimeUnixMS.littleEndian
        var rate    = header.sampleRateHz.bitPattern.littleEndian
        var count   = header.sampleCount.littleEndian
        withUnsafeBytes(of: &version) { data.replaceSubrange(10..<12, with: $0) }
        withUnsafeBytes(of: &startMS) { data.replaceSubrange(16..<24, with: $0) }
        withUnsafeBytes(of: &rate)    { data.replaceSubrange(24..<32, with: $0) }
        withUnsafeBytes(of: &count)   { data.replaceSubrange(32..<40, with: $0) }
        return data
    }

    /// Parses the 64-byte header from the start of a file.
    static func decodeHeader(_ data: Data) throws -> BinaryRecordingHeader {
        guard data.count >= BinaryRecordingHeader.headerByteSize else {
            throw BinaryRecordingError.malformedHeader
        }
        guard Array(data.prefix(10)) == BinaryRecordingHeader.magic else {
            throw BinaryRecordingError.malformedHeader
        }
        let version = data.readLittleEndian(at: 10, as: UInt16.self)
        guard version == BinaryRecordingHeader.currentVersion else {
            throw BinaryRecordingError.unsupportedVersion(version)
        }
        let startMS  = data.readLittleEndian(at: 16, as: Int64.self)
        let rateBits = data.readLittleEndian(at: 24, as: UInt64.self)
        let count    = data.readLittleEndian(at: 32, as: Int64.self)
        return BinaryRecordingHeader(
            version: version,
            startTimeUnixMS: startMS,
            sampleRateHz: Double(bitPattern: rateBits),
            sampleCount: count
        )
    }

    /// Writes a recording file (header + Float32 samples) to `url`.
    static func write(samples: [Float], header: BinaryRecordingHeader, to url: URL) throws {
        var data = encodeHeader(header)
        data.reserveCapacity(BinaryRecordingHeader.headerByteSize + samples.count * MemoryLayout<Float>.size)
        samples.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UInt8.self) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        try data.write(to: url, options: .atomic)
    }

    /// Reads a contiguous run of Float32 samples. `range` is sample indices, not bytes.
    static func readSamples(url: URL, range: Range<Int64>) throws -> [Float] {
        let access = try mappedAccess(url: url)
        return access.samples(range: range)
    }

    /// Opens a memory-mapped view. Cheap to open; holds the OS mapping until dropped.
    static func mappedAccess(url: URL) throws -> MappedSampleAccess {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let header = try decodeHeader(data)
        return MappedSampleAccess(data: data, header: header)
    }
}

/// Read-only view over a memory-mapped recording file.
struct MappedSampleAccess: Sendable {
    let data: Data
    let header: BinaryRecordingHeader

    /// Returns the Float32 samples in `range` (sample indices).
    /// Indices beyond the end of file return NaN.
    func samples(range: Range<Int64>) -> [Float] {
        let sampleSize = MemoryLayout<Float>.size
        let bodyStart  = BinaryRecordingHeader.headerByteSize
        let startByte  = bodyStart + Int(range.lowerBound) * sampleSize
        let wantedBytes = Int(range.count) * sampleSize
        var output = [Float](repeating: .nan, count: Int(range.count))
        let availableBytes = max(0, min(wantedBytes, data.count - startByte))
        guard availableBytes > 0 else { return output }
        data.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            output.withUnsafeMutableBytes { dst in
                guard let dstBase = dst.baseAddress else { return }
                dstBase.copyMemory(from: srcBase.advanced(by: startByte), byteCount: availableBytes)
            }
        }
        return output
    }
}

private extension Data {
    func readLittleEndian<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
        let start = self.startIndex + offset
        let end   = start + MemoryLayout<T>.size
        return self.subdata(in: start..<end).withUnsafeBytes { ptr in
            T(littleEndian: ptr.load(as: T.self))
        }
    }
}
