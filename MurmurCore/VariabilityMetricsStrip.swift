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
    @State private var scopeContext = MetricsScopeContext.shared
    @State private var showingMethod = false

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
            card(summary, id: "variability-metrics-strip", live: true)
        } else if let scope = context.insufficientScope {
            card(Self.insufficientSummary(scope: scope, beatCount: context.insufficientBeatCount),
                 id: "variability-metrics-insufficient", live: false)
        } else if context.isLocked {
            unlockSeam
        } else {
            // #291's placeholder, resized: the same grid as a measured
            // summary with every value an em-dash (`.unmeasured`), because
            // the 12a rule is dimensional — a short card that grows when
            // the orchestrator publishes is the frame moving. The size-
            // parity XCUI test holds the two renderings together.
            card(.unmeasured, id: "variability-metrics-unmeasured", live: false)
        }
    }

    // MARK: - The card (measured and unmeasured — one geometry)

    private func card(_ summary: VariabilityMetricsSummary, id: String, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(summary, live: live)
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
        .accessibilityIdentifier(id)
    }

    private func header(_ summary: VariabilityMetricsSummary, live: Bool) -> some View {
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
            scopePicker
            methodButton(summary)
            Button {
                copy(summary.exportText)
            } label: {
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            // Disabled, not absent, on the unmeasured card — the control
            // occupies its final position with nothing to copy yet, same
            // discipline as the idle toolbar.
            .disabled(!live)
            .help("Copy these metrics as text")
            .accessibilityIdentifier("variability-metrics-copy-button")
            Text("Research use only")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Whole / Window / Hour (X73).
    ///
    /// Writing the selection is all this does. The recompute happens in the
    /// App target's orchestrator, which owns MurmurMetrics and the entitlement
    /// gate; the strip continues to do no arithmetic of its own.
    private var scopePicker: some View {
        Picker("Scope", selection: Binding(
            get: { scopeContext.scope },
            set: { scopeContext.scope = $0 }
        )) {
            ForEach(MetricsScope.allCases, id: \.self) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .frame(maxWidth: 190)
        .accessibilityLabel("Metrics scope")
        .accessibilityIdentifier("metrics-scope-picker")
    }

    /// Method text behind an ⓘ, per the design.
    ///
    /// The captions carry estimator, window length, band edges and excluded
    /// fractions — real disclosures, but four paragraphs of them under the
    /// numbers is how the shipped block ended up mostly footnote. They move
    /// here; they are not trimmed, which the policy on provenance forbids.
    ///
    /// Advisories deliberately do NOT move. "Below Task Force minimum —
    /// interpret with caution" changes how the numbers should be read, and a
    /// caveat that has to be discovered is a caveat that will not be.
    @ViewBuilder
    private func methodButton(_ summary: VariabilityMetricsSummary) -> some View {
        // Only the captions that were actually moved out. A row-less section
        // still shows its captions inline, so repeating them here would make
        // the popover claim credit for text already on screen.
        let captions = summary.sections.filter { !$0.rows.isEmpty }.flatMap(\.captions)
        if !captions.isEmpty {
            Button {
                showingMethod.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help("How these metrics were computed")
            .accessibilityLabel("Method")
            .accessibilityIdentifier("variability-metrics-method-button")
            .popover(isPresented: $showingMethod, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Method")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(captions.enumerated()), id: \.offset) { _, caption in
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(width: 380, alignment: .leading)
                .accessibilityIdentifier("variability-metrics-method-popover")
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: VariabilityMetricsSummary.Section) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if section.title != nil || section.advisory != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let title = section.title {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    // Advisories share the header line rather than adding one
                    // below the rows: a caution must be visible (never behind
                    // the ⓘ), but it must not move the frame either — the
                    // card's height is identical with and without one. The
                    // full text survives truncation via the tooltip. The
                    // `.combine` boundary is what lets the identifier stick —
                    // the section container's identifier overrides plain
                    // child identifiers (same reason `rowView` combines).
                    if let advisory = section.advisory {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .imageScale(.small)
                            Text(advisory)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .help(advisory)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("\(section.id)-advisory")
                    }
                }
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
            // X73: captions move behind the header's ⓘ — but ONLY for a
            // section that has rows. A section with no rows is one whose
            // captions ARE its content ("No qualifying 5-min segments…"),
            // and moving those out leaves a bare title explaining nothing.
            // The three kinds of text here are not interchangeable: method
            // goes behind the ⓘ, advisories stay because they change how the
            // numbers read, and an explanation of ABSENCE stays because
            // without it the absence has no explanation.
            if section.rows.isEmpty {
                ForEach(Array(section.captions.enumerated()), id: \.offset) { _, caption in
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // `.contain` makes the section a real container element, the same
        // boundary the card itself draws. Without it, the identifier is
        // stamped onto every direct child, clobbering the advisory's own.
        .accessibilityElement(children: .contain)
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

    // MARK: - Insufficient scoped window (X95)

    /// The strip's FULL shape survives an unmeasurable scoped range: the same
    /// grid as the unmeasured skeleton, with the X95 explanation riding the
    /// first section's header line as an advisory. Unmounting (pre-X95) took
    /// the scope picker down with it; the header-plus-caption stub that
    /// replaced it collapsed the card instead — the frame moving, which 12a
    /// forbids. Three failure modes, one rule: the grid never changes shape.
    static func insufficientSummary(scope: MetricsScope, beatCount: Int) -> VariabilityMetricsSummary {
        var sections = VariabilityMetricsSummary.unmeasured.sections
        let first = sections[0]
        sections[0] = .init(
            id: first.id,
            title: first.title,
            rows: first.rows,
            captions: first.captions,
            advisory: insufficientCaption(scope: scope, beatCount: beatCount)
        )
        return .init(sections: sections, provenance: "—", exportText: "")
    }

    /// Static and public-in-effect (internal, testable): the caption states
    /// the population honestly — count, requirement, and the two ways out.
    static func insufficientCaption(scope: MetricsScope, beatCount: Int) -> String {
        let beats = beatCount == 1 ? "1 normal beat" : "\(beatCount) normal beats"
        return "\(beats) in this \(scope.provenanceLabel) — at least 3 are needed to measure. "
            + "Widen the window or switch scope."
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
