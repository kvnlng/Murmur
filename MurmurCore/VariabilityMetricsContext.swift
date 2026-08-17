//
//  VariabilityMetricsContext.swift
//  MurmurCore
//
//  Shared observable state that lets the App target's orchestrator hand a
//  computed whole-record variability summary to `BedsideView` without
//  MurmurCore importing MurmurMetrics. Same App-writes / MurmurCore-reads
//  pattern as `VariabilityLaneContext` and `IntervalMarkingsContext`.
//
//  The summary is carried as pre-formatted rows rather than a typed mirror of
//  every HRV field. That is deliberate, and it is the same choice
//  `VariabilityLaneContext` already makes for `metricLabel` / `unit` /
//  `windowCaption`: formatting a measurement is arithmetic about a
//  measurement, and per `project_metrics_module_boundaries.md` that belongs on
//  the paid side of the boundary. MurmurCore lays rows out; it never decides
//  what a number means or how many digits it deserves.
//
//  A nil `summary` is the "nothing to show" state, whatever the cause —
//  no entitlement, no recording, or too few beats. The strip renders the
//  unlock seam only for the entitlement case, which the orchestrator signals
//  separately via `isLocked`.
//

import Foundation
import Observation

/// A whole-record variability summary, ready to render.
///
/// Every value is a finished string. The orchestrator owns the numbers, the
/// units, the digit counts, and the captions; this type is a transport.
public struct VariabilityMetricsSummary: Sendable, Equatable {

    /// One labelled measurement.
    public struct Row: Sendable, Equatable, Identifiable {
        /// Stable key — drives `ForEach` identity and the accessibility
        /// identifier, so XCUI binds to this rather than to display text
        /// (the X49 separation: machine-readable leaf, human-readable label).
        public let id: String
        public let label: String
        public let value: String
        public let unit: String?

        public init(id: String, label: String, value: String, unit: String? = nil) {
            self.id = id
            self.label = label
            self.value = value
            self.unit = unit
        }
    }

    /// A titled group of rows with an optional trailing caption. Captions
    /// carry the method disclosures (estimator, window, band edges, excluded
    /// fraction) that must travel with the numbers.
    public struct Section: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String?
        public let rows: [Row]
        public let captions: [String]
        /// Advisory shown with a warning symbol — e.g. below the Task Force
        /// beat minimum. Kept distinct from `captions` so it can be styled as
        /// a caution without the strip deciding what counts as one.
        public let advisory: String?

        public init(
            id: String,
            title: String? = nil,
            rows: [Row] = [],
            captions: [String] = [],
            advisory: String? = nil
        ) {
            self.id = id
            self.title = title
            self.rows = rows
            self.captions = captions
            self.advisory = advisory
        }
    }

    public let sections: [Section]

    /// One line identifying WHAT was measured — record, beat count, span.
    ///
    /// Load-bearing, not decoration. This summary used to live in a detached
    /// window that named no record: switching recordings silently recomputed
    /// it under an unchanged title, and a screenshot of it was unattributable.
    /// Inside the record column that is less acute, but the provenance still
    /// travels with the numbers so a copied or captured block stands alone.
    public let provenance: String

    /// Plain-text rendering for the clipboard, composed on the paid side so
    /// the frozen, grep-friendly export format stays in one place.
    public let exportText: String

    public init(sections: [Section], provenance: String, exportText: String) {
        self.sections = sections
        self.provenance = provenance
        self.exportText = exportText
    }
}

public extension VariabilityMetricsSummary {
    /// The unmeasured card: the SAME sections and rows the orchestrator
    /// publishes, every value an em-dash. The strip renders this through
    /// the same grid as a measured summary, so populating the card changes
    /// glyphs and never geometry — the 12a rule is dimensional ("present at
    /// its final size with values blank"), and a short placeholder that
    /// grows when the numbers arrive is the frame moving.
    ///
    /// The ids and labels mirror `VariabilityMetricsOrchestrator`'s section
    /// builders (App target — deliberately unreachable from here, so this
    /// is a transcription, not a call). The XCUI size-parity test
    /// (`testUnmeasuredCardHoldsTheStripsFinalSize`) is the drift guard:
    /// a row added there without updating this skeleton changes the
    /// populated height and fails the comparison.
    static let unmeasured = VariabilityMetricsSummary(
        sections: [
            .init(
                id: "variability-metrics-time-domain",
                title: "Heart rate variability",
                rows: [
                    .init(id: "vm-mean-rr", label: "Mean RR", value: "—", unit: "ms"),
                    .init(id: "vm-sdnn", label: "SDNN", value: "—", unit: "ms"),
                    .init(id: "vm-rmssd", label: "RMSSD", value: "—", unit: "ms"),
                    .init(id: "vm-pnn50", label: "pNN50", value: "—", unit: "%"),
                ]
            ),
            .init(
                id: "variability-metrics-frequency-domain",
                title: "Frequency-domain HRV",
                rows: [
                    .init(id: "vm-vlf", label: "VLF", value: "—", unit: "ms²"),
                    .init(id: "vm-lf", label: "LF", value: "—", unit: "ms²"),
                    .init(id: "vm-hf", label: "HF", value: "—", unit: "ms²"),
                    .init(id: "vm-lfhf", label: "LF/HF", value: "—"),
                    .init(id: "vm-lfhf-nu", label: "LF / HF n.u.", value: "—"),
                ]
            ),
            .init(
                id: "variability-metrics-qtvi",
                title: "QT variability index",
                rows: [
                    .init(id: "vm-qtvi", label: "QTVI", value: "—"),
                    .init(id: "vm-sdqt", label: "SDQT", value: "—", unit: "ms"),
                    .init(id: "vm-qtvi-sdnn", label: "SDNN", value: "—", unit: "ms"),
                    .init(id: "vm-qtvi-meannn", label: "Mean NN", value: "—", unit: "ms"),
                ]
            ),
        ],
        provenance: "—",
        exportText: ""
    )
}

/// Process-wide variability-metrics state. `@MainActor` because the only
/// reader is the bedside view hierarchy.
@MainActor
@Observable
public final class VariabilityMetricsContext {

    public static let shared = VariabilityMetricsContext()

    /// The computed summary, or nil when there is nothing to render.
    public private(set) var summary: VariabilityMetricsSummary?

    /// True when a recording is open but the paid entitlement is absent — the
    /// one empty case that earns an unlock seam. No recording, or a whole
    /// record with too few beats, is silence: there is nothing to sell the
    /// analyst and nothing they can dial to change the answer.
    public private(set) var isLocked: Bool = false

    /// Set when the analyst NARROWED the scope (window / hour) to a stretch
    /// with too few beats to measure (X95). This is not silence: silence
    /// unmounts the whole strip, and the scope picker goes with it — leaving
    /// the analyst stuck in a scope whose only control just vanished, which
    /// reads as "the Variability Metrics window disappeared". The strip stays
    /// mounted, says why it is empty, and keeps the picker reachable.
    public private(set) var insufficientScope: MetricsScope?
    /// Beat count behind `insufficientScope`, for the caption's honesty.
    public private(set) var insufficientBeatCount: Int = 0

    public init() {}

    public func set(summary: VariabilityMetricsSummary?) {
        self.summary = summary
        self.isLocked = false
        self.insufficientScope = nil
    }

    public func setLocked() {
        self.summary = nil
        self.isLocked = true
        self.insufficientScope = nil
    }

    public func setInsufficient(scope: MetricsScope, beatCount: Int) {
        self.summary = nil
        self.isLocked = false
        self.insufficientScope = scope
        self.insufficientBeatCount = beatCount
    }

    public func clear() {
        self.summary = nil
        self.isLocked = false
        self.insufficientScope = nil
    }
}
