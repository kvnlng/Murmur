//
//  WFDBFormat212Tests.swift
//  MurmurTests
//
//  Regression for the format-212 second-sample unpacking bug. WFDB 212
//  packs two 12-bit two's-complement samples into 3 bytes:
//    s0 = byte0 | (byte1 & 0x0F) << 8
//    s1 = byte2 | (byte1 & 0xF0) << 4
//  The decoder had s1 wrong ((byte2 << 4) | (byte1 >> 4)), which corrupted
//  every second-of-pair sample: the 2nd lead of a 2-channel record, and
//  every other sample of a single-channel record (CUDB cu01 rendered as
//  chaos). Existing 212 coverage used synthetic format-16 data, so it never
//  exercised the packing. This pins it with hand-packed bytes + known values.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("WFDB format 212 — sample unpacking")
struct WFDBFormat212Tests {

    /// Pack 12-bit two's-complement sample pairs into WFDB-212 bytes.
    private func pack212(_ samples: [Int]) -> Data {
        var data = Data()
        var i = 0
        while i < samples.count {
            let s0 = samples[i] & 0xFFF
            let s1 = (i + 1 < samples.count ? samples[i + 1] : 0) & 0xFFF
            data.append(UInt8(s0 & 0xFF))
            data.append(UInt8(((s0 >> 8) & 0x0F) | (((s1 >> 8) & 0x0F) << 4)))
            data.append(UInt8(s1 & 0xFF))
            i += 2
        }
        return data
    }

    private func makeRecord(samples: [Int], dir: URL) throws -> URL {
        let hea = """
        tri 1 250 \(samples.count)
        tri.dat 212 1 12 0 \(samples.first ?? 0) 0 0 ECG
        """
        try hea.write(to: dir.appendingPathComponent("tri.hea"), atomically: true, encoding: .utf8)
        try pack212(samples).write(to: dir.appendingPathComponent("tri.dat"))
        return dir.appendingPathComponent("tri.hea")
    }

    @Test("Both samples of a 212 triple decode to their true values")
    func unpacksBothSlots() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfdb212-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Mix of small + near-rail, positive + negative, in both pair slots.
        // gain=1 so the physical readback equals the ADC value.
        let samples = [100, -50, 2000, -2000, -8, -60]
        let heaURL = try makeRecord(samples: samples, dir: dir)

        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: out)
        let channel = try #require(summary.recording.channels.first)
        let decoded = try BinaryRecordingFile.readSamples(
            url: summary.directory.appendingPathComponent(channel.storageFileName),
            range: 0..<channel.sampleCount
        )

        #expect(decoded.count == samples.count)
        for (got, want) in zip(decoded, samples) {
            #expect(abs(got - Float(want)) < 1e-3,
                    "212 sample decoded \(got), expected \(want)")
        }
    }
}
