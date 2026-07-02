//
//  ECGMetricsSurface.swift
//  Murmur (app target)
//
//  The orchestrator that lets `MurmurMetrics` stay ignorant of
//  `PurchaseStore` and `MurmurCore` stay ignorant of `MurmurMetrics`.
//  This view:
//
//   1. Reads `PurchaseStore.shared.owns(.ecgMetrics)` — MurmurCore
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

    @State private var isPurchasing = false
    @State private var lastPurchaseError: String?

    var body: some View {
        Group {
            if store.owns(.ecgMetrics) {
                ECGMetricsView(report: reportForCurrentRecording)
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
                displayPrice: store.products[.ecgMetrics]?.displayPrice,
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
            _ = try await store.purchase(.ecgMetrics)
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
        guard let intervals = ECGMetricsExtractor.rrIntervalsMs(
            fromBeatSampleIndices: beats,
            sampleRate: sampleRate
        ) else { return nil }
        return ECGMetricsService.compute(fromRRIntervalsMs: intervals)
    }
}
