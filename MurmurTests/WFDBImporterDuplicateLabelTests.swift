//
//  WFDBImporterDuplicateLabelTests.swift
//  MurmurTests
//
//  Regression for the duplicate-signal-label storage collision. VFDB (and
//  other PhysioNet records) name BOTH signals "ECG"; keying storage by
//  label alone made both channels resolve to channel_ECG.bin, so the
//  second signal clobbered the first and every channel rendered the
//  last-written signal's samples. The importer must give each signal its
//  own file and a distinguishable display name.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("WFDBImporter — duplicate signal labels")
struct WFDBImporterDuplicateLabelTests {

    /// Writes a minimal format-16 record whose two signals share the label
    /// "ECG" but carry DISTINCT constant data (ch0 = +100 adc, ch1 = −200
    /// adc), then imports it.
    private func makeDuplicateLabelRecord() throws -> (heaURL: URL, out: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vfdb-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let frames = 10
        let hea = """
        dup 2 250 \(frames)
        dup.dat 16 200 16 0 100 0 0 ECG
        dup.dat 16 200 16 0 -200 0 0 ECG
        """
        try hea.write(to: dir.appendingPathComponent("dup.hea"), atomically: true, encoding: .utf8)

        var dat = Data()
        for _ in 0..<frames {
            var a = Int16(100).littleEndian
            withUnsafeBytes(of: &a) { dat.append(contentsOf: $0) }
            var b = Int16(-200).littleEndian
            withUnsafeBytes(of: &b) { dat.append(contentsOf: $0) }
        }
        try dat.write(to: dir.appendingPathComponent("dup.dat"))

        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("dup.hea"), out)
    }

    @Test("Two signals sharing a label import as distinct channels with distinct data")
    func distinctChannels() throws {
        let (heaURL, out) = try makeDuplicateLabelRecord()
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: out)
        let channels = summary.recording.channels

        #expect(channels.count == 2)

        // Distinct storage files — the crux of the fix.
        #expect(channels[0].storageFileName != channels[1].storageFileName)

        // Distinguishable display names (LightWAVE-style suffixing).
        #expect(channels[0].name == "ECG:0")
        #expect(channels[1].name == "ECG:1")

        // Each channel reads back ITS OWN data: 100/200 = 0.5 mV and
        // −200/200 = −1.0 mV. A collision would make both equal.
        let s0 = try BinaryRecordingFile.readSamples(
            url: summary.directory.appendingPathComponent(channels[0].storageFileName),
            range: 0..<channels[0].sampleCount
        )
        let s1 = try BinaryRecordingFile.readSamples(
            url: summary.directory.appendingPathComponent(channels[1].storageFileName),
            range: 0..<channels[1].sampleCount
        )
        #expect(s0.allSatisfy { abs($0 - 0.5) < 1e-4 })
        #expect(s1.allSatisfy { abs($0 - (-1.0)) < 1e-4 })
    }
}
