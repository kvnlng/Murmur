//
//  PyramidBuilder.swift
//  Murmur
//
//  Single-pass multi-level pyramid builder for one channel. Each raw sample is
//  fed in; the builder cascades it through every level (10× downsampling per
//  level) and buffers the resulting min/max bins to disk via PyramidLevelFile.
//
//  Cascading construction means each higher level reads its inputs from the bins
//  emitted by the level below it, not from raw samples — so the per-sample cost
//  is O(level_count) regardless of total downsampling factor.
//

import Foundation

struct PyramidConfig: Equatable, Sendable {
    /// Downsampling factor between adjacent levels (i.e. each level has 1/factor
    /// the bin count of the one below).
    let stride: Int
    /// Maximum number of levels to emit. Construction stops early if a level
    /// would have zero bins given the data size.
    let maxLevels: Int

    static let standard = PyramidConfig(stride: 10, maxLevels: 6)
}

final class PyramidBuilder {
    let channelName: String
    let config: PyramidConfig
    let baseSampleRate: Double
    let startTimeUnixMS: Int64
    let directory: URL

    private struct Accumulator {
        var inputs: Int = 0
        var min: Double = .infinity
        var max: Double = -.infinity
        var hasNonNaN: Bool = false

        var isEmpty: Bool { inputs <= 0 }

        mutating func feed(_ value: Double) {
            inputs += 1
            if !value.isNaN {
                hasNonNaN = true
                if value < self.min { self.min = value }
                if value > self.max { self.max = value }
            }
        }

        mutating func feedBin(_ bin: PyramidBin) {
            inputs += 1
            if !bin.isNaN {
                hasNonNaN = true
                if bin.min < self.min { self.min = bin.min }
                if bin.max > self.max { self.max = bin.max }
            }
        }

        func emit() -> PyramidBin {
            hasNonNaN ? PyramidBin(min: min, max: max) : .nan
        }

        mutating func reset() {
            inputs = 0
            min = .infinity
            max = -.infinity
            hasNonNaN = false
        }
    }

    /// One pyramid level's mutable state: an accumulator, a write buffer for
    /// completed bins, and the file handle that owns the on-disk file.
    private final class Level {
        let levelIndex: Int               // 1-based: L1, L2, …
        let binSamples: Int               // 10^levelIndex
        let url: URL
        let handle: FileHandle
        var accumulator = Accumulator()
        var binCount: Int64 = 0
        var pendingBins: [PyramidBin] = []
        static let flushThreshold = 4096

        init(levelIndex: Int, binSamples: Int, url: URL, header: BinaryRecordingHeader) throws {
            self.levelIndex = levelIndex
            self.binSamples = binSamples
            self.url = url
            let placeholder = BinaryRecordingFile.encodeHeader(header)
            try placeholder.write(to: url, options: .atomic)
            self.handle = try FileHandle(forUpdating: url)
            try handle.seekToEnd()
            pendingBins.reserveCapacity(Self.flushThreshold)
        }

        func emitBin(_ bin: PyramidBin) throws {
            pendingBins.append(bin)
            binCount += 1
            if pendingBins.count >= Self.flushThreshold {
                try flush()
            }
        }

        func flush() throws {
            guard !pendingBins.isEmpty else { return }
            var flat: [Double] = []
            flat.reserveCapacity(pendingBins.count * 2)
            for bin in pendingBins {
                flat.append(bin.min)
                flat.append(bin.max)
            }
            try flat.withUnsafeBufferPointer { pointer in
                try handle.write(contentsOf: Data(UnsafeRawBufferPointer(pointer)))
            }
            pendingBins.removeAll(keepingCapacity: true)
        }

        func finalize() throws {
            try flush()
            try handle.seek(toOffset: 32)
            var packed = binCount.littleEndian
            let countBytes = withUnsafeBytes(of: &packed) { Data($0) }
            try handle.write(contentsOf: countBytes)
            try handle.close()
        }
    }

    private var levels: [Level] = []
    private(set) var didFinalize = false

    init(
        channelName: String,
        config: PyramidConfig = .standard,
        baseSampleRate: Double,
        startTimeUnixMS: Int64,
        directory: URL
    ) throws {
        self.channelName = channelName
        self.config = config
        self.baseSampleRate = baseSampleRate
        self.startTimeUnixMS = startTimeUnixMS
        self.directory = directory

        for levelIndex in 1...config.maxLevels {
            let binSamples = Int(pow(Double(config.stride), Double(levelIndex)))
            let url = directory.appendingPathComponent("channel_\(safeFileName(channelName)).lod\(levelIndex).bin")
            let header = BinaryRecordingHeader(
                version: BinaryRecordingHeader.currentVersion,
                startTimeUnixMS: startTimeUnixMS,
                sampleRateHz: baseSampleRate / Double(binSamples),
                sampleCount: 0
            )
            let level = try Level(levelIndex: levelIndex, binSamples: binSamples, url: url, header: header)
            levels.append(level)
        }
    }

    /// Feeds one raw sample through every level.
    func append(_ value: Double) throws {
        levels[0].accumulator.feed(value)
        try cascade(from: 0)
    }

    func appendNaN(count: Int) throws {
        guard count > 0 else { return }
        for _ in 0..<count {
            try append(.nan)
        }
    }

    /// Flushes any partially-filled bins, finalizes file headers, and prevents
    /// further appends. The number of levels actually written equals the highest
    /// level that received at least one bin.
    func finalize() throws -> [PyramidLevel] {
        guard !didFinalize else { return manifest() }
        didFinalize = true
        for index in 0..<levels.count {
            try emitPartialBin(at: index)
        }
        for level in levels { try level.finalize() }
        return manifest()
    }

    private func cascade(from levelIndex: Int) throws {
        // Every level accumulates `stride` inputs per bin — raw samples for L1,
        // L1 bins for L2, etc. Once an accumulator hits stride, emit a bin and
        // cascade it into the next higher level.
        let level = levels[levelIndex]
        guard level.accumulator.inputs >= config.stride else { return }
        let bin = level.accumulator.emit()
        level.accumulator.reset()
        try level.emitBin(bin)
        if levelIndex + 1 < levels.count {
            levels[levelIndex + 1].accumulator.feedBin(bin)
            try cascade(from: levelIndex + 1)
        }
    }

    private func emitPartialBin(at levelIndex: Int) throws {
        let level = levels[levelIndex]
        guard !level.accumulator.isEmpty else { return }
        let bin = level.accumulator.emit()
        level.accumulator.reset()
        try level.emitBin(bin)
        if levelIndex + 1 < levels.count {
            levels[levelIndex + 1].accumulator.feedBin(bin)
        }
    }

    private func manifest() -> [PyramidLevel] {
        levels.compactMap { level in
            guard level.binCount > 0 else { return nil }
            return PyramidLevel(
                binSamples: level.binSamples,
                binCount: level.binCount,
                storageFileName: level.url.lastPathComponent
            )
        }
    }

    private func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce("") { "\($0)\($1)" }
    }
}
