//
//  BeatHeartRateSeries.swift
//  MurmurCore
//
//  X89 — the beat-derived heart-rate series for the trend stack's HR lane.
//
//  The stack's existing HR lane draws a TREND CHANNEL (`HR_bpm`), which most
//  real ECG records don't carry — a MIT-BIH record is leads only, so the one
//  vital an analyst orients by was missing exactly where it matters. This
//  derives HR from the beats the delineator already found: one instantaneous
//  rate per beat (60000 / preceding R–R), binned to a fixed step with the
//  MEDIAN per bin, NaN where a bin caught no beats.
//
//  Median, not mean: a single mis-detected R peak makes one wild R–R, and a
//  location-finder lane must not let one artifact beat drag a whole bin. Same
//  reasoning as the interval trend's per-bin median (X41). Beats whose R–R is
//  physically impossible for a human heart are withheld entirely — the X53
//  plausibility principle: noise is not data.
//
//  Binning (not per-beat rendering) is what the whole-record plots already
//  speak: `HeartRateLanePlot` takes a uniform-rate series and skips
//  non-finite samples, so NaN-filled gaps render as gaps rather than as
//  interpolated fabrications.
//
//  Boundary ruling (#385): KEEP in MurmurCore. This is display-tier
//  derivation over beats the pipeline already found — a unit conversion
//  (60000/RR) plus per-bin median for the HR lane, which is part of the
//  shared render surface both tiers draw. It produces no measurement the
//  paid pipeline doesn't already publish per-beat.
//

import Foundation

public enum BeatHeartRateSeries {

    /// One whole-record series at a uniform bin rate — the exact shape
    /// `HeartRateLanePlot` consumes.
    public struct Series: Equatable, Sendable {
        /// Median bpm per bin; NaN where the bin caught no plausible beat.
        public let samples: [Float]
        /// 1 / binSeconds.
        public let sampleRate: Double
        /// Beats that contributed after the plausibility gate.
        public let beatCount: Int

        public static let empty = Series(samples: [], sampleRate: 0, beatCount: 0)

        public init(samples: [Float], sampleRate: Double, beatCount: Int) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.beatCount = beatCount
        }
    }

    /// 10 s bins: fine enough to localise a rate change worth clicking on,
    /// coarse enough that a 24 h record is ~8,600 samples.
    public static let defaultBinSeconds: Double = 10

    /// R–R plausibility bounds, in ms — 20…300 bpm. Outside this range the
    /// interval is not a heart rate, it is a detection artifact, and it is
    /// withheld the way X53 withholds impossible QT measurements.
    public static let plausibleRRMs: ClosedRange<Double> = 200...3000

    /// - Parameters:
    ///   - beats: the delineator's beats; only `rPeakSampleIndex` and
    ///     `precedingRRMs` are read.
    ///   - sampleRate: the ECG sample rate `rPeakSampleIndex` is expressed in.
    ///   - recordingDurationSeconds: the whole-record span the lane draws.
    public static func compute(
        beats: [MarkingsBeat],
        sampleRate: Double,
        recordingDurationSeconds: Double,
        binSeconds: Double = defaultBinSeconds
    ) -> Series {
        guard !beats.isEmpty, sampleRate > 0, binSeconds > 0,
              recordingDurationSeconds > 0 else { return .empty }

        let binCount = max(1, Int((recordingDurationSeconds / binSeconds).rounded(.up)))
        var perBin = [[Double]](repeating: [], count: binCount)
        var contributing = 0
        for beat in beats {
            guard let rr = beat.precedingRRMs, plausibleRRMs.contains(rr) else { continue }
            let t = Double(beat.rPeakSampleIndex) / sampleRate
            guard t >= 0, t <= recordingDurationSeconds else { continue }
            let bin = min(binCount - 1, Int(t / binSeconds))
            perBin[bin].append(60_000 / rr)
            contributing += 1
        }
        guard contributing > 0 else { return .empty }

        let samples = perBin.map { values -> Float in
            guard !values.isEmpty else { return .nan }
            return Float(median(of: values))
        }
        return Series(samples: samples, sampleRate: 1 / binSeconds, beatCount: contributing)
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
