//
//  IntervalMarkingsContext.swift
//  MurmurCore
//
//  Shared observable state for the on-beat interval markings feature.
//  The App target's orchestrator writes fiducials + template + interval
//  readouts here after delineating the current recording; BedsideView
//  and its overlays read from here.
//
//  Same MurmurCore-can't-import-MurmurMetrics constraint as
//  `VariabilityLaneContext` — the wire types here are all primitive
//  MurmurCore-visible value types (integer sample indices, Doubles,
//  Bools). The paid framework's `FiducialStore` / `NormalTemplate` /
//  `IntervalReadout` never cross the boundary; the orchestrator maps
//  them to the mirror types defined here.
//
//  Ordering: `beats` is sorted ascending by `rPeakSampleIndex` so
//  callers can do a cheap binary search for the beat under the cursor.
//
//  Design note on the two "identities":
//    `MarkingsBeat.id` is the R-peak sample index — stable per beat
//    within a recording and the natural anchor for interval lookups.
//    `MarkingsFiducial` carries no id; a beat's fiducials are
//    interpreted through their `MarkingsFiducialKind` role.
//

import Foundation
import Observation

/// Which morphological landmark a fiducial marks. Mirrors
/// `MurmurMetrics.FiducialKind` — kept separate so MurmurCore isn't
/// coupled to the paid framework's namespace, and so the enum can
/// evolve independently.
public enum MarkingsFiducialKind: String, Sendable, CaseIterable, Codable {
    case pOnset
    case pOffset
    case qrsOnset
    case rPeak
    case qrsOffset
    case tOnset
    case tOffset
}

/// A single fiducial: which landmark, where in the recording, how
/// confident.
public struct MarkingsFiducial: Sendable, Equatable, Codable, Hashable {
    public let kind: MarkingsFiducialKind
    public let sampleIndex: Int64
    public let confidence: Double

    public init(kind: MarkingsFiducialKind, sampleIndex: Int64, confidence: Double) {
        self.kind = kind
        self.sampleIndex = sampleIndex
        self.confidence = min(1.0, max(0.0, confidence))
    }
}

/// One beat's worth of fiducials + intervals. Every fiducial /
/// interval is optional — the delineator legitimately fails to locate
/// individual landmarks on ectopic / paced / near-VT beats.
public struct MarkingsBeat: Sendable, Equatable, Codable, Identifiable {

    /// R-peak sample position — the anchor + identity.
    public let rPeakSampleIndex: Int64
    public let rPeakConfidence: Double

    // Fiducial positions (nil when the delineator couldn't find one).
    public let pOnset: MarkingsFiducial?
    public let pOffset: MarkingsFiducial?
    public let qrsOnset: MarkingsFiducial?
    public let qrsOffset: MarkingsFiducial?
    public let tOnset: MarkingsFiducial?
    public let tOffset: MarkingsFiducial?

    // Pre-computed intervals in milliseconds (nil when required
    // fiducials are absent).
    public let prMs: Double?
    public let qrsMs: Double?
    public let qtMs: Double?
    public let qtcMs: Double?
    public let precedingRRMs: Double?

    public init(
        rPeakSampleIndex: Int64,
        rPeakConfidence: Double = 1.0,
        pOnset: MarkingsFiducial? = nil,
        pOffset: MarkingsFiducial? = nil,
        qrsOnset: MarkingsFiducial? = nil,
        qrsOffset: MarkingsFiducial? = nil,
        tOnset: MarkingsFiducial? = nil,
        tOffset: MarkingsFiducial? = nil,
        prMs: Double? = nil,
        qrsMs: Double? = nil,
        qtMs: Double? = nil,
        qtcMs: Double? = nil,
        precedingRRMs: Double? = nil
    ) {
        self.rPeakSampleIndex = rPeakSampleIndex
        self.rPeakConfidence = min(1.0, max(0.0, rPeakConfidence))
        self.pOnset = pOnset
        self.pOffset = pOffset
        self.qrsOnset = qrsOnset
        self.qrsOffset = qrsOffset
        self.tOnset = tOnset
        self.tOffset = tOffset
        self.prMs = prMs
        self.qrsMs = qrsMs
        self.qtMs = qtMs
        self.qtcMs = qtcMs
        self.precedingRRMs = precedingRRMs
    }

    public var id: Int64 { rPeakSampleIndex }

    /// Fetch a specific fiducial by kind, returning a synthesized
    /// R-peak fiducial for `.rPeak`.
    public func fiducial(_ kind: MarkingsFiducialKind) -> MarkingsFiducial? {
        switch kind {
        case .pOnset:    return pOnset
        case .pOffset:   return pOffset
        case .qrsOnset:  return qrsOnset
        case .rPeak:     return MarkingsFiducial(kind: .rPeak, sampleIndex: rPeakSampleIndex, confidence: rPeakConfidence)
        case .qrsOffset: return qrsOffset
        case .tOnset:    return tOnset
        case .tOffset:   return tOffset
        }
    }
}

/// Per-patient normal-template baselines. Mirror of
/// `MurmurMetrics.NormalTemplate` in primitive types.
public struct MarkingsTemplate: Sendable, Equatable, Codable {
    public let sampleCount: Int

    public let medianPRMs: Double?
    public let iqrPRMs: Double?
    public let medianQRSMs: Double?
    public let iqrQRSMs: Double?
    public let medianQTMs: Double?
    public let iqrQTMs: Double?

    /// Formula used to compute the QTc statistics — must be echoed in
    /// the caption / citation the analyst copies.
    public let qtcFormulaName: String

    public let medianQTcMs: Double?
    public let iqrQTcMs: Double?

    public init(
        sampleCount: Int,
        medianPRMs: Double?,
        iqrPRMs: Double?,
        medianQRSMs: Double?,
        iqrQRSMs: Double?,
        medianQTMs: Double?,
        iqrQTMs: Double?,
        qtcFormulaName: String,
        medianQTcMs: Double?,
        iqrQTcMs: Double?
    ) {
        self.sampleCount = sampleCount
        self.medianPRMs = medianPRMs
        self.iqrPRMs = iqrPRMs
        self.medianQRSMs = medianQRSMs
        self.iqrQRSMs = iqrQRSMs
        self.medianQTMs = medianQTMs
        self.iqrQTMs = iqrQTMs
        self.qtcFormulaName = qtcFormulaName
        self.medianQTcMs = medianQTcMs
        self.iqrQTcMs = iqrQTcMs
    }
}

/// Zoom-level-of-detail policy for the on-beat markings overlay:
/// low-zoom shows R-ticks + beat-class color only; high-zoom
/// progressively reveals full fiducials per the spec's "never
/// dense-mark every beat" rule.
public enum MarkingsDetailLevel: Sendable, Equatable {
    /// Very zoomed out: R-ticks only.
    case rTicksOnly
    /// Mid zoom: R + QRS boundaries.
    case qrsOnly
    /// High zoom: full P / QRS / T fiducials.
    case fullFiducials

    /// Pick the appropriate detail level from a viewport duration.
    /// Boundaries picked to keep the canvas legible at each scale:
    ///  - < 3 s window: full fiducials (each beat is wide enough).
    ///  - 3–30 s: QRS boundaries.
    ///  - > 30 s: R-ticks only.
    public static func level(forViewportSeconds seconds: Double) -> MarkingsDetailLevel {
        if seconds < 3 { return .fullFiducials }
        if seconds < 30 { return .qrsOnly }
        return .rTicksOnly
    }
}

/// Live state for the on-beat interval markings surface. `@MainActor`
/// because the readers (waveform canvas overlays, calipers) all run
/// on main.
@MainActor
@Observable
public final class IntervalMarkingsContext {

    public static let shared = IntervalMarkingsContext()

    /// R-peak-sorted per-beat markings. Empty means no fiducials
    /// available (no entitlement / no recording / no beats / delineator
    /// still running).
    public private(set) var beats: [MarkingsBeat] = []

    /// The recording's sample rate, needed for sample→time conversion
    /// in the overlays. 0 when no recording is loaded.
    public private(set) var sampleRate: Double = 0

    /// Per-patient normal template (interval baselines). `nil` when
    /// no template could be built (too few beats).
    public private(set) var template: MarkingsTemplate?

    /// User-selectable QTc rate-correction formula. Fridericia default
    /// per the interval-markings spec. Persisted to UserDefaults so
    /// the analyst's choice survives restarts.
    public var qtcFormula: MarkingsQTcFormula {
        didSet {
            UserDefaults.standard.set(qtcFormula.rawValue, forKey: Keys.qtcFormula)
        }
    }

    /// Currently focused beat — the one the calipers panel is pinned
    /// on, or the one under the cursor when nothing is pinned. `nil`
    /// when nothing is under focus.
    public private(set) var focusedBeatSampleIndex: Int64?

    /// A "please jump to this sample" signal from a command / menu
    /// item to the viewport. Written by the deviation-navigation
    /// menu handlers; consumed by BedsideView via `.onChange`. Cleared
    /// to nil after consumption. Kept as a tuple counter so repeated
    /// requests for the same sample still fire (SwiftUI `.onChange`
    /// only fires on value change).
    public private(set) var pendingJumpRequest: JumpRequest?

    /// Envelope around a pending jump — the counter ensures
    /// SwiftUI's `.onChange` fires even for repeated same-sample
    /// requests.
    public struct JumpRequest: Sendable, Equatable {
        public let sampleIndex: Int64
        public let counter: Int
    }

    /// Monotonic counter that ensures each jump request is a distinct
    /// value even for repeat clicks on the same beat.
    private var jumpCounter: Int = 0

    public init() {
        let raw = UserDefaults.standard.string(forKey: Keys.qtcFormula)
        self.qtcFormula = raw.flatMap(MarkingsQTcFormula.init(rawValue:)) ?? .fridericia
    }

    // MARK: - Writes (orchestrator)

    public func set(
        beats: [MarkingsBeat],
        sampleRate: Double,
        template: MarkingsTemplate?
    ) {
        // Defensive sort — reader relies on ascending R-peak order.
        self.beats = beats.sorted { $0.rPeakSampleIndex < $1.rPeakSampleIndex }
        self.sampleRate = sampleRate
        self.template = template
    }

    public func clear() {
        beats = []
        sampleRate = 0
        template = nil
        focusedBeatSampleIndex = nil
    }

    // MARK: - Focus / caliper state

    public func focus(beatSampleIndex: Int64?) {
        focusedBeatSampleIndex = beatSampleIndex
    }

    /// Post a jump request to be picked up by the viewport observer.
    /// Also focuses the target beat so the calipers surface immediately.
    public func requestJump(toSampleIndex sample: Int64) {
        jumpCounter += 1
        pendingJumpRequest = JumpRequest(sampleIndex: sample, counter: jumpCounter)
        focusedBeatSampleIndex = sample
    }

    /// Acknowledge and clear the current pending jump. Called by the
    /// viewport after applying it.
    public func acknowledgeJump() {
        pendingJumpRequest = nil
    }

    // MARK: - Lookup

    /// Beats whose R-peak falls within the given sample range
    /// (inclusive). Used by the overlay to slice fiducials to the
    /// visible viewport.
    public func beats(inSampleRange range: ClosedRange<Int64>) -> [MarkingsBeat] {
        // Linear filter — good enough at typical N (< 100k beats).
        beats.filter { range.contains($0.rPeakSampleIndex) }
    }

    /// Beat whose R-peak is closest to the given sample index.
    public func nearestBeat(toSampleIndex sample: Int64) -> MarkingsBeat? {
        guard !beats.isEmpty else { return nil }
        var lo = 0
        var hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].rPeakSampleIndex < sample { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return beats.first }
        if lo == beats.count { return beats.last }
        let a = beats[lo - 1]
        let b = beats[lo]
        return abs(sample - a.rPeakSampleIndex) <= abs(sample - b.rPeakSampleIndex) ? a : b
    }

    // MARK: - Deviation-ranked navigation

    /// Beats sorted by descending deviation from the per-patient
    /// normal template. Deviation is `abs(qtcMs - templateMedianQTc)`
    /// when the template has a QTc median, falling back to
    /// `abs(qrsMs - templateMedianQRS)` when it doesn't (some
    /// recordings never produce a stable QT baseline).
    ///
    /// Beats without any usable interval measurement are omitted
    /// rather than sorted to a defaulted position — navigation
    /// shouldn't take the analyst to nothing.
    public var beatsRankedByDeviation: [MarkingsBeat] {
        guard let t = template else { return [] }
        // Score each beat; keep only those with a defined score.
        let scored: [(MarkingsBeat, Double)] = beats.compactMap { beat in
            guard let d = deviationScore(for: beat, template: t) else { return nil }
            return (beat, d)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func deviationScore(for beat: MarkingsBeat, template t: MarkingsTemplate) -> Double? {
        if let qtc = beat.qtcMs, let mQtc = t.medianQTcMs {
            return abs(qtc - mQtc)
        }
        if let qrs = beat.qrsMs, let mQrs = t.medianQRSMs {
            return abs(qrs - mQrs)
        }
        if let qt = beat.qtMs, let mQt = t.medianQTMs {
            return abs(qt - mQt)
        }
        return nil
    }

    /// Next beat (by deviation rank) after `fromSampleIndex`. The
    /// deviation rank is descending, so this walks toward more-normal
    /// beats. Returns the first-ranked beat when `fromSampleIndex` is
    /// nil (i.e., "start with the most-deviant").
    public func nextDeviationBeat(after fromSampleIndex: Int64?) -> MarkingsBeat? {
        let ranked = beatsRankedByDeviation
        guard !ranked.isEmpty else { return nil }
        guard let from = fromSampleIndex,
              let currentIdx = ranked.firstIndex(where: { $0.rPeakSampleIndex == from }) else {
            return ranked.first
        }
        let nextIdx = currentIdx + 1
        return nextIdx < ranked.count ? ranked[nextIdx] : nil
    }

    /// Previous beat (by deviation rank) before `fromSampleIndex`.
    /// Walks toward more-deviant beats.
    public func previousDeviationBeat(before fromSampleIndex: Int64?) -> MarkingsBeat? {
        let ranked = beatsRankedByDeviation
        guard !ranked.isEmpty else { return nil }
        guard let from = fromSampleIndex,
              let currentIdx = ranked.firstIndex(where: { $0.rPeakSampleIndex == from }) else {
            return ranked.first
        }
        let prevIdx = currentIdx - 1
        return prevIdx >= 0 ? ranked[prevIdx] : nil
    }

    private enum Keys {
        static let qtcFormula = "murmur.intervalMarkings.qtcFormula"
    }
}

/// MurmurCore-visible mirror of `MurmurMetrics.QTcFormula`. Kept
/// separate so MurmurCore stays uncoupled from the paid framework's
/// symbols (settings UI + persistence live here).
public enum MarkingsQTcFormula: String, Sendable, CaseIterable, Codable {
    case bazett
    case fridericia
    case framingham
    case hodges

    public var displayName: String {
        switch self {
        case .bazett: return "Bazett"
        case .fridericia: return "Fridericia"
        case .framingham: return "Framingham"
        case .hodges: return "Hodges"
        }
    }
}
