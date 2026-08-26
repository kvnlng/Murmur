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

    @State private var reportCache: ReportCache?

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
                await recompute(range: range)
            }
    }

    private func recompute(range: Range<Int64>?) async {
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
        // The beat walk, range filter, RR series, full HRV report, and QTVI
        // segmentation run in `Task.detached` — they measured 4.8 s of blocked
        // main thread on a 25-hour nsrdb record (100k beats). Main-actor state
        // is gathered here, before detaching; only the publish hops back.
        // `defer` so the insufficient-beats and no-series returns are
        // measured too.
        var measuredBeatCount = 0
        let signpost = ComputeSignpost.begin("VariabilityMetrics")
        defer { ComputeSignpost.end(signpost, workSize: measuredBeatCount) }
        let sampleRate = recording.channels.first?.sampleRate
        let markingsBeats = markingsContext.beats
        let markingsSampleRate = markingsContext.sampleRate
        let cached = reportCache.flatMap {
            $0.matches(recordingID: recording.id, range: range) ? $0 : nil
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.computeOutcome(
                recording: recording,
                range: range,
                sampleRate: sampleRate,
                markings: (beats: markingsBeats, sampleRate: markingsSampleRate),
                cached: cached
            )
        }.value

        // A recording swap cancels this .task but not the detached compute —
        // never publish a stale record's summary over the new one's (the
        // Morphology precedent).
        switch outcome {
        case .empty(let beatCount):
            measuredBeatCount = beatCount
            guard !Task.isCancelled else { return }
            // Too few beats to measure. On the WHOLE record that is silence —
            // the pre-X73 behaviour, and nothing the analyst can dial changes
            // it. But a SCOPED range (window / hour) that comes up short must
            // keep the strip mounted (X95): unmounting takes the scope picker
            // with it, so "zoom to 10 s in Window scope" read as the whole
            // pane vanishing, with no way back except zooming out.
            if range != nil {
                metricsContext.setInsufficient(scope: scopeContext.scope, beatCount: beatCount)
            } else {
                metricsContext.clear()
            }
        case .computed(let report, let qtvi, let beatCount):
            measuredBeatCount = beatCount
            guard !Task.isCancelled else { return }
            reportCache = ReportCache(
                recordingID: recording.id,
                rangeStart: range?.lowerBound,
                rangeEnd: range?.upperBound,
                report: report,
                beatCount: beatCount
            )
            metricsContext.set(summary: Self.summary(
                report: report,
                qtvi: qtvi,
                recordName: recording.device,
                scope: scopeContext.scope
            ))
        }
    }

    /// The full chain, pure over its inputs — `nonisolated static` so the
    /// detached task can run it without touching the View's
    /// main-actor-inferred members.
    private nonisolated static func computeOutcome(
        recording: Recording,
        range: Range<Int64>?,
        sampleRate: Double?,
        markings: (beats: [MarkingsBeat], sampleRate: Double),
        cached: ReportCache?
    ) -> Outcome {
        // Cache hit: this re-key came from the markings side (delineation
        // finished, or endorsements changed the fiducial store) — only
        // the QTVI half can have changed. Skip the beat walk and report.
        if let cached {
            // Sub-measured: the Release run of 2026-08-18 logged 6.6 s for
            // this supposedly-QTVI-only path, which is out of proportion to
            // the work. This signpost splits the question — if
            // VariabilityQTVI ≈ the parent interval, QTVI itself is the
            // cost; if it is small, the cache missed and the full path ran.
            let qtvi = ComputeSignpost.measure("VariabilityQTVI", workSize: { markings.beats.count }) {
                qtviSummary(beats: markings.beats, sampleRate: markings.sampleRate)
            }
            return .computed(report: cached.report, qtvi: qtvi, beatCount: cached.beatCount)
        }
        var beats = recording.normalBeatSampleIndices()
        if let range {
            beats = beats.filter { range.contains($0) }
        }
        guard let sampleRate,
              let series = ECGMetricsExtractor.rrSeries(
                  fromBeatSampleIndices: beats,
                  sampleRate: sampleRate
              ),
              let report = ECGMetricsService.compute(from: series) else {
            return .empty(beatCount: beats.count)
        }
        let qtvi = ComputeSignpost.measure("VariabilityQTVI", workSize: { markings.beats.count }) {
            qtviSummary(beats: markings.beats, sampleRate: markings.sampleRate)
        }
        return .computed(report: report, qtvi: qtvi, beatCount: beats.count)
    }

    // MARK: - Summary assembly

    private static func summary(
        report: ECGMetricsReport,
        qtvi: QTVISegmentMedians?,
        recordName: String,
        scope: MetricsScope
    ) -> VariabilityMetricsSummary {
        let sections = [
            timeDomainSection(report),
            frequencyDomainSection(report.frequencyDomain),
            qtviSection(qtvi),
        ]
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
    /// em-dashed with a note when the window is too short, and the
    /// excluded-beat fraction is stated factually. All neutral: LF/HF is a
    /// measurement, never "sympathetic/parasympathetic balance".
    ///
    /// The full canonical row set is ALWAYS emitted — a band the analyzer
    /// could not measure renders an em-dash, never a missing row. 12a's rule
    /// is dimensional: the populated card and the unmeasured skeleton
    /// (`VariabilityMetricsSummary.unmeasured`) must be the same shape, so
    /// numbers arriving changes glyphs, not geometry.
    private static func frequencyDomainSection(
        _ fd: FrequencyDomainHRV?
    ) -> VariabilityMetricsSummary.Section {
        let lfhf: String
        if let ratio = fd?.lfhfRatio {
            lfhf = String(format: "%.2f", ratio)
        } else {
            lfhf = "—"
        }
        let nu: String
        if let lfnu = fd?.lfNormalizedUnits, let hfnu = fd?.hfNormalizedUnits {
            nu = String(format: "%.0f / %.0f", lfnu, hfnu)
        } else {
            nu = "—"
        }
        let rows: [VariabilityMetricsSummary.Row] = [
            .init(id: "vm-vlf", label: "VLF",
                  value: power(fd?.vlf.absolutePowerMs2), unit: "ms²"),
            .init(id: "vm-lf", label: "LF",
                  value: power(fd?.lf.absolutePowerMs2), unit: "ms²"),
            .init(id: "vm-hf", label: "HF",
                  value: power(fd?.hf.absolutePowerMs2), unit: "ms²"),
            .init(id: "vm-lfhf", label: "LF/HF", value: lfhf),
            .init(id: "vm-lfhf-nu", label: "LF / HF n.u.", value: nu),
        ]
        guard let fd else {
            // The thresholds are the analyzer's own published values (#383)
            // — the caption renders what the analyzer reports, not a copy.
            return .init(
                id: "variability-metrics-frequency-domain",
                title: "Frequency-domain HRV",
                rows: rows,
                captions: [
                    "Not measured — the spectrum needs at least "
                    + "\(FrequencyDomainHRVAnalyzer.minBeats) clean beats "
                    + "spanning \(Int(FrequencyDomainHRVAnalyzer.minWindowSeconds)) s of RR data.",
                ]
            )
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
        _ qtvi: QTVISegmentMedians?
    ) -> VariabilityMetricsSummary.Section {
        // The segment length is the package's published constant — the
        // caption renders the recipe's own value (#383).
        let segMin = Int(QTVarianceComputer.minSegmentSeconds / 60)
        guard let q = qtvi else {
            // Same id, same rows, values em-dash: absence is a state of this
            // section, not a different section. The old
            // "variability-metrics-qtvi-empty" collapsed to a bare caption,
            // which made the populated card shorter than the unmeasured
            // skeleton — the frame moving, which 12a forbids.
            return .init(
                id: "variability-metrics-qtvi",
                title: "QT variability index",
                rows: [
                    .init(id: "vm-qtvi", label: "QTVI", value: "—"),
                    .init(id: "vm-sdqt", label: "SDQT", value: "—", unit: "ms"),
                    .init(id: "vm-qtvi-sdnn", label: "SDNN", value: "—", unit: "ms"),
                    .init(id: "vm-qtvi-meannn", label: "Mean NN", value: "—", unit: "ms"),
                ],
                captions: ["No qualifying \(segMin)-min segments "
                           + "(needs ≥ \(segMin) min of stable, artifact-free rate)."]
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
                "Median over \(q.segmentCount) qualifying \(segMin)-min segment"
                + (q.segmentCount == 1 ? "" : "s")
                + " (stable rate, no excluded beats). No reference range — "
                + "QTVi tracks heart-rate variability (SDNN) more than QT duration.",
            ]
        )
    }

    // Digit counts carried over verbatim from `ECGMetricsView`.
    private static func value(_ v: Double) -> String { String(format: "%.1f", v) }
    private static func power(_ v: Double) -> String { String(format: "%.0f", v) }
    /// Em-dash for a band the analyzer could not measure — the row itself
    /// never goes missing (12a).
    private static func power(_ v: Double?) -> String {
        guard let v else { return "—" }
        return power(v)
    }

    private static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: "%.1f min", minutes) }
        return String(format: "%.1f h", minutes / 60)
    }

    // MARK: - QT Variability Index (X47)

    /// The recipe — 5-min segmentation, artifact/rate-stability admission,
    /// median across qualifying segments — is the paid computation
    /// (`QTVarianceComputer.summarize`, moved behind the boundary in #383).
    /// This translates `MarkingsBeat` to the package's primitive sample with
    /// dumb field copies, nothing more.
    private nonisolated static func qtviSummary(
        beats: [MarkingsBeat],
        sampleRate: Double
    ) -> QTVISegmentMedians? {
        QTVarianceComputer.summarize(
            beats: beats.map {
                QTVIBeatSample(
                    rPeakSampleIndex: $0.rPeakSampleIndex,
                    qtMs: $0.qtMs,
                    precedingRRMs: $0.precedingRRMs)
            },
            sampleRate: sampleRate
        )
    }
}

// MARK: - Compute plumbing (file scope, off the View type)

/// What the detached compute resolves to. `beatCount` rides along on every
/// case so the insufficient-beats publish and the signpost can report it.
private enum Outcome: Sendable {
    case empty(beatCount: Int)
    case computed(report: ECGMetricsReport, qtvi: QTVISegmentMedians?, beatCount: Int)
}

/// The HRV report keyed by what it actually depends on. The recompute Key
/// deliberately includes `markingsContext.beats.count` so the QTVI half
/// refreshes when delineation lands — but the report half depends only on
/// (recording, range), so a markings-only re-key was paying the full beat
/// walk + HRV compute twice per record open (measured: 4.8 s then 3.5 s over
/// the same 100,216 beats on nsrdb 16265). On a hit, only QTVI recomputes.
///
/// Sound under analyst edits: the report reads `normalBeatSampleIndices`,
/// which filters to `wfdb.atr`-sourced annotations — the immutable source
/// set. Authoring lands under a different source, so a same-id republish via
/// `onRecordingMutated` cannot change the report's inputs; a re-import
/// assigns a fresh recording id and misses the cache.
private struct ReportCache {
    let recordingID: UUID
    let rangeStart: Int64?
    let rangeEnd: Int64?
    let report: ECGMetricsReport
    let beatCount: Int

    func matches(recordingID: UUID, range: Range<Int64>?) -> Bool {
        self.recordingID == recordingID
            && rangeStart == range?.lowerBound
            && rangeEnd == range?.upperBound
    }
}
