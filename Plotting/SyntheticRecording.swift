//
//  SyntheticRecording.swift
//  Plotting
//
//  Generates a minimal WFDB record (8-lead ECG, format 16) for UI tests,
//  unit tests, and the welcome screen's "Try a sample recording" affordance.
//
//  Public API:
//    • makeFixture()          → Recording bundle directory ready for
//                               `RecordingStore.loadManifest`
//    • makeWFDBRecord(into:)  → URL of the .hea file (for unit tests)
//

import Foundation

enum SyntheticRecording {

    // MARK: - Public API

    /// Returns a fully-imported Recording bundle directory. Generates a synthetic
    /// WFDB record in a temp folder, runs it through `WFDBImporter`, and returns
    /// the resulting Recording bundle directory that `RecordingStore.loadManifest`
    /// can read directly.
    static func makeFixture() throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plotting-ui-test", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let heaURL = try makeWFDBRecord(into: workDir)
        let outputDir = workDir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outputDir)
        return summary.directory
    }

    /// Writes `synth.hea` + `synth.dat` (format 16, 8 ECG leads, 250 Hz, 10 s)
    /// into `directory` and returns the URL of the .hea file.
    static func makeWFDBRecord(into directory: URL) throws -> URL {
        let recordName = "synth"
        let labels: [String] = ["I", "II", "III", "aVR", "aVL", "aVF", "V1", "V2"]
        let sampleRate = 250.0
        let durationSeconds = 10.0
        let sampleCount = Int(durationSeconds * sampleRate)     // 2500
        let gain: Double = 200.0                                // 200 LSB/mV
        let baseline = 0
        let datFilename = "\(recordName).dat"

        // Build .hea text
        var heaLines: [String] = ["\(recordName) \(labels.count) \(Int(sampleRate)) \(sampleCount)"]
        for label in labels {
            heaLines.append("\(datFilename) 16 \(Int(gain))(mV)/\(baseline) 16 0 0 0 0 \(label)")
        }
        let heaText = heaLines.joined(separator: "\n") + "\n"
        let heaURL = directory.appendingPathComponent("\(recordName).hea")
        try heaText.write(to: heaURL, atomically: true, encoding: .utf8)

        // Build .dat binary (interleaved Int16 LE)
        let signalCount = labels.count
        var int16Data = Data(count: signalCount * sampleCount * 2)
        int16Data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let int16Base = base.assumingMemoryBound(to: Int16.self)
            for sampleIdx in 0..<sampleCount {
                for signalIdx in 0..<signalCount {
                    let physical = fakeECGSample(index: sampleIdx, signalIndex: signalIdx, sampleRate: sampleRate)
                    let adcValue = Int16(
                        clamping: Int(physical * gain) + baseline
                    )
                    let frameOffset = sampleIdx * signalCount + signalIdx
                    int16Base[frameOffset] = adcValue.littleEndian
                }
            }
        }
        let datURL = directory.appendingPathComponent(datFilename)
        try int16Data.write(to: datURL, options: .atomic)

        return heaURL
    }

    // MARK: - Signal synthesis

    /// Fake ECG-shaped waveform. Each lead gets a slightly different amplitude.
    private static func fakeECGSample(index: Int, signalIndex: Int, sampleRate: Double) -> Double {
        let t = Double(index) / sampleRate
        let bpm = 72.0
        let beatPhase = (t * bpm / 60.0).truncatingRemainder(dividingBy: 1.0)
        let amplitude = 0.8 + Double(signalIndex % 4) * 0.1     // 0.8 … 1.1 mV

        if beatPhase < 0.05 {
            return sin(beatPhase * .pi / 0.05) * amplitude       // QRS-ish spike
        }
        return sin(t * 2 * .pi * 1.2) * 0.05                     // baseline wander
    }
}
