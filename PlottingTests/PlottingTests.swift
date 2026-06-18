//
//  PlottingTests.swift
//  PlottingTests
//

import Foundation
import Testing
@testable import Plotting

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
            .appendingPathComponent("PlottingRecentsTest-\(UUID().uuidString)", isDirectory: true)
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
        #expect(resolved.path == folder.path)
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

        // 8 ECG signals + 5 low-rate signals (HR, SpO₂, alarm,
        // P(spontaneous), P(assist-control)) = 13 total.
        #expect(summary.recording.channels.count == 13)

        let ecg = summary.recording.channels.first { $0.name == "II" }
        let hr  = summary.recording.channels.first { $0.name == "HR_bpm" }
        let spo2 = summary.recording.channels.first { $0.name == "SpO2_pct" }
        let alarm = summary.recording.channels.first { $0.name == "had_high_priority_alarm" }
        let probSpontaneous = summary.recording.channels.first { $0.name == "prob_state_spontaneous" }
        try #require(ecg != nil)
        try #require(hr != nil)
        try #require(spo2 != nil)
        try #require(alarm != nil)
        try #require(probSpontaneous != nil)
        #expect(alarm!.isTrendChannel)
        #expect(probSpontaneous!.isTrendChannel)

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
}
