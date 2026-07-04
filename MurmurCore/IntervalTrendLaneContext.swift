//
//  IntervalTrendLaneContext.swift
//  MurmurCore
//
//  Analyst-facing config for the interval trend lane — which metric,
//  which bin length, how to render each bin. Persists to UserDefaults
//  so the analyst's preferred trend/bin survives restarts.
//
//  The trend BEATS + TEMPLATE come from `IntervalMarkingsContext`, so
//  no data hand-off needed here — this context only owns the small set
//  of view-config knobs the analyst can twiddle. Keeps a clean single-
//  writer story for the fiducial store (App-target orchestrator) while
//  the trend lane's own knobs are local to the free viewer.
//

import Foundation
import Observation

/// Bin-length presets shown in the trend-lane picker. The design spec
/// calls for 2-min default (drug-induced QT prolongation is the named
/// use case — 2 min is fine grain enough to see a slow rise but wide
/// enough that individual T-offset wobbles average out). 30 s / 5 min /
/// 10 min are the other reasonable stops.
public enum IntervalTrendBinPreset: String, Sendable, CaseIterable, Codable {
    case thirtySeconds
    case oneMinute
    case twoMinute
    case fiveMinute
    case tenMinute

    public var seconds: Double {
        switch self {
        case .thirtySeconds: return 30
        case .oneMinute:     return 60
        case .twoMinute:     return 120
        case .fiveMinute:    return 300
        case .tenMinute:     return 600
        }
    }

    public var shortLabel: String {
        switch self {
        case .thirtySeconds: return "30 s"
        case .oneMinute:     return "1 min"
        case .twoMinute:     return "2 min"
        case .fiveMinute:    return "5 min"
        case .tenMinute:     return "10 min"
        }
    }
}

@MainActor
@Observable
public final class IntervalTrendLaneContext {

    public static let shared = IntervalTrendLaneContext()

    /// Which interval metric the lane is showing. Default is QTc per
    /// the design spec — the named drug-induced-QT-prolongation use
    /// case is the reason this lane exists.
    public var metric: IntervalTrendMetric {
        didSet { persist() }
    }

    /// Bin-length preset. Default 2 min per the spec.
    public var binPreset: IntervalTrendBinPreset {
        didSet { persist() }
    }

    /// How to render each bin (median-only / median+IQR / per-beat
    /// scatter). Default is median+IQR — the spec's "visible honesty
    /// beats false precision" call.
    public var showMode: IntervalTrendShowMode {
        didSet { persist() }
    }

    public var binSeconds: Double { binPreset.seconds }

    public init() {
        let defaults = UserDefaults.standard
        let metricRaw = defaults.string(forKey: Keys.metric) ?? IntervalTrendMetric.qtc.rawValue
        self.metric = IntervalTrendMetric(rawValue: metricRaw) ?? .qtc
        let binRaw = defaults.string(forKey: Keys.bin) ?? IntervalTrendBinPreset.twoMinute.rawValue
        self.binPreset = IntervalTrendBinPreset(rawValue: binRaw) ?? .twoMinute
        let modeRaw = defaults.string(forKey: Keys.showMode) ?? IntervalTrendShowMode.medianAndIQR.rawValue
        self.showMode = IntervalTrendShowMode(rawValue: modeRaw) ?? .medianAndIQR
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(metric.rawValue, forKey: Keys.metric)
        defaults.set(binPreset.rawValue, forKey: Keys.bin)
        defaults.set(showMode.rawValue, forKey: Keys.showMode)
    }

    private enum Keys {
        static let metric = "murmur.intervalTrendLane.metric"
        static let bin = "murmur.intervalTrendLane.binPreset"
        static let showMode = "murmur.intervalTrendLane.showMode"
    }
}
