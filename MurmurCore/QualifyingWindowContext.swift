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
/// Hashable so the trend-bins orchestrator's `.task(id:)` key can carry the
/// whole (small) set and recompute when the facts arrive (#380).
public struct IntervalBinQualifier: Sendable, Equatable, Hashable {
    /// Bin start (seconds from recording start) — the join key to a trend bin.
    public let startSeconds: Double
    public let rateStable: Bool
    /// Max deviation of INSTANTANEOUS rate from the preceding window's mean.
    /// Reported, but no longer what `rateStable` rests on — see `rateDriftBpm`.
    public let rateMaxDeviationBpm: Double?
    /// Max deviation of a SUB-WINDOW MEAN rate from the preceding window's
    /// overall mean. This is the quantity `rateStable` is decided on, so it is
    /// the one the X43 marker must quote.
    public let rateDriftBpm: Double?
    public let excludedBeatFraction: Double?

    public init(
        startSeconds: Double,
        rateStable: Bool,
        rateMaxDeviationBpm: Double?,
        rateDriftBpm: Double? = nil,
        excludedBeatFraction: Double?
    ) {
        self.startSeconds = startSeconds
        self.rateStable = rateStable
        self.rateMaxDeviationBpm = rateMaxDeviationBpm
        self.rateDriftBpm = rateDriftBpm
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
