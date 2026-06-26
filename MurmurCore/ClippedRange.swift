//
//  ClippedRange.swift
//  Murmur
//
//  A contiguous run of samples whose values fall outside the clinical
//  physiological band (default ±5 mV). The trace shader produces visible gaps
//  at these runs; SwiftUI overlays use this list to draw ▲/▼ chevrons at the
//  chart edges so the analyst knows where data went off-scale.
//
//  Adjacent samples that exceed the band in opposite directions are split
//  into separate ranges so we can render a different chevron at each — going
//  up vs going down is meaningful (pacing spike vs lead-off).
//

import Foundation

struct ClippedRange: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case above       // y > clipMax
        case below       // y < clipMin
    }

    let startSample: Int64
    let endSample: Int64        // exclusive
    let direction: Direction

    var sampleCount: Int64 { endSample - startSample }
}

enum ClippedRangeScanner {
    /// Scans a Float32 sample buffer for contiguous runs outside `[clipMin, clipMax]`.
    /// Direction changes within a run split it into separate `ClippedRange` values.
    /// NaN samples are treated as in-range (they're already handled as gaps).
    static func scan(
        samples: [Float],
        clipMin: Float = -5,
        clipMax: Float = 5
    ) -> [ClippedRange] {
        var ranges: [ClippedRange] = []
        var runStart: Int64?
        var runDirection: ClippedRange.Direction?

        for (idx, value) in samples.enumerated() {
            guard value.isFinite else {
                if let start = runStart, let dir = runDirection {
                    ranges.append(ClippedRange(
                        startSample: start, endSample: Int64(idx), direction: dir
                    ))
                    runStart = nil
                    runDirection = nil
                }
                continue
            }
            let direction: ClippedRange.Direction?
            if value > clipMax { direction = .above }
            else if value < clipMin { direction = .below }
            else { direction = nil }

            if let dir = direction {
                if runStart == nil {
                    runStart = Int64(idx)
                    runDirection = dir
                } else if runDirection != dir {
                    // Switched sides — close the previous run and start a new one.
                    if let start = runStart, let oldDir = runDirection {
                        ranges.append(ClippedRange(
                            startSample: start, endSample: Int64(idx), direction: oldDir
                        ))
                    }
                    runStart = Int64(idx)
                    runDirection = dir
                }
            } else if let start = runStart, let dir = runDirection {
                ranges.append(ClippedRange(
                    startSample: start, endSample: Int64(idx), direction: dir
                ))
                runStart = nil
                runDirection = nil
            }
        }

        if let start = runStart, let dir = runDirection {
            ranges.append(ClippedRange(
                startSample: start, endSample: Int64(samples.count), direction: dir
            ))
        }

        return ranges
    }
}
