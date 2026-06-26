//
//  BooleanChannelScanner.swift
//  Murmur
//
//  Walks a low-rate boolean-ish channel (alarm flags, status indicators,
//  nebulizer running, etc.) and returns the contiguous sample-index spans
//  where the channel is "active." `NaN` is treated as inactive so missing
//  / sparse minutes don't extend a run by accident.
//
//  Producers don't really emit `Bool` — the Medallion feature store
//  encodes alarms as `DOUBLE` 0/1 values per 1-minute window. Anything
//  ≥ 0.5 reads as on; threshold is overridable for callers that want a
//  different gate.
//

import Foundation

enum BooleanChannelScanner {

    /// Each returned range is `firstActiveSample...lastActiveSample`,
    /// inclusive on both ends. Adjacent active samples coalesce; a single
    /// inactive sample between two active spans splits them into two
    /// ranges.
    static func scan(samples: [Float], threshold: Float = 0.5) -> [ClosedRange<Int64>] {
        guard !samples.isEmpty else { return [] }
        var ranges: [ClosedRange<Int64>] = []
        var runStart: Int64? = nil

        for (idx, value) in samples.enumerated() {
            let isActive = value.isFinite && value >= threshold
            if isActive {
                if runStart == nil { runStart = Int64(idx) }
            } else if let start = runStart {
                ranges.append(start...Int64(idx - 1))
                runStart = nil
            }
        }
        if let start = runStart {
            ranges.append(start...Int64(samples.count - 1))
        }
        return ranges
    }
}
