//
//  MetricsScope.swift
//  MurmurCore
//
//  Which stretch of the recording the variability metrics describe (X73).
//
//  Until now the block answered exactly one question — "what is this whole
//  record like" — which on a 25-hour Holter is an average over sleep, waking,
//  exercise and artefact together. That number is real but it is rarely the
//  one an analyst wants when they are looking at a specific run.
//
//  The scope is carried here rather than computed here. MurmurCore does no
//  arithmetic on measurements (`project_metrics_module_boundaries.md`): it
//  publishes WHICH range the analyst asked about, and the App target's
//  orchestrator — the only place MurmurCore and MurmurMetrics meet — decides
//  what that means and recomputes.
//

import Foundation
import Observation

public enum MetricsScope: String, CaseIterable, Sendable, Equatable {
    /// Every normal beat in the recording. The shipped behaviour, and still
    /// the default: it is the only scope whose answer does not move while the
    /// analyst navigates.
    case wholeRecord
    /// Beats inside the current viewport.
    case visibleWindow
    /// Beats inside the hour enclosing the current viewport — the same
    /// fixed-block hour the stage's hour band draws, so the metrics and the
    /// band agree about which hour "this hour" is.
    case hour

    public var label: String {
        switch self {
        case .wholeRecord: return "Whole"
        case .visibleWindow: return "Window"
        case .hour: return "Hour"
        }
    }

    /// Named in the provenance line, so a copied block says what it covered.
    public var provenanceLabel: String {
        switch self {
        case .wholeRecord: return "whole record"
        case .visibleWindow: return "visible window"
        case .hour: return "hour"
        }
    }
}

/// The analyst's scope choice plus the viewport it is measured against.
///
/// Two writers, deliberately: the strip writes `scope` when the analyst picks
/// one, and the bedside view writes `viewportRange` as they navigate. The
/// orchestrator reads both. Keeping them on one object means the recompute key
/// is a single value, so a scope change and a pan cannot race into two
/// overlapping computations.
@MainActor
@Observable
public final class MetricsScopeContext {
    public static let shared = MetricsScopeContext()

    public var scope: MetricsScope = .wholeRecord

    /// Current viewport, in samples. Nil before the first frame.
    public private(set) var viewportRange: Range<Int64>?
    /// Sample rate the range is expressed in, for deriving the hour block.
    public private(set) var sampleRate: Double = 0

    public init() {}

    public func set(viewportRange: Range<Int64>, sampleRate: Double) {
        self.viewportRange = viewportRange
        self.sampleRate = sampleRate
    }

    public func clear() {
        viewportRange = nil
        sampleRate = 0
        scope = .wholeRecord
    }

    /// The sample range the current scope selects, or nil for the whole
    /// record (which needs no filtering).
    ///
    /// The hour is quantised into fixed blocks from the recording's start,
    /// matching `HourBand` — an hour that slid with the viewport would make
    /// "this hour's SDNN" a different population on every pan, and two
    /// readings taken seconds apart would not be comparable.
    public func effectiveRange(totalSamples: Int64) -> Range<Int64>? {
        guard let viewportRange, sampleRate > 0 else { return nil }
        switch scope {
        case .wholeRecord:
            return nil
        case .visibleWindow:
            return viewportRange
        case .hour:
            let hourSamples = Int64(3600 * sampleRate)
            guard hourSamples > 0 else { return nil }
            let index = viewportRange.lowerBound / hourSamples
            let start = index * hourSamples
            let end = Swift.min(totalSamples, start + hourSamples)
            guard start < end else { return nil }
            return start..<end
        }
    }
}
