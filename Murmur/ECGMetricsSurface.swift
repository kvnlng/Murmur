//
//  ECGMetricsSurface.swift
//  Murmur (app target)
//
//  The orchestrator that lets `MurmurMetrics` stay ignorant of
//  `PurchaseStore` and `MurmurCore` stay ignorant of `MurmurMetrics`.
//  This view:
//
//   1. Reads `PurchaseStore.shared.hasStudio` — MurmurCore
//      exposes the entitlement.
//   2. When entitled: renders `ECGMetricsView` with a report. First
//      slice computes the report from a small synthetic RR sequence
//      so the panel renders end-to-end; later slices will plumb the
//      currently-loaded recording's beat annotations through
//      `ECGMetricsExtractor` and pass the result here.
//   3. When not entitled: renders `ECGMetricsLockedView` and hooks
//      its Buy / Restore closures back into `PurchaseStore`.
//
//  Both the App target and the two paid views live in modules that
//  know only about primitive types + their own domain, so this is
//  the only place either framework meets the other.
//

import MurmurCore
import MurmurMetrics
import StoreKit
import SwiftUI

struct ECGMetricsSurface: View {

    /// The paid-view state comes straight off `PurchaseStore` — no
    /// caching, no local mirror. Any StoreKit `Transaction.updates`
    /// tick that flips ownership flips the view too.
    @State private var store = PurchaseStore.shared

    /// Live "which recording is loaded?" from the main window.
    /// `@Observable` propagation re-runs `body` whenever the main
    /// window opens or closes a recording.
    @State private var recordingContext = CurrentRecordingContext.shared

    /// Delineated beats (per-beat QT + RR) for the QT Variability Index (X47).
    @State private var markingsContext = IntervalMarkingsContext.shared

    @State private var isPurchasing = false
    @State private var lastPurchaseError: String?

    var body: some View {
        Group {
            if store.hasStudio {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ECGMetricsView(report: reportForCurrentRecording)
                        qtviSection
                    }
                }
            } else {
                lockedBody
            }
        }
        .padding()
        .frame(minWidth: 340, minHeight: 240, alignment: .top)
    }

    // MARK: - Locked branch

    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ECGMetricsLockedView(
                displayPrice: store.displayPrice(for: .studio),
                onBuy: { Task { await purchase() } },
                onRestore: { Task { await store.restore() } }
            )
            if isPurchasing {
                ProgressView("Contacting App Store…")
                    .controlSize(.small)
            }
            if let msg = lastPurchaseError {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @MainActor
    private func purchase() async {
        isPurchasing = true
        lastPurchaseError = nil
        defer { isPurchasing = false }
        do {
            _ = try await store.purchase(.studio)
        } catch PurchaseStore.PurchaseError.productNotLoaded {
            lastPurchaseError = "Product not yet loaded. Try again in a moment."
        } catch PurchaseStore.PurchaseError.unverifiedTransaction {
            lastPurchaseError = "Purchase couldn't be verified. Please try again."
        } catch {
            lastPurchaseError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Report from the currently-loaded recording

    /// Compute an `ECGMetricsReport` from the current recording's
    /// Normal-beat annotations. Returns `nil` when nothing is loaded
    /// or when the recording has fewer than two Normal beats —
    /// `ECGMetricsView` renders the empty-state row in either case.
    private var reportForCurrentRecording: ECGMetricsReport? {
        guard let recording = recordingContext.recording,
              let sampleRate = recording.channels.first?.sampleRate else {
            return nil
        }
        let beats = recording.normalBeatSampleIndices()
        // Use the time-anchored RR series so the report carries frequency-
        // domain HRV (Lomb-Scargle) in addition to the time-domain metrics.
        guard let series = ECGMetricsExtractor.rrSeries(
            fromBeatSampleIndices: beats,
            sampleRate: sampleRate
        ) else { return nil }
        return ECGMetricsService.compute(from: series)
    }

    // MARK: - QT Variability Index (X47)

    private struct QTVISummary {
        let medianQTVI: Double
        let medianSDQT: Double
        let medianSDNN: Double
        let medianMeanNN: Double
        let segmentCount: Int
    }

    /// QTVI over qualifying 5-min segments of the delineated beats. A segment
    /// qualifies when it is artifact-free (no excluded RR) AND its rate is
    /// stable within Malik 2008's ±2 bpm — the spec's "stable rate, no ectopic
    /// disturbance". Reported as the median across qualifying segments; nil
    /// when none qualify.
    private var qtviSummary: QTVISummary? {
        let beats = markingsContext.beats
        let sampleRate = markingsContext.sampleRate
        guard sampleRate > 0, beats.count > 1 else { return nil }
        let segmentSeconds = QTVarianceComputer.minSegmentSeconds
        let tolerance = QualifyingWindowComputer.defaultStabilityToleranceBpm

        // Single pass: bucket beats into non-overlapping 5-min segments.
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
                  Self.rateStableWithin(rrMs: seg.rr, toleranceBpm: tolerance),
                  let idx = QTVarianceComputer.compute(
                      qtMs: seg.qt, rrMs: seg.rr, segmentSeconds: segmentSeconds
                  ) else { continue }
            indices.append(idx)
        }
        guard !indices.isEmpty else { return nil }
        return QTVISummary(
            medianQTVI: Self.median(indices.map(\.qtvi)),
            medianSDQT: Self.median(indices.map(\.sdqtMs)),
            medianSDNN: Self.median(indices.map(\.sdnnMs)),
            medianMeanNN: Self.median(indices.map(\.meanNNMs)),
            segmentCount: indices.count
        )
    }

    @ViewBuilder
    private var qtviSection: some View {
        if let s = qtviSummary {
            VStack(alignment: .leading, spacing: 3) {
                Text("QT Variability Index").font(.headline)
                Text(String(format: "QTVI %.2f · SDQT %.0f ms · SDNN %.0f ms · mean NN %.0f ms",
                            s.medianQTVI, s.medianSDQT, s.medianSDNN, s.medianMeanNN))
                    .font(.callout.monospacedDigit())
                // The RUO content: components always alongside, and NO reference
                // range — QTVi tracks SDNN more tightly than mean QT, so a
                // normal/abnormal band isn't defensible.
                Text("Median over \(s.segmentCount) qualifying 5-min segment"
                     + (s.segmentCount == 1 ? "" : "s")
                     + " (stable rate, no excluded beats). No reference range — "
                     + "QTVi tracks heart-rate variability (SDNN) more than QT duration.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("qtvi-summary")
        } else if !markingsContext.beats.isEmpty {
            Text("QT Variability Index — no qualifying 5-min segments (needs ≥ 5 min of stable, artifact-free rate).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("qtvi-summary-empty")
        }
    }

    /// Max deviation of instantaneous HR from its mean over `rrMs`, within
    /// `toleranceBpm` — the within-segment analogue of the qualifying-window
    /// rate-stability check, applied to the segment's own beats.
    private static func rateStableWithin(rrMs: [Double], toleranceBpm: Double) -> Bool {
        let hr = rrMs.compactMap { $0 > 0 ? 60_000 / $0 : nil }
        guard !hr.isEmpty else { return false }
        let mean = hr.reduce(0, +) / Double(hr.count)
        let maxDev = hr.map { abs($0 - mean) }.max() ?? 0
        return maxDev <= toleranceBpm
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
