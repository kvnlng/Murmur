//
//  PyramidLevelFile.swift
//  Murmur
//
//  Binary file format and I/O for a single pyramid level.
//
//  A pyramid level is a downsampled view of one channel: each bin summarizes a
//  fixed number of source samples (binSamples) with its (min, max). At zoom
//  levels where one screen pixel spans many raw samples we render bins instead
//  of points — one vertical line from `min` to `max` per bin keeps the waveform
//  envelope visible.
//
//  Layout (same header struct as raw channel files):
//      [ 0..64 ]  BinaryRecordingHeader
//                   - sampleCount stores BIN COUNT (not double count)
//                   - sampleRateHz stores the effective bin rate (channelRate / binSamples)
//      [64..  ]  Float64 × 2 × binCount   (min0, max0, min1, max1, …)
//

import Foundation

struct PyramidBin: Equatable, Sendable {
    var min: Double
    var max: Double

    static let nan = PyramidBin(min: .nan, max: .nan)

    var isNaN: Bool { min.isNaN || max.isNaN }
}

enum PyramidLevelFile {
    /// Returns the offset, in bytes, of the on-disk body where the bin data begins.
    static let bodyStart = BinaryRecordingHeader.headerByteSize

    /// Writes a freshly-built pyramid level (header + bins) to `url`.
    static func write(bins: [PyramidBin], header: BinaryRecordingHeader, to url: URL) throws {
        var data = BinaryRecordingFile.encodeHeader(header)
        data.reserveCapacity(bodyStart + bins.count * 2 * MemoryLayout<Double>.size)
        var flat: [Double] = []
        flat.reserveCapacity(bins.count * 2)
        for bin in bins {
            flat.append(bin.min)
            flat.append(bin.max)
        }
        flat.withUnsafeBufferPointer { pointer in
            data.append(UnsafeRawBufferPointer(pointer).bindMemory(to: UInt8.self))
        }
        try data.write(to: url, options: .atomic)
    }

    /// Opens a memory-mapped view over the pyramid file for many random reads.
    static func mappedAccess(url: URL) throws -> MappedPyramidAccess {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let header = try BinaryRecordingFile.decodeHeader(data)
        return MappedPyramidAccess(data: data, header: header)
    }
}

struct MappedPyramidAccess: Sendable {
    let data: Data
    let header: BinaryRecordingHeader

    var binCount: Int64 { header.sampleCount }

    /// Reads the bins in `range` (bin indices). Out-of-range bins come back as NaN.
    func bins(range: Range<Int64>) -> [PyramidBin] {
        let binSize = MemoryLayout<Double>.size * 2
        let startByte = PyramidLevelFile.bodyStart + Int(range.lowerBound) * binSize
        let requestedByteCount = Int(range.count) * binSize
        var output = [PyramidBin](repeating: .nan, count: Int(range.count))
        let availableByteCount = max(0, min(requestedByteCount, data.count - startByte))
        guard availableByteCount > 0 else { return output }
        data.withUnsafeBytes { sourceBytes in
            guard let sourceBase = sourceBytes.baseAddress else { return }
            let doublePointer = sourceBase.advanced(by: startByte).assumingMemoryBound(to: Double.self)
            let pairs = availableByteCount / binSize
            for binIndex in 0..<pairs {
                output[binIndex] = PyramidBin(
                    min: doublePointer[binIndex * 2],
                    max: doublePointer[binIndex * 2 + 1]
                )
            }
        }
        return output
    }
}
