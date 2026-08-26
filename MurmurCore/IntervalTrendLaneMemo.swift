//
//  IntervalTrendLaneMemo.swift
//  MurmurCore
//
//  The `Equatable` wrapper that lets SwiftUI skip the interval trend
//  lane's body during a zoom burst. Extracted from BedsideView in X67.
//
//  #380 retired the one-slot compute memo that used to live here: the
//  per-bin production (O(N_beats) with a per-bin bootstrap CI — the
//  thing that HUNG on an ~8 h NSRDB recording when it ran per zoom
//  frame) moved behind the paid boundary and runs ONCE, off-main, in
//  the App's `TrendBinsOrchestrator`. The strip now receives finished
//  bins and only assembles caption + baseline per body pass, which is
//  cheap; the `.equatable()` skip still spares even that during
//  pan/zoom.
//

import SwiftUI

/// Wraps `IntervalTrendComputer.compute` (caption/baseline assembly
/// over produced bins) + `IntervalTrendLane` so SwiftUI can
/// `.equatable()`-skip the whole subtree when the parent body re-runs
/// for reasons unrelated to the trend (the dominant case being
/// pan/zoom of the ECG viewport).
///
/// The equality fingerprint compares the produced `bins` directly —
/// per-bin aggregates plus per-beat value arrays, tens of doubles per
/// bin over at most hundreds of bins, far cheaper than the compute it
/// replaces. Closures are excluded — they're rebuilt on every parent
/// body pass but capture the same latest bindings, so skipping body
/// when only the closure identity changed is safe.
struct IntervalTrendLaneMemoizedStrip: View, Equatable {
    /// Produced trend bins from `TrendBinsContext` (paid compute, #380).
    /// Empty until the orchestrator publishes — the lane renders its
    /// caption and baseline band in the meantime.
    let bins: [IntervalTrendBin]
    let template: MarkingsTemplate?
    let sampleRate: Double
    /// #371: threaded through to the lane so the repro caption's lead
    /// fragment resolves declarations for THIS record. In the fingerprint —
    /// a record change must never render under a stale id.
    let recordID: String?
    let metric: IntervalTrendMetric
    let binSeconds: Double
    let templateBeatCount: Int?
    let qtcFormulaName: String
    /// The QTc formula in effect, for the X44 picker (distinct from the echoed
    /// `qtcFormulaName` string used in the repro caption).
    let qtcFormula: MarkingsQTcFormula
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
        lhs.bins == rhs.bins
            && lhs.template == rhs.template
            && lhs.templateBeatCount == rhs.templateBeatCount
            && lhs.sampleRate == rhs.sampleRate
            && lhs.recordID == rhs.recordID
            && lhs.metric == rhs.metric
            && lhs.binSeconds == rhs.binSeconds
            && lhs.qtcFormulaName == rhs.qtcFormulaName
            && lhs.qtcFormula == rhs.qtcFormula
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
        // Caption + baseline assembly over finished bins — cheap, so no
        // memo; the heavy production ran once in the orchestrator (#380).
        let data = IntervalTrendComputer.compute(
            bins: bins,
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
            tOffsetGateCaption: IntervalMarkingsContext.tOffsetGateCaption(
                enabled: tOffsetGateEnabled, score: tOffsetGateScore
            )
        )
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
