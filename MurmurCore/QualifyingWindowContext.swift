//
//  QualifyingWindowContext.swift
//  MurmurCore
//
//  The bridge that carries the paid qualifying-window facts (X42) from the App
//  orchestrator (which owns MurmurMetrics) into the MurmurCore trend lane,
//  as PRIMITIVE per-bin values — MurmurCore never imports MurmurMetrics
//  (project_metrics_module_boundaries.md). The App computes one
//  `IntervalBinQualifier` per trend bin and publishes them here; the lane's
//  `IntervalTrendComputer` stamps each bin it builds by matching start time,
//  which lights up the X43 rate-stability marker and the X46 qualifying gate.
//

import Foundation
import Observation

/// Per-bin qualifying facts, as primitives (no MurmurMetrics types). `nil`
/// deviation/fraction means "not computed" — distinct from a measured value.
public struct IntervalBinQualifier: Sendable, Equatable {
    /// Bin start (seconds from recording start) — the join key to a trend bin.
    public let startSeconds: Double
    public let rateStable: Bool
    public let rateMaxDeviationBpm: Double?
    public let excludedBeatFraction: Double?

    public init(
        startSeconds: Double,
        rateStable: Bool,
        rateMaxDeviationBpm: Double?,
        excludedBeatFraction: Double?
    ) {
        self.startSeconds = startSeconds
        self.rateStable = rateStable
        self.rateMaxDeviationBpm = rateMaxDeviationBpm
        self.excludedBeatFraction = excludedBeatFraction
    }
}

/// Process-wide publication of the current recording's per-bin qualifiers.
/// Written by the App's qualifying-window orchestrator (paid, entitlement-
/// gated); read by `BedsideView` when it builds the trend lane. Keyed to the
/// bin length they were computed for, so a stale set for a different bin
/// length is ignored rather than mis-joined.
@MainActor
@Observable
public final class QualifyingWindowContext {
    public static let shared = QualifyingWindowContext()

    public private(set) var qualifiers: [IntervalBinQualifier] = []
    /// The bin length (seconds) the qualifiers were computed against.
    public private(set) var binSeconds: Double = 0
    /// The rate-stability tolerance (bpm) used — echoed for provenance.
    public private(set) var toleranceBpm: Double = 0

    public init() {}

    public func set(qualifiers: [IntervalBinQualifier], binSeconds: Double, toleranceBpm: Double) {
        self.qualifiers = qualifiers
        self.binSeconds = binSeconds
        self.toleranceBpm = toleranceBpm
    }

    public func clear() {
        qualifiers = []
        binSeconds = 0
        toleranceBpm = 0
    }

    /// Qualifiers valid for `binSeconds`, or empty when the published set was
    /// computed for a different bin length (avoids mis-joining across a
    /// bin-length change before the orchestrator catches up).
    public func qualifiers(forBinSeconds seconds: Double) -> [IntervalBinQualifier] {
        abs(binSeconds - seconds) < 0.001 ? qualifiers : []
    }
}
