//
//  WFDBRecordWriter.swift
//  MurmurCore
//
//  Writes a PhysioNet WFDB signal record (`.hea` + `.dat`, format 16) — the
//  encode counterpart to WFDBHeader/WFDBSampleDecoder. Used by CSV import
//  (project_csv_import_spec.md) to land converted data as an ordinary WFDB
//  record, so everything downstream (WFDBImporter → the app bundle) shares ONE
//  representation with real WFDB files. No CSV-specific path survives past here.
//
//  Format 16: interleaved 16-bit little-endian signed samples, frame by frame
//  (all channels for sample 0, then all for sample 1, …). WFDB's invalid-sample
//  marker for format 16 is -32768 (Int16.min); marked-missing samples are
//  written as that.
//

import Foundation

enum WFDBRecordWriter {

    /// Per-channel amplitude calibration written to the `.hea` gain field so
    /// `WFDBSampleDecoder` recovers `(raw - baseline)/gain`. Shared across
    /// channels for now (matches CSVImport's shared-encoding scope).
    struct Calibration: Equatable, Sendable {
        let gain: Double     // ADC units per physical unit; MUST be > 0
        let baseline: Int
        let unit: String
    }

    /// Sentinel a caller uses in `channelSamples` to mean "missing" — written as
    /// WFDB's format-16 invalid sample.
    static let missingSample: Int32 = .min

    /// Writes `<recordName>.hea` + `<recordName>.dat` into `directory` and
    /// returns the `.hea` URL (ready for `WFDBImporter.importRecord`). All
    /// channels must be equal length.
    @discardableResult
    static func write(
        recordName: String,
        channelSamples: [[Int32]],
        sampleRateHz: Double,
        leadNames: [String],
        calibration: Calibration,
        in directory: URL
    ) throws -> URL {
        let channelCount = channelSamples.count
        let sampleCount = channelSamples.first?.count ?? 0
        precondition(leadNames.count == channelCount, "lead names must match channel count")

        // .dat — interleaved Int16 LE, frame by frame.
        var dat = Data(capacity: sampleCount * channelCount * 2)
        for s in 0..<sampleCount {
            for c in 0..<channelCount {
                let raw = channelSamples[c][s]
                let value: Int16 = raw == missingSample ? Int16.min : Int16(clamping: raw)
                var le = value.littleEndian
                withUnsafeBytes(of: &le) { dat.append(contentsOf: $0) }
            }
        }
        let datName = "\(recordName).dat"
        try dat.write(to: directory.appendingPathComponent(datName), options: .atomic)

        // .hea — record line + one signal line per channel.
        let fs = sampleRateHz == sampleRateHz.rounded()
            ? String(Int(sampleRateHz)) : String(sampleRateHz)
        var hea = "\(recordName) \(channelCount) \(fs) \(sampleCount)\n"
        // header(5) form: <gain>(<baseline>)/<units> (#360).
        let gainField = "\(formatGain(calibration.gain))(\(calibration.baseline))/\(calibration.unit)"
        for lead in leadNames {
            // filename format gain adcres adczero firstval checksum blocksize label
            hea += "\(datName) 16 \(gainField) 16 0 0 0 0 \(lead)\n"
        }
        let heaURL = directory.appendingPathComponent("\(recordName).hea")
        try Data(hea.utf8).write(to: heaURL, options: .atomic)
        return heaURL
    }

    /// Gain printed without a trailing `.0` when integral (200 not 200.0), so
    /// the header reads like a hand-written WFDB file.
    private static func formatGain(_ gain: Double) -> String {
        gain == gain.rounded() ? String(Int(gain)) : String(gain)
    }
}
