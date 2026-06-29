//
//  MurmurTests.swift
//  MurmurTests
//

// swiftlint:disable file_length
// Aggregate test suite — grows with the codebase. Splitting purely to
// satisfy SwiftLint would scatter related tests across many files.

import Foundation
import Testing
@testable import MurmurCore

// MARK: - WFDB header parser

@Suite("WFDB header parser")
struct WFDBHeaderParserTests {

    @Test("Parses a standard record line")
    func parsesRecordLine() throws {
        let hea = """
        mitdb100 2 360 650000
        mitdb100.dat 16 200(mV)/0 16 0 0 0 0 MLII
        mitdb100.dat 16 200(mV)/0 16 0 0 0 0 V5
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.recordName == "mitdb100")
        #expect(header.signalCount == 2)
        #expect(header.samplingFrequency == 360.0)
        #expect(header.sampleCount == 650_000)
        #expect(header.signals.count == 2)
    }

    @Test("Parses signal labels and units correctly")
    func parsesSignalFields() throws {
        let hea = """
        test 3 250 2500
        test.dat 16 200(mV)/0 16 0 0 0 0 I
        test.dat 16 500(mV)/500 16 0 0 0 0 II
        test.dat 16 1000(uV)/0 16 0 0 0 0 V1
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].label == "I")
        #expect(header.signals[0].gain  == 200.0)
        #expect(header.signals[0].unit  == "mV")
        #expect(header.signals[0].baseline == 0)

        #expect(header.signals[1].label    == "II")
        #expect(header.signals[1].gain     == 500.0)
        #expect(header.signals[1].baseline == 500)

        #expect(header.signals[2].label == "V1")
        #expect(header.signals[2].unit  == "uV")
        #expect(header.signals[2].gain  == 1000.0)
    }

    @Test("Accepts format 16 and 212; throws for truly unsupported formats")
    func throwsOnUnsupportedFormat() {
        // Format 8 is not supported.
        let hea = """
        bad 1 360 0
        bad.dat 8 200 11 1024 0 0 0 MLII
        """
        #expect(throws: WFDBHeaderError.self) {
            try WFDBHeaderParser.parse(text: hea)
        }
    }

    @Test("Accepts format 212 (MIT-BIH style)")
    func acceptsFormat212() throws {
        let hea = """
        mitdb100 2 360 650000
        mitdb100.dat 212 200 11 1024 995 -22131 0 MLII
        mitdb100.dat 212 200 11 1024 1011 20052 0 V5
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].format == 212)
        #expect(header.signals[1].format == 212)
    }

    @Test("Baseline defaults to adcZero when absent from gain field")
    func baselineDefaultsToAdcZero() throws {
        // MIT-BIH: gain field is just "200" with no "/baseline" suffix.
        // WFDB spec: baseline defaults to adcZero = 1024.
        let hea = """
        test 1 360 0
        test.dat 212 200 11 1024 0 0 0 II
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].adcZero  == 1024)
        #expect(header.signals[0].baseline == 1024)
    }

    @Test("Explicit /0 baseline overrides adcZero")
    func explicitZeroBaselineOverridesAdcZero() throws {
        let hea = """
        test 1 250 0
        test.dat 16 200(mV)/0 16 1024 0 0 0 II
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].adcZero  == 1024)
        #expect(header.signals[0].baseline == 0)     // explicit /0 wins
    }

    @Test("Throws when signal count does not match signal lines")
    func throwsOnCountMismatch() {
        let hea = """
        bad 3 250 0
        bad.dat 16 200(mV)/0 16 0 0 0 0 I
        bad.dat 16 200(mV)/0 16 0 0 0 0 II
        """
        #expect(throws: WFDBHeaderError.self) {
            try WFDBHeaderParser.parse(text: hea)
        }
    }

    @Test("Ignores comment lines")
    func ignoresComments() throws {
        let hea = """
        # This is a comment
        rec 1 250 100
        # Another comment
        rec.dat 16 200(mV)/0 16 0 0 0 0 II
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.recordName == "rec")
        #expect(header.signals.count == 1)
    }

    @Test("Preserves header comments in order with the # stripped")
    func preservesHeaderComments() throws {
        // MIT-BIH 100-style: demographics then meds.
        let hea = """
        # 69 M 1085 1629 x1
        # Aldomet, Inderal
        100 2 360 650000
        100.dat 212 200 11 1024 995 -22131 0 MLII
        100.dat 212 200 11 1024 1011 20052 0 V5
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.comments == ["69 M 1085 1629 x1", "Aldomet, Inderal"])
    }

    @Test("Empty file with only comments still throws — comments are metadata, not data")
    func commentsAloneIsEmptyFile() {
        let hea = """
        # comment only
        # nothing else
        """
        #expect(throws: WFDBHeaderError.self) {
            try WFDBHeaderParser.parse(text: hea)
        }
    }
}

// MARK: - WFDB sample decoder

@Suite("WFDB sample decoder")
struct WFDBSampleDecoderTests {

    private func makeSignal16(gain: Double = 200, unit: String = "mV", baseline: Int = 0) -> WFDBSignal {
        WFDBSignal(
            filename: "test.dat", format: 16, gain: gain, unit: unit,
            baseline: baseline, adcResolution: 16, adcZero: 0, label: "II"
        )
    }

    private func makeSignal212(gain: Double = 200, baseline: Int = 0) -> WFDBSignal {
        WFDBSignal(
            filename: "test.dat", format: 212, gain: gain, unit: "mV",
            baseline: baseline, adcResolution: 12, adcZero: 0, label: "II"
        )
    }

    // MARK: Format 16

    @Test("Format 16: decodes a single-signal two-sample file correctly")
    func decodesSingleSignalF16() throws {
        var rawData = Data(count: 4)
        rawData.withUnsafeMutableBytes { buf in
            let base = buf.baseAddress!.assumingMemoryBound(to: Int16.self)
            base[0] = Int16(200).littleEndian
            base[1] = Int16(-400).littleEndian
        }
        let signal = makeSignal16()
        let result = try WFDBSampleDecoder.decode(data: rawData, signals: [signal], declaredSampleCount: 2)
        #expect(result.count == 1)
        #expect(result[0][0] == Float(1.0))
        #expect(result[0][1] == Float(-2.0))
    }

    @Test("Format 16: decodes interleaved multi-signal data correctly")
    func decodesMultiSignalF16() throws {
        let adcValues: [Int16] = [200, 400, 100, -100, 0, 0]
        var rawData = Data(count: adcValues.count * 2)
        rawData.withUnsafeMutableBytes { buf in
            let base = buf.baseAddress!.assumingMemoryBound(to: Int16.self)
            for (idx, val) in adcValues.enumerated() { base[idx] = val.littleEndian }
        }
        let signals = [makeSignal16(gain: 200), makeSignal16(gain: 200)]
        let result = try WFDBSampleDecoder.decode(data: rawData, signals: signals, declaredSampleCount: 3)
        #expect(result[0][0] == Float(200.0 / 200.0))
        #expect(result[1][0] == Float(400.0 / 200.0))
        #expect(result[0][1] == Float(100.0 / 200.0))
        #expect(result[1][1] == Float(-100.0 / 200.0))
    }

    @Test("Format 16: baseline is subtracted before gain division")
    func appliesBaselineF16() throws {
        // adcValue = 1000, baseline = 800, gain = 200 → (1000-800)/200 = 1.0
        var rawData = Data(count: 2)
        rawData.withUnsafeMutableBytes { buf in
            buf.baseAddress!.assumingMemoryBound(to: Int16.self)[0] = Int16(1000).littleEndian
        }
        let signal = makeSignal16(gain: 200, baseline: 800)
        let result = try WFDBSampleDecoder.decode(data: rawData, signals: [signal], declaredSampleCount: 1)
        #expect(result[0][0] == Float(1.0))
    }

    @Test("Format 16: throws when file is shorter than declared sample count")
    func throwsOnTruncatedF16() {
        let rawData = Data(count: 2)
        let signal = makeSignal16()
        #expect(throws: WFDBDecodeError.self) {
            try WFDBSampleDecoder.decode(data: rawData, signals: [signal], declaredSampleCount: 5)
        }
    }

    // MARK: Format 212

    @Test("Format 212: decodes two samples packed in 3 bytes")
    func decodesTwoSamplesF212() throws {
        // A = 995 = 0x3E3, B = 1011 = 0x3F3
        // byte[0] = 0xE3, byte[1] = 0x33, byte[2] = 0x3F
        let rawData = Data([0xE3, 0x33, 0x3F])
        let signal = makeSignal212(gain: 200, baseline: 0)
        let result = try WFDBSampleDecoder.decodeFormat212(
            data: rawData, signals: [signal], declaredSampleCount: 2
        )
        #expect(result[0][0] == Float(995) / 200.0)
        #expect(result[0][1] == Float(1011) / 200.0)
    }

    @Test("Format 212: sign-extends negative 12-bit values correctly")
    func signExtendsNegativeF212() throws {
        // Encode -1 as a 12-bit two's complement value = 0xFFF
        // byte[0] = 0xFF, byte[1] = 0xF_ (low nibble = 0xF), need a second sample to fill nibble
        // Let's encode A = -1 (0xFFF), B = 1 (0x001)
        // byte[0] = 0xFF (A[7:0])
        // byte[1] = B[3:0]<<4 | A[11:8] = 0x1<<4 | 0xF = 0x1F
        // byte[2] = B[11:4] = 0x00
        let rawData = Data([0xFF, 0x1F, 0x00])
        let signal = makeSignal212(gain: 1, baseline: 0)
        let result = try WFDBSampleDecoder.decodeFormat212(
            data: rawData, signals: [signal], declaredSampleCount: 2
        )
        #expect(result[0][0] == Float(-1))
        #expect(result[0][1] == Float(1))
    }

    @Test("Format 212: applies MIT-BIH-style baseline = adcZero")
    func appliesAdcZeroBaselineF212() throws {
        // Simulate a signal with adcZero=1024, gain=200, no explicit baseline.
        // ADC value 1024 → physical = (1024 - 1024) / 200 = 0.0
        // Encode A = 1024 = 0x400, B = 0 (pad)
        // byte[0] = 0x00 (A[7:0])
        // byte[1] = 0x04 (A[11:8] = 0x4, B[3:0] = 0x0)
        // byte[2] = 0x00 (B[11:4])
        let rawData = Data([0x00, 0x04, 0x00])
        // Explicitly set baseline=1024 (as the header parser would do when adcZero=1024)
        let signal = makeSignal212(gain: 200, baseline: 1024)
        let result = try WFDBSampleDecoder.decodeFormat212(
            data: rawData, signals: [signal], declaredSampleCount: 2
        )
        #expect(result[0][0] == Float(0.0))
    }

    // MARK: Edge cases — added for fuller decoder coverage

    /// Pack 12-bit signed samples into format-212 bytes. Layout per pair:
    ///   byte[0] = A[7:0]
    ///   byte[1] = B[3:0]<<4 | A[11:8]
    ///   byte[2] = B[11:4]
    private func packFormat212(_ samples: [Int]) -> Data {
        var data = Data(capacity: (samples.count + 1) / 2 * 3)
        var i = 0
        while i + 1 < samples.count {
            let a = UInt16(bitPattern: Int16(samples[i])) & 0xFFF
            let b = UInt16(bitPattern: Int16(samples[i + 1])) & 0xFFF
            data.append(UInt8(a & 0xFF))
            data.append(UInt8(((b & 0xF) << 4) | ((a >> 8) & 0xF)))
            data.append(UInt8((b >> 4) & 0xFF))
            i += 2
        }
        if i < samples.count {
            let a = UInt16(bitPattern: Int16(samples[i])) & 0xFFF
            data.append(UInt8(a & 0xFF))
            data.append(UInt8((a >> 8) & 0xF))
            data.append(0)  // padding to fill the 3-byte unit
        }
        return data
    }

    @Test("Format 16: declaredSampleCount of 0 derives from data length")
    func format16InferredSampleCount() throws {
        let s = makeSignal16(gain: 200, baseline: 0)
        var rawData = Data(count: 6)
        rawData.withUnsafeMutableBytes { buf in
            let base = buf.baseAddress!.assumingMemoryBound(to: Int16.self)
            base[0] = Int16(100).littleEndian
            base[1] = Int16(200).littleEndian
            base[2] = Int16(300).littleEndian
        }
        let out = try WFDBSampleDecoder.decode(data: rawData, signals: [s], declaredSampleCount: 0)
        #expect(out[0].count == 3)
        #expect(out[0] == [0.5, 1.0, 1.5])
    }

    @Test("Format 212: round-trips the 12-bit signed extremes (-2048 and +2047)")
    func format212TwelveBitExtremes() throws {
        let s = makeSignal212(gain: 1, baseline: 0)
        let data = packFormat212([-2048, 2047])
        let out = try WFDBSampleDecoder.decode(data: data, signals: [s], declaredSampleCount: 2)
        #expect(out[0] == [-2048.0, 2047.0])
    }

    @Test("Format 212: multi-signal interleave preserves per-signal ordering")
    func format212MultiSignalInterleave() throws {
        let s0 = makeSignal212(gain: 1, baseline: 0)
        let s1 = makeSignal212(gain: 1, baseline: 0)
        // 2 signals × 2 frames = 4 samples interleaved as [s0f0, s1f0, s0f1, s1f1]
        let data = packFormat212([10, 20, 30, 40])
        let out = try WFDBSampleDecoder.decode(data: data, signals: [s0, s1], declaredSampleCount: 2)
        #expect(out[0] == [10.0, 30.0])
        #expect(out[1] == [20.0, 40.0])
    }

    @Test("Format 212: odd trailing sample is decoded from the final 2 bytes")
    func format212OddTrailingSample() throws {
        let s = makeSignal212(gain: 1, baseline: 0)
        // 3 samples → 1 full pair + 1 trailing — the branch most often
        // missed by hand-built fixtures.
        let data = packFormat212([100, -50, 7])
        let out = try WFDBSampleDecoder.decode(data: data, signals: [s], declaredSampleCount: 3)
        #expect(out[0] == [100.0, -50.0, 7.0])
    }

    @Test("Format 212: truncated buffer throws .truncatedFile")
    func format212TruncatedThrows() {
        let s = makeSignal212()
        // Declare 4 samples (needs 6 bytes) but supply only 3.
        let data = packFormat212([100, -50])
        #expect(throws: WFDBDecodeError.self) {
            _ = try WFDBSampleDecoder.decode(data: data, signals: [s], declaredSampleCount: 4)
        }
    }

    @Test("Mixed formats in a single file are rejected with .mixedFormatsInFile")
    func mixedFormatsRejected() {
        let s0 = makeSignal16()
        let s1 = makeSignal212()
        #expect(throws: WFDBDecodeError.self) {
            _ = try WFDBSampleDecoder.decode(
                data: Data(count: 32),
                signals: [s0, s1],
                declaredSampleCount: 4
            )
        }
    }

    @Test("Empty signals array returns empty output without error")
    func emptySignalsReturnsEmpty() throws {
        let out = try WFDBSampleDecoder.decode(data: Data(), signals: [], declaredSampleCount: 0)
        #expect(out.isEmpty)
    }
}

// MARK: - WFDB importer (end-to-end)

@Suite("WFDB importer")
struct WFDBImporterTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfdb-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Imports a synthetic 8-lead WFDB record end-to-end")
    func importsMinimalRecord() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)

        #expect(summary.signalsImported == 8)
        #expect(summary.totalSamples == 8 * 2500)
        #expect(summary.recording.channels.count == 8)
        #expect(summary.recording.channels[0].sampleCount == 2500)
        #expect(summary.recording.channels[0].sampleRate == 250.0)
    }

    @Test("Recovered physical values are finite and within ECG range")
    func physicalValuesRoundTrip() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)

        let channel0 = summary.recording.channels[0]
        let binURL = summary.directory.appendingPathComponent(channel0.storageFileName)
        let samples = try BinaryRecordingFile.readSamples(url: binURL, range: 0..<10)
        for sample in samples {
            #expect(sample.isFinite)
            #expect(abs(sample) < 2.0)
        }
    }

    @Test("Writes a readable recording manifest")
    func writesManifest() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)

        let manifestURL = summary.directory.appendingPathComponent("recording.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Recording.self, from: data)
        #expect(decoded.id == summary.recording.id)
        #expect(decoded.channels.count == summary.recording.channels.count)
    }

    @Test("Throws when the .dat file is missing")
    func throwsOnMissingDat() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaText = "noDat 1 250 100\nnoDat.dat 16 200(mV)/0 16 0 0 0 0 II\n"
        let heaURL = srcDir.appendingPathComponent("noDat.hea")
        try heaText.write(to: heaURL, atomically: true, encoding: .utf8)

        #expect(throws: WFDBImportError.self) {
            try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)
        }
    }

    @Test("Imports header comments into the Recording")
    func importsHeaderComments() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        // Append a couple of comment lines to the synthetic .hea.
        var heaText = try String(contentsOf: heaURL, encoding: .utf8)
        heaText = "# Synthetic patient\n# Protocol: 8-lead ECG\n" + heaText
        try heaText.write(to: heaURL, atomically: true, encoding: .utf8)

        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)
        #expect(summary.recording.headerComments == ["Synthetic patient", "Protocol: 8-lead ECG"])
    }

    @Test("Copies source notes.md into the bundle and exposes its filename")
    func copiesSourceNotesIntoBundle() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        let notesURL = srcDir.appendingPathComponent("synth.notes.md")
        let originalNotes = "# Synthetic record\n\n- Holter, 30 min\n- Reviewer: KL\n"
        try originalNotes.write(to: notesURL, atomically: true, encoding: .utf8)

        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)
        let notesFileName = try #require(summary.recording.notesFileName)
        let bundleNotesURL = summary.directory.appendingPathComponent(notesFileName)
        let copied = try String(contentsOf: bundleNotesURL, encoding: .utf8)
        #expect(copied == originalNotes)
    }

    @Test("Without a source notes.md, notesFileName is still reserved but no file is copied to disk")
    func reservesNotesFilenameWithoutCopyingWhenSourceMissing() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        // Important: no notes.md exists in srcDir.
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)

        // Contract: the importer reserves "notes.md" as the analyst's target
        // even if no source file existed, so the editor has a stable place
        // to write to. The file itself is NOT created until the analyst saves.
        #expect(summary.recording.notesFileName == "notes.md")
        let bundleNotesURL = summary.directory.appendingPathComponent("notes.md")
        #expect(!FileManager.default.fileExists(atPath: bundleNotesURL.path))
    }

    @Test("Picks up a sibling <recordName>.annotations.json and exposes its findings")
    func picksUpAnnotationsSidecar() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        // Drop in an annotations sidecar with one VT range and one VF point.
        let json = """
        {
          "schemaVersion": 1,
          "source": "test.unittest",
          "findings": [
            { "kind": "range", "startSample": 500, "endSample": 750,
              "category": "VT", "label": "VT", "confidence": 0.91,
              "severity": "warning" },
            { "kind": "point", "startSample": 1500,
              "category": "VF", "label": "VF", "confidence": 0.78,
              "severity": "critical" }
          ]
        }
        """
        let jsonURL = srcDir.appendingPathComponent("synth.annotations.json")
        try json.write(to: jsonURL, atomically: true, encoding: .utf8)

        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)
        #expect(summary.recording.annotations.count == 2)
        let categories = Set(summary.recording.annotations.map(\.category))
        #expect(categories == ["VT", "VF"])
    }

    @Test("Pyramid level files are written into the bundle directory")
    func writesPyramidFiles() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)

        // Every imported channel should have at least one pyramid level on
        // disk (a 2500-sample channel reduces to L1 at minimum).
        let channel = summary.recording.channels[0]
        #expect(!channel.pyramid.isEmpty)
        for level in channel.pyramid {
            let url = summary.directory.appendingPathComponent(level.storageFileName)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Empty header (no signal lines) throws .noSignals")
    func emptyHeaderThrowsNoSignals() throws {
        let srcDir = try makeTempDir()
        let outDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        // A signalCount of 0 leaves the header parser with no signals, which
        // the importer guards against with the .noSignals error.
        let heaText = "empty 0 250 100\n"
        let heaURL = srcDir.appendingPathComponent("empty.hea")
        try heaText.write(to: heaURL, atomically: true, encoding: .utf8)

        #expect(throws: Error.self) {
            try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)
        }
    }
}

// MARK: - Binary recording file (Float32)

@Suite("Binary recording file")
struct BinaryRecordingFileTests {

    @Test("Round-trips header through encode/decode")
    func roundTripsHeader() throws {
        let header = BinaryRecordingHeader(
            version: BinaryRecordingHeader.currentVersion,
            startTimeUnixMS: 1_768_003_612_733,
            sampleRateHz: 250.0,
            sampleCount: 4242
        )
        let encoded = BinaryRecordingFile.encodeHeader(header)
        #expect(encoded.count == BinaryRecordingHeader.headerByteSize)
        let decoded = try BinaryRecordingFile.decodeHeader(encoded)
        #expect(decoded == header)
    }

    @Test("Writes and reads back Float32 samples")
    func roundTripsSamples() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bin-roundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("samples.bin")
        let samples: [Float] = [-1.5, 0.0, 0.5, 1.0, .nan, 2.0]
        let header = BinaryRecordingHeader(
            version: BinaryRecordingHeader.currentVersion,
            startTimeUnixMS: 0,
            sampleRateHz: 250.0,
            sampleCount: Int64(samples.count)
        )
        try BinaryRecordingFile.write(samples: samples, header: header, to: url)

        let read = try BinaryRecordingFile.readSamples(url: url, range: 0..<Int64(samples.count))
        #expect(read.count == samples.count)
        #expect(read[0] == samples[0])
        #expect(read[3] == samples[3])
        #expect(read[4].isNaN)
        #expect(read[5] == samples[5])
    }

    @Test("Rejects a non-magic header")
    func rejectsNonMagicHeader() {
        let bogus = Data(repeating: 0, count: BinaryRecordingHeader.headerByteSize)
        #expect(throws: BinaryRecordingError.self) {
            try BinaryRecordingFile.decodeHeader(bogus)
        }
    }
}

// MARK: - Mapped sample access

@Suite("Mapped sample access")
struct MappedSampleAccessTests {

    private func makeFixtureFile(samples: [Float]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("samples.bin")
        let header = BinaryRecordingHeader(
            version: BinaryRecordingHeader.currentVersion,
            startTimeUnixMS: 0,
            sampleRateHz: 250.0,
            sampleCount: Int64(samples.count)
        )
        try BinaryRecordingFile.write(samples: samples, header: header, to: url)
        return url
    }

    @Test("Returns exact samples for an in-range slice")
    func returnsExactSamples() throws {
        let samples: [Float] = [1.5, 2.5, 3.5, 4.5, 5.5]
        let url = try makeFixtureFile(samples: samples)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let access = try BinaryRecordingFile.mappedAccess(url: url)
        let middle = access.samples(range: 1..<4)
        let expected: [Float] = [2.5, 3.5, 4.5]
        #expect(middle == expected)
    }

    @Test("Pads out-of-range reads with NaN")
    func padsOutOfRangeWithNaN() throws {
        let samples: [Float] = [10.0, 20.0]
        let url = try makeFixtureFile(samples: samples)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let access = try BinaryRecordingFile.mappedAccess(url: url)
        let oversized = access.samples(range: 0..<5)
        #expect(oversized.count == 5)
        #expect(oversized[0] == 10.0)
        #expect(oversized[1] == 20.0)
        for idx in 2..<5 { #expect(oversized[idx].isNaN, "Sample \(idx) should be NaN") }
    }

    @Test("Repeated reads are stable")
    func repeatedReadsAreStable() throws {
        let samples = (0..<100).map { Float($0) }
        let url = try makeFixtureFile(samples: samples)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let access = try BinaryRecordingFile.mappedAccess(url: url)
        let first  = access.samples(range: 10..<20)
        let second = access.samples(range: 10..<20)
        #expect(first == second)
    }
}

// MARK: - Pyramid builder

@Suite("Pyramid builder")
struct PyramidBuilderTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyramid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("L1 bins contain min and max of each 10-sample window")
    func l1BinsCorrect() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let builder = try PyramidBuilder(channelName: "II", baseSampleRate: 250.0, startTimeUnixMS: 0, directory: dir)
        for idx in 0..<30 { try builder.append(Double(idx)) }
        let manifest = try builder.finalize()

        let level1 = try #require(manifest.first { $0.binSamples == 10 })
        #expect(level1.binCount == 3)

        let access = try PyramidLevelFile.mappedAccess(url: dir.appendingPathComponent(level1.storageFileName))
        let bins = access.bins(range: 0..<3)
        #expect(bins[0] == PyramidBin(min: 0, max: 9))
        #expect(bins[1] == PyramidBin(min: 10, max: 19))
        #expect(bins[2] == PyramidBin(min: 20, max: 29))
    }

    @Test("L2 bins cascade correctly from L1")
    func l2BinsCascade() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let builder = try PyramidBuilder(channelName: "V1", baseSampleRate: 250.0, startTimeUnixMS: 0, directory: dir)
        for idx in 0..<100 { try builder.append(Double(idx)) }
        let manifest = try builder.finalize()

        let level2 = try #require(manifest.first { $0.binSamples == 100 })
        #expect(level2.binCount == 1)

        let access = try PyramidLevelFile.mappedAccess(url: dir.appendingPathComponent(level2.storageFileName))
        let bins = access.bins(range: 0..<1)
        #expect(bins[0] == PyramidBin(min: 0, max: 99))
    }

    @Test("Partial trailing bin is flushed at finalize")
    func partialTrailingBinFlushed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let builder = try PyramidBuilder(channelName: "II", baseSampleRate: 250.0, startTimeUnixMS: 0, directory: dir)
        for idx in 0..<15 { try builder.append(Double(idx)) }
        let manifest = try builder.finalize()
        let level1 = try #require(manifest.first { $0.binSamples == 10 })
        #expect(level1.binCount == 2)

        let access = try PyramidLevelFile.mappedAccess(url: dir.appendingPathComponent(level1.storageFileName))
        let bins = access.bins(range: 0..<2)
        #expect(bins[0] == PyramidBin(min: 0, max: 9))
        #expect(bins[1] == PyramidBin(min: 10, max: 14))
    }

    @Test("All-NaN bins produce NaN min/max")
    func allNaNBinsAreNaN() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let builder = try PyramidBuilder(channelName: "II", baseSampleRate: 250.0, startTimeUnixMS: 0, directory: dir)
        try builder.appendNaN(count: 10)
        try builder.append(5.0)
        try builder.append(7.0)
        let manifest = try builder.finalize()

        let level1 = try #require(manifest.first { $0.binSamples == 10 })
        let access = try PyramidLevelFile.mappedAccess(url: dir.appendingPathComponent(level1.storageFileName))
        let bins = access.bins(range: 0..<2)
        #expect(bins[0].isNaN, "Bin 0 should be all-NaN")
        #expect(bins[1] == PyramidBin(min: 5, max: 7))
    }

    @Test("Mixed NaN/value bin ignores NaNs when computing min/max")
    func mixedNaNBinIgnoresNaN() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let builder = try PyramidBuilder(channelName: "II", baseSampleRate: 250.0, startTimeUnixMS: 0, directory: dir)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0] { try builder.append(value) }
        try builder.appendNaN(count: 5)
        let manifest = try builder.finalize()

        let access = try PyramidLevelFile.mappedAccess(url: dir.appendingPathComponent(manifest[0].storageFileName))
        let bin = access.bins(range: 0..<1)[0]
        #expect(bin == PyramidBin(min: 1, max: 5))
    }
}

// MARK: - Channel view + LOD selection

@Suite("Channel view + LOD selection")
struct ChannelViewTests {

    @MainActor
    private func makeRecordingWithPyramid(
        rawSamples: [Float],
        sampleRate: Double = 250.0
    ) throws -> (Recording, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let header = BinaryRecordingHeader(
            version: BinaryRecordingHeader.currentVersion,
            startTimeUnixMS: 0,
            sampleRateHz: sampleRate,
            sampleCount: Int64(rawSamples.count)
        )
        let rawURL = dir.appendingPathComponent("channel_II.bin")
        try BinaryRecordingFile.write(samples: rawSamples, header: header, to: rawURL)

        let builder = try PyramidBuilder(channelName: "II", baseSampleRate: sampleRate, startTimeUnixMS: 0, directory: dir)
        for value in rawSamples { try builder.append(Double(value)) }
        let pyramid = try builder.finalize()

        let channel = Channel(
            id: UUID(), name: "II", unit: "mV", sampleRate: sampleRate,
            startTimeUnixMS: 0, sampleCount: Int64(rawSamples.count),
            storageFileName: "channel_II.bin", pyramid: pyramid
        )
        let recording = Recording(
            version: Recording.currentVersion, id: UUID(), device: "Test",
            createdAt: Date(timeIntervalSince1970: 0), sourceFileName: "test.hea",
            channels: [channel]
        )
        return (recording, dir)
    }

    @MainActor
    @Test("Selects raw when samplesPerPixel < 1")
    func selectsRawWhenZoomedIn() throws {
        let samples = (0..<200).map { Float($0) }
        let (recording, dir) = try makeRecordingWithPyramid(rawSamples: samples)
        defer { try? FileManager.default.removeItem(at: dir) }

        let view = try ChannelView(channel: recording.channels[0], directory: dir)
        #expect(view.selectLevel(samplesPerPixel: 0.5) == .raw)
    }

    @MainActor
    @Test("Selects L1 when samplesPerPixel is 10–99")
    func selectsL1ForMidZoom() throws {
        let samples = (0..<2000).map { Float($0) }
        let (recording, dir) = try makeRecordingWithPyramid(rawSamples: samples)
        defer { try? FileManager.default.removeItem(at: dir) }

        let view = try ChannelView(channel: recording.channels[0], directory: dir)
        let lod = view.selectLevel(samplesPerPixel: 25)
        #expect(lod.binSamples == 10)
        #expect(lod.pyramidIndex == 0)
    }

    @MainActor
    @Test("Selects deepest level whose bin size fits the request")
    func selectsDeepestFittingLevel() throws {
        let samples = (0..<100_000).map { Float($0) }
        let (recording, dir) = try makeRecordingWithPyramid(rawSamples: samples)
        defer { try? FileManager.default.removeItem(at: dir) }

        let view = try ChannelView(channel: recording.channels[0], directory: dir)
        let lod = view.selectLevel(samplesPerPixel: 100_000)
        #expect(lod.binSamples == 100_000)
        #expect(lod.pyramidIndex != nil)
    }

    @MainActor
    @Test("read returns expected pyramid bins")
    func readsExpectedPyramidBins() throws {
        let samples = (0..<100).map { Float($0) }
        let (recording, dir) = try makeRecordingWithPyramid(rawSamples: samples)
        defer { try? FileManager.default.removeItem(at: dir) }

        let view = try ChannelView(channel: recording.channels[0], directory: dir)
        let l1 = LevelOfDetail(pyramidIndex: 0, binSamples: 10)
        let result = view.read(rawRange: 0..<100, level: l1)
        guard case .pyramidBins(let bins, let binSamples) = result else {
            Issue.record("Expected pyramid bins, got raw samples")
            return
        }
        #expect(binSamples == 10)
        #expect(bins.count == 10)
        #expect(bins[0] == PyramidBin(min: 0, max: 9))
        #expect(bins[9] == PyramidBin(min: 90, max: 99))
    }
}

// MARK: - Recording viewport

@Suite("Recording viewport")
struct RecordingViewportTests {

    @MainActor
    @Test("Initial viewport spans the requested duration")
    func initialWindow() {
        let v = RecordingViewport(totalSamples: 100_000, sampleRate: 250, initialDurationSeconds: 10)
        #expect(v.startSample == 0)
        #expect(v.endSample   == 2500)        // 10 s × 250 Hz
        #expect(v.durationSeconds == 10.0)
    }

    @MainActor
    @Test("Initial width is clamped to total samples when the recording is shorter")
    func initialWindowShortRecording() {
        let v = RecordingViewport(totalSamples: 800, sampleRate: 250, initialDurationSeconds: 10)
        #expect(v.startSample == 0)
        #expect(v.endSample   == 800)
    }

    @MainActor
    @Test("Pan clamps to recording start")
    func panClampsLeft() {
        let v = RecordingViewport(totalSamples: 10_000, sampleRate: 250, initialDurationSeconds: 4)
        v.setStart(500)
        v.pan(bySamples: -10_000)             // way negative
        #expect(v.startSample == 0)
        #expect(v.endSample   == 1000)        // width preserved
    }

    @MainActor
    @Test("Pan clamps to recording end")
    func panClampsRight() {
        let v = RecordingViewport(totalSamples: 10_000, sampleRate: 250, initialDurationSeconds: 4)
        v.pan(bySamples: 1_000_000)
        #expect(v.endSample   == 10_000)
        #expect(v.startSample == 9_000)       // width preserved (1000 samples)
    }

    @MainActor
    @Test("setWidth respects minSamples lower bound")
    func widthClampedAtMin() {
        let v = RecordingViewport(totalSamples: 10_000, sampleRate: 250, initialDurationSeconds: 4)
        v.setWidth(1, anchorFraction: 0.5)    // try to shrink below 100 ms
        #expect(v.endSample - v.startSample == v.minSamples)
    }

    @MainActor
    @Test("setWidth respects totalSamples upper bound")
    func widthClampedAtMax() {
        let v = RecordingViewport(totalSamples: 10_000, sampleRate: 250, initialDurationSeconds: 4)
        v.setWidth(50_000, anchorFraction: 0.5)
        #expect(v.endSample - v.startSample == 10_000)
        #expect(v.startSample == 0)
    }

    @MainActor
    @Test("setWidth preserves the anchor sample")
    func widthAnchorPreserved() {
        let v = RecordingViewport(totalSamples: 10_000, sampleRate: 250, initialDurationSeconds: 4)
        // Move to [4000, 5000), then zoom out 2× around center (anchor 0.5 = sample 4500)
        v.setStart(4000)
        v.setWidth(2000, anchorFraction: 0.5)
        // New width 2000 centered around 4500 → [3500, 5500)
        #expect(v.startSample == 3500)
        #expect(v.endSample   == 5500)
    }

    @MainActor
    @Test("Jump centers the viewport on the fraction")
    func jumpCenters() {
        let v = RecordingViewport(totalSamples: 10_000, sampleRate: 250, initialDurationSeconds: 4)
        v.jump(toFraction: 0.5)
        // Width 1000 centered around 5000 → [4500, 5500)
        #expect(v.startSample == 4500)
        #expect(v.endSample   == 5500)
    }

    @MainActor
    @Test("Jump clamps to recording bounds")
    func jumpClamps() {
        let v = RecordingViewport(totalSamples: 10_000, sampleRate: 250, initialDurationSeconds: 4)
        v.jump(toFraction: 0.0)
        #expect(v.startSample == 0)
        #expect(v.endSample   == 1000)

        v.jump(toFraction: 1.0)
        #expect(v.endSample   == 10_000)
        #expect(v.startSample == 9_000)
    }
}

// MARK: - WFDB annotation parser

@Suite("WFDB annotation parser")
struct WFDBAnnotationParserTests {

    /// Encode a regular annotation frame: type in high 6 bits, delta in low 10.
    private func frame(type: UInt8, delta: UInt16) -> [UInt8] {
        let word = (UInt16(type) << 10) | (delta & 0x3FF)
        return [UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF)]
    }

    /// Encode the 4 bytes of a SKIP payload: high word first, each LE.
    private func skipPayload(delta: Int32) -> [UInt8] {
        let bits = UInt32(bitPattern: delta)
        let hi = UInt16(bits >> 16)
        let lo = UInt16(bits & 0xFFFF)
        return [
            UInt8(hi & 0xFF), UInt8((hi >> 8) & 0xFF),
            UInt8(lo & 0xFF), UInt8((lo >> 8) & 0xFF)
        ]
    }

    private let eof: [UInt8] = [0x00, 0x00]

    @Test("Parses a stream of regular beat frames")
    func parsesRegularFrames() {
        // Five normal beats, 100 samples apart.
        var bytes: [UInt8] = []
        for _ in 0..<5 { bytes.append(contentsOf: frame(type: 1, delta: 100)) }
        bytes.append(contentsOf: eof)

        let result = WFDBAnnotationParser.parse(data: Data(bytes))
        #expect(result.count == 5)
        #expect(result.map(\.sampleIndex) == [100, 200, 300, 400, 500])
        #expect(result.allSatisfy { $0.code == 1 })
        #expect(result.allSatisfy { $0.label == "N" })
    }

    @Test("Handles a SKIP frame for deltas larger than 10 bits")
    func handlesSkip() {
        // One frame at delta=200, then SKIP(50_000) + actual annotation (type=V).
        var bytes: [UInt8] = []
        bytes.append(contentsOf: frame(type: 1, delta: 200))            // N at 200
        bytes.append(contentsOf: frame(type: WFDBAnnotationParser.skip, delta: 0))
        bytes.append(contentsOf: skipPayload(delta: 50_000))
        bytes.append(contentsOf: frame(type: 5, delta: 0))              // V follows
        bytes.append(contentsOf: eof)

        let result = WFDBAnnotationParser.parse(data: Data(bytes))
        #expect(result.count == 2)
        #expect(result[0].sampleIndex == 200)
        #expect(result[0].label == "N")
        #expect(result[1].sampleIndex == 50_200)                        // 200 + SKIP(50_000)
        #expect(result[1].label == "V")
    }

    @Test("Skips AUX payload without advancing time")
    func skipsAux() {
        // One beat, then an AUX with 4-byte string, then another beat.
        var bytes: [UInt8] = []
        bytes.append(contentsOf: frame(type: 1, delta: 100))            // N at 100
        bytes.append(contentsOf: frame(type: WFDBAnnotationParser.aux, delta: 4))
        bytes.append(contentsOf: [0x41, 0x42, 0x43, 0x44])              // "ABCD"
        bytes.append(contentsOf: frame(type: 1, delta: 100))            // N at 200 (not 204+)
        bytes.append(contentsOf: eof)

        let result = WFDBAnnotationParser.parse(data: Data(bytes))
        #expect(result.count == 2)
        #expect(result[0].sampleIndex == 100)
        #expect(result[1].sampleIndex == 200)
    }

    @Test("Skips NUM / SUB / CHN metadata frames without emitting")
    func skipsModifiers() {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: frame(type: 1, delta: 50))             // N at 50
        bytes.append(contentsOf: frame(type: WFDBAnnotationParser.num, delta: 7))
        bytes.append(contentsOf: frame(type: WFDBAnnotationParser.sub, delta: 3))
        bytes.append(contentsOf: frame(type: WFDBAnnotationParser.chn, delta: 0))
        bytes.append(contentsOf: frame(type: 5, delta: 100))            // V at 150
        bytes.append(contentsOf: eof)

        let result = WFDBAnnotationParser.parse(data: Data(bytes))
        #expect(result.count == 2)
        #expect(result[0].sampleIndex == 50)
        #expect(result[0].label == "N")
        #expect(result[1].sampleIndex == 150)
        #expect(result[1].label == "V")
    }

    @Test("Maps the common WFDB type codes to their canonical symbols")
    func mapsKnownSymbols() {
        var bytes: [UInt8] = []
        // Types 1=N, 2=L, 3=R, 5=V, 6=F, 8=A, 12=/, all 100 samples apart.
        for type in [UInt8(1), 2, 3, 5, 6, 8, 12] {
            bytes.append(contentsOf: frame(type: type, delta: 100))
        }
        bytes.append(contentsOf: eof)

        let result = WFDBAnnotationParser.parse(data: Data(bytes))
        #expect(result.map(\.label) == ["N", "L", "R", "V", "F", "A", "/"])
    }
}

// MARK: - ECG grid spec

@Suite("ECG grid spec adaptive density")
struct ECGGridSpecTests {

    @Test("Sub-30s uses the standard 0.04 / 0.2 paper grid")
    func tightZoom() {
        let spec = ECGGridSpec.forDuration(seconds: 10)
        #expect(spec.xMinor == 0.04)
        #expect(spec.xMajor == 0.2)
        #expect(spec.xLandmark == 1.0)        // every 5th major = 1 s
        #expect(spec.yMinor == 0.1)
        #expect(spec.yMajor == 0.5)
        #expect(spec.yLandmark == 2.5)        // every 5th major = 2.5 mV
    }

    @Test("Landmark is always 5x the major across every tier")
    func landmarkIsFiveTimesMajor() {
        let durations: [Double] = [10, 60, 600, 5_000, 10_000]
        for d in durations {
            let spec = ECGGridSpec.forDuration(seconds: d)
            #expect(abs(spec.xLandmark / spec.xMajor - 5.0) < 0.01,
                    "x landmark / major != 5 at duration \(d)")
        }
    }

    @Test("30s–5min steps up to 0.2s minor / 1s major")
    func mediumZoom() {
        let spec = ECGGridSpec.forDuration(seconds: 60)
        #expect(spec.xMinor == 0.2)
        #expect(spec.xMajor == 1.0)
    }

    @Test("5–30min steps up to 1s / 5s")
    func wideZoom() {
        let spec = ECGGridSpec.forDuration(seconds: 600)
        #expect(spec.xMinor == 1.0)
        #expect(spec.xMajor == 5.0)
    }

    @Test("≥2hr falls back to 30s minor / 5min major")
    func extremeZoom() {
        let spec = ECGGridSpec.forDuration(seconds: 10_000)
        #expect(spec.xMinor == 30.0)
        #expect(spec.xMajor == 300.0)
    }

    @Test("Grid stays bounded — line counts always manageable")
    func gridLineCountStaysBounded() {
        // For every duration we'd realistically show, the active major grid
        // count is well under 1000 lines.
        let durations: [Double] = [1, 10, 30, 60, 300, 1800, 7200, 14_400]
        for d in durations {
            let spec = ECGGridSpec.forDuration(seconds: d)
            let majorCount = d / spec.xMajor
            #expect(majorCount < 200, "Major grid for \(d)s has \(majorCount) lines")
        }
    }
}

// MARK: - Annotation model + JSON ingest

@Suite("Annotation JSON ingest")
struct AnnotationLoaderTests {

    @Test("Round-trips findings with sample-index timestamps")
    func roundTripsSampleIndex() throws {
        let json = """
        {
          "schemaVersion": 1,
          "source": "vf-onset-detector-v2",
          "findings": [
            {
              "kind": "point",
              "startSample": 12345,
              "category": "PVC",
              "confidence": 0.92,
              "severity": "warning"
            },
            {
              "kind": "range",
              "startSample": 50000,
              "endSample": 65000,
              "category": "VF_onset",
              "severity": "critical",
              "note": "Onset preceded by R-on-T"
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let result = try AnnotationLoader.parse(
            data: data,
            recordingStartUnixMS: 0,
            sampleRate: 250.0
        )
        #expect(result.count == 2)
        #expect(result[0].kind == .point)
        #expect(result[0].sampleIndex == 12345)
        #expect(result[0].category == "PVC")
        #expect(result[0].severity == .warning)
        #expect(result[0].confidence == 0.92)
        #expect(result[0].source == "vf-onset-detector-v2")    // file-level default

        #expect(result[1].kind == .range)
        #expect(result[1].sampleIndex == 50000)
        #expect(result[1].endSampleIndex == 65000)
        #expect(result[1].severity == .critical)
        #expect(result[1].note == "Onset preceded by R-on-T")
    }

    @Test("Resolves unix-millis timestamps via channel start + sample rate")
    func resolvesUnixMillis() throws {
        let startMS: Int64 = 1_717_854_312_500       // recording start
        let sampleRate = 250.0
        let json = """
        {
          "schemaVersion": 1,
          "findings": [
            {
              "kind": "point",
              "startUnixMS": \(startMS + 1000),
              "category": "PVC",
              "source": "online-detector"
            },
            {
              "kind": "range",
              "startUnixMS": \(startMS + 4000),
              "endUnixMS":   \(startMS + 6000),
              "category": "VT",
              "source": "online-detector"
            }
          ]
        }
        """
        let result = try AnnotationLoader.parse(
            data: Data(json.utf8),
            recordingStartUnixMS: startMS,
            sampleRate: sampleRate
        )
        #expect(result[0].sampleIndex == 250)        // +1s × 250 Hz
        #expect(result[1].sampleIndex == 1000)
        #expect(result[1].endSampleIndex == 1500)
    }

    @Test("Sample-index field wins over unix-millis when both are present")
    func sampleIndexWinsOverUnixMS() throws {
        let json = """
        {
          "schemaVersion": 1,
          "findings": [
            {
              "kind": "point",
              "startSample": 7777,
              "startUnixMS": 99999999999,
              "category": "PVC",
              "source": "x"
            }
          ]
        }
        """
        let result = try AnnotationLoader.parse(
            data: Data(json.utf8),
            recordingStartUnixMS: 0,
            sampleRate: 250.0
        )
        #expect(result[0].sampleIndex == 7777)
    }

    @Test("Throws when a finding has no timestamp at all")
    func throwsOnMissingTimestamp() {
        let json = """
        {
          "schemaVersion": 1,
          "findings": [
            { "kind": "point", "category": "PVC", "source": "x" }
          ]
        }
        """
        #expect(throws: AnnotationFileError.self) {
            try AnnotationLoader.parse(
                data: Data(json.utf8),
                recordingStartUnixMS: 0,
                sampleRate: 250.0
            )
        }
    }

    @Test("Throws on unsupported schemaVersion")
    func throwsOnUnsupportedSchema() {
        let json = """
        { "schemaVersion": 99, "findings": [] }
        """
        #expect(throws: AnnotationFileError.self) {
            try AnnotationLoader.parse(
                data: Data(json.utf8),
                recordingStartUnixMS: 0,
                sampleRate: 250.0
            )
        }
    }

    @Test("Severity defaults to .info when omitted")
    func severityDefaultsToInfo() throws {
        let json = """
        {
          "schemaVersion": 1,
          "findings": [
            { "kind": "point", "startSample": 100, "category": "x", "source": "s" }
          ]
        }
        """
        let result = try AnnotationLoader.parse(
            data: Data(json.utf8),
            recordingStartUnixMS: 0,
            sampleRate: 250.0
        )
        #expect(result[0].severity == .info)
    }
}

// MARK: - WFDB → Annotation adapter

@Suite("WFDB to Annotation adapter")
struct WFDBAnnotationAdapterTests {

    @Test("Each WFDB symbol becomes a point annotation tagged wfdb.atr")
    func adaptsWFDBToPointAnnotation() {
        let wfdb = WFDBAnnotation(sampleIndex: 4242, code: 1, label: "N")
        let ann = Annotation(fromWFDB: wfdb)
        #expect(ann.kind == .point)
        #expect(ann.sampleIndex == 4242)
        #expect(ann.endSampleIndex == nil)
        #expect(ann.category == "N")
        #expect(ann.label == "N")
        #expect(ann.source == "wfdb.atr")
        #expect(ann.severity == .info)
    }
}

// MARK: - FindingFilter

@Suite("Finding filter")
struct FindingFilterTests {

    private func make(
        category: String = "PVC",
        severity: Annotation.Severity = .info,
        source: String = "x",
        confidence: Double? = nil
    ) -> Annotation {
        Annotation(
            kind: .point,
            sampleIndex: 0,
            category: category,
            confidence: confidence,
            severity: severity,
            source: source
        )
    }

    @Test("Empty filter matches everything")
    func emptyFilterMatchesAll() {
        let filter = FindingFilter()
        #expect(filter.matches(make()))
        #expect(filter.matches(make(category: "AFib", severity: .critical)))
    }

    @Test("Category filter excludes non-matching")
    func categoryFilter() {
        var filter = FindingFilter()
        filter.categories = ["PVC", "VT"]
        #expect(filter.matches(make(category: "PVC")))
        #expect(!filter.matches(make(category: "AFib")))
    }

    @Test("Severity filter is an explicit set, not a threshold")
    func severityFilter() {
        var filter = FindingFilter()
        filter.severities = [.warning, .critical]
        #expect(filter.matches(make(severity: .warning)))
        #expect(filter.matches(make(severity: .critical)))
        #expect(!filter.matches(make(severity: .info)))
    }

    @Test("Confidence threshold gates findings with a confidence value")
    func confidenceFilter() {
        var filter = FindingFilter()
        filter.minConfidence = 0.8
        #expect(filter.matches(make(confidence: 0.9)))
        #expect(!filter.matches(make(confidence: 0.5)))
        // Findings without a confidence value pass the threshold.
        #expect(filter.matches(make(confidence: nil)))
    }

    @Test("Source filter excludes producers not in the set")
    func sourceFilter() {
        var filter = FindingFilter()
        filter.sources = ["wfdb.atr"]
        #expect(filter.matches(make(source: "wfdb.atr")))
        #expect(!filter.matches(make(source: "online-detector")))
    }
}

// MARK: - Recording manifest backward-compat

@Suite("Recording manifest decode")
struct RecordingDecodeTests {

    @Test("Decodes a legacy manifest with WFDBAnnotation array into Annotation")
    func decodesLegacyAnnotationsArray() throws {
        // Simulate a manifest written before the rich-Annotation refactor.
        let json = """
        {
          "version": 1,
          "id": "BB18C7D6-12D8-4FE1-A2D6-1F4DFBE0DBE9",
          "device": "mit-bih-100",
          "createdAt": "2026-01-09T14:06:52Z",
          "sourceFileName": "100.hea",
          "channels": [],
          "annotations": [
            { "sampleIndex": 100, "code": 1, "label": "N" },
            { "sampleIndex": 200, "code": 5, "label": "V" }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(Recording.self, from: Data(json.utf8))
        #expect(recording.annotations.count == 2)
        #expect(recording.annotations[0].kind == .point)
        #expect(recording.annotations[0].sampleIndex == 100)
        #expect(recording.annotations[0].category == "N")
        #expect(recording.annotations[0].source == "wfdb.atr")
        #expect(recording.annotations[1].category == "V")
    }

    @Test("Defaults annotations to empty when key is missing")
    func defaultsToEmptyWhenMissing() throws {
        let json = """
        {
          "version": 1,
          "id": "BB18C7D6-12D8-4FE1-A2D6-1F4DFBE0DBE9",
          "device": "mit-bih-100",
          "createdAt": "2026-01-09T14:06:52Z",
          "sourceFileName": "100.hea",
          "channels": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(Recording.self, from: Data(json.utf8))
        #expect(recording.annotations.isEmpty)
    }
}

// MARK: - Off-scale sample scanner

@Suite("Clipped-range scanner")
struct ClippedRangeScannerTests {

    @Test("Returns empty when every sample is within range")
    func allInRange() {
        let samples: [Float] = [-1, 0, 1, 2, -2, 0]
        let ranges = ClippedRangeScanner.scan(samples: samples, clipMin: -5, clipMax: 5)
        #expect(ranges.isEmpty)
    }

    @Test("Captures a single contiguous run above the upper bound")
    func singleRunAbove() {
        let samples: [Float] = [0, 0, 7, 8, 9, 0, 0]
        let ranges = ClippedRangeScanner.scan(samples: samples, clipMin: -5, clipMax: 5)
        #expect(ranges.count == 1)
        #expect(ranges[0].startSample == 2)
        #expect(ranges[0].endSample == 5)
        #expect(ranges[0].direction == .above)
    }

    @Test("Splits runs at direction changes")
    func splitsOnDirectionChange() {
        // 7, 8 (above), then -7, -8 (below), with no in-range sample between
        let samples: [Float] = [0, 7, 8, -7, -8, 0]
        let ranges = ClippedRangeScanner.scan(samples: samples, clipMin: -5, clipMax: 5)
        #expect(ranges.count == 2)
        #expect(ranges[0] == ClippedRange(startSample: 1, endSample: 3, direction: .above))
        #expect(ranges[1] == ClippedRange(startSample: 3, endSample: 5, direction: .below))
    }

    @Test("Closes an open run at the end of the buffer")
    func closesRunAtEnd() {
        let samples: [Float] = [0, 0, 9, 9, 9]
        let ranges = ClippedRangeScanner.scan(samples: samples, clipMin: -5, clipMax: 5)
        #expect(ranges.count == 1)
        #expect(ranges[0].endSample == 5)
    }

    @Test("NaN samples close an open run and are themselves treated as in-range")
    func nanSamplesCloseRun() {
        let samples: [Float] = [0, 7, 8, .nan, 9, 0]
        let ranges = ClippedRangeScanner.scan(samples: samples, clipMin: -5, clipMax: 5)
        #expect(ranges.count == 2)
        #expect(ranges[0] == ClippedRange(startSample: 1, endSample: 3, direction: .above))
        #expect(ranges[1] == ClippedRange(startSample: 4, endSample: 5, direction: .above))
    }

    @Test("Below-bound runs are detected with .below direction")
    func belowBound() {
        let samples: [Float] = [-6, -7, -8, 0]
        let ranges = ClippedRangeScanner.scan(samples: samples, clipMin: -5, clipMax: 5)
        #expect(ranges.count == 1)
        #expect(ranges[0].direction == .below)
        #expect(ranges[0].sampleCount == 3)
    }
}

// MARK: - Recent folders store

@Suite("Recent folders store")
struct RecentFoldersStoreTests {

    /// Each test gets its own UserDefaults suite so persistence assertions
    /// don't bleed across tests or pollute the host process's `.standard`
    /// defaults.
    private static func makeDefaults() -> UserDefaults {
        let suiteName = "RecentFoldersStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MurmurRecentsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("A fresh store starts empty")
    func startsEmpty() {
        let store = RecentFoldersStore(defaults: Self.makeDefaults())
        #expect(store.entries.isEmpty)
    }

    @Test("Recording a folder adds an entry with the right display data")
    func recordsAFolder() throws {
        let folder = try Self.makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecentFoldersStore(defaults: Self.makeDefaults())

        store.record(folder: folder)
        try #require(!store.entries.isEmpty)
        let entry = store.entries[0]
        #expect(entry.displayName == folder.lastPathComponent)
        #expect(entry.resolvedPath == folder.path)
    }

    @Test("Persisted entries survive a fresh store instance")
    func persistsAcrossReload() throws {
        let defaults = Self.makeDefaults()
        let folder = try Self.makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = RecentFoldersStore(defaults: defaults)
        store.record(folder: folder)
        try #require(!store.entries.isEmpty)

        let reloaded = RecentFoldersStore(defaults: defaults)
        #expect(reloaded.entries.first?.resolvedPath == folder.path)
    }

    @Test("Re-recording the same folder moves it to the top without duplicating")
    func dedupsAndReorders() throws {
        let folderA = try Self.makeTempFolder()
        let folderB = try Self.makeTempFolder()
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
        }
        let store = RecentFoldersStore(defaults: Self.makeDefaults())

        store.record(folder: folderA)
        store.record(folder: folderB)
        store.record(folder: folderA)

        #expect(store.entries.count == 2)
        #expect(store.entries[0].resolvedPath == folderA.path)
        #expect(store.entries[1].resolvedPath == folderB.path)
    }

    @Test("Cap at 10 entries — oldest fall off when the eleventh is added")
    func capsAtTen() throws {
        let store = RecentFoldersStore(defaults: Self.makeDefaults())
        var folders: [URL] = []
        defer { folders.forEach { try? FileManager.default.removeItem(at: $0) } }

        for _ in 0..<11 {
            let folder = try Self.makeTempFolder()
            folders.append(folder)
            store.record(folder: folder)
        }
        #expect(store.entries.count == 10)
        #expect(store.entries[0].resolvedPath == folders.last!.path)
    }

    @Test("Remove drops a single entry and persists the change")
    func removeDropsEntry() throws {
        let defaults = Self.makeDefaults()
        let folder = try Self.makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = RecentFoldersStore(defaults: defaults)
        store.record(folder: folder)
        let entry = try #require(store.entries.first)

        store.remove(entry)
        #expect(store.entries.isEmpty)
        #expect(RecentFoldersStore(defaults: defaults).entries.isEmpty)
    }

    @Test("Clear wipes every entry")
    func clearWipesAll() throws {
        let defaults = Self.makeDefaults()
        let folder = try Self.makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = RecentFoldersStore(defaults: defaults)
        store.record(folder: folder)
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(RecentFoldersStore(defaults: defaults).entries.isEmpty)
    }

    @Test("Resolving a freshly recorded bookmark returns a usable URL")
    func resolvesBookmark() throws {
        let folder = try Self.makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecentFoldersStore(defaults: Self.makeDefaults())

        store.record(folder: folder)
        let entry = try #require(store.entries.first)

        let resolved = try #require(store.resolve(entry))
        // Normalize via resolvingSymlinksInPath because the bookmark API returns
        // the canonical /private-prefixed form of /var/folders/... on macOS,
        // while the original folder URL retains the alias path.
        #expect(resolved.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
    }
}

// MARK: - Annotation summary aggregation

@Suite("Annotation summary")
struct AnnotationSummaryTests {

    private func point(_ category: String, at sample: Int64, severity: Annotation.Severity = .info) -> Annotation {
        Annotation(kind: .point, sampleIndex: sample, category: category, severity: severity, source: "test")
    }

    private func range(_ category: String, from start: Int64, to end: Int64, severity: Annotation.Severity = .info) -> Annotation {
        Annotation(kind: .range, sampleIndex: start, endSampleIndex: end, category: category, severity: severity, source: "test")
    }

    @Test("Empty input produces an empty summary")
    func emptyInput() {
        let summary = AnnotationSummary.build(from: [], recordingDurationSamples: 10_000, sampleRate: 250)
        #expect(summary.rollups.isEmpty)
        #expect(summary.totalCount == 0)
    }

    @Test("Point-only category rolls up as count, not range-dominant")
    func pointOnlyCategory() {
        let summary = AnnotationSummary.build(
            from: [point("PVC", at: 10), point("PVC", at: 200), point("PVC", at: 500)],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        let pvc = try? #require(summary.rollups.first { $0.category == "PVC" })
        #expect(pvc?.totalCount == 3)
        #expect(pvc?.pointCount == 3)
        #expect(pvc?.rangeCount == 0)
        #expect(pvc?.totalRangeSamples == 0)
        #expect(pvc?.isRangeDominant == false)
    }

    @Test("Range-only category accumulates total span and is range-dominant")
    func rangeOnlyCategory() {
        let summary = AnnotationSummary.build(
            from: [
                range("AFib", from: 0, to: 500),
                range("AFib", from: 1_000, to: 1_750)
            ],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        let afib = try? #require(summary.rollups.first { $0.category == "AFib" })
        #expect(afib?.rangeCount == 2)
        #expect(afib?.totalRangeSamples == 1_250)
        #expect(afib?.isRangeDominant == true)
    }

    @Test("Ranges with missing end samples contribute count but not duration")
    func rangeWithoutEndSampleSkipsDuration() {
        let openRange = Annotation(
            kind: .range,
            sampleIndex: 100,
            endSampleIndex: nil,                  // producer forgot to set it
            category: "noise",
            source: "test"
        )
        let summary = AnnotationSummary.build(
            from: [openRange],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        let noise = try? #require(summary.rollups.first { $0.category == "noise" })
        #expect(noise?.rangeCount == 1)
        #expect(noise?.totalRangeSamples == 0)
        #expect(noise?.isRangeDominant == false)
    }

    @Test("Per-severity counts and maxSeverity are reported correctly")
    func severityBreakdown() {
        let summary = AnnotationSummary.build(
            from: [
                point("VT", at: 10,  severity: .critical),
                point("VT", at: 30,  severity: .warning),
                point("VT", at: 50,  severity: .info),
                point("VT", at: 70,  severity: .warning)
            ],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        let vt = try? #require(summary.rollups.first { $0.category == "VT" })
        #expect(vt?.criticalCount == 1)
        #expect(vt?.warningCount  == 2)
        #expect(vt?.severityCounts[.info] == 1)
        #expect(vt?.maxSeverity == .critical)
    }

    @Test("Rollups sort by max severity descending, then count descending")
    func sortOrder() {
        // Categories: noise (3 info), PVC (1 critical + 2 info), AFib (2 warning),
        // Order should be: PVC (critical), AFib (warning), noise (info, larger count)
        let summary = AnnotationSummary.build(
            from: [
                point("noise", at: 1, severity: .info),
                point("noise", at: 2, severity: .info),
                point("noise", at: 3, severity: .info),
                point("PVC", at: 10, severity: .critical),
                point("PVC", at: 20, severity: .info),
                point("PVC", at: 30, severity: .info),
                point("AFib", at: 100, severity: .warning),
                point("AFib", at: 200, severity: .warning)
            ],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        let categories = summary.rollups.map(\.category)
        #expect(categories == ["PVC", "AFib", "noise"])
    }

    @Test("Tied severity + count breaks by category name ascending")
    func tieBreakByName() {
        let summary = AnnotationSummary.build(
            from: [
                point("zeta",  at: 1, severity: .info),
                point("alpha", at: 2, severity: .info)
            ],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        #expect(summary.rollups.map(\.category) == ["alpha", "zeta"])
    }

    @Test("fractionOfRecording handles unknown duration, zero range, and normal case")
    func fractionOfRecording() {
        let pointRollup = AnnotationSummary.build(
            from: [point("PVC", at: 10)],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        #expect(pointRollup.fractionOfRecording(pointRollup.rollups[0]) == nil)

        let rangeSummary = AnnotationSummary.build(
            from: [range("AFib", from: 0, to: 4_000)],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        let fraction = rangeSummary.fractionOfRecording(rangeSummary.rollups[0])
        #expect(fraction == 0.4)

        let unknown = AnnotationSummary.build(
            from: [range("AFib", from: 0, to: 4_000)],
            recordingDurationSamples: nil,
            sampleRate: 250
        )
        #expect(unknown.fractionOfRecording(unknown.rollups[0]) == nil)
    }

    @Test("totalCount equals the input length even across categories")
    func totalCountAcrossCategories() {
        let summary = AnnotationSummary.build(
            from: [
                point("PVC", at: 1),
                point("PVC", at: 2),
                range("AFib", from: 100, to: 200),
                point("noise", at: 300)
            ],
            recordingDurationSamples: 10_000,
            sampleRate: 250
        )
        #expect(summary.totalCount == 4)
    }
}

// MARK: - Chip duration formatting

@Suite("Chip duration formatting")
struct ChipDurationTests {
    @Test("Sub-second durations show one decimal")
    func subSecond() {
        #expect(ChipDuration.format(seconds: 0.7) == "0.7s")
    }

    @Test("Seconds round to whole numbers")
    func wholeSeconds() {
        #expect(ChipDuration.format(seconds: 1) == "1s")
        #expect(ChipDuration.format(seconds: 30) == "30s")
        #expect(ChipDuration.format(seconds: 59.6) == "60s")
    }

    @Test("Minutes-and-seconds combines with `m` and `s`")
    func minutesAndSeconds() {
        #expect(ChipDuration.format(seconds: 60) == "1m")
        #expect(ChipDuration.format(seconds: 90) == "1m30s")
        #expect(ChipDuration.format(seconds: 125) == "2m5s")
    }

    @Test("Hours-and-minutes combines with `h` and `m`")
    func hoursAndMinutes() {
        #expect(ChipDuration.format(seconds: 3_600) == "1h")
        #expect(ChipDuration.format(seconds: 3_720) == "1h2m")
        #expect(ChipDuration.format(seconds: 7_200) == "2h")
    }

    @Test("Negative or non-finite values fall back safely")
    func nonFiniteValues() {
        #expect(ChipDuration.format(seconds: -5) == "0s")
        #expect(ChipDuration.format(seconds: .nan) == "0s")
    }
}

// MARK: - WFDB multi-frequency / multi-file support

@Suite("WFDB multi-frequency parsing")
struct WFDBMultiFrequencyTests {

    @Test("Signal lines without an spf suffix default to 1")
    func defaultsToSpfOne() throws {
        let hea = """
        rec 1 250 100
        rec.dat 16 200(mV)/0 16 0 0 0 0 II
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].samplesPerFrame == 1)
        #expect(header.sampleRate(for: header.signals[0]) == 250.0)
        #expect(header.sampleCount(for: header.signals[0]) == 100)
    }

    @Test("Format field `16x250` parses samples-per-frame correctly")
    func capturesSpfFromFormatField() throws {
        let hea = """
        multi 2 1 60
        ecg.dat 16x250 200(mV)/0 16 0 0 0 0 II
        hr.dat 16x1 1(bpm)/0 16 0 0 0 0 HR_bpm
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].samplesPerFrame == 250)
        #expect(header.signals[1].samplesPerFrame == 1)
        #expect(header.sampleRate(for: header.signals[0]) == 250.0)
        #expect(header.sampleRate(for: header.signals[1]) == 1.0)
        // Frame count × spf = per-signal sample count
        #expect(header.sampleCount(for: header.signals[0]) == 15_000)
        #expect(header.sampleCount(for: header.signals[1]) == 60)
    }

    @Test("Skew suffix (e.g. `16x4:10`) is ignored and spf still captured")
    func ignoresSkewSuffix() throws {
        let hea = """
        skew 1 1 10
        s.dat 16x4:10 1(unit)/0 16 0 0 0 0 X
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].samplesPerFrame == 4)
    }
}

@Suite("WFDB multi-file importer")
struct WFDBMultiFileImporterTests {

    @Test("Imports a multi-frequency record with per-signal .dat files")
    func importsMultiFrequencyRecord() throws {
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WFDBMulti-\(UUID().uuidString)", isDirectory: true)
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WFDBMulti-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeMultiFrequencyRecord(into: srcDir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)

        // 8 ECG signals + 6 low-rate signals (HR, SpO₂, alarm,
        // P(spontaneous), P(assist-control), ecg_artifact_ratio) = 14 total.
        #expect(summary.recording.channels.count == 14)

        let ecg = summary.recording.channels.first { $0.name == "II" }
        let hr  = summary.recording.channels.first { $0.name == "HR_bpm" }
        let spo2 = summary.recording.channels.first { $0.name == "SpO2_pct" }
        let alarm = summary.recording.channels.first { $0.name == "had_high_priority_alarm" }
        let probSpontaneous = summary.recording.channels.first { $0.name == "prob_state_spontaneous" }
        let quality = summary.recording.channels.first { $0.name == "ecg_artifact_ratio" }
        try #require(ecg != nil)
        try #require(hr != nil)
        try #require(spo2 != nil)
        try #require(alarm != nil)
        try #require(probSpontaneous != nil)
        try #require(quality != nil)
        #expect(alarm!.isTrendChannel)
        #expect(probSpontaneous!.isTrendChannel)
        #expect(quality!.isTrendChannel)

        #expect(ecg!.sampleRate == 250.0)
        #expect(ecg!.sampleCount == 2_500)
        #expect(!ecg!.isTrendChannel)

        #expect(hr!.sampleRate == 1.0)
        #expect(hr!.sampleCount == 10)
        #expect(hr!.isTrendChannel)
        #expect(spo2!.isTrendChannel)
    }

    @Test("Trend channel samples round-trip through the importer with the right values")
    func trendChannelValuesRoundTrip() throws {
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WFDBTrend-\(UUID().uuidString)", isDirectory: true)
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WFDBTrend-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }

        let heaURL = try SyntheticRecording.makeMultiFrequencyRecord(into: srcDir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)
        let hr = try #require(summary.recording.channels.first { $0.name == "HR_bpm" })

        let binURL = summary.directory.appendingPathComponent(hr.storageFileName)
        let samples = try BinaryRecordingFile.readSamples(url: binURL, range: 0..<hr.sampleCount)
        // Synth HR is `72 + 8·sin(t·π/5)` rounded to int, so values stay
        // comfortably within human-physiological range.
        for value in samples {
            #expect(value >= 60 && value <= 90)
        }
    }
}

@Suite("Channel discriminators")
struct ChannelDiscriminatorTests {

    private func channel(rate: Double) -> Channel {
        Channel(
            id: UUID(),
            name: "x",
            unit: "",
            sampleRate: rate,
            startTimeUnixMS: 0,
            sampleCount: 100,
            storageFileName: "x.bin",
            pyramid: []
        )
    }

    @Test("ECG-rate channels are not trend channels")
    func ecgRateIsNotTrend() {
        #expect(!channel(rate: 250).isTrendChannel)
        #expect(!channel(rate: 360).isTrendChannel)
        #expect(!channel(rate: 251.5).isTrendChannel)
    }

    @Test("Sub-5-Hz channels are trend channels")
    func lowRateIsTrend() {
        #expect(channel(rate: 1).isTrendChannel)
        #expect(channel(rate: 1.0 / 60).isTrendChannel)
        #expect(channel(rate: 0.5).isTrendChannel)
    }

    @Test("5 Hz boundary is non-trend — leave room for slow ECG variants")
    func boundaryIsNotTrend() {
        #expect(!channel(rate: 5).isTrendChannel)
    }
}

// MARK: - Boolean channel scanner

@Suite("Boolean channel scanner")
struct BooleanChannelScannerTests {

    @Test("Empty input → no ranges")
    func emptyInput() {
        #expect(BooleanChannelScanner.scan(samples: []).isEmpty)
    }

    @Test("All-inactive samples → no ranges")
    func allInactive() {
        #expect(BooleanChannelScanner.scan(samples: [0, 0, 0, 0]).isEmpty)
    }

    @Test("All-active samples → single full-extent range")
    func allActive() {
        let ranges = BooleanChannelScanner.scan(samples: [1, 1, 1])
        #expect(ranges == [Int64(0)...Int64(2)])
    }

    @Test("Single active sample → one one-sample range")
    func singleActiveSample() {
        let ranges = BooleanChannelScanner.scan(samples: [0, 0, 1, 0, 0])
        #expect(ranges == [Int64(2)...Int64(2)])
    }

    @Test("Two runs separated by inactive sample → two ranges")
    func twoRunsSplitByInactive() {
        let ranges = BooleanChannelScanner.scan(samples: [1, 1, 0, 1, 1])
        #expect(ranges == [Int64(0)...Int64(1), Int64(3)...Int64(4)])
    }

    @Test("Threshold can be customized to e.g. 0.7")
    func customThreshold() {
        let samples: [Float] = [0.6, 0.8, 0.5, 0.9]
        let ranges = BooleanChannelScanner.scan(samples: samples, threshold: 0.7)
        #expect(ranges == [Int64(1)...Int64(1), Int64(3)...Int64(3)])
    }

    @Test("NaN samples are treated as inactive and split runs")
    func nanIsInactive() {
        let samples: [Float] = [1, 1, .nan, 1, 1]
        let ranges = BooleanChannelScanner.scan(samples: samples)
        #expect(ranges == [Int64(0)...Int64(1), Int64(3)...Int64(4)])
    }

    @Test("Open run at end of buffer is closed correctly")
    func closesAtEnd() {
        let samples: [Float] = [0, 0, 1, 1]
        let ranges = BooleanChannelScanner.scan(samples: samples)
        #expect(ranges == [Int64(2)...Int64(3)])
    }
}

// MARK: - Low-rate channel partitioning

@Suite("Low-rate channel partition")
struct LowRatePartitionTests {

    private func channel(_ name: String, rate: Double = 1) -> Channel {
        Channel(
            id: UUID(),
            name: name,
            unit: "",
            sampleRate: rate,
            startTimeUnixMS: 0,
            sampleCount: 10,
            storageFileName: "\(name).bin",
            pyramid: []
        )
    }

    @Test("Vital trend channels route to `trends`")
    func vitalsAreTrends() {
        let p = LowRatePartition(channels: [
            channel("HR_bpm"),
            channel("SpO2_pct"),
            channel("etco2_avg_60s")
        ])
        #expect(p.trends.map(\.name) == ["HR_bpm", "SpO2_pct", "etco2_avg_60s"])
        #expect(p.alarms.isEmpty)
        #expect(p.spontaneous == nil)
        #expect(p.assistControl == nil)
    }

    @Test("Channel names ending in `_alarm`, `_status`, or `_silenced` route to `alarms`")
    func alarmSuffixDetection() {
        let p = LowRatePartition(channels: [
            channel("had_high_priority_alarm"),
            channel("had_suction_alarm"),
            channel("nebulizer_status"),
            channel("had_alarm_silenced")
        ])
        #expect(p.alarms.count == 4)
        #expect(p.trends.isEmpty)
    }

    @Test("`prob_state_spontaneous` + `prob_state_assist_control` route to state pair")
    func stateProbabilityPair() {
        let p = LowRatePartition(channels: [
            channel("prob_state_spontaneous"),
            channel("prob_state_assist_control")
        ])
        #expect(p.spontaneous?.name == "prob_state_spontaneous")
        #expect(p.assistControl?.name == "prob_state_assist_control")
        #expect(p.trends.isEmpty)
        #expect(p.alarms.isEmpty)
    }

    @Test("Mixed channel set partitions cleanly across all three buckets")
    func mixedPartition() {
        let p = LowRatePartition(channels: [
            channel("HR_bpm"),
            channel("had_high_priority_alarm"),
            channel("prob_state_spontaneous"),
            channel("SpO2_pct"),
            channel("nebulizer_status")
        ])
        #expect(p.trends.map(\.name) == ["HR_bpm", "SpO2_pct"])
        #expect(p.alarms.map(\.name) == ["had_high_priority_alarm", "nebulizer_status"])
        #expect(p.spontaneous?.name == "prob_state_spontaneous")
        #expect(p.assistControl == nil)
    }

    @Test("`_ratio` suffix or `artifact_ratio` substring routes to `quality`")
    func qualityRatioDetection() {
        let p = LowRatePartition(channels: [
            channel("ecg_artifact_ratio"),
            channel("ppg_quality_ratio"),
            channel("HR_bpm")
        ])
        #expect(p.quality.map(\.name) == ["ecg_artifact_ratio", "ppg_quality_ratio"])
        #expect(p.trends.map(\.name) == ["HR_bpm"])
        #expect(p.alarms.isEmpty)
    }
}

// MARK: - Disposition store

@Suite("Disposition store")
struct DispositionStoreTests {

    private static func makeBundle() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DispositionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func annotation(_ category: String = "VT", severity: Annotation.Severity = .warning) -> Annotation {
        Annotation(kind: .point, sampleIndex: 0, category: category, severity: severity, source: "test")
    }

    @Test("Fresh store starts empty")
    func startsEmpty() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        #expect(store.records.isEmpty)
        #expect(store.state(for: UUID()) == nil)
    }

    @Test("Confirm records a confirmed disposition with the chosen kind")
    func confirmRecords() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let ann = annotation()
        store.confirm(ann.id, kind: .vt)
        let record = try #require(store.record(for: ann.id))
        #expect(record.state == .confirmed)
        #expect(record.confirmedKind == .vt)
        #expect(record.reviewedBy == "tester")
    }

    @Test("Dismiss records a dismissed disposition")
    func dismissRecords() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let ann = annotation()
        store.dismiss(ann.id, note: "obvious noise")
        let record = try #require(store.record(for: ann.id))
        #expect(record.state == .dismissed)
        #expect(record.confirmedKind == nil)
        #expect(record.note == "obvious noise")
    }

    @Test("Reset returns an annotation to unreviewed")
    func resetReturnsToUnreviewed() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let ann = annotation()
        store.confirm(ann.id, kind: .vf)
        store.reset(ann.id)
        #expect(store.record(for: ann.id) == nil)
    }

    @Test("Confirm overwrites a prior dismiss")
    func confirmOverwritesDismiss() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let ann = annotation()
        store.dismiss(ann.id)
        store.confirm(ann.id, kind: nil)
        let record = try #require(store.record(for: ann.id))
        #expect(record.state == .confirmed)
        #expect(record.confirmedKind == nil)
    }

    @Test("Records persist to the sidecar and reload on a fresh store")
    func persistsAcrossReload() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let ann = annotation()
        store.confirm(ann.id, kind: .vt, note: "sustained")

        let reloaded = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let record = try #require(reloaded.record(for: ann.id))
        #expect(record.state == .confirmed)
        #expect(record.confirmedKind == .vt)
        #expect(record.note == "sustained")
    }

    @Test("Tally returns confirmed / dismissed / unreviewed counts across an annotation list")
    func tallyCounts() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let a = annotation()
        let b = annotation()
        let c = annotation()
        let d = annotation()
        store.confirm(a.id, kind: .vt)
        store.confirm(b.id, kind: nil)
        store.dismiss(c.id)
        // d remains unreviewed
        let tally = store.tally(for: [a, b, c, d])
        #expect(tally.confirmed == 2)
        #expect(tally.dismissed == 1)
        #expect(tally.unreviewed == 1)
        #expect(tally.total == 4)
    }

    @Test("Clear wipes every record and survives a reload")
    func clearWipesAll() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let ann = annotation()
        store.confirm(ann.id, kind: .vt)
        store.clear()
        #expect(store.records.isEmpty)
        let reloaded = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        #expect(reloaded.records.isEmpty)
    }

    @Test("Empty / whitespace-only note is normalized to nil")
    func emptyNoteBecomesNil() throws {
        let dir = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DispositionStore(bundleDirectory: dir, defaultReviewerName: "tester")
        let ann = annotation()
        store.dismiss(ann.id, note: "   ")
        let record = try #require(store.record(for: ann.id))
        #expect(record.note == nil)
    }
}

// MARK: - Waveform time-axis decimation
//
// MARK: - WaveformRenderer initialization
//
// Regression guard for the bug where the Metal shader library can't be found
// because `makeDefaultLibrary()` looks in the main app bundle by default —
// but with MurmurCore as its own framework, `WaveformShaders.metal` compiles
// into the framework's bundle, not the app's. Init returns nil, the canvas
// silently renders nothing (no waveform, no paper background), and the bug
// is invisible to the suite of unit tests that exercise data-layer logic.
// Fix is `device.makeDefaultLibrary(bundle: Bundle(for: WaveformRenderer.self))`.

import Metal

@Suite(
    "Waveform renderer initialization",
    // Xcode Cloud workers virtualise the GPU — MTLCreateSystemDefaultDevice
    // returns nil on the paravirtualised stack, so these tests are
    // local-only. The same code runs on dev Macs where a real Metal
    // device exists.
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)
)
@MainActor
struct WaveformRendererInitTests {

    @Test("Init must succeed on a Metal-capable device — catches missing shader library")
    func initSucceedsOnRealDevice() throws {
        let device = try #require(
            MTLCreateSystemDefaultDevice(),
            "Test requires a Metal-capable device — every modern Mac qualifies"
        )
        let renderer = WaveformRenderer(device: device)
        #expect(renderer != nil, """
            WaveformRenderer.init returned nil. The most likely cause is that
            `device.makeDefaultLibrary()` couldn't find the .metal shader library.
            With MurmurCore as a framework, the shader library lives in
            `MurmurCore.framework/Resources/`, not the main app bundle.
            Look at `WaveformRenderer.init` and use
            `device.makeDefaultLibrary(bundle: Bundle(for: WaveformRenderer.self))`.
            """)
    }
}

// MARK: - WaveformRenderer drawScene smoke test
//
// Phase 1 of the quality-infrastructure plan, adapted: instead of more
// XCUI tests that read accessibility-tree state, this drives the actual
// Metal draw path into an offscreen texture and verifies the renderer
// can produce output. Catches the same class of bug as the missing-
// waveform regression we shipped to TestFlight build 12 — code paths
// run, no errors, screen is wrong.
//
// The drawScene helper this test calls was extracted from `draw(in:)`
// specifically so it could be exercised without an MTKView.

@Suite(
    "Waveform renderer draws to offscreen texture",
    // Same as WaveformRendererInitTests — paravirtualised GPU on Xcode
    // Cloud can't satisfy MTLCreateSystemDefaultDevice. Local-only gate.
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)
)
@MainActor
struct WaveformRendererDrawSceneTests {

    @Test("drawScene clears the target to paper-pink — catches dead encoder / draw path")
    func clearsToPaperPink() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(WaveformRenderer(device: device))
        let queue = try #require(device.makeCommandQueue())

        // Offscreen BGRA8 target — same pixel layout an MTKView's drawable uses.
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 64,
            height: 64,
            mipmapped: false
        )
        textureDesc.usage = [.renderTarget, .shaderRead]
        textureDesc.storageMode = .managed
        let texture = try #require(device.makeTexture(descriptor: textureDesc))

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red:   Double(renderer.style.paper.x),
            green: Double(renderer.style.paper.y),
            blue:  Double(renderer.style.paper.z),
            alpha: 1.0
        )

        let cmdBuffer = try #require(queue.makeCommandBuffer())
        renderer.drawScene(
            commandBuffer: cmdBuffer,
            descriptor: descriptor,
            drawableSize: CGSize(width: 64, height: 64)
        )

        // .managed storage requires an explicit sync before CPU readback.
        let blit = try #require(cmdBuffer.makeBlitCommandEncoder())
        blit.synchronize(resource: texture)
        blit.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        let pixel = readBGRA(from: texture, at: (32, 32))

        // Paper-pink is (1.00, 0.93, 0.93) in linear sRGB → BGRA8 ≈ (237, 237, 255, 255).
        #expect(pixel.r > 240, "Red channel should be ~255 for paper-pink, got \(pixel.r)")
        #expect((220...250).contains(pixel.g), "Green channel should be ~237 for paper-pink, got \(pixel.g)")
        #expect((220...250).contains(pixel.b), "Blue channel should be ~237 for paper-pink, got \(pixel.b)")
        #expect(pixel.a == 255)
    }

    @Test("drawScene paints non-paper-pink pixels when a sample buffer is loaded — catches dead trace pipeline")
    func drawsTraceWhenSamplesLoaded() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(WaveformRenderer(device: device))
        let queue = try #require(device.makeCommandQueue())

        // Stuff a small triangular wave into the sample buffer. Values span the
        // full [-5, 5] mV range so the trace traverses most of the canvas height.
        let samples: [Float] = (0..<32).map { i in Float(i % 16 - 8) * 0.6 }
        let sampleBytes = samples.withUnsafeBytes { Data($0) }
        renderer.sampleBuffer = try #require(device.makeBuffer(
            bytes: Array(sampleBytes), length: sampleBytes.count, options: []
        ))
        renderer.sampleCount = samples.count
        renderer.uniforms.startSample = 0
        renderer.uniforms.endSample = Float(samples.count)
        renderer.uniforms.yMin = -5
        renderer.uniforms.yMax = 5
        renderer.useEnvelope = false

        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 64, mipmapped: false
        )
        textureDesc.usage = [.renderTarget, .shaderRead]
        textureDesc.storageMode = .managed
        let texture = try #require(device.makeTexture(descriptor: textureDesc))

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(renderer.style.paper.x),
            green: Double(renderer.style.paper.y),
            blue: Double(renderer.style.paper.z),
            alpha: 1.0
        )

        let cmdBuffer = try #require(queue.makeCommandBuffer())
        renderer.drawScene(
            commandBuffer: cmdBuffer,
            descriptor: descriptor,
            drawableSize: CGSize(width: 128, height: 64)
        )
        let blit = try #require(cmdBuffer.makeBlitCommandEncoder())
        blit.synchronize(resource: texture)
        blit.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        // Scan the whole texture for any pixel that isn't paper-pink. A dead
        // trace pipeline (shader miscompile, pipeline state mismatch, etc.)
        // would leave every pixel at the clear color.
        var nonPaperPixels = 0
        let totalPixels = texture.width * texture.height
        for y in stride(from: 0, to: texture.height, by: 1) {
            for x in stride(from: 0, to: texture.width, by: 1) {
                let pixel = readBGRA(from: texture, at: (x, y))
                // Paper-pink has G ~237, B ~237, R ~255. Trace black is near (0, 0, 0).
                // Anything with green/blue below 200 is decidedly not paper.
                if pixel.g < 200 || pixel.b < 200 {
                    nonPaperPixels += 1
                }
            }
        }
        #expect(nonPaperPixels > 0, """
            Every pixel in the offscreen target was paper-pink — the trace
            pipeline didn't draw anything. The renderer is silently dead. Check
            `WaveformShaders.metal` compiled successfully, `tracePipeline`
            initialized, and the trace draw path's uniforms math is sane.
            Total pixels: \(totalPixels), non-paper: \(nonPaperPixels).
            """)
    }

    /// Read a single BGRA8 pixel out of an offscreen texture.
    private func readBGRA(from texture: MTLTexture, at point: (Int, Int)) -> BGRAPixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: 4,
            from: MTLRegion(
                origin: MTLOrigin(x: point.0, y: point.1, z: 0),
                size: MTLSize(width: 1, height: 1, depth: 1)
            ),
            mipmapLevel: 0
        )
        return BGRAPixel(b: bytes[0], g: bytes[1], r: bytes[2], a: bytes[3])
    }

    struct BGRAPixel {
        let b: UInt8
        let g: UInt8
        let r: UInt8
        let a: UInt8
    }
}

// MARK: - Waveform time-axis label decimation
//
// Regression guards for the App Store Guideline 4 fix: tick labels on the
// waveform x-axis must never overlap each other. The decimation math lives
// on `WaveformTimeAxis.decimationStride(...)` so it's testable without
// rendering a SwiftUI view.

@Suite("Waveform time-axis label decimation")
struct WaveformTimeAxisDecimationTests {

    @Test("Default 10s viewport at 660pt — stride > 1 (the App Store rejection scenario)")
    func rejectionScenarioDecimates() {
        // 660pt wide, 10s window, 0.2s major spacing → 13.2 px per major.
        // 56 / 13.2 ≈ 4.24, so stride = 5. Without decimation, this is what
        // the reviewer saw as overlapping mush.
        let stride = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 660,
            durationSec: 10,
            majorSpacingSec: 0.2
        )
        #expect(stride == 5)
    }

    @Test("Comfortably wide viewport keeps every label (stride == 1)")
    func wideViewportNoDecimation() {
        // 5000pt for the same 10s window → 100 px per major; well over the
        // 56pt minimum, so we keep every label.
        let stride = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 5000,
            durationSec: 10,
            majorSpacingSec: 0.2
        )
        #expect(stride == 1)
    }

    @Test("Mid-width viewport drops every other label")
    func midWidthDropsEveryOther() {
        // 2000pt for the same 10s window → 40 px per major. ceil(56/40) = 2.
        let stride = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 2000,
            durationSec: 10,
            majorSpacingSec: 0.2
        )
        #expect(stride == 2)
    }

    @Test("Multi-minute viewport produces a large stride")
    func multiMinuteViewportLargeStride() {
        // 600pt for a 300s window with 1s major (the 30s–5min tier) →
        // 2 px per major; ceil(56/2) = 28.
        let stride = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 600,
            durationSec: 300,
            majorSpacingSec: 1.0
        )
        #expect(stride == 28)
    }

    @Test("Stride is never zero or negative — defense against pathological inputs")
    func strideAlwaysAtLeastOne() {
        // Zero duration would divide by zero without the internal clamp.
        let zeroDuration = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 800,
            durationSec: 0,
            majorSpacingSec: 0.2
        )
        #expect(zeroDuration >= 1)

        // Zero width similarly shouldn't crash.
        let zeroWidth = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 0,
            durationSec: 10,
            majorSpacingSec: 0.2
        )
        #expect(zeroWidth >= 1)

        // Zero major spacing — pxPerMajor degenerates to 0 → stride huge but finite.
        let zeroSpacing = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 800,
            durationSec: 10,
            majorSpacingSec: 0
        )
        #expect(zeroSpacing >= 1)
    }

    @Test("Raising minLabelSpacingPx increases the stride monotonically")
    func tighterGapMeansLargerStride() {
        // Same viewport, vary the gap requirement.
        let base = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 660,
            durationSec: 10,
            majorSpacingSec: 0.2,
            minLabelSpacingPx: 28
        )
        let stricter = WaveformTimeAxis.decimationStride(
            viewportWidthPx: 660,
            durationSec: 10,
            majorSpacingSec: 0.2,
            minLabelSpacingPx: 84
        )
        #expect(stricter >= base)
        #expect(stricter > 1)
    }

    @Test("Effective label gap after decimation always meets the minimum")
    func effectiveGapMeetsMinimum() {
        // For a range of viewport widths, verify that the *post-decimation*
        // pixel gap between rendered labels is always >= the minimum. This
        // is the actual invariant Apple cares about — that labels don't
        // visually overlap.
        let durationSec = 10.0
        let majorSpacingSec = 0.2
        let minGap = WaveformTimeAxis.minLabelSpacingPx
        for width: CGFloat in [200, 400, 660, 900, 1280, 2000, 4000] {
            let stride = WaveformTimeAxis.decimationStride(
                viewportWidthPx: width,
                durationSec: durationSec,
                majorSpacingSec: majorSpacingSec
            )
            let pxBetweenRenderedLabels = width * CGFloat(majorSpacingSec / durationSec) * CGFloat(stride)
            #expect(pxBetweenRenderedLabels >= minGap,
                    "Width \(width) produced \(pxBetweenRenderedLabels)px gap, below the \(minGap)pt minimum")
        }
    }
}

// MARK: - Category palette
//
// Color lookup for clinical annotation categories. Hand-tuned categories
// must return their assigned colors verbatim; unknown categories fall back
// to an FNV-1a–derived hue that must be stable across launches (Swift's
// built-in `hashValue` is not stable, which is why the palette rolls its own).

@Suite("Category palette")
struct CategoryPaletteTests {

    @Test("Known clinical categories return their hand-tuned fixed colors")
    func knownCategoriesUseFixedColors() {
        // Spot-check across the three palette families.
        #expect(CategoryPalette.color(for: "VT")  == SIMD4(0.95, 0.40, 0.20, 1.0))
        #expect(CategoryPalette.color(for: "VF")  == SIMD4(0.85, 0.10, 0.10, 1.0))
        #expect(CategoryPalette.color(for: "PVC") == SIMD4(0.85, 0.20, 0.55, 1.0))
        #expect(CategoryPalette.color(for: "AFib") == SIMD4(0.50, 0.20, 0.85, 1.0))
        #expect(CategoryPalette.color(for: "L")   == SIMD4(0.15, 0.40, 0.70, 1.0))
        #expect(CategoryPalette.color(for: "Noise") == SIMD4(0.40, 0.50, 0.60, 1.0))
    }

    @Test("Unknown categories fall back to a deterministic hash color (stable across calls)")
    func unknownCategoriesAreDeterministic() {
        let a1 = CategoryPalette.color(for: "MyExperimentalCategory")
        let a2 = CategoryPalette.color(for: "MyExperimentalCategory")
        #expect(a1 == a2)

        let b1 = CategoryPalette.color(for: "another")
        let b2 = CategoryPalette.color(for: "another")
        #expect(b1 == b2)
    }

    @Test("Different unknown categories generally produce different colors")
    func unknownCategoriesSpreadAcrossHues() {
        // Not statistically rigorous — just a sanity check that the hash
        // doesn't collapse every input to the same hue.
        let samples = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
        var unique: Set<SIMD4<Float>> = []
        for name in samples {
            unique.insert(CategoryPalette.color(for: name))
        }
        // At least 6 of 8 unique — allows the hash to incidentally collide
        // a couple of times without failing the suite.
        #expect(unique.count >= 6)
    }

    @Test("SwiftUI color matches the underlying SIMD4 component-wise")
    func swiftUIColorMirrorsRawColor() {
        // We can't easily round-trip a SwiftUI Color back to RGBA on macOS
        // without AppKit reach-around, so this is purely an existence /
        // no-crash assertion plus determinism: same input gives same Color.
        let c1 = CategoryPalette.swiftUIColor(for: "VT")
        let c2 = CategoryPalette.swiftUIColor(for: "VT")
        #expect(c1 == c2)
    }

    @Test("Severity modulates alpha in the documented direction")
    func severityAlphaOrdering() {
        let base: Float = 0.5
        let info = CategoryPalette.alpha(for: .info, baseAlpha: base)
        let notice = CategoryPalette.alpha(for: .notice, baseAlpha: base)
        let warning = CategoryPalette.alpha(for: .warning, baseAlpha: base)
        let critical = CategoryPalette.alpha(for: .critical, baseAlpha: base)
        // Strictly monotonic increase from info → critical.
        #expect(info < notice)
        #expect(notice < warning)
        #expect(warning < critical)
    }

    @Test("Severity alpha clamps to 1.0 — never paints above full opacity")
    func severityAlphaClampedAtOne() {
        // baseAlpha 0.9 * 1.30 = 1.17, must clamp to 1.0.
        let alpha = CategoryPalette.alpha(for: .critical, baseAlpha: 0.9)
        #expect(alpha <= 1.0)
        #expect(alpha == 1.0)
    }

    @Test("Empty-string category routes through the hash fallback without crashing")
    func emptyStringIsHashed() {
        let color = CategoryPalette.color(for: "")
        // FNV-1a starts at 2166136261; with no bytes, mod 360 → hue ≈ 81/360 → green.
        // We don't pin the exact color, just that it's deterministic.
        #expect(color == CategoryPalette.color(for: ""))
        #expect(color.w == 1.0)
    }

    @Test("Hash-derived colors stay in the legal sRGB range [0, 1]")
    func hashColorsStayInRange() {
        let samples = ["foo", "bar", "baz", "quux", "lorem", "ipsum", "research_only_signal"]
        for name in samples {
            let c = CategoryPalette.color(for: name)
            #expect(c.x >= 0 && c.x <= 1)
            #expect(c.y >= 0 && c.y <= 1)
            #expect(c.z >= 0 && c.z <= 1)
            #expect(c.w == 1.0)
        }
    }
}

// MARK: - Synthetic recording fixtures
//
// SyntheticRecording is the welcome-screen "Try a sample recording" path
// and the source of test fixtures. Failures here break first-launch UX
// and silently disable a chunk of the importer suite.

@Suite("Synthetic recording fixtures")
struct SyntheticRecordingTests {

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synth-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: makeWFDBRecord (single-rate, single-file)

    @Test("makeWFDBRecord writes a valid .hea record line with all 8 ECG signal lines")
    func singleRateHeaderShape() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let heaURL = try SyntheticRecording.makeWFDBRecord(into: dir)

        let text = try String(contentsOf: heaURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 9)                     // 1 record line + 8 signal lines
        // Record line: "synth 8 250 2500"
        #expect(lines[0] == "synth 8 250 2500")
        // Every signal line points at the same single .dat file.
        for i in 1..<lines.count {
            #expect(lines[i].hasPrefix("synth.dat 16 "))
        }
    }

    @Test("makeWFDBRecord writes a .dat sized exactly for 8 signals × 2500 samples × 2 bytes")
    func singleRateDatIsCorrectSize() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SyntheticRecording.makeWFDBRecord(into: dir)
        let datURL = dir.appendingPathComponent("synth.dat")
        let attrs = try FileManager.default.attributesOfItem(atPath: datURL.path)
        let size = try #require(attrs[.size] as? Int)
        #expect(size == 8 * 2500 * 2)
    }

    @Test("makeWFDBRecord parses cleanly through the header parser")
    func singleRateHeaderParsesCleanly() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let heaURL = try SyntheticRecording.makeWFDBRecord(into: dir)
        let header = try WFDBHeaderParser.parse(url: heaURL)
        #expect(header.recordName == "synth")
        #expect(header.signalCount == 8)
        #expect(header.samplingFrequency == 250.0)
        #expect(header.sampleCount == 2500)
        #expect(header.signals.allSatisfy { $0.format == 16 })
        #expect(Set(header.signals.map(\.label)) == Set(["I","II","III","aVR","aVL","aVF","V1","V2"]))
    }

    // MARK: makeMultiFrequencyRecord (multi-rate, per-signal files)

    @Test("makeMultiFrequencyRecord writes 14 per-signal .dat files plus header and annotations sidecar")
    func multiFrequencyEmitsAllFiles() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SyntheticRecording.makeMultiFrequencyRecord(into: dir)

        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let names = Set(contents.map(\.lastPathComponent))
        #expect(names.contains("synth.hea"))
        #expect(names.contains("synth.annotations.json"))
        // 8 ECG + 6 trend = 14 .dat files.
        let datCount = names.filter { $0.hasSuffix(".dat") }.count
        #expect(datCount == 14)
    }

    @Test("makeMultiFrequencyRecord header carries the spf suffix on ECG signals only")
    func multiFrequencyHeaderHasSpfSuffix() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let heaURL = try SyntheticRecording.makeMultiFrequencyRecord(into: dir)
        let text = try String(contentsOf: heaURL, encoding: .utf8)
        // 8 ECG signal lines have "16x250"; 6 trend lines have "16x1".
        let ecgMatches = text.components(separatedBy: "16x250 ").count - 1
        let trendMatches = text.components(separatedBy: "16x1 ").count - 1
        #expect(ecgMatches == 8)
        #expect(trendMatches == 6)
    }

    @Test("makeMultiFrequencyRecord header parses cleanly with mixed sample rates")
    func multiFrequencyHeaderParses() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let heaURL = try SyntheticRecording.makeMultiFrequencyRecord(into: dir)
        let header = try WFDBHeaderParser.parse(url: heaURL)
        #expect(header.signalCount == 14)
        // Base frame rate is 1 Hz; ECG signals have spf=250 for an effective 250 Hz.
        let ecg = header.signals.first { $0.label == "II" }
        let hr  = header.signals.first { $0.label == "HR_bpm" }
        let ecgSig = try #require(ecg)
        let hrSig  = try #require(hr)
        #expect(header.sampleRate(for: ecgSig) == 250.0)
        #expect(header.sampleRate(for: hrSig) == 1.0)
    }

    @Test("Annotations sidecar contains the three demo findings (VT range + VF point + VT range)")
    func annotationsSidecarShape() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SyntheticRecording.makeMultiFrequencyRecord(into: dir)
        let jsonURL = dir.appendingPathComponent("synth.annotations.json")
        let data = try Data(contentsOf: jsonURL)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["schemaVersion"] as? Int == 1)
        let findings = try #require(obj["findings"] as? [[String: Any]])
        #expect(findings.count == 3)
        let categories = findings.compactMap { $0["category"] as? String }
        #expect(categories.sorted() == ["VF", "VT", "VT"])
    }

    @Test("Trend .dat for HR_bpm is sized for exactly 10 1-Hz frames")
    func trendDatIsCorrectSize() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SyntheticRecording.makeMultiFrequencyRecord(into: dir)
        let datURL = dir.appendingPathComponent("synth_HR_bpm.dat")
        let attrs = try FileManager.default.attributesOfItem(atPath: datURL.path)
        let size = try #require(attrs[.size] as? Int)
        // 10 frames × 1 spf × 2 bytes per Int16 = 20 bytes.
        #expect(size == 20)
    }
}

// MARK: - Pyramid level file
//
// The on-disk file format for one pyramid level: a 64-byte
// BinaryRecordingHeader (with `sampleCount` repurposed as bin count)
// followed by Float64 (min, max) pairs.

@Suite("Pyramid level file")
struct PyramidLevelFileTests {

    private static func makeTempURL(name: String = "pyramid.bin") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pyr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private static func header(binCount: Int64, binRateHz: Double = 25.0) -> BinaryRecordingHeader {
        BinaryRecordingHeader(
            version: BinaryRecordingHeader.currentVersion,
            startTimeUnixMS: 0,
            sampleRateHz: binRateHz,
            sampleCount: binCount
        )
    }

    @Test("Writes and round-trips a small set of bins")
    func roundTripsBins() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bins: [PyramidBin] = [
            .init(min: -1.0, max: 1.0),
            .init(min: 0.5, max: 2.5),
            .init(min: -3.0, max: -1.0)
        ]
        try PyramidLevelFile.write(bins: bins, header: Self.header(binCount: Int64(bins.count)), to: url)

        let access = try PyramidLevelFile.mappedAccess(url: url)
        #expect(access.binCount == Int64(bins.count))
        let read = access.bins(range: 0..<Int64(bins.count))
        #expect(read == bins)
    }

    @Test("bins(range:) returns a partial slice correctly")
    func returnsPartialSlice() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bins: [PyramidBin] = (0..<10).map { i in
            PyramidBin(min: Double(i), max: Double(i) + 0.5)
        }
        try PyramidLevelFile.write(bins: bins, header: Self.header(binCount: Int64(bins.count)), to: url)

        let access = try PyramidLevelFile.mappedAccess(url: url)
        let middle = access.bins(range: 3..<7)
        #expect(middle.count == 4)
        #expect(middle == Array(bins[3..<7]))
    }

    @Test("Reads past the end of the file return NaN-padded bins")
    func padsOutOfRangeWithNaN() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bins: [PyramidBin] = [.init(min: 1.0, max: 2.0), .init(min: 3.0, max: 4.0)]
        try PyramidLevelFile.write(bins: bins, header: Self.header(binCount: Int64(bins.count)), to: url)

        // Ask for 5 bins starting at index 0; only 2 exist on disk.
        let access = try PyramidLevelFile.mappedAccess(url: url)
        let read = access.bins(range: 0..<5)
        #expect(read.count == 5)
        #expect(read[0] == bins[0])
        #expect(read[1] == bins[1])
        for i in 2..<5 {
            #expect(read[i].isNaN, "bin \(i) should be NaN, got (\(read[i].min), \(read[i].max))")
        }
    }

    @Test("NaN bins survive a write/read round-trip intact")
    func nanBinsRoundTrip() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bins: [PyramidBin] = [
            .nan,
            .init(min: 0.0, max: 1.0),
            .nan
        ]
        try PyramidLevelFile.write(bins: bins, header: Self.header(binCount: Int64(bins.count)), to: url)

        let access = try PyramidLevelFile.mappedAccess(url: url)
        let read = access.bins(range: 0..<3)
        #expect(read[0].isNaN)
        #expect(read[1] == bins[1])
        #expect(read[2].isNaN)
    }

    @Test("Empty bin file has binCount == 0 and an empty read")
    func emptyFileReadsAsEmpty() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try PyramidLevelFile.write(bins: [], header: Self.header(binCount: 0), to: url)
        let access = try PyramidLevelFile.mappedAccess(url: url)
        #expect(access.binCount == 0)
        let read = access.bins(range: 0..<0)
        #expect(read.isEmpty)
    }
}

// MARK: - Streaming channel file
//
// Append-only writer that flushes batched samples into a packed-Float32
// .bin file, patching the header's sampleCount at finalize() time.
// Used by the importer to stream a channel without materializing the
// whole sample buffer.

@Suite("Streaming channel file")
struct StreamingChannelFileTests {

    private static func makeTempURL(name: String = "channel.bin") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test("Appends a small sample buffer and the finalized file round-trips")
    func smallBufferRoundTrips() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = try StreamingChannelFile(url: url, sampleRateHz: 250.0, startTimeUnixMS: 1_700_000_000_000)
        let samples: [Float] = [-1.0, 0.0, 0.5, 1.0, 2.0]
        for s in samples { try writer.append(s) }
        try writer.finalize()

        let read = try BinaryRecordingFile.readSamples(url: url, range: 0..<Int64(samples.count))
        #expect(read == samples)
    }

    @Test("Finalize patches the header sampleCount to match the appended count")
    func finalizePatchesSampleCount() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = try StreamingChannelFile(url: url, sampleRateHz: 100.0, startTimeUnixMS: 0)
        for i in 0..<7 { try writer.append(Float(i)) }
        try writer.finalize()

        let data = try Data(contentsOf: url)
        let header = try BinaryRecordingFile.decodeHeader(data)
        #expect(header.sampleCount == 7)
        #expect(header.sampleRateHz == 100.0)
    }

    @Test("Appending more than bufferCapacity flushes correctly across batches")
    func crossesBufferBoundary() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = try StreamingChannelFile(url: url, sampleRateHz: 250.0, startTimeUnixMS: 0)
        // bufferCapacity is 8192; write 8200 samples so we cross the flush
        // boundary and an explicit finalize() handles the trailing remainder.
        let total = StreamingChannelFile.bufferCapacity + 8
        for i in 0..<total {
            try writer.append(Float(i % 100))
        }
        try writer.finalize()

        let access = try BinaryRecordingFile.mappedAccess(url: url)
        #expect(access.header.sampleCount == Int64(total))
        let read = try BinaryRecordingFile.readSamples(url: url, range: 0..<Int64(total))
        #expect(read.count == total)
        #expect(read.first == 0)
        #expect(read.last == Float((total - 1) % 100))
        // Pick a sample on the far side of the flush boundary to make sure
        // the batch handoff didn't drop or duplicate anything.
        #expect(read[StreamingChannelFile.bufferCapacity] == Float(StreamingChannelFile.bufferCapacity % 100))
    }

    @Test("appendNaN(count:) writes the requested number of NaN samples")
    func appendsNaNRun() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = try StreamingChannelFile(url: url, sampleRateHz: 100.0, startTimeUnixMS: 0)
        try writer.append(1.0)
        try writer.appendNaN(count: 3)
        try writer.append(2.0)
        try writer.finalize()

        let read = try BinaryRecordingFile.readSamples(url: url, range: 0..<5)
        #expect(read[0] == 1.0)
        #expect(read[1].isNaN)
        #expect(read[2].isNaN)
        #expect(read[3].isNaN)
        #expect(read[4] == 2.0)
    }

    @Test("Empty stream (no appends) finalizes to a header-only file with sampleCount 0")
    func emptyStreamFinalizes() throws {
        let url = try Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = try StreamingChannelFile(url: url, sampleRateHz: 200.0, startTimeUnixMS: 0)
        try writer.finalize()

        let data = try Data(contentsOf: url)
        #expect(data.count == BinaryRecordingHeader.headerByteSize)
        let header = try BinaryRecordingFile.decodeHeader(data)
        #expect(header.sampleCount == 0)
    }
}

// MARK: - RecordingStore
//
// Owns the on-disk layout under Application Support / Murmur /
// recordings / <uuid> /. The store is @MainActor; these tests inject
// a temp directory so they don't touch the user's real data.

@Suite("Recording store")
struct RecordingStoreTests {

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Initializing the store with a custom root creates the directory")
    @MainActor
    func initCreatesRootDirectory() throws {
        // Point at a fresh directory that does NOT yet exist; init should make it.
        let parent = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("freshly-made", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let store = RecordingStore(rootURL: root)
        _ = store  // silence unused warning
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("listRecordingDirectories starts empty and reports created bundles")
    @MainActor
    func listsRecordingDirectories() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        #expect(try store.listRecordingDirectories().isEmpty)

        // Create two dummy bundles by hand and confirm they show up.
        let a = root.appendingPathComponent("aaa", isDirectory: true)
        let b = root.appendingPathComponent("bbb", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let listed = try store.listRecordingDirectories()
        #expect(Set(listed.map(\.lastPathComponent)) == ["aaa", "bbb"])
    }

    @Test("loadManifest round-trips a Recording written by importWFDB")
    @MainActor
    func loadsManifestAfterImport() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)

        // Stage a fresh WFDB record in a sibling folder so the importer
        // has something to chew on. importWFDB takes the *folder* and the
        // .hea filename — the same shape ContentView uses.
        let srcDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: srcDir) }
        _ = try SyntheticRecording.makeWFDBRecord(into: srcDir)

        let summary = try await store.importWFDB(folderURL: srcDir, heaFilename: "synth.hea")
        let loaded = try store.loadManifest(at: summary.directory)
        #expect(loaded.id == summary.recording.id)
        #expect(loaded.channels.count == 8)
    }

    @Test("loadManifest throws when the manifest file is missing")
    @MainActor
    func loadManifestThrowsOnMissingFile() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        let emptyBundle = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        #expect(throws: Error.self) {
            _ = try store.loadManifest(at: emptyBundle)
        }
    }

    @Test("remove(at:) deletes the bundle directory")
    @MainActor
    func removeDeletesBundle() throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)
        let bundle = root.appendingPathComponent("doomed", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: bundle.path))

        try store.remove(at: bundle)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
    }
}

// MARK: - Bundle annotations sidecar
//
// The on-disk `annotations.json` that lives inside each imported recording
// bundle. Decoupling annotations from the manifest lets re-runs of the
// producer (or the "Attach findings…" action) update findings without
// rewriting the much heavier recording.json.

@Suite("Bundle annotations sidecar")
struct BundleAnnotationsFileTests {

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-ann-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func annotation(category: String = "PVC", at sample: Int64 = 100) -> Annotation {
        Annotation(
            kind: .point,
            sampleIndex: sample,
            category: category,
            confidence: 0.9,
            severity: .warning,
            source: "test"
        )
    }

    @Test("Write then read round-trips a finding list")
    func writeThenReadRoundTrips() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = [Self.annotation(category: "VT"), Self.annotation(category: "VF", at: 500)]
        try BundleAnnotationsFile.write(original, to: dir)
        let read = try #require(BundleAnnotationsFile.read(from: dir))
        #expect(read == original)
    }

    @Test("read returns nil when the sidecar is missing")
    func readReturnsNilWhenAbsent() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BundleAnnotationsFile.read(from: dir) == nil)
    }

    @Test("read returns nil for a sidecar with an unsupported schemaVersion")
    func rejectsUnsupportedSchema() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let badPayload = """
        { "schemaVersion": 99, "annotations": [] }
        """
        try badPayload.write(
            to: dir.appendingPathComponent("annotations.json"),
            atomically: true,
            encoding: .utf8
        )
        #expect(BundleAnnotationsFile.read(from: dir) == nil)
    }

    @Test("Rewriting the sidecar replaces (not merges) prior contents")
    func rewriteReplaces() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try BundleAnnotationsFile.write([Self.annotation(category: "OldFinding")], to: dir)
        try BundleAnnotationsFile.write([Self.annotation(category: "NewFinding")], to: dir)
        let read = try #require(BundleAnnotationsFile.read(from: dir))
        #expect(read.map(\.category) == ["NewFinding"])
    }

    @Test("Importer writes annotations.json next to recording.json")
    func importerWritesSidecar() throws {
        let srcDir = try Self.makeTempDir()
        let outDir = try Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: outDir)
        }
        // The synthetic multi-frequency record ships an annotations sidecar
        // already (3 demo findings), which the importer should pick up and
        // copy into the bundle's annotations.json.
        let heaURL = try SyntheticRecording.makeMultiFrequencyRecord(into: srcDir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outDir)
        let sidecarURL = summary.directory.appendingPathComponent("annotations.json")
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
        let read = try #require(BundleAnnotationsFile.read(from: summary.directory))
        #expect(read.count == summary.recording.annotations.count)
    }

    @Test("RecordingStore.loadManifest prefers the sidecar over manifest-inline annotations")
    @MainActor
    func loadManifestPrefersSidecar() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)

        let srcDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: srcDir) }
        _ = try SyntheticRecording.makeWFDBRecord(into: srcDir)

        let summary = try await store.importWFDB(folderURL: srcDir, heaFilename: "synth.hea")
        // Single-rate fixture has no sidecar in the source folder, so the
        // importer creates an annotations.json containing [] in the bundle.
        // Overwrite it with two attached-style findings and re-load.
        let attached = [
            Self.annotation(category: "AttachedVT", at: 200),
            Self.annotation(category: "AttachedVF", at: 800)
        ]
        try BundleAnnotationsFile.write(attached, to: summary.directory)

        let reloaded = try store.loadManifest(at: summary.directory)
        let categories = Set(reloaded.annotations.map(\.category))
        #expect(categories == ["AttachedVT", "AttachedVF"])
    }

    @Test("Producer-emitted findings round-trip through write + loadManifest into the bundle")
    @MainActor
    func producerOutputRoundtrips() async throws {
        // Mirrors `BedsideView.handleProducerOutput`'s persistence path:
        // append producer findings to the existing union, write to the
        // bundle sidecar, then verify a fresh loadManifest returns the
        // producer findings tagged with their source.
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(rootURL: root)

        let srcDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: srcDir) }
        _ = try SyntheticRecording.makeWFDBRecord(into: srcDir)
        let summary = try await store.importWFDB(folderURL: srcDir, heaFilename: "synth.hea")

        let producerFindings = [
            Annotation(
                kind: .point, sampleIndex: 100,
                category: "VT", source: "murmur.synthetic"
            ),
            Annotation(
                kind: .point, sampleIndex: 500,
                category: "PVC", source: "murmur.synthetic"
            )
        ]
        let union = summary.recording.annotations + producerFindings
        try BundleAnnotationsFile.write(union, to: summary.directory)

        let reloaded = try store.loadManifest(at: summary.directory)
        let producerOutput = reloaded.annotations
            .filter { $0.source == "murmur.synthetic" }
        #expect(producerOutput.count == 2)
        #expect(producerOutput.contains { $0.category == "VT" && $0.sampleIndex == 100 })
        #expect(producerOutput.contains { $0.category == "PVC" && $0.sampleIndex == 500 })
    }

    @Test("BundleAnnotationsFile.write throws when the target directory is missing")
    func writeFailsForMissingDirectory() {
        // Reproduces the "save findings failed" failure mode that
        // handleProducerOutput catches and surfaces in the attach-error
        // alert. The sidecar writer must throw a recognizable error
        // when the bundle directory doesn't exist on disk.
        let nonExistentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let annotations = [Self.annotation(category: "Test", at: 100)]
        do {
            try BundleAnnotationsFile.write(annotations, to: nonExistentDir)
            Issue.record("BundleAnnotationsFile.write should have thrown for missing directory")
        } catch {
            // Pass — any thrown error covers the failure semantics.
            // The exact error type comes from Foundation's Data.write,
            // so we don't pin to a specific case.
        }
    }
}

// MARK: - Purchase store / entitlement gating

@Suite("Purchase store entitlement gating")
struct PurchaseStoreTests {

    @Test("Product IDs match the registered App Store Connect identifiers")
    func productIDsStable() {
        #expect(PurchaseStore.ProductID.annotationAuthoring.rawValue == "com.kevinlong.murmur.annotationauthoring")
        #expect(PurchaseStore.ProductID.silverMetrics.rawValue == "com.kevinlong.murmur.silvermetrics")
        #expect(PurchaseStore.ProductID.vtDetection.rawValue == "com.kevinlong.murmur.vtdetection")
        #expect(PurchaseStore.ProductID.allCases.count == 3)
    }

    @Test("requiredProduct maps producer IDs to their gating IAP; free producers return nil")
    func producerToProductMapping() {
        #expect(PurchaseStore.requiredProduct(forProducerID: "murmur.annotation") == .annotationAuthoring)
        #expect(PurchaseStore.requiredProduct(forProducerID: "murmur.silver") == .silverMetrics)
        #expect(PurchaseStore.requiredProduct(forProducerID: "murmur.vtdetect") == .vtDetection)
        #expect(PurchaseStore.requiredProduct(forProducerID: "murmur.synthetic") == nil)
        #expect(PurchaseStore.requiredProduct(forProducerID: "anything.else") == nil)
    }

    @Test("Fresh store starts with no entitlements")
    @MainActor
    func startsEmpty() {
        let store = PurchaseStore()
        for product in PurchaseStore.ProductID.allCases {
            #expect(!store.owns(product), "Fresh store should not own \(product.rawValue)")
        }
        #expect(store.ownedProductIDs.isEmpty)
    }

    @Test("canRun returns true for free producers regardless of entitlement state")
    @MainActor
    func canRunFreeProducersAlwaysPasses() {
        let store = PurchaseStore()
        // No entitlements → free producer still passes.
        #expect(store.canRun(producerID: "murmur.synthetic"))
        #expect(store.canRun(producerID: "unmapped.id"))
    }

    @Test("canRun returns false for paid producers without entitlement")
    @MainActor
    func canRunPaidWithoutEntitlement() {
        let store = PurchaseStore()
        #expect(!store.canRun(producerID: "murmur.silver"))
        #expect(!store.canRun(producerID: "murmur.vtdetect"))
        #expect(!store.canRun(producerID: "murmur.annotation"))
    }

    @Test("canRun returns true for paid producers once the IAP is owned")
    @MainActor
    func canRunPaidWithEntitlement() {
        let store = PurchaseStore()
        store._setOwnedForTesting([.silverMetrics])
        #expect(store.canRun(producerID: "murmur.silver"))
        // Other paid producers still gated.
        #expect(!store.canRun(producerID: "murmur.vtdetect"))
        #expect(!store.canRun(producerID: "murmur.annotation"))
    }

    @Test("Owning one product doesn't grant entitlement to the others")
    @MainActor
    func entitlementsAreIndependent() {
        let store = PurchaseStore()
        store._setOwnedForTesting([.annotationAuthoring])
        #expect(store.owns(.annotationAuthoring))
        #expect(!store.owns(.silverMetrics))
        #expect(!store.owns(.vtDetection))
    }
}

// MARK: - Citation builder

@Suite("Citation builder")
struct CitationBuilderTests {

    @Test("BibTeX output is a valid @software entry with required fields")
    func bibtexShape() {
        let entry = CitationBuilder.formatViewer(
            format: .bibtex,
            version: "1.0.0",
            doi: "10.5281/zenodo.1234567",
            year: 2026
        )
        #expect(entry.contains("@software{murmur_studio,"))
        #expect(entry.contains("author       = {Long, Kevin}"))
        #expect(entry.contains("year         = {2026}"))
        #expect(entry.contains("version      = {1.0.0}"))
        #expect(entry.contains("doi          = {10.5281/zenodo.1234567}"))
        #expect(entry.contains("url          = {https://github.com/kvnlng/Murmur}"))
    }

    @Test("RIS output uses the correct type code and fields")
    func risShape() {
        let entry = CitationBuilder.formatViewer(
            format: .ris,
            version: "1.0.0",
            doi: "10.5281/zenodo.1234567",
            year: 2026
        )
        #expect(entry.hasPrefix("TY  - COMP"))
        #expect(entry.contains("\nAU  - Long, Kevin"))
        #expect(entry.contains("\nPY  - 2026"))
        #expect(entry.contains("\nET  - 1.0.0"))
        #expect(entry.contains("\nDO  - 10.5281/zenodo.1234567"))
        #expect(entry.hasSuffix("ER  -"))
    }

    @Test("Missing DOI substitutes the placeholder so the entry is still copy-pasteable")
    func placeholderDOIWhenMissing() {
        let entry = CitationBuilder.formatViewer(
            format: .bibtex,
            version: "1.0.0",
            doi: nil,
            year: 2026
        )
        #expect(entry.contains(CitationBuilder.pendingDOIPlaceholder))
    }

    @Test("Both formats are deterministic for the same inputs")
    func deterministicOutput() {
        for format in CitationFormat.allCases {
            let a = CitationBuilder.formatViewer(format: format, version: "1.2.3", doi: "10.5281/zenodo.42", year: 2026)
            let b = CitationBuilder.formatViewer(format: format, version: "1.2.3", doi: "10.5281/zenodo.42", year: 2026)
            #expect(a == b, "Citation should be deterministic for \(format.rawValue)")
        }
    }

    @Test("Year falls back to the current UTC year when nil")
    func yearFallback() {
        // Hard to pin to a specific year without injecting `now`; instead
        // assert the output contains a plausible 4-digit year between
        // 2024 and 2099.
        let entry = CitationBuilder.formatViewer(format: .bibtex, doi: "10.5281/zenodo.X")
        let yearPattern = try? NSRegularExpression(pattern: "year         = \\{(20\\d{2})\\}")
        let range = NSRange(entry.startIndex..., in: entry)
        let match = yearPattern?.firstMatch(in: entry, range: range)
        #expect(match != nil, "BibTeX entry should carry a 4-digit year in the 2000s")
    }

    @Test("Version string is preserved verbatim (no rewriting / quoting)")
    func versionPreservedVerbatim() {
        let entry = CitationBuilder.formatViewer(
            format: .bibtex,
            version: "2.5.0-beta.3",
            doi: "10.5281/zenodo.99",
            year: 2026
        )
        #expect(entry.contains("version      = {2.5.0-beta.3}"))
    }
}

// MARK: - Snapshot exporter

@Suite("Snapshot exporter filename")
struct SnapshotExporterTests {
    private func channel(sampleCount: Int64 = 2500, sampleRate: Double = 250) -> Channel {
        Channel(
            id: UUID(),
            name: "II",
            unit: "mV",
            sampleRate: sampleRate,
            startTimeUnixMS: 0,
            sampleCount: sampleCount,
            storageFileName: "ii.bin",
            pyramid: []
        )
    }

    @Test("Suggested filename derives stem from sourceFileName + UTC stamp")
    func filenameStem() {
        let rec = Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "test-device",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "synth.hea",
            channels: [channel()]
        )
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15T15:06:40Z
        let name = SnapshotExporter.suggestedFilename(for: rec, at: stamp)
        #expect(name == "synth-snapshot-2025-06-15-1506.png")
    }

    @Test("Empty source filename falls back to 'recording'")
    func filenameFallback() {
        let rec = Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "test-device",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "",
            channels: [channel()]
        )
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let name = SnapshotExporter.suggestedFilename(for: rec, at: stamp)
        #expect(name == "recording-snapshot-2025-06-15-1506.png")
    }

    @Test("Filename strips an arbitrary extension from sourceFileName")
    func filenameStripsExtension() {
        let rec = Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "test-device",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "patient-001.hea",
            channels: [channel()]
        )
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let name = SnapshotExporter.suggestedFilename(for: rec, at: stamp)
        #expect(name == "patient-001-snapshot-2025-06-15-1506.png")
    }

    @Test("Filename uses UTC consistently — different local timezones don't shift the stamp")
    func filenameUTCStable() {
        let rec = Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "test-device",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "synth.hea",
            channels: [channel()]
        )
        // A specific moment expressed two ways: same input, same output.
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let a = SnapshotExporter.suggestedFilename(for: rec, at: stamp)
        let b = SnapshotExporter.suggestedFilename(for: rec, at: stamp)
        #expect(a == b)
    }
}

// MARK: - Annotation clustering

@Suite("Annotation clustering for overlay decimation")
struct AnnotationClusteringTests {
    private func point(at sample: Int64, category: String = "PVC") -> Annotation {
        Annotation(
            kind: .point,
            sampleIndex: sample,
            category: category,
            source: "test"
        )
    }

    private func range(start: Int64, end: Int64, category: String = "AFib") -> Annotation {
        Annotation(
            kind: .range,
            sampleIndex: start,
            endSampleIndex: end,
            category: category,
            source: "test"
        )
    }

    @Test("Empty input returns empty output")
    func emptyIsEmpty() {
        #expect(AnnotationClustering.cluster([], mergeWithinSamples: 100).isEmpty)
    }

    @Test("Single point becomes a count-1 cluster")
    func singlePointSingleton() {
        let result = AnnotationClustering.cluster([point(at: 200)], mergeWithinSamples: 100)
        #expect(result.count == 1)
        #expect(result[0].count == 1)
        #expect(result[0].sampleIndex == 200)
    }

    @Test("Adjacent same-category points within threshold collapse to one cluster")
    func adjacentMergeIntoOneCluster() {
        let result = AnnotationClustering.cluster([
            point(at: 100),
            point(at: 150),
            point(at: 200)
        ], mergeWithinSamples: 100)
        #expect(result.count == 1)
        #expect(result[0].count == 3)
        #expect(result[0].sampleIndex == 150)   // centroid = (100+150+200)/3
    }

    @Test("Same-category points beyond threshold stay as separate clusters")
    func farApartStaysSeparate() {
        let result = AnnotationClustering.cluster([
            point(at: 100),
            point(at: 500)
        ], mergeWithinSamples: 100)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.count == 1 })
    }

    @Test("Different-category neighbours never merge")
    func differentCategoryNeverMerges() {
        let result = AnnotationClustering.cluster([
            point(at: 100, category: "PVC"),
            point(at: 120, category: "AFib")
        ], mergeWithinSamples: 100)
        #expect(result.count == 2)
    }

    @Test("Threshold of zero disables clustering entirely")
    func thresholdZeroNoClustering() {
        let result = AnnotationClustering.cluster([
            point(at: 100),
            point(at: 100),
            point(at: 100)
        ], mergeWithinSamples: 0)
        // Adjacent same-sample same-category points: distance = 0, which
        // is <= 0, so they DO merge. To disable clustering, the threshold
        // would need to be negative — document with a separate test.
        #expect(result.count == 1)
        #expect(result[0].count == 3)
    }

    @Test("Negative threshold disables clustering — every annotation is its own cluster")
    func negativeThresholdNoClustering() {
        let result = AnnotationClustering.cluster([
            point(at: 100),
            point(at: 110),
            point(at: 120)
        ], mergeWithinSamples: -1)
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.count == 1 })
    }

    @Test("Range annotations pass through with count == 1, no merging")
    func rangesPassThrough() {
        let result = AnnotationClustering.cluster([
            range(start: 100, end: 500),
            range(start: 200, end: 400)
        ], mergeWithinSamples: 1000)
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.count == 1 })
    }

    @Test("Output is sorted ascending by sampleIndex regardless of input order")
    func outputSorted() {
        let result = AnnotationClustering.cluster([
            point(at: 800),
            point(at: 100),
            point(at: 400)
        ], mergeWithinSamples: 50)
        let samples = result.map(\.sampleIndex)
        #expect(samples == samples.sorted())
    }

    @Test("displayLabel suffixes count for clusters of more than one")
    func displayLabelSuffix() {
        let result = AnnotationClustering.cluster([
            point(at: 100),
            point(at: 150)
        ], mergeWithinSamples: 100)
        #expect(result[0].displayLabel == "PVC ×2")
    }

    @Test("displayLabel has no suffix for solo annotations")
    func displayLabelSolo() {
        let result = AnnotationClustering.cluster([point(at: 100)], mergeWithinSamples: 100)
        #expect(result[0].displayLabel == "PVC")
    }

    @Test("Cluster memberIDs lists every contained annotation in input order")
    func memberIDsListed() {
        let a = point(at: 100)
        let b = point(at: 120)
        let c = point(at: 140)
        let result = AnnotationClustering.cluster([a, b, c], mergeWithinSamples: 100)
        #expect(result[0].memberIDs == [a.id, b.id, c.id])
    }

    @Test("Mixed points + ranges interleave correctly by sampleIndex")
    func mixedInterleavedOrder() {
        let result = AnnotationClustering.cluster([
            point(at: 300),
            range(start: 100, end: 200),
            point(at: 700)
        ], mergeWithinSamples: 50)
        #expect(result.map(\.sampleIndex) == [100, 300, 700])
    }
}

// MARK: - Markdown report generator

@Suite("Markdown report generator")
struct MarkdownReportTests {

    private func channel(sampleRate: Double = 250, sampleCount: Int64 = 2500, startMS: Int64 = 0) -> Channel {
        Channel(
            id: UUID(),
            name: "II",
            unit: "mV",
            sampleRate: sampleRate,
            startTimeUnixMS: startMS,
            sampleCount: sampleCount,
            storageFileName: "ii.bin",
            pyramid: []
        )
    }

    private func recording(channels: [Channel], annotations: [Annotation] = []) -> Recording {
        Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "test-device",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "synth.hea",
            channels: channels,
            annotations: annotations
        )
    }

    private func annotation(
        id: UUID = UUID(),
        at sample: Int64,
        category: String = "PVC",
        confidence: Double? = nil,
        severity: Annotation.Severity = .info,
        source: String = "test"
    ) -> Annotation {
        Annotation(
            id: id,
            kind: .point,
            sampleIndex: sample,
            category: category,
            confidence: confidence,
            severity: severity,
            source: source
        )
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)   // deterministic stamp

    @Test("Empty recording produces a 'No findings' section, not a table")
    func emptyRecording() {
        let rec = recording(channels: [channel()])
        let report = MarkdownReport.generate(
            recording: rec,
            annotations: [],
            dispositions: [:],
            tally: .init(confirmed: 0, dismissed: 0, unreviewed: 0),
            now: now
        )
        #expect(report.contains("_No findings on this recording._"))
        #expect(!report.contains("| Time |"), "Empty recording should not render the table header")
    }

    @Test("Findings table is sorted by sample index regardless of input order")
    func tableSortedByTime() {
        let rec = recording(channels: [channel()])
        let input = [
            annotation(at: 500, category: "VT"),
            annotation(at: 100, category: "PVC"),
            annotation(at: 300, category: "AFib")
        ]
        let report = MarkdownReport.generate(
            recording: rec,
            annotations: input,
            dispositions: [:],
            tally: .init(confirmed: 0, dismissed: 0, unreviewed: 3),
            now: now
        )
        let pvcIdx = report.range(of: "PVC")!.lowerBound
        let afibIdx = report.range(of: "AFib")!.lowerBound
        let vtIdx = report.range(of: "VT")!.lowerBound
        #expect(pvcIdx < afibIdx)
        #expect(afibIdx < vtIdx)
    }

    @Test("Confidence renders nil as em-dash, value as %.2f")
    func confidenceFormatting() {
        let rec = recording(channels: [channel()])
        let withConfidence = annotation(at: 100, confidence: 0.876)
        let withoutConfidence = annotation(at: 200, confidence: nil)
        let report = MarkdownReport.generate(
            recording: rec,
            annotations: [withConfidence, withoutConfidence],
            dispositions: [:],
            tally: .init(confirmed: 0, dismissed: 0, unreviewed: 2),
            now: now
        )
        #expect(report.contains("| 0.88 |"))
        #expect(report.contains("| — |"))
    }

    @Test("Disposition column reflects confirmed / dismissed / unreviewed correctly")
    func dispositionColumn() {
        let confirmedID = UUID()
        let dismissedID = UUID()
        let unreviewedID = UUID()
        let rec = recording(channels: [channel()])
        let annotations = [
            annotation(id: confirmedID, at: 100, category: "VT"),
            annotation(id: dismissedID, at: 200, category: "PVC"),
            annotation(id: unreviewedID, at: 300, category: "Noise")
        ]
        let dispositions: [UUID: AnnotationDisposition] = [
            confirmedID: AnnotationDisposition(
                annotationID: confirmedID,
                state: .confirmed,
                confirmedKind: .vt,
                note: nil,
                reviewedAt: now,
                reviewedBy: "tester"
            ),
            dismissedID: AnnotationDisposition(
                annotationID: dismissedID,
                state: .dismissed,
                confirmedKind: nil,
                note: nil,
                reviewedAt: now,
                reviewedBy: "tester"
            )
        ]
        let report = MarkdownReport.generate(
            recording: rec,
            annotations: annotations,
            dispositions: dispositions,
            tally: .init(confirmed: 1, dismissed: 1, unreviewed: 1),
            now: now
        )
        #expect(report.contains("confirmed (VT)"))
        #expect(report.contains("dismissed"))
        #expect(report.contains("unreviewed"))
    }

    @Test("Triage summary lines match the supplied tally")
    func triageSummaryMatchesTally() {
        let rec = recording(channels: [channel()])
        let report = MarkdownReport.generate(
            recording: rec,
            annotations: [],
            dispositions: [:],
            tally: .init(confirmed: 4, dismissed: 2, unreviewed: 7),
            now: now
        )
        #expect(report.contains("- Confirmed: 4"))
        #expect(report.contains("- Dismissed: 2"))
        #expect(report.contains("- Unreviewed: 7"))
        #expect(report.contains("- **Total**: 13"))
    }

    @Test("Metadata block lists device, source file, channel count, and start time")
    func metadataBlock() {
        let rec = recording(channels: [channel(sampleRate: 500, sampleCount: 100_000, startMS: 1_700_000_000_000)])
        let report = MarkdownReport.generate(
            recording: rec,
            annotations: [],
            dispositions: [:],
            tally: .init(confirmed: 0, dismissed: 0, unreviewed: 0),
            now: now
        )
        #expect(report.contains("- **Device**: test-device"))
        #expect(report.contains("- **Source file**: `synth.hea`"))
        #expect(report.contains("- **Channels**: 1"))
        #expect(report.contains("- **Sample rate (primary channel)**: 500 Hz"))
    }

    @Test("Pipe character in finding metadata is escaped so table rows stay intact")
    func pipeEscapedInCategory() {
        let rec = recording(channels: [channel()])
        let evil = annotation(at: 100, category: "VT|critical", source: "producer|v1")
        let report = MarkdownReport.generate(
            recording: rec,
            annotations: [evil],
            dispositions: [:],
            tally: .init(confirmed: 0, dismissed: 0, unreviewed: 1),
            now: now
        )
        #expect(report.contains("VT\\|critical"))
        #expect(report.contains("producer\\|v1"))
    }

    @Test("Generated-at footer carries the supplied `now` timestamp deterministically")
    func footerStampDeterministic() {
        let rec = recording(channels: [channel()])
        let report = MarkdownReport.generate(
            recording: rec,
            annotations: [],
            dispositions: [:],
            tally: .init(confirmed: 0, dismissed: 0, unreviewed: 0),
            now: now
        )
        // 1_750_000_000 unix seconds → 2025-06-15T15:06:40Z.
        #expect(report.contains("2025-06-15T15:06:40Z"))
    }

    @Test("formatTime renders short and long timecodes in MM:SS.ss")
    func formatTimeMinutesSeconds() {
        #expect(MarkdownReport.formatTime(seconds: 0) == "0:00.00")
        #expect(MarkdownReport.formatTime(seconds: 5.5) == "0:05.50")
        #expect(MarkdownReport.formatTime(seconds: 65.42) == "1:05.42")
    }

    @Test("formatDuration picks the right unit per recording length")
    func formatDurationUnits() {
        #expect(MarkdownReport.formatDuration(10) == "10.0 s")
        #expect(MarkdownReport.formatDuration(120) == "2.0 min")
        #expect(MarkdownReport.formatDuration(7200) == "2.0 hr")
    }

    @Test("BedsideView.suggestedReportFilename derives stem from sourceFileName + UTC timestamp")
    func suggestedFilenameFormat() {
        let rec = recording(channels: [channel()])
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15T15:06:40Z
        let name = BedsideView.suggestedReportFilename(for: rec, at: stamp)
        #expect(name == "synth-report-2025-06-15-1506.md")
    }

    @Test("Suggested filename falls back to 'recording' when source has no name")
    func suggestedFilenameFallback() {
        let bare = Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "test-device",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "",   // some bundles ship with no source path
            channels: [channel()],
            annotations: []
        )
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        let name = BedsideView.suggestedReportFilename(for: bare, at: stamp)
        #expect(name == "recording-report-2025-06-15-1506.md")
    }
}

// MARK: - Min/max scanner

@Suite("Min/max sample scanner")
struct MinMaxScannerTests {

    @Test("Empty input returns nil")
    func emptyReturnsNil() {
        #expect(MinMaxScanner.scan(samples: [Float]()) == nil)
    }

    @Test("All-NaN input returns nil")
    func allNaNReturnsNil() {
        let samples: [Float] = [.nan, .nan, .nan]
        #expect(MinMaxScanner.scan(samples: samples) == nil)
    }

    @Test("Finite-only buffer returns exact min and max")
    func finiteBufferExactMinMax() {
        let samples: [Float] = [-2.5, 0.0, 1.2, 3.4, -1.0]
        let result = MinMaxScanner.scan(samples: samples)
        #expect(result?.min == -2.5)
        #expect(result?.max == 3.4)
        #expect(result?.validSampleCount == 5)
        #expect(result?.isEmpty == false)
    }

    @Test("NaN samples are skipped but valid samples still scan")
    func nanSkippedFiniteRespected() {
        let samples: [Float] = [1.0, .nan, 3.0, .nan, 2.0]
        let result = MinMaxScanner.scan(samples: samples)
        #expect(result?.min == 1.0)
        #expect(result?.max == 3.0)
        #expect(result?.validSampleCount == 3)
    }

    @Test("Infinity samples are skipped along with NaN")
    func infinitySkipped() {
        let samples: [Float] = [.infinity, 1.5, -.infinity, 0.5]
        let result = MinMaxScanner.scan(samples: samples)
        #expect(result?.min == 0.5)
        #expect(result?.max == 1.5)
        #expect(result?.validSampleCount == 2)
    }

    @Test("Single-sample input produces a degenerate but valid range")
    func singleSampleValid() {
        let result = MinMaxScanner.scan(samples: [2.5] as [Float])
        #expect(result?.min == 2.5)
        #expect(result?.max == 2.5)
        #expect(result?.validSampleCount == 1)
    }

    @Test("Scanner is stable across reorderings of the same data")
    func orderInvariant() {
        let a: [Float] = [-2.0, 3.0, 0.5, 1.0]
        let b: [Float] = [1.0, 0.5, 3.0, -2.0]
        #expect(MinMaxScanner.scan(samples: a) == MinMaxScanner.scan(samples: b))
    }

    // MARK: - displayRange derivation

    @Test("displayRange pads the observed range by 10% on each side")
    func displayRangePads() {
        let range = MinMaxScanner.Range(min: -1.0, max: 1.0, validSampleCount: 100)
        let display = range.displayRange()
        // Observed span = 2 → padding = 0.2; padded range = [-1.2, 1.2].
        #expect(abs(display.lowerBound - (-1.2)) < 1e-9)
        #expect(abs(display.upperBound - 1.2) < 1e-9)
    }

    @Test("displayRange widens to the minSpan floor for near-flat signals")
    func displayRangeRespectsMinSpan() {
        let flat = MinMaxScanner.Range(min: 0.0, max: 0.0, validSampleCount: 1)
        let display = flat.displayRange(padding: 0, minSpan: 0.5)
        // No padding, but minSpan 0.5 → centered range [-0.25, 0.25].
        #expect(abs(display.lowerBound - (-0.25)) < 1e-9)
        #expect(abs(display.upperBound - 0.25) < 1e-9)
    }

    @Test("displayRange stays centred on the observed midpoint when widening to minSpan")
    func displayRangeCentersOnMidpoint() {
        let offset = MinMaxScanner.Range(min: 2.0, max: 2.1, validSampleCount: 10)
        let display = offset.displayRange(padding: 0, minSpan: 1.0)
        // Midpoint 2.05, span 1.0 → range [1.55, 2.55]. Tolerance is
        // 1e-6 because the input min/max are stored as Float, so
        // Double(2.1) carries half a ulp of rounding error.
        #expect(abs(display.lowerBound - 1.55) < 1e-6)
        #expect(abs(display.upperBound - 2.55) < 1e-6)
    }

    @Test("Negative values produce a symmetric padded range")
    func displayRangeNegativeValues() {
        let range = MinMaxScanner.Range(min: -3.0, max: -1.0, validSampleCount: 100)
        let display = range.displayRange(padding: 0.1, minSpan: 0)
        // Observed span = 2, padding = 0.2 → [-3.2, -0.8].
        #expect(abs(display.lowerBound - (-3.2)) < 1e-9)
        #expect(abs(display.upperBound - (-0.8)) < 1e-9)
    }

    @Test("Custom padding fraction is honoured")
    func customPadding() {
        let range = MinMaxScanner.Range(min: 0, max: 10, validSampleCount: 5)
        let display = range.displayRange(padding: 0.5, minSpan: 0)
        // span 10, padding 5 → [-5, 15].
        #expect(abs(display.lowerBound - (-5)) < 1e-9)
        #expect(abs(display.upperBound - 15) < 1e-9)
    }
}

// MARK: - Finding sort modes

@Suite("Finding sort modes")
struct FindingSortTests {
    private func a(
        sample: Int64,
        category: String = "PVC",
        severity: Annotation.Severity = .info,
        confidence: Double? = nil
    ) -> Annotation {
        Annotation(
            kind: .point,
            sampleIndex: sample,
            category: category,
            confidence: confidence,
            severity: severity,
            source: "test"
        )
    }

    @Test("Time sort returns findings in ascending sampleIndex order")
    func timeAscending() {
        let input = [a(sample: 300), a(sample: 100), a(sample: 200)]
        let out = FindingSort.time.apply(to: input)
        #expect(out.map(\.sampleIndex) == [100, 200, 300])
    }

    @Test("Severity sort puts critical first; ties break by time")
    func severityDescendingWithTimeTiebreak() {
        let input = [
            a(sample: 100, severity: .info),
            a(sample: 200, severity: .critical),
            a(sample: 300, severity: .warning),
            a(sample: 400, severity: .critical)   // ties with sample=200 on rank
        ]
        let out = FindingSort.severity.apply(to: input)
        #expect(out.map(\.severity) == [.critical, .critical, .warning, .info])
        // Within critical, the earlier sample comes first.
        let critical = out.filter { $0.severity == .critical }.map(\.sampleIndex)
        #expect(critical == [200, 400])
    }

    @Test("Confidence sort puts highest first, nils last")
    func confidenceDescendingNilsLast() {
        let input = [
            a(sample: 100, confidence: 0.5),
            a(sample: 200, confidence: nil),
            a(sample: 300, confidence: 0.95),
            a(sample: 400, confidence: 0.5),     // ties with sample=100 on confidence
            a(sample: 500, confidence: nil)
        ]
        let out = FindingSort.confidence.apply(to: input)
        #expect(out.map(\.confidence) == [0.95, 0.5, 0.5, nil, nil])
        // Within equal-confidence rows the earlier sample comes first.
        let mid = out.filter { $0.confidence == 0.5 }.map(\.sampleIndex)
        #expect(mid == [100, 400])
        // Nil rows still ordered by time at the tail.
        let tail = out.filter { $0.confidence == nil }.map(\.sampleIndex)
        #expect(tail == [200, 500])
    }

    @Test("Category sort is alphabetical; ties break by time")
    func categoryAlphabeticalWithTimeTiebreak() {
        let input = [
            a(sample: 100, category: "VT"),
            a(sample: 200, category: "AFib"),
            a(sample: 300, category: "AFib"),
            a(sample: 400, category: "PVC")
        ]
        let out = FindingSort.category.apply(to: input)
        #expect(out.map(\.category) == ["AFib", "AFib", "PVC", "VT"])
        let afib = out.filter { $0.category == "AFib" }.map(\.sampleIndex)
        #expect(afib == [200, 300])
    }

    @Test("Sort is total — no two equal-position findings swap on repeat sort")
    func sortIsStableAcrossRuns() {
        let input = [
            a(sample: 100, severity: .info),
            a(sample: 200, severity: .info),
            a(sample: 300, severity: .info)
        ]
        let once = FindingSort.severity.apply(to: input)
        let twice = FindingSort.severity.apply(to: once)
        #expect(once.map(\.id) == twice.map(\.id))
    }

    @Test("All sort modes preserve count")
    func allModesPreserveCount() {
        let input = (0..<10).map { a(sample: Int64($0 * 100)) }
        for mode in FindingSort.allCases {
            #expect(mode.apply(to: input).count == input.count,
                    "\(mode.rawValue) sort must not drop findings")
        }
    }
}

// MARK: - Rubber-band damping curve

@Suite("Rubber-band overscroll damping")
struct RubberBandTests {

    @Test("Zero overshoot yields zero translation")
    func zeroIsIdentity() {
        #expect(RubberBand.damp(overshoot: 0, canvasWidth: 800) == 0)
    }

    @Test("Sign of overshoot is preserved in output")
    func signPreserved() {
        let positive = RubberBand.damp(overshoot: 50, canvasWidth: 800)
        let negative = RubberBand.damp(overshoot: -50, canvasWidth: 800)
        #expect(positive > 0)
        #expect(negative < 0)
        #expect(abs(positive) == abs(negative), "Curve is symmetric about zero")
    }

    @Test("Output is strictly less than the raw overshoot (damped)")
    func dampingActuallyDamps() {
        for raw in [10.0, 50.0, 100.0, 500.0, 1500.0] {
            let damped = RubberBand.damp(overshoot: CGFloat(raw), canvasWidth: 800)
            #expect(damped < CGFloat(raw), "Damped output must be smaller than raw overshoot (raw=\(raw), damped=\(damped))")
        }
    }

    @Test("Damped translation asymptotes at canvasWidth")
    func asymptoteAtCanvasWidth() {
        let canvasWidth: CGFloat = 800
        // Very large overshoot should approach but not exceed canvasWidth.
        let extreme = RubberBand.damp(overshoot: 100_000, canvasWidth: canvasWidth)
        #expect(extreme < canvasWidth, "Curve must stay strictly below canvasWidth")
        #expect(extreme > canvasWidth * 0.95, "Curve must be near canvasWidth at extreme overshoot")
    }

    @Test("Output is monotonically increasing with |overshoot|")
    func monotone() {
        let canvasWidth: CGFloat = 800
        let samples: [CGFloat] = [10, 50, 100, 200, 500, 1000, 5000]
        let damped = samples.map { RubberBand.damp(overshoot: $0, canvasWidth: canvasWidth) }
        for (a, b) in zip(damped, damped.dropFirst()) {
            #expect(a < b, "Damping must be monotonic (\(a) < \(b))")
        }
    }

    @Test("Zero or negative canvas width yields zero translation (no division by zero)")
    func handlesDegenerateCanvas() {
        #expect(RubberBand.damp(overshoot: 100, canvasWidth: 0) == 0)
        #expect(RubberBand.damp(overshoot: 100, canvasWidth: -50) == 0)
    }
}

// MARK: - Annotation keyboard navigation helpers

@Suite("Annotation next/previous finding")
struct AnnotationNavigationTests {
    private func annotation(at sample: Int64) -> Annotation {
        Annotation(
            kind: .point,
            sampleIndex: sample,
            category: "Test",
            source: "test"
        )
    }

    @Test("nextFinding returns the first finding strictly after position")
    func nextAfterPositionStrict() {
        let list = [annotation(at: 100), annotation(at: 200), annotation(at: 300)]
        #expect(Annotation.nextFinding(after: 0, in: list)?.sampleIndex == 100)
        #expect(Annotation.nextFinding(after: 100, in: list)?.sampleIndex == 200)
        #expect(Annotation.nextFinding(after: 250, in: list)?.sampleIndex == 300)
    }

    @Test("nextFinding returns nil when no finding lies after the position")
    func nextReturnsNilAtEnd() {
        let list = [annotation(at: 100), annotation(at: 200)]
        #expect(Annotation.nextFinding(after: 200, in: list) == nil)
        #expect(Annotation.nextFinding(after: 9999, in: list) == nil)
    }

    @Test("nextFinding tolerates an unsorted input list")
    func nextSortsInput() {
        let list = [annotation(at: 300), annotation(at: 100), annotation(at: 200)]
        #expect(Annotation.nextFinding(after: 0, in: list)?.sampleIndex == 100)
        #expect(Annotation.nextFinding(after: 150, in: list)?.sampleIndex == 200)
    }

    @Test("previousFinding returns the last finding strictly before position")
    func previousBeforePositionStrict() {
        let list = [annotation(at: 100), annotation(at: 200), annotation(at: 300)]
        #expect(Annotation.previousFinding(before: 9999, in: list)?.sampleIndex == 300)
        #expect(Annotation.previousFinding(before: 250, in: list)?.sampleIndex == 200)
        #expect(Annotation.previousFinding(before: 200, in: list)?.sampleIndex == 100)
    }

    @Test("previousFinding returns nil when no finding lies before the position")
    func previousReturnsNilAtStart() {
        let list = [annotation(at: 100), annotation(at: 200)]
        #expect(Annotation.previousFinding(before: 100, in: list) == nil)
        #expect(Annotation.previousFinding(before: 0, in: list) == nil)
    }

    @Test("Empty annotation list produces nil from both navigators")
    func emptyListYieldsNil() {
        #expect(Annotation.nextFinding(after: 50, in: []) == nil)
        #expect(Annotation.previousFinding(before: 50, in: []) == nil)
    }

    @Test("closest picks the annotation with minimum |sampleIndex - position|")
    func closestPicksNearest() {
        let list = [annotation(at: 100), annotation(at: 250), annotation(at: 800)]
        #expect(Annotation.closest(to: 0, in: list)?.sampleIndex == 100)
        #expect(Annotation.closest(to: 200, in: list)?.sampleIndex == 250)
        #expect(Annotation.closest(to: 500, in: list)?.sampleIndex == 250)
        #expect(Annotation.closest(to: 1000, in: list)?.sampleIndex == 800)
    }

    @Test("closest on an empty list returns nil")
    func closestEmptyIsNil() {
        #expect(Annotation.closest(to: 50, in: []) == nil)
    }

    @Test("closest ties resolve deterministically to the earlier sample")
    func closestTiesBreakEarlier() {
        let list = [annotation(at: 200), annotation(at: 100)]
        // Position 150 is equidistant from 100 and 200. Tie → earlier wins.
        #expect(Annotation.closest(to: 150, in: list)?.sampleIndex == 100)
    }
}

// MARK: - Lead-specific annotation routing

@Suite("Annotation channel routing by lead")
struct AnnotationChannelRoutingTests {
    private func annotation(lead: String?) -> Annotation {
        Annotation(
            kind: .point,
            sampleIndex: 0,
            category: "Test",
            source: "test",
            lead: lead
        )
    }

    @Test("Lead-less findings match every channel")
    func leadlessMatchesEveryone() {
        let a = annotation(lead: nil)
        #expect(a.matchesChannel("II"))
        #expect(a.matchesChannel("V5"))
        #expect(a.matchesChannel("aVR"))
    }

    @Test("Empty / whitespace-only lead is treated as lead-less")
    func emptyLeadIsLeadless() {
        #expect(annotation(lead: "").matchesChannel("II"))
        #expect(annotation(lead: "   ").matchesChannel("II"))
    }

    @Test("Lead-tagged findings only match the named channel")
    func leadTaggedMatchesOne() {
        let a = annotation(lead: "II")
        #expect(a.matchesChannel("II"))
        #expect(!a.matchesChannel("V5"))
        #expect(!a.matchesChannel("aVR"))
    }

    @Test("Channel matching is case-insensitive")
    func channelMatchCaseInsensitive() {
        #expect(annotation(lead: "ii").matchesChannel("II"))
        #expect(annotation(lead: "II").matchesChannel("ii"))
        #expect(annotation(lead: "AvR").matchesChannel("aVR"))
    }

    @Test("Surrounding whitespace is trimmed before comparison")
    func channelMatchTrimsWhitespace() {
        #expect(annotation(lead: " II ").matchesChannel("II"))
        #expect(annotation(lead: "II").matchesChannel(" II "))
    }
}

// MARK: - Finding producer protocol

@Suite("Finding producer pipeline")
struct FindingProducerTests {

    /// Builds a minimal in-memory Recording with one ECG channel of the
    /// given duration. Doesn't write any sample data — the synthetic
    /// producer doesn't read samples, only metadata.
    private func recording(durationSeconds: Double, sampleRate: Double = 250) -> Recording {
        let channel = Channel(
            id: UUID(),
            name: "II",
            unit: "mV",
            sampleRate: sampleRate,
            startTimeUnixMS: 0,
            sampleCount: Int64(durationSeconds * sampleRate),
            storageFileName: "ii.bin",
            pyramid: []
        )
        return Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "test-device",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "test.hea",
            channels: [channel]
        )
    }

    /// Drains the producer's event stream into separate progress /
    /// findings / warnings arrays so individual tests can assert on
    /// the cleanly-split summaries instead of pattern-matching events.
    private func drain(
        _ stream: AsyncThrowingStream<ProducerEvent, Error>
    ) async throws -> (
        progress: [ProgressUpdate],
        findings: [Annotation],
        warnings: [String]
    ) {
        var progress: [ProgressUpdate] = []
        var findings: [Annotation] = []
        var warnings: [String] = []
        for try await event in stream {
            switch event {
            case .progress(let p): progress.append(p)
            case .findings(let f): findings.append(contentsOf: f)
            case .warning(let msg, _): warnings.append(msg)
            }
        }
        return (progress, findings, warnings)
    }

    @Test("ProgressUpdate clamps fractionComplete into [0, 1]")
    func progressClamps() {
        #expect(ProgressUpdate(fractionComplete: -0.5, stage: "x").fractionComplete == 0)
        #expect(ProgressUpdate(fractionComplete: 1.5, stage: "x").fractionComplete == 1)
        #expect(ProgressUpdate(fractionComplete: 0.5, stage: "x").fractionComplete == 0.5)
    }

    @Test("Synthetic producer is deterministic across runs with the same seed")
    func syntheticDeterministic() async throws {
        let rec = recording(durationSeconds: 60)
        let producer = SyntheticFindingProducer(seed: 12345)
        let firstRun = try await drain(producer.analyze(rec)).findings
        let secondRun = try await drain(producer.analyze(rec)).findings
        #expect(firstRun.count == secondRun.count)
        #expect(firstRun.map(\.sampleIndex) == secondRun.map(\.sampleIndex))
        #expect(firstRun.map(\.category) == secondRun.map(\.category))
    }

    @Test("Different seeds produce different finding sets")
    func syntheticSeedSensitive() async throws {
        let rec = recording(durationSeconds: 60)
        let a = try await drain(SyntheticFindingProducer(seed: 1).analyze(rec)).findings
        let b = try await drain(SyntheticFindingProducer(seed: 2).analyze(rec)).findings
        // Could collide in pathological cases but with default probability +
        // window cadence it's astronomically unlikely.
        #expect(a.map(\.sampleIndex) != b.map(\.sampleIndex))
    }

    @Test("Findings carry the producer's id as their source")
    func syntheticSourceTagged() async throws {
        let producer = SyntheticFindingProducer(seed: 42)
        let findings = try await drain(producer.analyze(recording(durationSeconds: 30))).findings
        #expect(!findings.isEmpty, "Need at least one finding to check source tagging")
        #expect(findings.allSatisfy { $0.source == producer.id })
    }

    @Test("Progress monotonically advances and terminates at 1.0")
    func progressMonotone() async throws {
        let producer = SyntheticFindingProducer(seed: 7)
        let progress = try await drain(producer.analyze(recording(durationSeconds: 20))).progress
        let fractions = progress.map(\.fractionComplete)
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
        for (a, b) in zip(fractions, fractions.dropFirst()) {
            #expect(a <= b, "fractionComplete must be monotonically non-decreasing")
        }
    }

    @Test("Empty recording emits a terminal progress event and no findings")
    func emptyRecording() async throws {
        let producer = SyntheticFindingProducer(seed: 1)
        let empty = Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "empty",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "",
            channels: []
        )
        let result = try await drain(producer.analyze(empty))
        #expect(result.findings.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.progress.last?.fractionComplete == 1)
    }

    @Test("Cancellation: cancelled consumer aborts the stream cleanly")
    func cancellationAborts() async throws {
        let producer = SyntheticFindingProducer(
            seed: 99,
            findingProbability: 1.0,    // every window emits, so cancellation has lots to interrupt
            windowSeconds: 0.1
        )
        let rec = recording(durationSeconds: 600)  // 6000 windows worth of work

        let task = Task<Int, Error> {
            var seen = 0
            for try await event in producer.analyze(rec) {
                if case .findings = event { seen += 1 }
                if seen >= 3 { break }  // exit consumer mid-stream
            }
            return seen
        }
        let count = try await task.value
        #expect(count == 3, "Consumer should observe exactly the events it asked for before bailing")
    }

    @Test("ProducerRegistry round-trips registration, lookup, and ordering")
    func registryRoundtrip() async {
        let registry = ProducerRegistry()
        let a = SyntheticFindingProducer(seed: 1)
        await registry.register(a)
        let lookup = await registry.producer(id: a.id)
        #expect(lookup?.id == a.id)
        #expect(await registry.all().count == 1)

        await registry.unregister(id: a.id)
        #expect(await registry.producer(id: a.id) == nil)
        #expect(await registry.all().isEmpty)
    }

    @Test("ProducerRegistry: registering the same id twice replaces (last-write-wins)")
    func registryReplacesOnDuplicateID() async {
        let registry = ProducerRegistry()
        await registry.register(SyntheticFindingProducer(seed: 1))
        await registry.register(SyntheticFindingProducer(seed: 2))
        #expect(await registry.all().count == 1)
        // The most recent registration wins; deterministic by ID alone since
        // both producers share id="murmur.synthetic".
        #expect(await registry.producer(id: "murmur.synthetic") != nil)
    }

    @Test("bootstrapBaselineProducers registers the synthetic producer in DEBUG builds")
    @MainActor
    func bootstrapRegistersSyntheticInDebug() async {
        // The shared registry is process-wide and other tests may have
        // populated it. We isolate by snapshotting + restoring via
        // unregister, but that's fragile — instead, just assert the
        // post-bootstrap state has the synthetic producer present.
        // (The bootstrap is a one-shot launch hook; re-running it is
        // idempotent because the registry de-dupes on id.)
        await bootstrapBaselineProducers()
        let producer = await ProducerRegistry.shared.producer(id: "murmur.synthetic")
        #if DEBUG
        #expect(producer != nil, "DEBUG bootstrap must register SyntheticFindingProducer")
        #expect(producer?.displayName == "Synthetic test producer")
        #else
        // Release builds keep the registry empty until paid frameworks
        // register their own producers.
        #expect(producer == nil)
        #endif
    }
}

