//
//  BeatCalipers.swift
//  MurmurCore
//
//  Focus-beat calipers readout — a floating panel that surfaces the
//  PR / QRS / QT / QTc measurements of the beat currently under the
//  cursor (or the pinned focus beat), with per-interval deltas vs the
//  per-patient normal template. Per the interval-markings spec:
//
//    "Hover a beat → floating readout (PR, QRS, QT, QTc + deltas);
//     click → pins interval brackets on THAT beat only."
//
//  This file ships the READOUT. The bracket-pinning-on-click gesture
//  needs a click hit-test integration with the Metal canvas that's a
//  small BedsideView-side change; the calipers themselves are the
//  visually load-bearing bit.
//
//  Values render with one decimal of ms so copy-paste is stable; the
//  delta column colors positive/negative deviation from template so a
//  QT prolongation is visually loud without inventing a threshold
//  (per the spec's "no built-in clinical cutoffs" rule).
//

import SwiftUI

struct BeatCalipers: View {

    /// The beat whose numbers to display.
    let beat: MarkingsBeat

    /// Sample rate of the source channel — converts `beat.rPeakSampleIndex`
    /// into a wall-clock second label.
    let sampleRate: Double

    /// Per-patient normal template — powers the delta columns. When
    /// nil, deltas are suppressed.
    let template: MarkingsTemplate?

    /// QTc formula in use — echoed into the QTc row's label.
    let qtcFormula: MarkingsQTcFormula

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Divider().opacity(0.4)
            row("PR",   value: beat.prMs, delta: delta(beat.prMs, vs: template?.medianPRMs))
            row("QRS",  value: beat.qrsMs, delta: delta(beat.qrsMs, vs: template?.medianQRSMs))
            row("QT",   value: beat.qtMs, delta: delta(beat.qtMs, vs: template?.medianQTMs))
            row("QTc",  qtcSuffix: qtcFormula.displayName,
                value: beat.qtcMs, delta: delta(beat.qtcMs, vs: template?.medianQTcMs))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("beat-calipers")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(headerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("beat-calipers-anchor")
            if template == nil {
                Text("(no template yet)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var headerLabel: String {
        let seconds = sampleRate > 0
            ? Double(beat.rPeakSampleIndex) / sampleRate
            : 0
        return "Beat \(String(format: "%.2f", seconds)) s · sample \(beat.rPeakSampleIndex)"
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ label: String,
                     qtcSuffix: String? = nil,
                     value: Double?,
                     delta: Double?) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                if let s = qtcSuffix {
                    Text("(\(s))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 78, alignment: .leading)
            Text(msString(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 62, alignment: .trailing)
            deltaLabel(delta)
                .frame(width: 62, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func deltaLabel(_ delta: Double?) -> some View {
        if let d = delta {
            let sign = d >= 0 ? "+" : "−"
            Text("\(sign)\(String(format: "%.1f", abs(d))) ms")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(deltaColor(d))
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func deltaColor(_ d: Double) -> Color {
        // Neutral for small deltas (< 10 ms); warmer for positive
        // (prolongation), cooler for negative. Never asserts a
        // clinical verdict — just a visual cue.
        let mag = abs(d)
        if mag < 10 { return .secondary }
        if mag < 30 { return .yellow }
        return d > 0 ? .orange : .cyan
    }

    // MARK: - Helpers

    private func msString(_ v: Double?) -> String {
        guard let v = v else { return "—" }
        return String(format: "%.1f ms", v)
    }

    private func delta(_ v: Double?, vs baseline: Double?) -> Double? {
        guard let v = v, let b = baseline else { return nil }
        return v - b
    }
}
