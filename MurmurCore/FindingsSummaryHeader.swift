//
//  FindingsSummaryHeader.swift
//  Murmur
//
//  Compact horizontal chip row that answers "what's in this recording?" at
//  a glance. Each chip shows category color + a primary metric (count for
//  point-dominant categories, total time for range-dominant ones) and an
//  optional severity indicator when any critical or warning events exist.
//
//  Tapping a chip toggles the category in the shared `FindingFilter` — same
//  semantics as the chip bar in `FindingsPanel`, so the two affordances
//  stay in sync.
//

import SwiftUI

struct FindingsSummaryHeader: View {
    let summary: AnnotationSummary
    @Binding var filter: FindingFilter
    /// Optional disposition tally rendered alongside the total count.
    /// `nil` keeps the chip row backwards-compatible for callers that
    /// don't surface analyst review state.
    var dispositionTally: DispositionStore.Tally? = nil

    var body: some View {
        if summary.rollups.isEmpty {
            emptyView
        } else {
            content
        }
    }

    private var emptyView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            Text("No findings on this recording")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("findings-summary-header")
    }

    private var content: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                totalChip
                Divider().frame(height: 18)
                ForEach(summary.rollups) { rollup in
                    SummaryChip(
                        rollup: rollup,
                        fraction: summary.fractionOfRecording(rollup),
                        sampleRate: summary.sampleRate,
                        isOn: isCategoryActive(rollup.category),
                        action: { toggle(rollup.category) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("findings-summary-header")
    }

    private var totalChip: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                Text("\(summary.totalCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(summary.totalCount == 1 ? "finding" : "findings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let tally = dispositionTally, tally.total > 0 {
                tallyBadge(count: tally.confirmed, color: .green, systemImage: "checkmark")
                tallyBadge(count: tally.dismissed, color: .secondary, systemImage: "xmark")
                if tally.unreviewed > 0 {
                    tallyBadge(count: tally.unreviewed, color: .orange, systemImage: "questionmark")
                }
            }
        }
    }

    private func tallyBadge(count: Int, color: Color, systemImage: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.caption2)
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(color)
    }

    private func isCategoryActive(_ category: String) -> Bool {
        // No category filter set → every chip is implicitly "active."
        filter.categories.isEmpty || filter.categories.contains(category)
    }

    private func toggle(_ category: String) {
        if filter.categories.contains(category) {
            filter.categories.remove(category)
        } else {
            filter.categories.insert(category)
        }
    }
}

// MARK: - Chip

private struct SummaryChip: View {
    let rollup: CategoryRollup
    let fraction: Double?
    let sampleRate: Double
    let isOn: Bool
    let action: () -> Void

    private var color: Color {
        CategoryPalette.swiftUIColor(for: rollup.category)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(rollup.category)
                    .font(.caption.weight(.semibold).monospaced())
                Text(metricLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if rollup.criticalCount > 0 {
                    severityBadge(count: rollup.criticalCount, tint: .red, label: "critical")
                } else if rollup.warningCount > 0 {
                    severityBadge(count: rollup.warningCount, tint: .orange, label: "warning")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isOn ? color.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(isOn ? color.opacity(0.7) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("summary-chip-\(rollup.category)")
        .help(helpString)
    }

    private var metricLabel: String {
        if rollup.isRangeDominant {
            let seconds = Double(rollup.totalRangeSamples) / max(sampleRate, 1)
            return ChipDuration.format(seconds: seconds)
        }
        return "\(rollup.totalCount)"
    }

    private func severityBadge(count: Int, tint: Color, label: String) -> some View {
        Text("\(count)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(tint.opacity(0.15))
            )
            .accessibilityLabel("\(count) \(label)")
    }

    private var helpString: String {
        var parts: [String] = ["\(rollup.totalCount) finding\(rollup.totalCount == 1 ? "" : "s")"]
        if rollup.rangeCount > 0 {
            let seconds = Double(rollup.totalRangeSamples) / max(sampleRate, 1)
            parts.append("\(ChipDuration.format(seconds: seconds)) total")
            if let fraction {
                parts.append("\(Int((fraction * 100).rounded()))% of recording")
            }
        }
        if rollup.criticalCount > 0 { parts.append("\(rollup.criticalCount) critical") }
        if rollup.warningCount > 0 { parts.append("\(rollup.warningCount) warning") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Duration formatting

/// Compact ECG-paper-friendly duration formatter — keeps chip widths small
/// even on multi-hour records. "30s", "12m", "1h12m".
enum ChipDuration {
    static func format(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0s" }
        if seconds < 1 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            let leftoverSec = Int(seconds.truncatingRemainder(dividingBy: 60).rounded())
            return leftoverSec > 0 ? "\(minutes)m\(leftoverSec)s" : "\(minutes)m"
        }
        let hours = Int(seconds / 3600)
        let leftoverMin = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        return leftoverMin > 0 ? "\(hours)h\(leftoverMin)m" : "\(hours)h"
    }
}

#Preview("Mixed findings") {
    let annotations: [Annotation] = [
        Annotation(kind: .point, sampleIndex: 100,  category: "PVC",  severity: .warning,  source: "demo"),
        Annotation(kind: .point, sampleIndex: 200,  category: "PVC",  severity: .critical, source: "demo"),
        Annotation(kind: .point, sampleIndex: 350,  category: "PVC",  severity: .info,     source: "demo"),
        Annotation(kind: .range, sampleIndex: 1_000, endSampleIndex: 1_750, category: "AFib", severity: .warning, source: "demo"),
        Annotation(kind: .range, sampleIndex: 2_000, endSampleIndex: 2_120, category: "VT",   severity: .critical, source: "demo"),
        Annotation(kind: .point, sampleIndex: 2_500, category: "noise", severity: .info,    source: "demo")
    ]
    let summary = AnnotationSummary.build(
        from: annotations,
        recordingDurationSamples: 3_000,
        sampleRate: 250
    )
    return FindingsSummaryHeader(
        summary: summary,
        filter: .constant(FindingFilter())
    )
    .padding()
}
