//
//  BeatHeartRateSeriesTests.swift
//  MurmurTests
//
//  X89 — the beat-derived HR series behind the trend stack's new lane.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("Beat-derived HR series (X89)")
struct BeatHeartRateSeriesTests {

    /// A beat at `second` with the given preceding R–R, at 250 Hz.
    private func beat(atSecond second: Double, rrMs: Double?) -> MarkingsBeat {
        MarkingsBeat(
            rPeakSampleIndex: Int64(second * 250),
            rPeakConfidence: 1.0,
            precedingRRMs: rrMs
        )
    }

    @Test("Uniform 800 ms R–R reads exactly 75 bpm in every occupied bin")
    func uniformRRReadsExactRate() {
        // One beat every 0.8 s across 30 s: every 10 s bin is occupied.
        let beats = stride(from: 0.8, to: 30, by: 0.8).map { beat(atSecond: $0, rrMs: 800) }
        let series = BeatHeartRateSeries.compute(
            beats: beats, sampleRate: 250, recordingDurationSeconds: 30
        )
        #expect(series.samples.count == 3)
        #expect(series.sampleRate == 0.1)
        #expect(series.samples.allSatisfy { $0 == 75.0 })
        #expect(series.beatCount == beats.count)
    }

    @Test("A bin with no beats is NaN — a gap, not an interpolated fabrication")
    func emptyBinIsNaN() {
        // Beats only in the first 10 s of a 30 s record.
        let beats = stride(from: 0.8, to: 9, by: 0.8).map { beat(atSecond: $0, rrMs: 1000) }
        let series = BeatHeartRateSeries.compute(
            beats: beats, sampleRate: 250, recordingDurationSeconds: 30
        )
        #expect(series.samples.count == 3)
        #expect(series.samples[0] == 60.0)
        #expect(series.samples[1].isNaN)
        #expect(series.samples[2].isNaN)
    }

    /// Median, not mean: one mis-detected R peak must not drag the bin.
    @Test("The bin reports the median, so one wild R–R cannot drag it")
    func medianResistsOutliers() {
        var beats = (1...9).map { beat(atSecond: Double($0), rrMs: 800) }
        beats.append(beat(atSecond: 9.5, rrMs: 2900))   // plausible but wild: ~21 bpm
        let series = BeatHeartRateSeries.compute(
            beats: beats, sampleRate: 250, recordingDurationSeconds: 10
        )
        #expect(series.samples.count == 1)
        #expect(series.samples[0] == 75.0, "the median must hold at the population's centre")
    }

    /// The X53 principle: a physically impossible measurement is withheld,
    /// not averaged in.
    @Test("Implausible R–R intervals are withheld entirely")
    func implausibleRRWithheld() {
        let beats = [
            beat(atSecond: 1, rrMs: 800),
            beat(atSecond: 2, rrMs: 50),      // 1200 bpm — artifact
            beat(atSecond: 3, rrMs: 5000),    // 12 bpm — dropout
            beat(atSecond: 4, rrMs: nil),     // first beat of the record
            beat(atSecond: 5, rrMs: 800),
        ]
        let series = BeatHeartRateSeries.compute(
            beats: beats, sampleRate: 250, recordingDurationSeconds: 10
        )
        #expect(series.beatCount == 2)
        #expect(series.samples[0] == 75.0)
    }

    @Test("No beats, no rate, or no duration produce the empty series")
    func degenerateInputsAreEmpty() {
        let some = [beat(atSecond: 1, rrMs: 800)]
        #expect(BeatHeartRateSeries.compute(
            beats: [], sampleRate: 250, recordingDurationSeconds: 10
        ) == .empty)
        #expect(BeatHeartRateSeries.compute(
            beats: some, sampleRate: 0, recordingDurationSeconds: 10
        ) == .empty)
        #expect(BeatHeartRateSeries.compute(
            beats: some, sampleRate: 250, recordingDurationSeconds: 0
        ) == .empty)
        // All beats implausible reads as empty too — no fabricated lane.
        #expect(BeatHeartRateSeries.compute(
            beats: [beat(atSecond: 1, rrMs: 10)], sampleRate: 250, recordingDurationSeconds: 10
        ) == .empty)
    }

    @Test("A beat past the recording's end is ignored, not crashed on")
    func beatBeyondDurationIgnored() {
        let beats = [beat(atSecond: 1, rrMs: 800), beat(atSecond: 99, rrMs: 800)]
        let series = BeatHeartRateSeries.compute(
            beats: beats, sampleRate: 250, recordingDurationSeconds: 10
        )
        #expect(series.beatCount == 1)
        #expect(series.samples.count == 1)
    }
}
