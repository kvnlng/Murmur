//
//  VariabilityMetricsStrip.swift
//  MurmurCore
//
//  Whole-record variability summary, rendered inline in the bedside context
//  column directly beneath the variability lane.
//
//  This content used to be a detached `Window` (⌘⇧M, "ECG Metrics"). It moved
//  for three reasons, in order of weight:
//
//   1. **It occluded what it described.** A floating panel over the trace
//      meant reading the summary of a signal required covering the signal.
//   2. **It carried no provenance.** The panel named beat count and span but
//      never the record; changing recordings recomputed it silently under an
//      unchanged title, so a screenshot of it could not be attributed.
//   3. **The concept already lived here.** The variability LANE (time-resolved)
//      sits in this column; the window held the same quantity as whole-record
//      scalars. One idea, two containers, one of them detached.
//
//  macOS HIG, "Designing for macOS": present more content in fewer nested
//  levels and with less need for modality. An auxiliary window is a level.
//
//  MurmurCore does no arithmetic here — the App-target orchestrator publishes
//  finished strings (see `VariabilityMetricsContext`).
//

import SwiftUI

public struct VariabilityMetricsStrip: View {

    @State private var context: VariabilityMetricsContext

    public init() {
        _context = State(initialValue: .shared)
    }

    /// Injectable seam for snapshots and previews — lets a test render a
    /// fixture without touching the process-wide singleton, so parallel runs
    /// stay isolated.
    public init(context: VariabilityMetricsContext) {
        _context = State(initialValue: context)
    }

    public var body: some View {
        if let summary = context.summary {
            populated(summary)
        } else if context.isLocked {
            unlockSeam
        }
    }

    // MARK: - Populated

    private func populated(_ summary: VariabilityMetricsSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(summary)
            ForEach(summary.sections) { section in
                sectionView(section)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("variability-metrics-strip")
    }

    private func header(_ summary: VariabilityMetricsSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Variability Metrics")
                .font(.subheadline.weight(.semibold))
            Text(summary.provenance)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("variability-metrics-provenance")
            Spacer(minLength: 8)
            Button {
                copy(summary.exportText)
            } label: {
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help("Copy these metrics as text")
            .accessibilityIdentifier("variability-metrics-copy-button")
            Text("Research use only")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: VariabilityMetricsSummary.Section) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = section.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Rows flow into as many columns as the width allows. The old
            // window was a fixed narrow column, so eleven metrics became a
            // scroll; inline in a wide window they fit on two or three lines.
            // "Leverage large displays" is the whole reason this moved.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 260), alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(section.rows) { row in
                    rowView(row)
                }
            }
            ForEach(Array(section.captions.enumerated()), id: \.offset) { _, caption in
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let advisory = section.advisory {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                    Text(advisory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("\(section.id)-advisory")
            }
        }
        .accessibilityIdentifier(section.id)
    }

    private func rowView(_ row: VariabilityMetricsSummary.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.value)
                .font(.body.monospacedDigit())
            if let unit = row.unit {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(row.id)
    }

    // MARK: - Locked

    /// Mirrors `FindingsPanel`'s departure-sort seam: name the capability,
    /// name the product, point at the one place it can be bought. No pitch
    /// and no Buy button here — Settings owns the purchase surface, and two
    /// purchase surfaces is the thing that let them drift apart before.
    private var unlockSeam: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("Heart-rate and QT variability for this recording — Murmur Studio")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityIdentifier("variability-metrics-unlock-seam")
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
