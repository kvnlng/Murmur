//
//  VTVFSampleSourceAdapter.swift
//  Murmur (app target)
//
//  Bridges the App's in-memory channel samples to the MurmurInference
//  `VTVFSampleSource` protocol, resampling to the model's rate (250 Hz).
//  The recording is already materialised as `[Float]` for delineation, so
//  an in-memory source is consistent with the existing app; the scanner
//  still processes in bounded windows so peak memory stays flat during
//  the scan itself.
//

import Foundation
import MurmurInference

/// A rewindable in-memory source over a resampled sample buffer.
final class ArrayVTVFSampleSource: VTVFSampleSource {
    private let samples: [Float]
    let sampleRateHz: Double
    private var cursor = 0

    init(samples: [Float], sampleRateHz: Double) {
        self.samples = samples
        self.sampleRateHz = sampleRateHz
    }

    var sampleCount: Int { samples.count }

    func readSamples(maxCount: Int) -> [Float] {
        guard cursor < samples.count else { return [] }
        let end = min(cursor + maxCount, samples.count)
        defer { cursor = end }
        return Array(samples[cursor..<end])
    }

    func rewind() { cursor = 0 }
}

enum ECGResampler {
    /// Linear-resample `samples` from `fromRate` to `toRate`. Returns the
    /// input unchanged when the rates already match. Linear interpolation
    /// is a pragmatic first pass — adequate for the detector's tolerance
    /// to modest rate conversion; a future pass can add anti-aliased
    /// decimation for large downsampling ratios.
    static func resample(_ samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard fromRate > 0, toRate > 0, samples.count > 1 else { return samples }
        if abs(fromRate - toRate) < 1e-6 { return samples }

        let ratio = toRate / fromRate
        let outCount = max(1, Int((Double(samples.count) * ratio).rounded(.down)))
        let step = fromRate / toRate   // input samples advanced per output sample

        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * step
            let lo = Int(srcPos)
            guard lo < samples.count else {
                out[i] = samples[samples.count - 1]
                continue
            }
            let frac = Float(srcPos - Double(lo))
            let a = samples[lo]
            let b = lo + 1 < samples.count ? samples[lo + 1] : a
            out[i] = a + (b - a) * frac
        }
        return out
    }
}
