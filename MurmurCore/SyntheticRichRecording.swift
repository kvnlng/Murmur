//
//  SyntheticRichRecording.swift
//  MurmurCore
//
//  X99 (#164) — the RICH synthetic fixture: an ECGSYN-style record
//  (MurmurCore.SyntheticECG) written as WFDB and imported through the same
//  path as every real record. Split from SyntheticRecording.swift, which
//  keeps the original thin demo fixture; this file owns everything whose
//  numbers are constructed ground truth.
//

import Foundation

extension SyntheticRecording {
    /// Generates, writes, and imports the rich record. Returns the imported
    /// bundle directory; the source folder beside it keeps
    /// `<record>.synthesis-truth.json` for anything that wants the oracle at
    /// runtime.
    static func makeRichFixture(parameters: SyntheticECG.Parameters) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("plotting-ui-test", isDirectory: true)
        sweepStaleFixtures(in: parent)
        let workDir = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let heaURL = try makeRichRecord(into: workDir, parameters: parameters)
        let outputDir = workDir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outputDir)
        return summary.directory
    }

    /// Writes the rich record as WFDB (same multi-.dat layout as the demo
    /// fixture: 8 ECG leads at 250 Hz plus 1 Hz trend signals), an
    /// annotations sidecar whose normal beats are the TRUE R peaks (atr-like
    /// provenance, so `normalBeatSampleIndices()` — and therefore the whole
    /// variability pipeline — measures exactly the generated tachogram), and
    /// the ground-truth JSON beside the header.
    static func makeRichRecord(
        into directory: URL,
        parameters: SyntheticECG.Parameters,
        recordName: String = "synthrich"
    ) throws -> URL {
        let output = SyntheticECG.generate(parameters)
        let frameCount = Int(parameters.durationSeconds)

        var heaLines: [String] = [
            "\(recordName) \(SyntheticECG.leadNames.count + 2) 1 \(frameCount)"
        ]
        heaLines += try writeLeadSignals(output, parameters: parameters,
                                         recordName: recordName, into: directory)
        heaLines += try writeTrendSignals(output, frameCount: frameCount,
                                          recordName: recordName, into: directory)
        heaLines.append("# Synthetic ECGSYN-style recording with known ground truth (X99)")
        heaLines.append("# Rhythm: sinus, LF/HF \(parameters.lfHfRatio)"
            + (parameters.afEpisode != nil ? ", one simulated AF episode" : "")
            + (parameters.rateEpisodes.isEmpty ? ""
               : ", \(parameters.rateEpisodes.count) constructed rate episode(s)")
            + (parameters.pvcTimesSeconds.isEmpty ? ""
               : ", \(parameters.pvcTimesSeconds.count) constructed PVC(s)")
            + (parameters.wideComplexRuns.isEmpty ? ""
               : ", \(parameters.wideComplexRuns.count) wide-complex run(s)"))
        let heaURL = directory.appendingPathComponent("\(recordName).hea")
        try (heaLines.joined(separator: "\n") + "\n")
            .write(to: heaURL, atomically: true, encoding: .utf8)

        try writeTruthAnnotations(output.truth, recordName: recordName, into: directory)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output.truth).write(
            to: directory.appendingPathComponent("\(recordName).synthesis-truth.json")
        )
        return heaURL
    }

    // MARK: - Signal writing

    private struct RichTrendChannel {
        let label: String
        let unit: String
        let gain: Int
        let values: [Double]
    }

    /// One `.dat` per lead, quantized at a fixed 200 adu/mV gain. Returns the
    /// `.hea` signal lines describing what was written.
    private static func writeLeadSignals(
        _ output: SyntheticECG.Output,
        parameters: SyntheticECG.Parameters,
        recordName: String,
        into directory: URL
    ) throws -> [String] {
        let ecgGain = 200.0
        var heaLines: [String] = []
        for (leadIdx, label) in SyntheticECG.leadNames.enumerated() {
            let datFilename = "\(recordName)_\(safeFileName(label)).dat"
            heaLines.append(
                "\(datFilename) 16x\(Int(parameters.ecgSampleRate)) \(Int(ecgGain))(mV)/0 16 0 0 0 0 \(label)"
            )
            let data = int16Samples(output.leads[leadIdx], gain: ecgGain,
                                    count: output.leads[leadIdx].count)
            try data.write(to: directory.appendingPathComponent(datFilename), options: .atomic)
        }
        return heaLines
    }

    /// Trend channels, consistent with the truth by construction.
    private static func writeTrendSignals(
        _ output: SyntheticECG.Output,
        frameCount: Int,
        recordName: String,
        into directory: URL
    ) throws -> [String] {
        let trends = [
            RichTrendChannel(label: "HR_bpm", unit: "bpm", gain: 1,
                             values: output.heartRatePerSecond),
            RichTrendChannel(label: "ecg_artifact_ratio", unit: "ratio", gain: 100,
                             values: output.artifactRatioPerSecond),
        ]
        var heaLines: [String] = []
        for trend in trends {
            let datFilename = "\(recordName)_\(safeFileName(trend.label)).dat"
            heaLines.append(
                "\(datFilename) 16x1 \(trend.gain)(\(trend.unit))/0 16 0 0 0 0 \(trend.label)"
            )
            let data = int16Samples(trend.values, gain: Double(trend.gain), count: frameCount)
            try data.write(to: directory.appendingPathComponent(datFilename), options: .atomic)
        }
        return heaLines
    }

    /// Little-endian Int16 quantization, zero-padded to `count` frames.
    private static func int16Samples(_ values: [Double], gain: Double, count: Int) -> Data {
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            let int16Base = base.assumingMemoryBound(to: Int16.self)
            for i in 0..<count {
                let v = i < values.count ? values[i] : 0
                int16Base[i] = Int16(clamping: Int((v * gain).rounded())).littleEndian
            }
        }
        return data
    }

    // MARK: - Truth sidecars

    /// TRUE R peaks as annotator-coded beats (`source` prefixed "wfdb.atr";
    /// category N is what `normalBeatSampleIndices()` reads). X104: ectopic
    /// beats are coded "V" — exactly like a real annotator file — so the
    /// variability pipeline EXCLUDES them by the same rule it applies to
    /// real records. No fabricated VT/VF verdicts here — the rich record's
    /// findings are whatever the detectors find.
    private static func writeTruthAnnotations(
        _ truth: SyntheticECG.Truth,
        recordName: String,
        into directory: URL
    ) throws {
        let findings: [String] = zip(truth.beatSampleIndices, truth.beatFiducials).map { sample, beat in
            let code = beat.kind == .sinus ? "N" : "V"
            return """
            {
              "kind": "point",
              "startSample": \(sample),
              "category": "\(code)",
              "label": "\(code)",
              "source": "wfdb.atr.synth"
            }
            """
        }
        let annotationsJSON = """
        {
          "schemaVersion": 1,
          "source": "synth.ecgsyn.v1",
          "findings": [\(findings.joined(separator: ","))]
        }
        """
        try annotationsJSON.write(
            to: directory.appendingPathComponent("\(recordName).annotations.json"),
            atomically: true, encoding: .utf8
        )
    }
}
