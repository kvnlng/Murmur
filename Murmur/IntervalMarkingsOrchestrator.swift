//
//  IntervalMarkingsOrchestrator.swift
//  Murmur (app target)
//
//  Invisible glue view that computes fiducials + normal template for
//  the currently-loaded recording and publishes them to
//  `IntervalMarkingsContext.shared` for BedsideView's overlays to
//  render. Same pattern as `VariabilityLaneOrchestrator`.
//
//  Enforces the ECG Metrics entitlement gate on the paid-framework
//  side of the boundary — MurmurCore never sees fiducials unless the
//  IAP is owned, matching "no arithmetic on measurements in
//  MurmurCore" from `project_metrics_module_boundaries.md`.
//
//  Delineation is a fair amount of work per recording (thousands of
//  beats × per-beat window computations). Runs on a background
//  detached Task so we don't block the main actor while the analyst
//  opens a large recording.
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct IntervalMarkingsOrchestrator: View {

    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var markingsContext = IntervalMarkingsContext.shared
    @State private var store = PurchaseStore.shared

    /// Task key changes whenever recompute is warranted.
    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
        let qtcFormula: MarkingsQTcFormula
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.owns(.ecgMetrics),
                qtcFormula: markingsContext.qtcFormula
            )) {
                await recompute()
            }
    }

    private func recompute() async {
        // Gate on entitlement + presence of a recording; clear
        // otherwise so a mid-session unmount doesn't leave stale
        // fiducials rendering on the next recording.
        guard store.owns(.ecgMetrics),
              let recording = recordingContext.recording,
              let directory = recordingContext.directory,
              let ecgChannel = recording.primaryECGChannel else {
            await MainActor.run { markingsContext.clear() }
            return
        }
        let beatSampleIndices = recording.normalBeatSampleIndices()
        guard !beatSampleIndices.isEmpty,
              let samples = recording.primaryECGSamples(inDirectory: directory) else {
            await MainActor.run { markingsContext.clear() }
            return
        }
        let sampleRate = ecgChannel.sampleRate
        let qtcFormula = await MainActor.run { markingsContext.qtcFormula }

        // Delineate + measure + build template off the main actor.
        // Even a multi-hour recording (~100k beats) is a few hundred
        // milliseconds; we don't want to jitter the canvas while it
        // runs.
        let computed = await Task.detached(priority: .userInitiated) { () -> (
            beats: [MarkingsBeat],
            template: MarkingsTemplate?
        ) in
            let store = BeatDelineator.delineate(
                samples: samples,
                sampleRate: sampleRate,
                rPeaks: beatSampleIndices
            )
            let readouts = IntervalMeasurement.measureAll(store: store)
            let template = NormalTemplateBuilder.build(
                from: readouts,
                qtcFormula: Self.metricsFormula(from: qtcFormula)
            )
            let beats = zip(store.beats, readouts).map { (bf, ro) in
                MarkingsBeat(
                    rPeakSampleIndex: bf.rPeakSampleIndex,
                    rPeakConfidence: bf.rPeakConfidence,
                    pOnset: bf.pOnset.map(Self.coreFiducial(_:)),
                    pOffset: bf.pOffset.map(Self.coreFiducial(_:)),
                    qrsOnset: bf.qrsOnset.map(Self.coreFiducial(_:)),
                    qrsOffset: bf.qrsOffset.map(Self.coreFiducial(_:)),
                    tOnset: bf.tOnset.map(Self.coreFiducial(_:)),
                    tOffset: bf.tOffset.map(Self.coreFiducial(_:)),
                    prMs: ro.prMs,
                    qrsMs: ro.qrsMs,
                    qtMs: ro.qtMs,
                    qtcMs: ro.qtcMs(formula: Self.metricsFormula(from: qtcFormula)),
                    precedingRRMs: ro.precedingRRMs
                )
            }
            let coreTemplate: MarkingsTemplate? = template.sampleCount > 0
                ? MarkingsTemplate(
                    sampleCount: template.sampleCount,
                    medianPRMs: template.medianPRMs,
                    iqrPRMs: template.iqrPRMs,
                    medianQRSMs: template.medianQRSMs,
                    iqrQRSMs: template.iqrQRSMs,
                    medianQTMs: template.medianQTMs,
                    iqrQTMs: template.iqrQTMs,
                    qtcFormulaName: template.qtcFormula.displayName,
                    medianQTcMs: template.medianQTcMs,
                    iqrQTcMs: template.iqrQTcMs
                )
                : nil
            return (beats, coreTemplate)
        }.value

        await MainActor.run {
            if computed.beats.isEmpty {
                markingsContext.clear()
            } else {
                markingsContext.set(
                    beats: computed.beats,
                    sampleRate: sampleRate,
                    template: computed.template
                )
            }
        }
    }

    // MARK: - Enum bridging

    private static func metricsFormula(from mirror: MarkingsQTcFormula) -> QTcFormula {
        switch mirror {
        case .bazett:     return .bazett
        case .fridericia: return .fridericia
        case .framingham: return .framingham
        case .hodges:     return .hodges
        }
    }

    // MARK: - Fiducial bridging

    private static func coreFiducial(_ f: Fiducial) -> MarkingsFiducial {
        MarkingsFiducial(
            kind: coreKind(f.kind),
            sampleIndex: f.sampleIndex,
            confidence: f.confidence
        )
    }

    private static func coreKind(_ kind: FiducialKind) -> MarkingsFiducialKind {
        switch kind {
        case .pOnset:    return .pOnset
        case .pOffset:   return .pOffset
        case .qrsOnset:  return .qrsOnset
        case .rPeak:     return .rPeak
        case .qrsOffset: return .qrsOffset
        case .tOnset:    return .tOnset
        case .tOffset:   return .tOffset
        }
    }
}
