//
//  VariabilityMetricsOrchestrator.swift
//  Murmur (app target)
//
//  Computes the whole-record variability summary and publishes it to
//  `VariabilityMetricsContext` for the bedside strip to render. Same pattern
//  as `VariabilityLaneOrchestrator` / `IntervalMarkingsOrchestrator`: the App
//  target is the only place MurmurCore and MurmurMetrics meet, so it owns the
//  entitlement gate and all measurement formatting.
//
//  Replaces `ECGMetricsSurface`, which was the content of a detached window
//  (⌘⇧M). The window is gone — the summary now lives in the record's own
//  column beneath the variability lane. See `VariabilityMetricsStrip` for the
//  reasoning.
//
//  Formatting lives here, not in MurmurCore, because how many digits a
//  measurement deserves is a statement about the measurement
//  (`project_metrics_module_boundaries.md`). Digit counts and captions are
//  carried over verbatim from `ECGMetricsView` so the numbers an analyst has
//  been reading do not change shape underneath them.
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct VariabilityMetricsOrchestrator: View {
    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var markingsContext = IntervalMarkingsContext.shared
    @State private var metricsContext = VariabilityMetricsContext.shared
    @State private var scopeContext = MetricsScopeContext.shared
    @State private var store = PurchaseStore.shared

    /// Recompute key. Beat count stands in for "the fiducial store changed" —
    /// the QTVI half reads `markingsContext.beats`, which arrives
    /// asynchronously after delineation finishes.
    ///
    /// X73 added the scope and the range it resolves to. The RESOLVED range is
    /// the key, not the raw viewport: in whole-record scope the range is nil,
    /// so panning does not re-key at all, and in hour scope it only changes
    /// when the analyst crosses an hour boundary. Keying on the viewport
    /// itself would recompute on every pixel of pan in every scope.
    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
        let beatCount: Int
        let scope: MetricsScope
        let rangeStart: Int64?
        let rangeEnd: Int64?
    }

    /// How long a scoped range must hold still before it is worth recomputing.
    ///
    /// Only whole-record scope is free. Window scope re-keys on every pan, and
    /// the compute walks every normal beat in the recording — 6.4 M on a 72 h
    /// record. `.task(id:)` cancels and restarts on each key change, so a
    /// sleep at the top of the task IS the debounce: a drag that crosses fifty
    /// keys pays for one compute, at the end.
    private static let scopeDebounceNS: UInt64 = 350_000_000

    private var resolvedRange: Range<Int64>? {
        guard let recording = recordingContext.recording,
              let total = recording.channels.first?.sampleCount else { return nil }
        return scopeContext.effectiveRange(totalSamples: total)
    }

    var body: some View {
        let range = resolvedRange
        return Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio,
                beatCount: markingsContext.beats.count,
                scope: scopeContext.scope,
                rangeStart: range?.lowerBound,
                rangeEnd: range?.upperBound
            )) {
                if scopeContext.scope != .wholeRecord {
                    try? await Task.sleep(nanoseconds: Self.scopeDebounceNS)
                    if Task.isCancelled { return }
                }
                recompute(range: range)
            }
    }

    @MainActor
    private func recompute(range: Range<Int64>?) {
        guard let recording = recordingContext.recording else {
            metricsContext.clear()
            return
        }
        // A recording is open but unpaid — the one empty state that earns a
        // seam. Everything else stays silent. X73 keeps the scope control
        // behind the same gate: it is a way of asking the paid computation a
        // narrower question, not a free capability.
        guard store.hasStudio else {
            metricsContext.setLocked()
            return
        }
        var beats = recording.normalBeatSampleIndices()
        if let range {
            beats = beats.filter { range.contains($0) }
        }
        // Too few beats to measure. On the WHOLE record that is silence — the
        // pre-X73 behaviour, and nothing the analyst can dial changes it. But
        // a SCOPED range (window / hour) that comes up short must keep the
        // strip mounted (X95): unmounting takes the scope picker with it, so
        // "zoom to 10 s in Window scope" read as the whole pane vanishing,
        // with no way back except zooming out.
        func publishEmpty() {
            if range != nil {
                metricsContext.setInsufficient(scope: scopeContext.scope, beatCount: beats.count)
            } else {
                metricsContext.clear()
            }
        }
        guard let sampleRate = recording.channels.first?.sampleRate,
              let series = ECGMetricsExtractor.rrSeries(
                  fromBeatSampleIndices: beats,
                  sampleRate: sampleRate
              ) else {
            publishEmpty()
            return
        }
        guard let report = ECGMetricsService.compute(from: series) else {
            publishEmpty()
            return
        }
        metricsContext.set(summary: Self.summary(
            report: report,
            qtvi: qtviSummary(),
            recordName: recording.device,
            scope: scopeContext.scope
        ))
    }

    // MARK: - Summary assembly

    private static func summary(
        report: ECGMetricsReport,
        qtvi: QTVISummary?,
        recordName: String,
        scope: MetricsScope
    ) -> VariabilityMetricsSummary {
        var sections = [timeDomainSection(report)]
        if let fd = report.frequencyDomain {
            sections.append(frequencyDomainSection(fd))
        }
        sections.append(qtviSection(qtvi))
        // The scope is named in the provenance, not just shown in the picker.
        // A copied or screenshotted block has to say what it covered — a
        // 5-minute SDNN and a 25-hour SDNN are different measurements, and
        // without the scope in the text they are indistinguishable.
        return VariabilityMetricsSummary(
            sections: sections,
            provenance: "\(recordName) · \(scope.provenanceLabel) · "
                + "\(report.beatCount) beats · \(duration(report.durationSeconds))",
            exportText: "Scope: \(scope.provenanceLabel)\n" + report.formattedReport()
        )
    }

    private static func timeDomainSection(
        _ report: ECGMetricsReport
    ) -> VariabilityMetricsSummary.Section {
        .init(
            id: "variability-metrics-time-domain",
            title: "Heart rate variability",
            rows: [
                .init(id: "vm-mean-rr", label: "Mean RR", value: value(report.meanRRMs), unit: "ms"),
                .init(id: "vm-sdnn", label: "SDNN", value: value(report.sdnnMs), unit: "ms"),
                .init(id: "vm-rmssd", label: "RMSSD", value: value(report.rmssdMs), unit: "ms"),
                .init(id: "vm-pnn50", label: "pNN50", value: value(report.pnn50Percent), unit: "%"),
            ],
            advisory: report.meetsTaskForceMinimum ? nil :
                "Below Task Force minimum (\(report.beatCount) < \(ECGMetricsReport.taskForceMinimumBeats) beats). "
                + "Interpret variability with caution."
        )
    }

    /// Reports each band's power with the estimator, window, and band edges
    /// alongside — never a bare LF/HF — plus the two validity surfaces: VLF is
    /// omitted with a note when the window is too short, and the excluded-beat
    /// fraction is stated factually. All neutral: LF/HF is a measurement, never
    /// "sympathetic/parasympathetic balance".
    private static func frequencyDomainSection(
        _ fd: FrequencyDomainHRV
    ) -> VariabilityMetricsSummary.Section {
        var rows: [VariabilityMetricsSummary.Row] = []
        if let vlf = fd.vlf.absolutePowerMs2 {
            rows.append(.init(id: "vm-vlf", label: "VLF", value: power(vlf), unit: "ms²"))
        }
        if let lf = fd.lf.absolutePowerMs2 {
            rows.append(.init(id: "vm-lf", label: "LF", value: power(lf), unit: "ms²"))
        }
        if let hf = fd.hf.absolutePowerMs2 {
            rows.append(.init(id: "vm-hf", label: "HF", value: power(hf), unit: "ms²"))
        }
        if let ratio = fd.lfhfRatio {
            rows.append(.init(id: "vm-lfhf", label: "LF/HF", value: String(format: "%.2f", ratio)))
        }
        if let lfnu = fd.lfNormalizedUnits, let hfnu = fd.hfNormalizedUnits {
            rows.append(.init(
                id: "vm-lfhf-nu",
                label: "LF / HF n.u.",
                value: String(format: "%.0f / %.0f", lfnu, hfnu)
            ))
        }
        var captions = [
            "\(fd.estimator) · \(duration(fd.windowSeconds)) window · "
            + "VLF 0.003–0.04 / LF 0.04–0.15 / HF 0.15–0.40 Hz",
        ]
        if !fd.vlfSupported {
            captions.append("VLF not reported — window too short for very-low-frequency content.")
        }
        captions.append(String(
            format: "%.0f%% of beats excluded as artifact before the spectrum.",
            fd.excludedBeatFraction * 100
        ))
        return .init(
            id: "variability-metrics-frequency-domain",
            title: "Frequency-domain HRV",
            rows: rows,
            captions: captions
        )
    }

    private static func qtviSection(
        _ qtvi: QTVISummary?
    ) -> VariabilityMetricsSummary.Section {
        guard let q = qtvi else {
            return .init(
                id: "variability-metrics-qtvi-empty",
                title: "QT variability index",
                captions: ["No qualifying 5-min segments (needs ≥ 5 min of stable, artifact-free rate)."]
            )
        }
        return .init(
            id: "variability-metrics-qtvi",
            title: "QT variability index",
            rows: [
                .init(id: "vm-qtvi", label: "QTVI", value: String(format: "%.2f", q.medianQTVI)),
                .init(id: "vm-sdqt", label: "SDQT", value: String(format: "%.0f", q.medianSDQTMs), unit: "ms"),
                .init(id: "vm-qtvi-sdnn", label: "SDNN", value: String(format: "%.0f", q.medianSDNNMs), unit: "ms"),
                .init(id: "vm-qtvi-meannn", label: "Mean NN", value: String(format: "%.0f", q.medianMeanNNMs), unit: "ms"),
            ],
            // No reference range — QTVi tracks SDNN more tightly than mean QT,
            // so a normal/abnormal band isn't defensible (RUO stance).
            captions: [
                "Median over \(q.segmentCount) qualifying 5-min segment"
                + (q.segmentCount == 1 ? "" : "s")
                + " (stable rate, no excluded beats). No reference range — "
                + "QTVi tracks heart-rate variability (SDNN) more than QT duration.",
            ]
        )
    }

    // Digit counts carried over verbatim from `ECGMetricsView`.
    private static func value(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func power(_ v: Double) -> String { String(format: "%.0f", v) }

    private static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%.1f min", minutes) }
        return String(format: "%.1f h", minutes / 60)
    }

    // MARK: - QT Variability Index (X47)

    private struct QTVISummary {
        let medianQTVI: Double
        let medianSDQTMs: Double
        let medianSDNNMs: Double
        let medianMeanNNMs: Double
        let segmentCount: Int
    }

    /// QTVI over qualifying 5-min segments of the delineated beats. A segment
    /// qualifies when it is artifact-free (no excluded RR) AND its rate is
    /// stable within Malik 2008's ±2 bpm — the spec's "stable rate, no ectopic
    /// disturbance". Reported as the median across qualifying segments; nil
    /// when none qualify.
    ///
    /// Stability comes from `QualifyingWindowComputer.isRateStable`, the same
    /// definition the trend lane's X43 marker uses. This path used to carry its
    /// own private copy that compared every beat's INSTANTANEOUS rate against
    /// the ±2 bpm tolerance; respiratory sinus arrhythmia alone exceeds that
    /// within a few beats, so it qualified 0 of 4,620 segments across the whole
    /// normal-sinus database. Two copies of one rule is how they diverged —
    /// there is now one.
    private func qtviSummary() -> QTVISummary? {
        let beats = markingsContext.beats
        let sampleRate = markingsContext.sampleRate
        guard sampleRate > 0, beats.count > 1 else { return nil }
        let segmentSeconds = QTVarianceComputer.minSegmentSeconds

        var buckets: [Int: (qt: [Double], rr: [Double])] = [:]
        for beat in beats {
            guard let qt = beat.qtMs, let rr = beat.precedingRRMs,
                  qt.isFinite, rr.isFinite, rr > 0 else { continue }
            let segment = Int((Double(beat.rPeakSampleIndex) / sampleRate) / segmentSeconds)
            buckets[segment, default: ([], [])].qt.append(qt)
            buckets[segment, default: ([], [])].rr.append(rr)
        }

        var indices: [QTVariabilityIndex] = []
        for (_, seg) in buckets {
            guard RRArtifactFilter.excludedFraction(for: seg.rr) == 0,
                  QualifyingWindowComputer.isRateStable(rrMs: seg.rr),
                  let idx = QTVarianceComputer.compute(
                      qtMs: seg.qt, rrMs: seg.rr, segmentSeconds: segmentSeconds
                  ) else { continue }
            indices.append(idx)
        }
        guard !indices.isEmpty else { return nil }
        return QTVISummary(
            medianQTVI: Self.median(indices.map(\.qtvi)),
            medianSDQTMs: Self.median(indices.map(\.sdqtMs)),
            medianSDNNMs: Self.median(indices.map(\.sdnnMs)),
            medianMeanNNMs: Self.median(indices.map(\.meanNNMs)),
            segmentCount: indices.count
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
