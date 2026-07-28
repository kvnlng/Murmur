//
//  CSVImportTests.swift
//  MurmurTests
//
//  The one-hard-form CSV importer: golden parses, header-vs-dialog parity,
//  sentinel handling, and one fixture per refusal reason. Per
//  project_csv_import_spec.md the importer's only outcomes are a parsed result
//  or a single-reason refusal — these pin both.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("CSVImport — accept one form, refuse the rest")
struct CSVImportTests {

    private func parse(_ csv: String, _ meta: CSVImport.Metadata? = nil) throws -> CSVImport.Parsed {
        try CSVImport.parse(data: Data(csv.utf8), dialogMetadata: meta)
    }

    /// Refusal reason for a CSV, or nil if it parsed.
    private func reason(_ csv: String, _ meta: CSVImport.Metadata? = nil) -> CSVImport.Refusal.Reason? {
        do { _ = try parse(csv, meta); return nil }
        catch let r as CSVImport.Refusal { return r.reason }
        catch { return nil }
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-wfdb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - CSV → WFDB → import round-trip (X15-B)

    @Test("ADC-counts CSV → WFDB record → import recovers the counts")
    func adcRoundTripThroughImporter() throws {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 2
        # lead_names: II, V1
        # amplitude_encoding: adc_counts
        0,10,-20
        1,11,-21
        2,12,-22
        """
        let parsed = try parse(csv)
        let dir = try tempDir()
        let heaURL = try CSVImport.writeWFDBRecord(parsed, recordName: "rec", in: dir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: try tempDir())
        #expect(summary.recording.channels.count == 2)
        #expect(summary.recording.channels.first?.sampleRate == 250)
        let primary = try #require(summary.recording.primaryECGSamples(inDirectory: summary.directory))
        // gain unspecified → 1, so physical readback equals the raw counts.
        #expect(primary.map { Int($0.rounded()) } == [10, 11, 12])
    }

    @Test("Physical CSV → WFDB record → import recovers the physical values")
    func physicalRoundTripThroughImporter() throws {
        let csv = """
        # index_kind: time_seconds
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: physical
        # physical_unit: mV
        0,0.10
        0.004,0.25
        0.008,-0.05
        """
        let parsed = try parse(csv)
        let dir = try tempDir()
        let heaURL = try CSVImport.writeWFDBRecord(parsed, recordName: "rec", in: dir)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: try tempDir())
        let primary = try #require(summary.recording.primaryECGSamples(inDirectory: summary.directory))
        let expected = [0.10, 0.25, -0.05]
        #expect(primary.count == 3)
        for (got, want) in zip(primary, expected) {
            #expect(abs(Double(got) - want) < 1e-4, "recovered \(got), expected \(want)")
        }
    }

    // MARK: - Golden parses

    @Test("ADC-counts + sample_number header block parses verbatim")
    func goldenADC() throws {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 2
        # lead_names: II, V1
        # amplitude_encoding: adc_counts
        0,10,-20
        1,11,-21
        2,12,-22
        """
        let p = try parse(csv)
        #expect(p.sampleRateHz == 250)
        #expect(p.channelSamples == [[10, 11, 12], [-20, -21, -22]])
        #expect(p.missingByChannel == [[], []])
        #expect(p.metadataFromHeaderBlock)
    }

    @Test("Physical + time_seconds proposes a lossless power-of-ten gain")
    func goldenPhysical() throws {
        let csv = """
        # index_kind: time_seconds
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: physical
        # physical_unit: mV
        0,0.10
        0.004,0.25
        0.008,-0.05
        """
        let p = try parse(csv)
        #expect(abs(p.sampleRateHz - 250) < 1e-6)
        #expect(p.gain == 100)
        #expect(p.channelSamples == [[10, 25, -5]])
    }

    @Test("Same data via header block and via dialog metadata parse identically")
    func headerVsDialogParity() throws {
        let data = """
        0,10,-20
        1,11,-21
        """
        let header = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 2
        # lead_names: II, V1
        # amplitude_encoding: adc_counts
        \(data)
        """
        let dialogMeta = CSVImport.Metadata(
            indexKind: .sampleNumber, sampleRateHz: 250, numChannels: 2,
            leadNames: ["II", "V1"], amplitude: .adcCounts(resolutionBits: 16, gain: 0, baseline: 0, unit: "mV")
        )
        let viaHeader = try parse(header)
        let viaDialog = try parse(data, dialogMeta)
        #expect(viaHeader.channelSamples == viaDialog.channelSamples)
        #expect(viaHeader.sampleRateHz == viaDialog.sampleRateHz)
        #expect(viaHeader.gain == viaDialog.gain)
    }

    // MARK: - Sentinel

    @Test("Declared sentinel cells become marked-missing at the right indices")
    func sentinelMarksMissing() throws {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: adc_counts
        # sentinel: -32768
        0,10
        1,-32768
        2,12
        """
        let p = try parse(csv)
        #expect(p.missingByChannel == [[1]])
        #expect(p.channelSamples[0][0] == 10 && p.channelSamples[0][2] == 12)
    }

    @Test("A non-sentinel non-conformant cell refuses even when a sentinel is declared")
    func nonSentinelGarbageRefuses() {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: adc_counts
        # sentinel: -32768
        0,10
        1,oops
        """
        #expect(reason(csv) == .nonConformantCell)
    }

    // MARK: - One fixture per refusal reason

    @Test("Semicolon delimiter → column-count mismatch (no delimiter sniffing)")
    func wrongDelimiter() {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 2
        # lead_names: II, V1
        # amplitude_encoding: adc_counts
        0;10;-20
        """
        #expect(reason(csv) == .columnCountMismatch)
    }

    @Test("Ragged row refuses")
    func raggedRow() {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 2
        # lead_names: II, V1
        # amplitude_encoding: adc_counts
        0,10,-20
        1,11
        """
        #expect(reason(csv) == .raggedRow)
    }

    @Test("adc_counts value out of 16-bit range refuses")
    func adcOutOfRange() {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: adc_counts
        # adc_resolution_bits: 16
        0,40000
        """
        #expect(reason(csv) == .adcValueOutOfRange)
    }

    @Test("Embedded unit in a physical cell refuses")
    func embeddedUnit() {
        let csv = """
        # index_kind: time_seconds
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: physical
        # physical_unit: mV
        0,0.1
        0.004,0.2mV
        """
        #expect(reason(csv) == .embeddedUnitOrSeparator)
    }

    @Test("Non-uniform time index refuses")
    func nonUniformIndex() {
        let csv = """
        # index_kind: time_seconds
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: physical
        # physical_unit: mV
        0,0.1
        0.004,0.2
        0.010,0.3
        """
        #expect(reason(csv) == .indexStepNotUniform)
    }

    @Test("sample_number step ≠ 1 refuses")
    func sampleNumberStep() {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: adc_counts
        0,10
        2,11
        """
        #expect(reason(csv) == .sampleNumberStepNotOne)
    }

    @Test("Index-implied rate contradicting sample_rate_hz refuses")
    func rateContradiction() {
        let csv = """
        # index_kind: time_seconds
        # sample_rate_hz: 500
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: physical
        # physical_unit: mV
        0,0.1
        0.004,0.2
        """
        #expect(reason(csv) == .rateContradiction)
    }

    @Test("num_channels not matching the signal columns refuses")
    func channelCountMismatch() {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 3
        # lead_names: II, V1, V2
        # amplitude_encoding: adc_counts
        0,10,-20
        """
        #expect(reason(csv) == .columnCountMismatch)
    }

    @Test("Malformed / mislocated header block refuses")
    func malformedHeader() {
        let csv = """
        # index_kind: sample_number
        0,10
        # num_channels: 1
        """
        #expect(reason(csv) == .malformedHeaderBlock)
    }

    @Test("Quoted field refuses")
    func quotedField() {
        let csv = """
        # index_kind: sample_number
        # sample_rate_hz: 250
        # num_channels: 1
        # lead_names: II
        # amplitude_encoding: adc_counts
        0,"10"
        """
        #expect(reason(csv) == .quotedField)
    }

    @Test("No header block and no dialog metadata refuses")
    func missingMetadata() {
        #expect(reason("0,10\n1,11") == .incompleteMetadata)
    }

    @Test("Non-UTF8 bytes refuse")
    func nonUTF8() {
        // Lone 0xFF is invalid UTF-8.
        do {
            _ = try CSVImport.parse(data: Data([0x30, 0xFF, 0x0A]), dialogMetadata: nil)
            Issue.record("expected refusal")
        } catch let r as CSVImport.Refusal {
            #expect(r.reason == .notUTF8)
        } catch { Issue.record("wrong error") }
    }
}
