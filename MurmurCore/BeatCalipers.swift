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

    /// Classification of this beat. `.ectopic` suppresses PR / QT /
    /// QTc rendering; defaults to `.unknown` (unchanged behaviour) for
    /// callers that haven't wired classification yet.
    var kind: BeatCaliperKind = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            qtcFormulaSubtitle
            // An impossible measurement takes precedence over the ectopic note
            // — it's the stronger statement about why the numbers are absent.
            if beat.isImplausible {
                excludedSubtitle
            } else if kind == .ectopic {
                ectopicSubtitle
            } else if beat.isUnreliable {
                unreliableSubtitle
            }
            Divider().opacity(0.4)
            row("PR",  value: prValueForRendering, delta: prDeltaForRendering,
                undefined: suppressRepolarisationIntervals)
            row("QRS", value: beat.isImplausible ? nil : beat.qrsMs,
                delta: beat.isImplausible ? nil : delta(beat.qrsMs, vs: template?.medianQRSMs),
                undefined: beat.isImplausible)
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
            if showsJT {
                row("JT",  value: beat.jtMs,  delta: nil)
                row("JTc", value: beat.jtcMs, delta: nil)
            }
            templateProvenanceFooter
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("beat-calipers")
    }

    /// True when the T-offset walk clipped at the search-window ceiling
    /// — QT / QTc are lower bounds ("≥ X ms"), NOT confident point
    /// estimates. Ectopic beats already suppress QT/QTc as undefined so
    /// the censored treatment yields to that.
    private var qtIsCensored: Bool { beat.tOffsetCensored && kind != .ectopic && !beat.isImplausible }
    private var qtHalfWidthForRendering: Double? {
        kind == .ectopic ? nil : beat.qtCalibratedHalfWidthMs
    }

    /// C4: the per-patient normal template's provenance — how many beats
    /// constituted it and over what stretch of the recording. On a heavily
    /// ectopic record this is a methods choice a reviewer will interrogate,
    /// so it's surfaced in the inspector (and persisted to `.mur`). Factual,
    /// engineered measurement — no clinical verdict.
    @ViewBuilder
    private var templateProvenanceFooter: some View {
        if let template {
            Divider().opacity(0.4)
            Text(Self.templateProvenanceText(template, sampleRate: sampleRate))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("beat-calipers-template-provenance")
        }
    }

    /// Internal (not private) so the wording — methods provenance the
    /// analyst reads against the template — is pinned by unit tests.
    static func templateProvenanceText(_ t: MarkingsTemplate, sampleRate: Double) -> String {
        var text = "Patient normal: \(t.sampleCount) beats"
        // X25: disclose the lead the intervals were measured in. Convention is
        // to measure where the T offset is clearest (II / V5 commonly), so
        // which lead was used is reproducibility-relevant.
        if let lead = t.sourceLead, !lead.isEmpty {
            text += " · lead \(lead)"
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

    private var ectopicSubtitle: some View {
        Text("Ectopic — PR / QT undefined")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("beat-calipers-ectopic-subtitle")
    }

    /// X53: this beat's QT measurement is physically impossible, so it was
    /// excluded from the bin medians and the patient-normal template. State the
    /// fact — a factual statement about the MEASUREMENT, never a verdict about
    /// the patient — rather than rendering an absurd interval.
    private var excludedSubtitle: some View {
        Text("Excluded — QT physically impossible; withheld from aggregates")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("beat-calipers-excluded-subtitle")
    }

    /// X79: the delineator flagged this beat's T-offset as unreliable, so its
    /// QT/QTc were withheld from the bin medians, the template, and the
    /// departure ranking. The values still RENDER (with their calibrated CI)
    /// — exclude-and-count shows its work, and the analyst holding the
    /// threshold needs to see what the gate withheld — but the statement of
    /// withholding travels with them.
    private var unreliableSubtitle: some View {
        Text("T-offset unreliable — QT/QTc withheld from aggregates")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("beat-calipers-unreliable-subtitle")
    }

    /// PR / QT / QTc are meaningless on either an ectopic OR a physically
    /// impossible beat, so both collapse the interval to "—".
    private var suppressRepolarisationIntervals: Bool { kind == .ectopic || beat.isImplausible }

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
            && beat.jtMs != nil
            && (beat.qrsMs ?? 0) >= Self.wideQRSThresholdMs
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
    private var prValueForRendering: Double?  { suppressRepolarisationIntervals ? nil : beat.prMs }
    private var qtValueForRendering: Double?  { suppressRepolarisationIntervals ? nil : beat.qtMs }
    private var qtcValueForRendering: Double? { suppressRepolarisationIntervals ? nil : beat.qtcMs }
    private var prDeltaForRendering: Double?  { suppressRepolarisationIntervals ? nil : delta(beat.prMs, vs: template?.medianPRMs) }
    private var qtDeltaForRendering: Double?  { suppressRepolarisationIntervals ? nil : delta(beat.qtMs, vs: template?.medianQTMs) }
    private var qtcDeltaForRendering: Double? { suppressRepolarisationIntervals ? nil : delta(beat.qtcMs, vs: template?.medianQTcMs) }

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
                     value: Double?,
                     delta: Double?,
                     undefined: Bool = false,
                     censored: Bool = false,
                     halfWidthMs: Double? = nil) -> some View {
        HStack(spacing: 4) {
            // Column widths sized to fit the widest content that renders
            // in each column ("QRS"/"QTc" · "≥ 545.0 ms" · "+117.0 ±22 ms")
            // so the panel's overall footprint fits the docked
            // inspector's 220pt hard-width budget in the pinned stage.
            Text(label)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
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
                .frame(width: 72, alignment: .trailing)
                .accessibilityIdentifier(censored ? "beat-calipers-\(label.lowercased())-censored" : "beat-calipers-\(label.lowercased())")
            deltaLabel(delta, halfWidthMs: undefined ? nil : halfWidthMs)
                .frame(width: 78, alignment: .trailing)
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
                    Text("\(sign)\(String(format: "%.1f", abs(d)))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("±\(String(format: "%.0f", hw)) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("beat-calipers-ci-halfwidth")
                } else {
                    Text("\(sign)\(String(format: "%.1f", abs(d))) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary)
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
