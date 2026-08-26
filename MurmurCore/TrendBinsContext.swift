//
//  TrendBinsContext.swift
//  MurmurCore
//
//  The bridge that carries the produced interval-trend bins from the App
//  orchestrator (which owns MurmurMetrics) into the MurmurCore trend lane —
//  finished `IntervalTrendBin` values, no arithmetic on this side
//  (project_metrics_module_boundaries.md, #380). The App computes the bins
//  off-main via `TrendBinComputer` (grouping, X53/X79 exclusion, the
//  estimators, the K9 carry, the X42 qualifier join) and publishes them
//  here; `IntervalTrendComputer.compute` now only assembles them with the
//  caption and baseline. Same pattern as `QualifyingWindowContext`.
//

import Foundation
import Observation

/// Process-wide publication of the current recording's produced trend bins.
/// Written by the App's trend-bins orchestrator (paid, entitlement-gated);
/// read by `BedsideView` when it builds the trend lane. Keyed to the metric
/// and bin length they were computed for, so a stale set is ignored rather
/// than mis-rendered across a metric or bin-length change.
@MainActor
@Observable
public final class TrendBinsContext {
    public static let shared = TrendBinsContext()

    public private(set) var bins: [IntervalTrendBin] = []
    /// The metric the bins were computed for.
    public private(set) var metric: IntervalTrendMetric?
    /// The bin length (seconds) the bins were computed against.
    public private(set) var binSeconds: Double = 0

    public init() {}

    public func set(bins: [IntervalTrendBin], metric: IntervalTrendMetric, binSeconds: Double) {
        self.bins = bins
        self.metric = metric
        self.binSeconds = binSeconds
    }

    public func clear() {
        bins = []
        metric = nil
        binSeconds = 0
    }

    /// Bins valid for (`metric`, `binSeconds`), or empty when the published
    /// set was computed for a different pair (avoids rendering stale bins
    /// before the orchestrator catches up).
    public func bins(forMetric metric: IntervalTrendMetric, binSeconds seconds: Double) -> [IntervalTrendBin] {
        self.metric == metric && abs(binSeconds - seconds) < 0.001 ? bins : []
    }
}
