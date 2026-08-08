//
//  RollingLFHFContext.swift
//  MurmurCore
//
//  Published rolling LF/HF series for the trend stack's LF/HF lane (X76).
//
//  Same boundary as `VariabilityLaneContext`: the series is COMPUTED by the
//  App target's `RollingLFHFOrchestrator` (the only place MurmurCore and
//  MurmurMetrics meet, which is also where the entitlement gate lives) and
//  merely RENDERED from here. MurmurCore does no arithmetic on measurements.
//
//  Empty samples mean "no lane": not entitled, no recording, too few beats,
//  or a record shorter than one window. The lane simply does not render —
//  the free viewer never sees a paid measurement surface.
//

import Foundation
import Observation

@MainActor
@Observable
public final class RollingLFHFContext {

    public static let shared = RollingLFHFContext()

    /// One sample per analysis window that produced a ratio. Windows the
    /// analyzer declined (too few clean beats, zero variance) are simply
    /// absent — a gap in the lane, never a zero.
    public private(set) var samples: [VariabilityLaneSample] = []

    /// Provenance for the lane's sublabel — estimator, window, step. Travels
    /// with the numbers; never trimmed (provenance is not decoration).
    public private(set) var caption: String?

    public init() {}

    public func set(samples: [VariabilityLaneSample], caption: String) {
        self.samples = samples
        self.caption = caption
    }

    public func clear() {
        samples = []
        caption = nil
    }
}

/// Rolling-window placement over a time-ordered series (X76).
///
/// Lives in MurmurCore rather than beside the orchestrator because it is
/// SLICING, not measurement — pure index math on a time axis, with no idea
/// what will be computed inside each window. That keeps it unit-testable
/// (MurmurTests is not hosted by the app, so App-target code can't be) while
/// the spectrum stays in MurmurMetrics and the composition stays in the
/// App-target orchestrator, per the module-boundary rule.
public enum RollingWindows {

    public struct Window: Equatable, Sendable {
        public let startSeconds: Double
        public let endSeconds: Double
        /// Half-open index range into the source arrays: elements whose time
        /// falls in `startSeconds...endSeconds`.
        public let indices: Range<Int>
    }

    /// Place `windowSeconds`-long windows at `stepSeconds` intervals from the
    /// first timestamp, keeping only windows that fit entirely inside the
    /// series and contain at least one element. `timesSeconds` must be
    /// non-decreasing.
    public static func place(
        timesSeconds: [Double],
        windowSeconds: Double,
        stepSeconds: Double
    ) -> [Window] {
        guard windowSeconds > 0, stepSeconds > 0,
              let first = timesSeconds.first,
              let last = timesSeconds.last,
              last - first >= windowSeconds else { return [] }

        var out: [Window] = []
        var lowerIndex = 0
        var windowStart = first
        while windowStart + windowSeconds <= last {
            let windowEnd = windowStart + windowSeconds
            // Time-ordered input, so the lower bound only ever advances.
            while lowerIndex < timesSeconds.count, timesSeconds[lowerIndex] < windowStart {
                lowerIndex += 1
            }
            var upperIndex = lowerIndex
            while upperIndex < timesSeconds.count, timesSeconds[upperIndex] <= windowEnd {
                upperIndex += 1
            }
            if upperIndex > lowerIndex {
                out.append(Window(
                    startSeconds: windowStart,
                    endSeconds: windowEnd,
                    indices: lowerIndex..<upperIndex
                ))
            }
            windowStart += stepSeconds
        }
        return out
    }
}
