//
//  IntervalTrendLaneMemo.swift
//  MurmurCore
//
//  Memoisation for the interval trend lane: a one-slot compute cache and the
//  `Equatable` wrapper that lets SwiftUI skip the lane's body during a zoom
//  burst. Extracted from BedsideView in X67.
//

import SwiftUI


/// One-slot memo for the trend compute, keyed on ONLY the inputs the compute
/// actually depends on — NOT the viewport. The memoized strip's `==` includes
/// the compute inputs, so the strip body
/// re-runs on every pan/zoom frame. Without this, `IntervalTrendComputer.compute`
/// — O(N_beats) with a per-bin bootstrap CI — ran again on each of those frames
/// and HUNG on a long recording (NSRDB is ~8 h → tens of thousands of beats over
/// hundreds of bins). Zoom repeats the same key, so this collapses the recompute
/// to an O(1) cache hit. Single slot is enough: there is one trend lane, and a
/// zoom burst hammers one identical key.
@MainActor
private enum IntervalTrendComputeMemo {
    struct Key: Equatable {
        let beatsCount: Int
        let firstRPeak: Int64?
        let lastRPeak: Int64?
        let sampleRate: Double
        let metric: IntervalTrendMetric
        let binSeconds: Double
        let templateBeatCount: Int?
        let qtcFormulaName: String
        let template: MarkingsTemplate?
        let qualifiers: [IntervalBinQualifier]
        /// X58: the gate echo lands in the repro caption, so a dial change
        /// with an unchanged template (nothing newly excluded) must still
        /// bust the memo.
        let tOffsetGateCaption: String
    }

    private static var cachedKey: Key?
    private static var cachedValue: IntervalTrendData?

    static func data(for key: Key, compute: () -> IntervalTrendData) -> IntervalTrendData {
        if key == cachedKey, let cachedValue { return cachedValue }
        let value = compute()
        cachedKey = key
        cachedValue = value
        return value
    }
}

// MARK: - Interval trend lane memoization

/// Wraps `IntervalTrendComputer.compute` + `IntervalTrendLane` so
/// SwiftUI can `.equatable()`-skip the whole subtree when the parent
/// body re-runs for reasons unrelated to the trend (the dominant
/// case being pan/zoom of the ECG viewport). Compute is O(N_beats)
/// with bootstrap CI on every bin — on a 1600-beat recording it
/// dominates the per-tick cost of a pan burst.
///
/// The equality fingerprint is intentionally lightweight: `beats`
/// count + endpoint R-peak samples. The delineator writes the entire
/// beats array atomically per recording; middle mutations don't
/// happen at runtime, so this fingerprint catches every real change
/// (new recording / delineator re-run with different config both
/// change endpoints or count) without paying an O(N) hash per pass.
/// Closures are excluded — they're rebuilt on every parent body
/// pass but capture the same latest bindings, so skipping body when
/// only the closure identity changed is safe.
struct IntervalTrendLaneMemoizedStrip: View, Equatable {
    let beats: [MarkingsBeat]
    let template: MarkingsTemplate?
    let sampleRate: Double
    /// #371: threaded through to the lane so the repro caption's lead
    /// fragment resolves declarations for THIS record. In the fingerprint —
    /// a record change must never render under a stale id. NOT a compute
    /// input: the memo key stays placement-free.
    let recordID: String?
    let metric: IntervalTrendMetric
    let binSeconds: Double
    let templateBeatCount: Int?
    let qtcFormulaName: String
    /// The QTc formula in effect, for the X44 picker (distinct from the echoed
    /// `qtcFormulaName` string used in the repro caption).
    let qtcFormula: MarkingsQTcFormula
    /// Paid per-bin qualifying facts (X42) joined into the bins for the X43
    /// marker + X46 gate. Empty in the free viewer.
    let qualifiers: [IntervalBinQualifier]
    let recordingTimeRange: ClosedRange<Double>
    let showMode: IntervalTrendShowMode
    let selectedBinPreset: IntervalTrendBinPreset
    let guides: [IntervalTrendGuide]
    let events: [IntervalTrendEvent]
    let externalHoverTimeSeconds: Double?
    /// Analyst-authored range findings rendered as amber overlays. In the
    /// fingerprint so authoring a new finding rebuilds the lane.
    let rangeFindings: [IntervalTrendRangeFinding]
    /// Whether drag-to-author is active (edit latch + Annotation IAP). In the
    /// fingerprint so toggling edit mode / entitlement re-arms the gesture.
    let authoringEnabled: Bool
    let onLaneHover: (Double?) -> Void
    let onBinClick: (Double) -> Void
    let onPickMetric: (IntervalTrendMetric) -> Void
    let onPickBinPreset: (IntervalTrendBinPreset) -> Void
    let onPickShowMode: (IntervalTrendShowMode) -> Void
    let onPickFormula: (MarkingsQTcFormula) -> Void
    /// X58: the T-offset gate in effect + its setter. In the fingerprint so a
    /// dial change re-renders the chip and recomputes the caption.
    let qtWithheldReason: String?
    let rrCVFlagPercent: Double
    let onPickRRCVFlag: ((Double) -> Void)?
    let tOffsetGateEnabled: Bool
    let tOffsetGateScore: Int
    let onSetTOffsetGate: (Bool, Int) -> Void
    let onAddGuide: (Double, String) -> Void
    let onRemoveGuide: (UUID) -> Void
    /// Excluded from `==` (a closure rebuilt every pass); gated by
    /// `authoringEnabled`, which IS in the fingerprint.
    let onAuthorRange: (Double, Double, String, String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.beats.count == rhs.beats.count,
              lhs.beats.first?.rPeakSampleIndex == rhs.beats.first?.rPeakSampleIndex,
              lhs.beats.last?.rPeakSampleIndex == rhs.beats.last?.rPeakSampleIndex else {
            return false
        }
        return lhs.templateBeatCount == rhs.templateBeatCount
            && lhs.sampleRate == rhs.sampleRate
            && lhs.recordID == rhs.recordID
            && lhs.metric == rhs.metric
            && lhs.binSeconds == rhs.binSeconds
            && lhs.qtcFormulaName == rhs.qtcFormulaName
            && lhs.qtcFormula == rhs.qtcFormula
            && lhs.qualifiers == rhs.qualifiers
            && lhs.recordingTimeRange == rhs.recordingTimeRange
            && lhs.showMode == rhs.showMode
            && lhs.selectedBinPreset == rhs.selectedBinPreset
            && lhs.guides == rhs.guides
            && lhs.events == rhs.events
            && lhs.externalHoverTimeSeconds == rhs.externalHoverTimeSeconds
            && lhs.rangeFindings == rhs.rangeFindings
            && lhs.authoringEnabled == rhs.authoringEnabled
            && lhs.qtWithheldReason == rhs.qtWithheldReason
            && lhs.rrCVFlagPercent == rhs.rrCVFlagPercent
            && lhs.tOffsetGateEnabled == rhs.tOffsetGateEnabled
            && lhs.tOffsetGateScore == rhs.tOffsetGateScore
    }

    var body: some View {
        // Recompute only when a COMPUTE input changes — not on pan/zoom, which
        // only moves the render's x-domain. This is what keeps a long recording
        // from hanging as the strip body re-runs on each zoom frame.
        let gateCaption = IntervalMarkingsContext.tOffsetGateCaption(
            enabled: tOffsetGateEnabled, score: tOffsetGateScore
        )
        let key = IntervalTrendComputeMemo.Key(
            beatsCount: beats.count,
            firstRPeak: beats.first?.rPeakSampleIndex,
            lastRPeak: beats.last?.rPeakSampleIndex,
            sampleRate: sampleRate,
            metric: metric,
            binSeconds: binSeconds,
            templateBeatCount: templateBeatCount,
            qtcFormulaName: qtcFormulaName,
            template: template,
            qualifiers: qualifiers,
            tOffsetGateCaption: gateCaption
        )
        let data = IntervalTrendComputeMemo.data(for: key) {
            IntervalTrendComputer.compute(
                beats: beats,
                template: template,
                sampleRate: sampleRate,
                metric: metric,
                binSeconds: binSeconds,
                templateBeatCount: templateBeatCount,
                qtcFormulaName: qtcFormulaName,
                // X48 §4(b): the template's beats are the annotator's normal-beat
                // code (Recording.normalBeatSampleIndices), NOT an app-computed
                // morphology cluster — state that selection basis in the caption.
                // X112 §2 adds the adjudication state: the annotator-normal
                // default is TODAY'S behaviour, named (X112b) — and an
                // endorsed baseline states its analyst provenance instead,
                // including the §6 off-band count for a second mode (X112c).
                templateSelectionBasis: template.map {
                    $0.adjudicationBasis ?? "unadjudicated — annotator-coded normal (N)"
                },
                qualifiers: qualifiers,
                tOffsetGateCaption: gateCaption
            )
        }
        IntervalTrendLane(
            // X88: the lane is a location finder — its x-domain is ALWAYS
            // the whole recording, never the viewport.
            timeRangeSeconds: recordingTimeRange,
            data: data,
            metric: metric,
            recordID: recordID,
            showMode: showMode,
            qtcFormula: qtcFormula,
            selectedBinPreset: selectedBinPreset,
            guides: guides,
            events: events,
            rangeFindings: rangeFindings,
            externalHoverTimeSeconds: externalHoverTimeSeconds,
            onLaneHover: onLaneHover,
            onBinClick: onBinClick,
            onPickMetric: onPickMetric,
            onPickBinPreset: onPickBinPreset,
            onPickShowMode: onPickShowMode,
            onPickFormula: onPickFormula,
            qtWithheldReason: qtWithheldReason,
            rrCVFlagPercent: rrCVFlagPercent,
            onPickRRCVFlag: onPickRRCVFlag,
            tOffsetGateEnabled: tOffsetGateEnabled,
            tOffsetGateScore: tOffsetGateScore,
            onSetTOffsetGate: onSetTOffsetGate,
            onAddGuide: onAddGuide,
            onRemoveGuide: onRemoveGuide,
            // Gate the gesture here so a locked / unentitled lane still taps +
            // hovers but never authors.
            onAuthorRange: authoringEnabled ? onAuthorRange : nil
        )
    }
}


