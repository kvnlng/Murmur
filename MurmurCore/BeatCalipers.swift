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

/// Classification of the focused beat for interval-readout purposes.
/// The docked inspector prints confident PR/QT/QTc only on a beat that
/// has a conducted P wave and a stable morphology — an ectopic (PVC,
/// paced-with-broad-QRS) beat has no meaningful PR, and its QT is
/// unstable on a premature beat, so those intervals render as an
/// explicit undefined state instead of a false confident number.
/// Mockup-review Correction A, ratified 2026-07-05.
public enum BeatCaliperKind: Sendable, Equatable {
    /// No classification available. Every interval row renders as
    /// usual — the default and the behaviour before this feature
    /// landed.
    case unknown
    /// Beat morphology is consistent with sinus — every interval row
    /// renders as usual.
    case normal
    /// Beat is ectopic (PVC / paced / any premature beat with no
    /// conducted P). PR is undefined; QT / QTc are unstable. Render
    /// those three rows as "—" with the low-confidence styling.
    case ectopic
}

struct BeatCalipers: View {

    /// The beat whose numbers to display. Nil renders the SAME card with
    /// every value withheld — #246: the card holds its place and size even
    /// with nothing to show, because a card that pops in and out under the
    /// analyst's eye reads as breakage, and one that holds still is
    /// scannable. (This reverses X71's "no empty state"; see the comment at
    /// the BedsideView call site.)
    let beat: MarkingsBeat?

    /// Sample rate of the source channel — converts `beat.rPeakSampleIndex`
    /// into a wall-clock second label.
    let sampleRate: Double

    /// Per-patient normal template — powers the delta columns. When
    /// nil, deltas are suppressed.
    let template: MarkingsTemplate?

    /// X112c — the endorsed morphology modes (empty unless the analyst
    /// endorsed ≥ 2). Deltas then run against the beat's OWN mode's
    /// template, and the comparison is named ("vs mode B") so a number is
    /// never silently measured against the wrong conduction's baseline.
    var modes: [MarkingsMode] = []

    /// The baseline this beat's deltas actually compare against.
    private var deltaTemplate: MarkingsTemplate? {
        guard let beat else { return template }
        return IntervalMarkingsContext.deltaTemplate(for: beat, modes: modes, fallback: template)
    }

    /// QTc formula in use — echoed into the QTc row's label.
    let qtcFormula: MarkingsQTcFormula

    /// Classification of this beat. `.ectopic` suppresses PR / QT /
    /// QTc rendering; defaults to `.unknown` (unchanged behaviour) for
    /// callers that haven't wired classification yet.
    var kind: BeatCaliperKind = .unknown

    /// X109 (§2.4): non-nil ⇒ automated QT was withheld for this whole
    /// recording (no conventional lead). QT/QTc rows already read "—"
    /// (their values are structurally nil); this states WHY beneath them,
    /// as a status rather than an error.
    var qtWithheldReason: String?

    /// #246: what the status line says when no beat is focused. The caller
    /// distinguishes "hover to focus" from "this record has no beats".
    var placeholderNote: String = "Hover the trace to focus a beat"

    // #246: every slot below renders in EVERY state, so the card's height
    // cannot change under the analyst's eye. What varies per beat — the
    // status, the mode basis, JT applicability — varies inside a reserved
    // line or a row that renders "—", never by mounting and unmounting. The
    // only inputs that move the height are record-stable ones (template
    // arrival, a record-wide QT withholding, mode endorsement), which change
    // once per record, not once per hover.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            qtcFormulaSubtitle
            statusLine
            Divider().opacity(0.4)
            row("PR",  value: prValueForRendering, delta: prDeltaForRendering,
                undefined: suppressRepolarisationIntervals)
            row("QRS", value: beatIsImplausible ? nil : beat?.qrsMs,
                delta: beatIsImplausible ? nil : delta(beat?.qrsMs, vs: deltaTemplate?.medianQRSMs),
                undefined: beatIsImplausible)
            row("QT",  value: qtValueForRendering, delta: qtDeltaForRendering,
                undefined: suppressRepolarisationIntervals,
                censored: qtIsCensored,
                halfWidthMs: qtHalfWidthForRendering)
            row("QTc", value: qtcValueForRendering, delta: qtcDeltaForRendering,
                undefined: suppressRepolarisationIntervals,
                censored: qtIsCensored,
                halfWidthMs: qtHalfWidthForRendering)
            // X54: on a wide-QRS beat, QT is inflated mechanically by the
            // widened depolarisation, so also surface JT (QT − QRS) and JTc —
            // repolarisation with depolarisation removed. Transcription of
            // already-measured intervals, no BBB adjustment applied.
            // #246: the rows now render on every beat — muted "—" when the
            // beat is narrow — so the card cannot grow two rows when the
            // pointer crosses a wide-QRS beat. X54's presentation rule holds:
            // values still appear only where the research frames JT.
            row("JT",  value: showsJT ? beat?.jtMs  : nil, delta: nil, undefined: !showsJT)
            row("JTc", value: showsJT ? beat?.jtcMs : nil, delta: nil, undefined: !showsJT)
            // X112c §6: with ≥ 2 endorsed modes, name the baseline these
            // deltas compare against — the beat's own conduction mode.
            // Reserved (not mounted) per #246: `nearestModeName` is per-beat.
            if modes.count > 1 {
                Text(beat?.nearestModeName.map { "Δ vs mode \($0)" } ?? " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1, reservesSpace: true)
                    .accessibilityIdentifier("beat-calipers-mode-basis")
            }
            // X109 (§2.4): the QT/QTc dashes above are a deliberate
            // withholding, not a delineation failure — say so, plainly.
            // Record-wide, so it renders identically with and without a
            // focused beat and cannot flicker the height.
            if let reason = qtWithheldReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("beat-calipers-qt-withheld")
            }
            templateProvenanceFooter
        }
        .padding(.horizontal, Columns.horizontalPadding)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        // `children: .contain` per X51 §4: an identifier-bearing wrapper
        // without it collapses into ONE element and swallows every
        // identifier inside — measured here as `docked-beat-inspector-empty`
        // existing in the view and XCUI reporting it absent (#246).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("beat-calipers")
    }

    // MARK: - Status line (#246)

    /// The one reserved line where per-beat statements live. An impossible
    /// measurement takes precedence over the ectopic note — it's the
    /// stronger statement about why the numbers are absent — and the
    /// placeholder note takes the slot when no beat is focused. Truncated to
    /// one line with the full text in `.help`, so a long statement changes
    /// what the line says, never how tall the card is.
    private var statusLine: some View {
        Text(statusText ?? " ")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1, reservesSpace: true)
            .truncationMode(.tail)
            .help(statusText ?? "")
            .accessibilityIdentifier(statusIdentifier)
    }

    private var statusText: String? {
        guard let beat else { return placeholderNote }
        if beat.isImplausible {
            return "Excluded — QT physically impossible; withheld from aggregates"
        }
        if kind == .ectopic { return "Ectopic — PR / QT undefined" }
        if beat.isUnreliable {
            return "T-offset unreliable — QT/QTc withheld from aggregates"
        }
        return nil
    }

    /// Same per-state identifiers the three retired subtitle views carried
    /// (X53 / X79 tests find them by name), plus the revived
    /// `docked-beat-inspector-empty` — the identifier X71 deleted with the
    /// placeholder card, back because the placeholder is back.
    private var statusIdentifier: String {
        guard let beat else { return "docked-beat-inspector-empty" }
        if beat.isImplausible { return "beat-calipers-excluded-subtitle" }
        if kind == .ectopic { return "beat-calipers-ectopic-subtitle" }
        if beat.isUnreliable { return "beat-calipers-unreliable-subtitle" }
        return "beat-calipers-status-clear"
    }

    private var beatIsImplausible: Bool { beat?.isImplausible ?? false }

    /// The measurement row's column widths, in ONE place, with the budget
    /// they have to live inside stated next to them.
    ///
    /// #205: these were three literals (40 / 72 / 78 + 10 pt padding = 218 pt)
    /// sized against a 220 pt docked column that X71 later narrowed to 186 —
    /// so the card drew 32 pt past its column, under the review queue, and
    /// clipped the delta cell ("+23.4 m"). Nothing connected the two numbers,
    /// so nothing noticed. `totalWidth` is now derived and pinned against
    /// `BedsideGeometry.dockedColumnWidth` by a test.
    ///
    /// Each width is the measured worst-case string plus a little slack, at
    /// `.caption.monospacedDigit()`: "QRS" 21 pt, "≥ 545.0 ms" 56 pt,
    /// "+400.0 ms" without a CI or "−999 ±999 ms" with one (the delta is
    /// quoted at integer precision whenever a calibrated half-width rides
    /// along — tenths beside ±100 ms are false precision, and they are what
    /// pushed "+183.3 ±100 ms" past this cell and wrapped it, growing the
    /// card mid-hover).
    enum Columns {
        static let label: CGFloat = 22
        static let value: CGFloat = 58
        static let delta: CGFloat = 78
        static let spacing: CGFloat = 4
        static let horizontalPadding: CGFloat = 8

        /// What the card demands horizontally — what a test can compare
        /// against the column it is given.
        static var totalWidth: CGFloat {
            label + value + delta + 2 * spacing + 2 * horizontalPadding
        }
    }

    /// True when the T-offset walk clipped at the search-window ceiling
    /// — QT / QTc are lower bounds ("≥ X ms"), NOT confident point
    /// estimates. Ectopic beats already suppress QT/QTc as undefined so
    /// the censored treatment yields to that.
    private var qtIsCensored: Bool { (beat?.tOffsetCensored ?? false) && kind != .ectopic && !beatIsImplausible }
    private var qtHalfWidthForRendering: Double? {
        kind == .ectopic ? nil : beat?.qtCalibratedHalfWidthMs
    }

    /// C4: the per-patient normal template's provenance — how many beats
    /// constituted it and over what stretch of the recording. On a heavily
    /// ectopic record this is a methods choice a reviewer will interrogate,
    /// so it's surfaced in the inspector (and persisted to `.mur`). Factual,
    /// engineered measurement — no clinical verdict.
    /// #246: always rendered. The provenance text is record-stable — it can
    /// wrap to however many lines it needs, because it never changes on
    /// hover; what it must not do is mount and unmount. Without a template
    /// the slot states that instead (absorbing the header's old "(no
    /// template yet)" suffix).
    @ViewBuilder
    private var templateProvenanceFooter: some View {
        Divider().opacity(0.4)
        Text(template.map { Self.templateProvenanceText($0, sampleRate: sampleRate) }
             ?? "No per-patient normal template yet")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("beat-calipers-template-provenance")
    }

    /// Internal (not private) so the wording — methods provenance the
    /// analyst reads against the template — is pinned by unit tests.
    static func templateProvenanceText(_ t: MarkingsTemplate, sampleRate: Double) -> String {
        // X112 §2: the baseline names its adjudication state — the
        // annotator-coded default until an analyst endorses (X112b), the
        // endorsement provenance once one has (X112c).
        let basis = t.adjudicationBasis ?? "unadjudicated — annotator-coded"
        var text = "Patient normal (\(basis)): \(t.sampleCount) beats"
        // X25: disclose the lead the intervals were measured in. #357 §1.5:
        // that lead is the ANALYSIS lead (designated, scored, or first in
        // file). `sourceLead` is its NAME; the "not a conventional QT lead"
        // clause is appended HERE, at render time, because this card states
        // QT and QTc — convention measures QT where the T offset is clearest
        // (II / V5 commonly), so a departure is reproducibility-relevant and
        // is stated rather than corrected. (Task 7 replaces this line with
        // the full header disclosure.)
        if let lead = t.sourceLead, !lead.isEmpty {
            text += " · lead \(QTLeadDisclosure.citedLeadName(for: lead))"
        }
        if let start = t.spanStartSample, let end = t.spanEndSample, sampleRate > 0 {
            text += " · \(clockString(start, sampleRate: sampleRate))–\(clockString(end, sampleRate: sampleRate))"
        }
        // X58: exclude-and-count, per reason — a bare total (or attributing
        // everything to "physically impossible") would mislabel the
        // reliability exclusions.
        if t.excludedBeatCount > 0 {
            text += " · \(t.excludedBeatCount) excluded (\(t.excludedImplausibleCount) physically impossible · \(t.excludedUnreliableCount) unreliable T-offset)"
        }
        return text
    }

    private static func clockString(_ sample: Int64, sampleRate: Double) -> String {
        let total = max(0, Int((Double(sample) / sampleRate).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // The X53 (excluded) / X79 (unreliable) subtitle prose now lives in
    // `statusText` — one reserved line, same identifiers, full text in .help.

    /// PR / QT / QTc are meaningless on either an ectopic OR a physically
    /// impossible beat, so both collapse the interval to "—".
    private var suppressRepolarisationIntervals: Bool { kind == .ectopic || beatIsImplausible }

    /// The QRS-duration boundary (ms) above which QRS is conventionally "wide"
    /// — the standard ECG definition of QRS prolongation, not a Murmur-chosen
    /// clinical cutoff. JT is surfaced only above it, where the widened
    /// depolarisation is inflating QT enough that reading JT instead matters.
    private static let wideQRSThresholdMs: Double = 120

    /// Show JT / JTc only for a measurable, wide-QRS beat — the case the
    /// research frames JT for. Kept off narrow-QRS beats so the common inspector
    /// stays uncluttered; nothing is hidden that a normal beat needs.
    private var showsJT: Bool {
        !suppressRepolarisationIntervals
            && beat?.jtMs != nil
            && (beat?.qrsMs ?? 0) >= Self.wideQRSThresholdMs
    }

    /// QTc rate-correction formula identifier, rendered once beneath
    /// the header instead of appended to the QTc row's label. Keeps
    /// the row's label column narrow enough for the docked inspector's
    /// fixed width budget (the "(Fridericia)" suffix on the label
    /// used to overflow it and clip the delta column).
    private var qtcFormulaSubtitle: some View {
        Text("QTc: \(qtcFormula.displayName)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("beat-calipers-qtc-formula")
    }

    /// Intervals suppressed on ectopic beats collapse to nil before
    /// hitting `row(...)` so the renderer prints "—" and skips the
    /// delta — matching the existing low-confidence style used by
    /// the T-offset in FiducialOverlay / interval-markings mockup.
    private var prValueForRendering: Double?  { suppressRepolarisationIntervals ? nil : beat?.prMs }
    private var qtValueForRendering: Double?  { suppressRepolarisationIntervals ? nil : beat?.qtMs }
    private var qtcValueForRendering: Double? { suppressRepolarisationIntervals ? nil : beat?.qtcMs }
    private var prDeltaForRendering: Double?  { suppressRepolarisationIntervals ? nil : delta(beat?.prMs, vs: deltaTemplate?.medianPRMs) }
    private var qtDeltaForRendering: Double?  { suppressRepolarisationIntervals ? nil : delta(beat?.qtMs, vs: deltaTemplate?.medianQTMs) }
    private var qtcDeltaForRendering: Double? { suppressRepolarisationIntervals ? nil : delta(beat?.qtcMs, vs: deltaTemplate?.medianQTcMs) }

    // MARK: - Header

    private var header: some View {
        // The "(no template yet)" suffix that used to sit here moved to the
        // always-rendered footer (#246), which states it in full.
        Text(headerLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .accessibilityIdentifier("beat-calipers-anchor")
    }

    private var headerLabel: String {
        guard let beat else { return "Beat —" }
        let seconds = sampleRate > 0
            ? Double(beat.rPeakSampleIndex) / sampleRate
            : 0
        return "Beat \(String(format: "%.2f", seconds)) s · sample \(beat.rPeakSampleIndex)"
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ label: String,
                     value: Double?,
                     delta: Double?,
                     undefined: Bool = false,
                     censored: Bool = false,
                     halfWidthMs: Double? = nil) -> some View {
        HStack(spacing: Columns.spacing) {
            Text(label)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: Columns.label, alignment: .leading)
            // Reuses the same "—" glyph as a missing value but styles
            // the whole row muted + italic when the interval is
            // explicitly undefined for this beat kind (PR on a PVC,
            // etc.). Extends the low-confidence T-offset pattern the
            // fiducial overlay already uses — muted, not caution-hued.
            // Censored (T-offset walk hit the ceiling) renders as
            // "≥ X ms" — a lower bound, not a point estimate —
            // per project_qtc_trend_uncertainty_wireup_spec.md.
            Text(valueDisplay(value: value, undefined: undefined, censored: censored))
                .font(.caption.monospacedDigit())
                .italic(undefined)
                .foregroundStyle(undefined ? Color.secondary : Color.primary)
                .frame(width: Columns.value, alignment: .trailing)
                .accessibilityIdentifier(censored ? "beat-calipers-\(label.lowercased())-censored" : "beat-calipers-\(label.lowercased())")
            deltaLabel(delta, halfWidthMs: undefined ? nil : halfWidthMs)
                .frame(width: Columns.delta, alignment: .trailing)
        }
    }

    /// The value cell string. Undefined (ectopic) wins over censored —
    /// PR on a PVC is undefined outright, not a lower bound.
    private func valueDisplay(value: Double?, undefined: Bool, censored: Bool) -> String {
        if undefined { return "—" }
        guard let v = value else { return "—" }
        if censored { return String(format: "≥ %.1f ms", v) }
        return String(format: "%.1f ms", v)
    }

    @ViewBuilder
    private func deltaLabel(_ delta: Double?, halfWidthMs: Double? = nil) -> some View {
        if let d = delta {
            let sign = d >= 0 ? "+" : "−"
            // Neutral ink for every departure magnitude. App-computed
            // deviation from patient-normal is a measurement, not a
            // verdict — caution hues would encode a clinical call the
            // app is not allowed to make (RUO / mockup-review B-RUO,
            // ratified 2026-07-05). Sign + magnitude carry the signal.
            // When the calibrated per-beat CI half-width is available,
            // the "±X ms" adornment surfaces the measurement uncertainty
            // per project_qtc_trend_uncertainty_wireup_spec.md.
            HStack(spacing: 3) {
                // Unit "ms" is only rendered on the last token in the
                // row — either the delta itself, or its calibrated
                // ±half-width. Avoids "+117.0 ms ± 22 ms" wrapping in
                // the compact panel while keeping units unambiguous.
                if let hw = halfWidthMs {
                    // Integer precision when the CI is shown, twice over:
                    // quoting +183.3 beside ±100 ms is false precision (the
                    // tenths digit asserts a resolution the calibrated
                    // uncertainty has already disclaimed), and the tenths
                    // are what pushed the widest real cell ("+183.3 ±100 ms")
                    // past the 78 pt column — where the ± text wrapped and
                    // the card, whose height the stage canvas follows, grew
                    // under the analyst's eye (#246's invariant).
                    Text("\(sign)\(String(format: "%.0f", abs(d)))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("±\(String(format: "%.0f", hw)) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityIdentifier("beat-calipers-ci-halfwidth")
                } else {
                    Text("\(sign)\(String(format: "%.1f", abs(d))) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
