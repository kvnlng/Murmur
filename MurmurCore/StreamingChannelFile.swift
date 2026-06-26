//
//  StreamingChannelFile.swift
//  Murmur
//
//  Buffered append-only writer for one channel's packed-Float32 binary file.
//  Batches writes (~32 KB / 8192 floats) to amortise syscall overhead, and
//  patches the header's sampleCount field in place at finalize() time.
//

import Foundation

final class StreamingChannelFile {
    let url: URL
    let sampleRateHz: Double
    let startTimeUnixMS: Int64

    private let handle: FileHandle
    private var buffer: [Float]
    private(set) var sampleCount: Int64

    static let bufferCapacity = 8192

    init(url: URL, sampleRateHz: Double, startTimeUnixMS: Int64) throws {
        self.url             = url
        self.sampleRateHz    = sampleRateHz
        self.startTimeUnixMS = startTimeUnixMS
        self.sampleCount     = 0
        self.buffer          = []
        self.buffer.reserveCapacity(Self.bufferCapacity)

        // Pre-write the placeholder header; sampleCount is patched at finalize().
        let placeholder = BinaryRecordingFile.encodeHeader(BinaryRecordingHeader(
            version: BinaryRecordingHeader.currentVersion,
            startTimeUnixMS: startTimeUnixMS,
            sampleRateHz: sampleRateHz,
            sampleCount: 0
        ))
        try placeholder.write(to: url, options: .atomic)
        self.handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    func append(_ value: Float) throws {
        buffer.append(value)
        sampleCount += 1
        if buffer.count >= Self.bufferCapacity { try flushBuffer() }
    }

    func appendNaN(count: Int) throws {
        guard count > 0 else { return }
        for _ in 0..<count {
            buffer.append(.nan)
            sampleCount += 1
            if buffer.count >= Self.bufferCapacity { try flushBuffer() }
        }
    }

    func finalize() throws {
        try flushBuffer()
        // Patch sampleCount at byte offset 32 (8 little-endian bytes).
        try handle.seek(toOffset: 32)
        var packed = sampleCount.littleEndian
        try handle.write(contentsOf: withUnsafeBytes(of: &packed) { Data($0) })
        try handle.close()
    }

    private func flushBuffer() throws {
        guard !buffer.isEmpty else { return }
        try buffer.withUnsafeBufferPointer { pointer in
            let raw = UnsafeRawBufferPointer(pointer)
            try handle.write(contentsOf: Data(raw))
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
