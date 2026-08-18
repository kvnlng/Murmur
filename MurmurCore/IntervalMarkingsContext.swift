//
//  IntervalMarkingsContext.swift
//  MurmurCore
//
//  Shared observable state for the on-beat interval markings feature.
//  The App target's orchestrator writes fiducials + template + interval
//  readouts here after delineating the current recording; BedsideView
//  and its overlays read from here.
//
//  Same MurmurCore-can't-import-MurmurMetrics constraint as
//  `VariabilityLaneContext` — the wire types here are all primitive
//  MurmurCore-visible value types (integer sample indices, Doubles,
//  Bools). The paid framework's `FiducialStore` / `NormalTemplate` /
//  `IntervalReadout` never cross the boundary; the orchestrator maps
//  them to the mirror types defined here.
//
//  Ordering: `beats` is sorted ascending by `rPeakSampleIndex` so
//  callers can do a cheap binary search for the beat under the cursor.
//
//  Design note on the two "identities":
//    `MarkingsBeat.id` is the R-peak sample index — stable per beat
//    within a recording and the natural anchor for interval lookups.
//    `MarkingsFiducial` carries no id; a beat's fiducials are
//    interpreted through their `MarkingsFiducialKind` role.
//

import Foundation
import Observation

/// Which morphological landmark a fiducial marks. Mirrors
/// `MurmurMetrics.FiducialKind` — kept separate so MurmurCore isn't
/// coupled to the paid framework's namespace, and so the enum can
/// evolve independently.
public enum MarkingsFiducialKind: String, Sendable, CaseIterable, Codable {
    case pOnset
    case pOffset
    case qrsOnset
    case rPeak
    case qrsOffset
    case tOnset
    case tOffset
}

/// User-toggleable layer groups for the on-beat fiducial overlay.
/// Per the interval-markings design spec: "Toggleable layers (P /
/// QRS / T / ST) so a QT study and a conduction study each show
/// only what's relevant." R-peak marks are non-toggleable (they
/// anchor every beat's identity).
public enum MarkingsFiducialLayer: String, Sendable, CaseIterable, Codable {
    case p
    case qrs
    case t

    public var displayName: String {
        switch self {
        case .p:   return "P"
        case .qrs: return "QRS"
        case .t:   return "T"
        }
    }
}

/// A single fiducial: which landmark, where in the recording, how
/// confident.
public struct MarkingsFiducial: Sendable, Equatable, Codable, Hashable {
    public let kind: MarkingsFiducialKind
    public let sampleIndex: Int64
    public let confidence: Double

    public init(kind: MarkingsFiducialKind, sampleIndex: Int64, confidence: Double) {
        self.kind = kind
        self.sampleIndex = sampleIndex
        self.confidence = min(1.0, max(0.0, confidence))
    }
}

/// One beat's worth of fiducials + intervals. Every fiducial /
/// interval is optional — the delineator legitimately fails to locate
/// individual landmarks on ectopic / paced / near-VT beats.
public struct MarkingsBeat: Sendable, Equatable, Codable, Identifiable {

    /// R-peak sample position — the anchor + identity.
    public let rPeakSampleIndex: Int64
    public let rPeakConfidence: Double

    // Fiducial positions (nil when the delineator couldn't find one).
    public let pOnset: MarkingsFiducial?
    public let pOffset: MarkingsFiducial?
    public let qrsOnset: MarkingsFiducial?
    public let qrsOffset: MarkingsFiducial?
    public let tOnset: MarkingsFiducial?
    public let tOffset: MarkingsFiducial?

    // Pre-computed intervals in milliseconds (nil when required
    // fiducials are absent).
    public let prMs: Double?
    public let qrsMs: Double?
    public let qtMs: Double?
    public let qtcMs: Double?
    public let precedingRRMs: Double?

    /// JT interval (J-point → T-offset) and its rate-corrected form, in ms —
    /// the REPOLARISATION portion of QT with depolarisation removed (X54).
    /// Threaded as PRIMITIVES from `MurmurMetrics.IntervalReadout` (the free
    /// viewer does no arithmetic on measurements); nil when QT or QRS was
    /// unavailable. Surfaced for wide-QRS beats, where QT is inflated
    /// mechanically by the widened QRS with no repolarisation abnormality.
    public let jtMs: Double?
    public let jtcMs: Double?

    /// True when the delineator's T-offset walk clipped at the
    /// physiological search-window ceiling — true T-offset is ≥ the
    /// reported value. Drives the "open-top / QT ≥" rendering per
    /// project_qtc_trend_uncertainty_wireup_spec.md. Default false;
    /// wired through by the orchestrator when using the wavelet
    /// delineator's per-beat features. Distinct from a low-confidence
    /// beat — a censored beat has a KNOWN LOWER BOUND, not just noise.
    public let tOffsetCensored: Bool

    /// Symmetric half-width of the calibrated 95% CI on this beat's QT
    /// measurement, in ms. Derived from the T-offset risk-score →
    /// calibration bin lookup (the P95 |err| from
    /// `MurmurMetrics.CalibrationTable`). Nil when the orchestrator
    /// hasn't propagated calibrated uncertainty for this beat — the
    /// focus-beat inspector then falls back to the point estimate
    /// without a "±X ms" adornment. Populated during the orchestrator's
    /// v1→v2 delineator swap (separate ticket).
    public let qtCalibratedHalfWidthMs: Double?

    /// UPPER edge of the per-beat T-offset uncertainty bracket — the
    /// signal-domain isoelectric-return sample. Combined with the
    /// tangent-based `tOffset` (LOWER edge / point estimate), the two
    /// endpoints define a visible interval on the waveform at
    /// full-zoom LOD per project_qtc_trend_uncertainty_wireup_spec.md
    /// Phase 6. Nil when the isoelectric detector abstained
    /// (sub-noise T) or timed out (broad-T past the search window);
    /// the render layer suppresses the bracket in that case rather
    /// than substituting a fabricated upper edge.
    public let tOffsetIsoelectricSampleIndex: Int64?

    /// True when this beat's QT measurement is physically impossible
    /// (`MurmurMetrics.QTPlausibilityFilter` — X53), so it was EXCLUDED from
    /// every aggregate: bin medians, the patient-normal template, and the
    /// departure baselines those feed. Surfaced so the focus-beat inspector can
    /// state "excluded — why" rather than render an absurd number. Distinct
    /// from `tOffsetCensored` (a known lower bound) and from a low-confidence
    /// beat (noise): this beat is not physically measurable at all. Default
    /// false; set by the orchestrator that owns the plausibility filter.
    public let isImplausible: Bool

    /// X79 — true when the delineator flagged this beat's T-OFFSET as
    /// unreliable (X58's confidence gate), so its QT/QTc were withheld from
    /// the bin medians, the patient-normal template, and the departure
    /// ranking. Distinct from `isImplausible` (X53 — the whole measurement is
    /// physically impossible): here the R-peak and QRS are fine and the beat
    /// still contributes RR and QRS aggregates; only the repolarisation
    /// interval is untrustworthy — measurable-looking but biased long (false
    /// T-terminations). Set by the orchestrator from the SAME
    /// `TOffsetReliability` call the template builder uses, so the two
    /// consumers cannot drift. Default false (free viewer: no delineation).
    public let isUnreliable: Bool

    /// X112c — the endorsed morphology mode this beat belongs to ("A", "B"),
    /// per the drawer's cluster letters. Set ONLY when the analyst has
    /// endorsed ≥ 2 modes: the inspector then names the comparison baseline
    /// ("vs mode B") and deltas run against THAT mode's template. nil in the
    /// unendorsed / single-mode states, where naming a mode is noise.
    public let nearestModeName: String?

    public init(
        rPeakSampleIndex: Int64,
        rPeakConfidence: Double = 1.0,
        pOnset: MarkingsFiducial? = nil,
        pOffset: MarkingsFiducial? = nil,
        qrsOnset: MarkingsFiducial? = nil,
        qrsOffset: MarkingsFiducial? = nil,
        tOnset: MarkingsFiducial? = nil,
        tOffset: MarkingsFiducial? = nil,
        prMs: Double? = nil,
        qrsMs: Double? = nil,
        qtMs: Double? = nil,
        qtcMs: Double? = nil,
        precedingRRMs: Double? = nil,
        jtMs: Double? = nil,
        jtcMs: Double? = nil,
        tOffsetCensored: Bool = false,
        qtCalibratedHalfWidthMs: Double? = nil,
        tOffsetIsoelectricSampleIndex: Int64? = nil,
        isImplausible: Bool = false,
        isUnreliable: Bool = false,
        nearestModeName: String? = nil
    ) {
        self.rPeakSampleIndex = rPeakSampleIndex
        self.rPeakConfidence = min(1.0, max(0.0, rPeakConfidence))
        self.pOnset = pOnset
        self.pOffset = pOffset
        self.qrsOnset = qrsOnset
        self.qrsOffset = qrsOffset
        self.tOnset = tOnset
        self.tOffset = tOffset
        self.prMs = prMs
        self.qrsMs = qrsMs
        self.qtMs = qtMs
        self.qtcMs = qtcMs
        self.precedingRRMs = precedingRRMs
        self.jtMs = jtMs
        self.jtcMs = jtcMs
        self.tOffsetCensored = tOffsetCensored
        self.qtCalibratedHalfWidthMs = qtCalibratedHalfWidthMs
        self.tOffsetIsoelectricSampleIndex = tOffsetIsoelectricSampleIndex
        self.isImplausible = isImplausible
        self.isUnreliable = isUnreliable
        self.nearestModeName = nearestModeName
    }

    public var id: Int64 { rPeakSampleIndex }

    /// X112c — the same beat, tagged with its endorsed mode. One place
    /// rebuilds the field list so the orchestrator doesn't restate twenty
    /// fields at the call site.
    public func named(mode: String?) -> MarkingsBeat {
        MarkingsBeat(
            rPeakSampleIndex: rPeakSampleIndex,
            rPeakConfidence: rPeakConfidence,
            pOnset: pOnset, pOffset: pOffset,
            qrsOnset: qrsOnset, qrsOffset: qrsOffset,
            tOnset: tOnset, tOffset: tOffset,
            prMs: prMs, qrsMs: qrsMs, qtMs: qtMs, qtcMs: qtcMs,
            precedingRRMs: precedingRRMs,
            jtMs: jtMs, jtcMs: jtcMs,
            tOffsetCensored: tOffsetCensored,
            qtCalibratedHalfWidthMs: qtCalibratedHalfWidthMs,
            tOffsetIsoelectricSampleIndex: tOffsetIsoelectricSampleIndex,
            isImplausible: isImplausible,
            isUnreliable: isUnreliable,
            nearestModeName: mode)
    }

    /// Fetch a specific fiducial by kind, returning a synthesized
    /// R-peak fiducial for `.rPeak`.
    public func fiducial(_ kind: MarkingsFiducialKind) -> MarkingsFiducial? {
        switch kind {
        case .pOnset:    return pOnset
        case .pOffset:   return pOffset
        case .qrsOnset:  return qrsOnset
        case .rPeak:     return MarkingsFiducial(kind: .rPeak, sampleIndex: rPeakSampleIndex, confidence: rPeakConfidence)
        case .qrsOffset: return qrsOffset
        case .tOnset:    return tOnset
        case .tOffset:   return tOffset
        }
    }
}

/// Per-patient normal-template baselines. Mirror of
/// `MurmurMetrics.NormalTemplate` in primitive types.
public struct MarkingsTemplate: Sendable, Equatable, Codable {
    public let sampleCount: Int

    public let medianPRMs: Double?
    public let iqrPRMs: Double?
    public let medianQRSMs: Double?
    public let iqrQRSMs: Double?
    public let medianQTMs: Double?
    public let iqrQTMs: Double?

    /// Formula used to compute the QTc statistics — must be echoed in
    /// the caption / citation the analyst copies.
    public let qtcFormulaName: String

    public let medianQTcMs: Double?
    public let iqrQTcMs: Double?

    /// Reproducibility provenance (C3/C4). `sourceLead` is the lead the
    /// intervals were measured in; `spanStartSample`/`spanEndSample` bound the
    /// stretch of recording the template beats were drawn from. All optional
    /// so older `.mur` sessions and snapshot fixtures decode/compile
    /// unchanged. A methods reviewer requires both — cheaper to carry now than
    /// to retrofit after the preprint.
    public let sourceLead: String?
    public let spanStartSample: Int64?
    public let spanEndSample: Int64?

    /// Beats withheld from these medians for EITHER reason: the QT measurement
    /// was physically impossible (X53), or the delineator flagged its T-offset
    /// as unreliable (X58). Mirror of
    /// `MurmurMetrics.NormalTemplate.excludedBeatCount`; `sampleCount` is the
    /// beats that contributed, this is the beats dropped. 0 when no filter ran.
    ///
    /// This is the TOTAL; a surface naming a cause must use the split below,
    /// since "physically impossible" alone would mislabel the X58 exclusions.
    public let excludedBeatCount: Int

    /// Of `excludedBeatCount`, the beats dropped as physically impossible
    /// (X53). Mirror of `MurmurMetrics.NormalTemplate.excludedImplausibleCount`.
    public let excludedImplausibleCount: Int

    /// Of `excludedBeatCount`, the beats dropped because the delineator flagged
    /// the T-offset as unreliable (X58) — measurable-looking but biased long.
    ///
    /// A beat failing both tests is counted once, under implausible, so
    /// `implausible + unreliable == excludedBeatCount` and a stated breakdown
    /// reconciles against the total (the X48 arithmetic-closes discipline).
    public let excludedUnreliableCount: Int

    /// X112c — the template's adjudication provenance, when an analyst has
    /// endorsed the baseline ("analyst-endorsed · 2 modes · 2026-08-11").
    /// nil = the unadjudicated annotator-normal default; surfaces render
    /// the X112b "unadjudicated — annotator-coded" wording for it.
    public let adjudicationBasis: String?

    public init(
        sampleCount: Int,
        medianPRMs: Double?,
        iqrPRMs: Double?,
        medianQRSMs: Double?,
        iqrQRSMs: Double?,
        medianQTMs: Double?,
        iqrQTMs: Double?,
        qtcFormulaName: String,
        medianQTcMs: Double?,
        iqrQTcMs: Double?,
        sourceLead: String? = nil,
        spanStartSample: Int64? = nil,
        spanEndSample: Int64? = nil,
        excludedBeatCount: Int = 0,
        excludedImplausibleCount: Int = 0,
        excludedUnreliableCount: Int = 0,
        adjudicationBasis: String? = nil
    ) {
        self.sampleCount = sampleCount
        self.medianPRMs = medianPRMs
        self.iqrPRMs = iqrPRMs
        self.medianQRSMs = medianQRSMs
        self.iqrQRSMs = iqrQRSMs
        self.medianQTMs = medianQTMs
        self.iqrQTMs = iqrQTMs
        self.qtcFormulaName = qtcFormulaName
        self.medianQTcMs = medianQTcMs
        self.iqrQTcMs = iqrQTcMs
        self.sourceLead = sourceLead
        self.spanStartSample = spanStartSample
        self.spanEndSample = spanEndSample
        self.excludedBeatCount = excludedBeatCount
        self.excludedImplausibleCount = excludedImplausibleCount
        self.excludedUnreliableCount = excludedUnreliableCount
        self.adjudicationBasis = adjudicationBasis
    }
}

/// X112c — one analyst-endorsed morphology mode's interval baselines. The
/// mode letter is the drawer's cluster letter (the analyst's vocabulary);
/// the template is built from THAT mode's beats through the same X53/X58
/// gated pipeline as the single-template case — exclude-and-count applies
/// per mode.
public struct MarkingsMode: Sendable, Equatable, Codable {
    public let name: String
    public let beatCount: Int
    public let template: MarkingsTemplate

    public init(name: String, beatCount: Int, template: MarkingsTemplate) {
        self.name = name
        self.beatCount = beatCount
        self.template = template
    }
}

/// Zoom-level-of-detail policy for the on-beat markings overlay:
/// low-zoom shows R-ticks + beat-class color only; high-zoom
/// progressively reveals full fiducials per the spec's "never
/// dense-mark every beat" rule.
public enum MarkingsDetailLevel: Sendable, Equatable {
    /// Very zoomed out: R-ticks only.
    case rTicksOnly
    /// Mid zoom: R + QRS boundaries.
    case qrsOnly
    /// High zoom: full P / QRS / T fiducials.
    case fullFiducials

    /// Longest window that still shows full P / QRS / T fiducials. Named
    /// rather than inlined because the Layers chip QUOTES it back to the
    /// analyst ("P and T marks need a window under 3 s") — a literal in the
    /// copy and a literal in the rule drift apart silently, which is the
    /// class of defect X61 was filed for.
    public static let fullFiducialsMaxSeconds: Double = 3

    /// Longest window that still shows QRS boundary marks.
    public static let qrsMaxSeconds: Double = 30

    /// Pick the appropriate detail level from a viewport duration.
    /// Boundaries picked to keep the canvas legible at each scale:
    ///  - < 3 s window: full fiducials (each beat is wide enough).
    ///  - 3–30 s: QRS boundaries.
    ///  - > 30 s: R-ticks only.
    public static func level(forViewportSeconds seconds: Double) -> MarkingsDetailLevel {
        if seconds < fullFiducialsMaxSeconds { return .fullFiducials }
        if seconds < qrsMaxSeconds { return .qrsOnly }
        return .rTicksOnly
    }
}

/// Live state for the on-beat interval markings surface. `@MainActor`
/// because the readers (waveform canvas overlays, calipers) all run
/// on main.
@MainActor
@Observable
public final class IntervalMarkingsContext {

    public static let shared = IntervalMarkingsContext()

    /// Default QTc rate-correction formula when the analyst hasn't chosen one
    /// (P21). Fridericia per ICH E14/S7B — Bazett is no longer warranted in most
    /// applications absent a reason to match historical Bazett data. Named so a
    /// silent drift of the default is a one-line change a test can pin.
    public static let defaultQTcFormula: MarkingsQTcFormula = .fridericia

    /// R-peak-sorted per-beat markings. Empty means no fiducials
    /// available (no entitlement / no recording / no beats / delineator
    /// still running).
    public private(set) var beats: [MarkingsBeat] = []

    /// The recording's sample rate, needed for sample→time conversion
    /// in the overlays. 0 when no recording is loaded.
    public private(set) var sampleRate: Double = 0

    /// Per-patient normal template (interval baselines). `nil` when
    /// no template could be built (too few beats).
    public private(set) var template: MarkingsTemplate?

    /// User-selectable QTc rate-correction formula. Fridericia default
    /// per the interval-markings spec. Persisted to UserDefaults so
    /// the analyst's choice survives restarts.
    public var qtcFormula: MarkingsQTcFormula {
        didSet {
            UserDefaults.standard.set(qtcFormula.rawValue, forKey: Keys.qtcFormula)
        }
    }

    /// Analyst-toggleable overlay layers. Default: every layer on.
    /// Persisted so a QT-study configuration (P off, QRS off, T on)
    /// survives across launches.
    public var enabledLayers: Set<MarkingsFiducialLayer> {
        didSet {
            let raw = enabledLayers.map(\.rawValue).sorted()
            UserDefaults.standard.set(raw, forKey: Keys.enabledLayers)
        }
    }

    /// #227 — whether the focused beat draws its PR / QRS / QT spans against
    /// the patient's own normal.
    ///
    /// Its own flag rather than a fourth `MarkingsFiducialLayer` case, for two
    /// reasons. The layer enum is the letter vocabulary — every case has a
    /// letter and a colour in `FiducialPalette`, and "intervals" has neither.
    /// And its raw values are persisted, so adding a case means a stored set
    /// from an older launch decodes to a different meaning.
    ///
    /// Default ON. The roadmap line this completes has always read "toggleable
    /// layers (P / QRS / T / ST / intervals)", and the point of #227 is that the
    /// span half is what an analyst actually reads — shipping it off by default
    /// would leave the feature exactly as undiscovered as it was.
    public var showIntervalSpans: Bool {
        didSet {
            UserDefaults.standard.set(showIntervalSpans, forKey: Keys.showIntervalSpans)
        }
    }

    // MARK: - T-offset reliability gate (X58 — the analyst's dial)

    /// The derived default exclusion threshold — mirror of
    /// `MurmurMetrics.TOffsetReliability.defaultExclusionScore` (score ≥ 1,
    /// the QTDB+LUDB-swept operating point: T-offset SD 59.3 ms at 12.6%
    /// excluded). Named here so MurmurCore UI can state the default without
    /// importing the paid framework, and so a drift between the two is a
    /// one-line test.
    public nonisolated static let defaultTOffsetExclusionScore = 1

    /// X58: whether beats with an unreliable T-offset are EXCLUDED from the
    /// QT aggregates — bin medians, the patient-normal template, and the
    /// departure baseline. Default true (exclude): the rec-212 failure mode
    /// is false T-terminations biased LONG, and including them silently
    /// re-poisons the template. The analyst can include them; the app ships
    /// the default and never arbitrates the dial.
    public var tOffsetExclusionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(tOffsetExclusionEnabled, forKey: Keys.tOffsetExclusionEnabled)
        }
    }

    /// X58: the risk-score threshold at which a T-offset counts as
    /// unreliable (exclude at score ≥ this). Clamped to 1…6 — 0 would
    /// exclude every beat (the flag-free majority score 0), and the risk
    /// score's practical ceiling is single-digit.
    public var tOffsetExclusionScore: Int {
        didSet {
            let clamped = min(6, max(1, tOffsetExclusionScore))
            if clamped != tOffsetExclusionScore {
                tOffsetExclusionScore = clamped
                return  // didSet re-fires with the clamped value and persists.
            }
            UserDefaults.standard.set(tOffsetExclusionScore, forKey: Keys.tOffsetExclusionScore)
        }
    }

    /// The gate stated for captions/citations — a methods fact a reviewer
    /// needs to reproduce the aggregates. Pure so tests pin the wording.
    public nonisolated static func tOffsetGateCaption(enabled: Bool, score: Int) -> String {
        enabled
            ? "T-offset gate: exclude score ≥ \(score)"
            : "T-offset gate: off (low-confidence beats included)"
    }

    /// What the fiducial overlay is ACTUALLY drawing right now, published
    /// by the focused channel panel (the only place that knows the zoom
    /// tier, which needs canvas geometry). The Layers chip reads it so the
    /// control reports the renderer's behaviour instead of asserting a state
    /// the canvas is not honouring — X61. Defaults to the fully-permissive
    /// policy so a surface that never publishes reads as "nothing
    /// suppressed" rather than inventing a suppression.
    public private(set) var renderPolicy: FiducialRenderPolicy =
        .resolve(tier: .inspect, detailLevel: .fullFiducials)

    /// The beat under the cursor. Transient by construction: the canvas
    /// clears it on mouse-exit, because a hover that outlived the pointer
    /// would be a lie about where the analyst is looking.
    public private(set) var hoveredBeatSampleIndex: Int64?

    /// The beat the analyst CHOSE, by clicking it. Survives the pointer
    /// leaving the trace — which is the whole point (#225).
    ///
    /// Until this existed, the docked beat card was driven by hover alone,
    /// so moving the pointer toward the card in order to read it was exactly
    /// the gesture that closed it. Every measurement on that card was
    /// legible only out of the corner of an eye. This property's absence was
    /// recorded in the doc comment of the thing it should have been beside
    /// — "the one the calipers panel is pinned on, or the one under the
    /// cursor when nothing is pinned" — describing a pin nothing implemented.
    public private(set) var pinnedBeatSampleIndex: Int64?

    /// The beat every surface should be showing: the hover when there is
    /// one, otherwise the pin.
    ///
    /// Hover WINS over the pin, rather than the pin freezing the surfaces.
    /// The alternative reading — pin ?? hover — makes a pinned beat
    /// un-leaveable and kills the compare-against-this-one workflow the pin
    /// is for. This order gives both: hover to preview any beat, leave the
    /// trace and the pinned one comes back.
    public var focusedBeatSampleIndex: Int64? {
        hoveredBeatSampleIndex ?? pinnedBeatSampleIndex
    }

    public init() {
        let raw = UserDefaults.standard.string(forKey: Keys.qtcFormula)
        self.qtcFormula = raw.flatMap(MarkingsQTcFormula.init(rawValue:)) ?? Self.defaultQTcFormula
        let persistedLayers = UserDefaults.standard.stringArray(forKey: Keys.enabledLayers)
        if let persistedLayers, !persistedLayers.isEmpty {
            self.enabledLayers = Set(persistedLayers.compactMap(MarkingsFiducialLayer.init(rawValue:)))
        } else {
            self.enabledLayers = Set(MarkingsFiducialLayer.allCases)
        }
        // #227: absent key reads as ON — see `showIntervalSpans`.
        self.showIntervalSpans =
            UserDefaults.standard.object(forKey: Keys.showIntervalSpans) as? Bool ?? true
        // X58 gate: absent keys read as the shipped defaults (exclude, at the
        // derived operating point).
        self.tOffsetExclusionEnabled = UserDefaults.standard.object(forKey: Keys.tOffsetExclusionEnabled) as? Bool ?? true
        let persistedScore = UserDefaults.standard.object(forKey: Keys.tOffsetExclusionScore) as? Int
            ?? Self.defaultTOffsetExclusionScore
        self.tOffsetExclusionScore = min(6, max(1, persistedScore))
    }

    /// X109 (cardiologist review §2.4): non-nil when automated QT was
    /// WITHHELD — the recording has no conventional QT lead (II/V5), and a
    /// best-effort number on another lead would be physically
    /// misrepresentative. The string is the null-state status every QT
    /// surface renders where the metric normally sits; PR/QRS and the
    /// fiducial overlays below the T wave stay live. Manual calipers are
    /// the sanctioned override.
    public private(set) var qtWithheldReason: String?

    /// X112c — the analyst-endorsed morphology modes, majority first. Empty
    /// in the unendorsed state (the single annotator-normal template). When
    /// ≥ 2 modes exist, `template` is the MAJORITY mode's baseline (the
    /// trend band renders one band, per the settled §8.2 decision) and
    /// per-beat deltas run against each beat's own mode.
    public private(set) var modes: [MarkingsMode] = []

    /// X112c §5 — the adjudication basis for an endorsed baseline, stated
    /// everywhere the unadjudicated qualifier used to sit. Pure so the
    /// wording is pinned by unit tests.
    ///
    ///   1 mode:  "analyst-endorsed · 2026-08-11"
    ///   2 modes: "analyst-endorsed · 2 modes · 2026-08-11 · band: mode A ·
    ///             off-band: mode B 312 beats"
    ///
    /// The off-band clause is §6's honesty requirement: one band renders,
    /// so the caption counts the beats it does NOT cover.
    public nonisolated static func endorsedBasis(
        modes: [(name: String, beatCount: Int)],
        endorsedAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let date = formatter.string(from: endorsedAt)
        guard modes.count > 1 else { return "analyst-endorsed · \(date)" }
        let offBand = modes.dropFirst()
            .map { "mode \($0.name) \($0.beatCount) beats" }
            .joined(separator: " · ")
        return "analyst-endorsed · \(modes.count) modes · \(date)"
            + " · band: mode \(modes[0].name) · off-band: \(offBand)"
    }

    /// The mode template a beat's deltas compare against: its own endorsed
    /// mode when one is named, the published (majority) template otherwise.
    /// Pure lookup, pinned by tests so the inspector and the lane cannot
    /// disagree about which baseline a number is "vs".
    public nonisolated static func deltaTemplate(
        for beat: MarkingsBeat,
        modes: [MarkingsMode],
        fallback: MarkingsTemplate?
    ) -> MarkingsTemplate? {
        guard let name = beat.nearestModeName,
              let mode = modes.first(where: { $0.name == name }) else { return fallback }
        return mode.template
    }

    // MARK: - Writes (orchestrator)

    public func set(
        beats: [MarkingsBeat],
        sampleRate: Double,
        template: MarkingsTemplate?,
        qtWithheldReason: String? = nil,
        modes: [MarkingsMode] = []
    ) {
        // Defensive sort — reader relies on ascending R-peak order.
        self.beats = beats.sorted { $0.rPeakSampleIndex < $1.rPeakSampleIndex }
        self.sampleRate = sampleRate
        self.template = template
        self.qtWithheldReason = qtWithheldReason
        self.modes = modes
    }

    public func clear() {
        beats = []
        sampleRate = 0
        template = nil
        // A pin belongs to the record it was placed in. Carrying it across a
        // record change would leave the card reporting a sample index the
        // new recording knows nothing about.
        hoveredBeatSampleIndex = nil
        pinnedBeatSampleIndex = nil
        qtWithheldReason = nil
        modes = []
    }

    /// Publish what the overlay is drawing for the current viewport. Written
    /// by the focused channel panel only — it is the surface that knows the
    /// zoom tier, which needs canvas geometry the chip cannot see.
    public func set(renderPolicy: FiducialRenderPolicy) {
        guard renderPolicy != self.renderPolicy else { return }
        self.renderPolicy = renderPolicy
    }

    // MARK: - Focus / caliper state

    /// Report the beat under the cursor, or `nil` on mouse-exit.
    public func focus(beatSampleIndex: Int64?) {
        hoveredBeatSampleIndex = beatSampleIndex
    }

    /// Pin the beat the analyst clicked, or unpin it if it is already the
    /// pinned one — clicking the same beat twice is the cheapest possible
    /// "put it away", and the only one discoverable without a legend.
    public func togglePin(beatSampleIndex: Int64) {
        pinnedBeatSampleIndex = pinnedBeatSampleIndex == beatSampleIndex ? nil : beatSampleIndex
    }

    /// Release the pin — Escape, or a record change.
    public func clearPin() {
        pinnedBeatSampleIndex = nil
    }

    /// Land on a beat the analyst asked for by name — a deviation shortcut
    /// (`]` / `[`) or a click on an interval-trend bin.
    ///
    /// PINS rather than hover-focuses. Every caller here is an explicit
    /// request for one specific beat, so nothing about where the pointer
    /// subsequently goes should discard it; routed through `focus` it was
    /// hover state and the next mouse-exit erased the card (#279) — #225
    /// again, for the gesture least ambiguous about intent.
    ///
    /// Clearing the hover is the other half, and it is not tidiness. The
    /// viewport moves to the target, so a stationary pointer is now over a
    /// different part of the signal while `hoveredBeatSampleIndex` still
    /// holds the beat it left. Since focus reads `hovered ?? pinned`, that
    /// stale hover would outrank the beat just asked for and the card would
    /// show the wrong one. The next pointer move recomputes it.
    public func pin(beatSampleIndex sample: Int64) {
        pinnedBeatSampleIndex = sample
        hoveredBeatSampleIndex = nil
    }

    // MARK: - Lookup

    /// Beats whose R-peak falls within the given sample range
    /// (inclusive). Used by the overlay to slice fiducials to the
    /// visible viewport.
    public func beats(inSampleRange range: ClosedRange<Int64>) -> [MarkingsBeat] {
        // Linear filter — good enough at typical N (< 100k beats).
        beats.filter { range.contains($0.rPeakSampleIndex) }
    }

    /// Beat whose R-peak is closest to the given sample index.
    public func nearestBeat(toSampleIndex sample: Int64) -> MarkingsBeat? {
        guard !beats.isEmpty else { return nil }
        var lo = 0
        var hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].rPeakSampleIndex < sample { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return beats.first }
        if lo == beats.count { return beats.last }
        let a = beats[lo - 1]
        let b = beats[lo]
        return abs(sample - a.rPeakSampleIndex) <= abs(sample - b.rPeakSampleIndex) ? a : b
    }

    // MARK: - Deviation-ranked navigation

    /// Beats sorted by descending deviation from the per-patient
    /// normal template. Deviation is `abs(qtcMs - templateMedianQTc)`
    /// when the template has a QTc median, falling back to
    /// `abs(qrsMs - templateMedianQRS)` when it doesn't (some
    /// recordings never produce a stable QT baseline).
    ///
    /// Beats without any usable interval measurement are omitted
    /// rather than sorted to a defaulted position — navigation
    /// shouldn't take the analyst to nothing.
    public var beatsRankedByDeviation: [MarkingsBeat] {
        guard let t = template else { return [] }
        // Score each beat; keep only those with a defined score.
        let scored: [(MarkingsBeat, Double)] = beats.compactMap { beat in
            guard let d = deviationScore(for: beat, template: t) else { return nil }
            return (beat, d)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func deviationScore(for beat: MarkingsBeat, template t: MarkingsTemplate) -> Double? {
        // X79: an unreliable T-offset must not RANK as a departure — on
        // rec 212 it put 457 measurement errors at the top of J/K navigation,
        // "departing" from a template that had excluded those very beats.
        // The QRS fallback stays: the unreliability is the T-offset, and the
        // QRS measurement is untouched by it.
        if !beat.isUnreliable {
            if let qtc = beat.qtcMs, let mQtc = t.medianQTcMs {
                return abs(qtc - mQtc)
            }
        }
        if let qrs = beat.qrsMs, let mQrs = t.medianQRSMs {
            return abs(qrs - mQrs)
        }
        if !beat.isUnreliable {
            if let qt = beat.qtMs, let mQt = t.medianQTMs {
                return abs(qt - mQt)
            }
        }
        return nil
    }

    /// Next beat (by deviation rank) after `fromSampleIndex`. The
    /// deviation rank is descending, so this walks toward more-normal
    /// beats. Returns the first-ranked beat when `fromSampleIndex` is
    /// nil (i.e., "start with the most-deviant").
    public func nextDeviationBeat(after fromSampleIndex: Int64?) -> MarkingsBeat? {
        let ranked = beatsRankedByDeviation
        guard !ranked.isEmpty else { return nil }
        guard let from = fromSampleIndex,
              let currentIdx = ranked.firstIndex(where: { $0.rPeakSampleIndex == from }) else {
            return ranked.first
        }
        let nextIdx = currentIdx + 1
        return nextIdx < ranked.count ? ranked[nextIdx] : nil
    }

    /// Previous beat (by deviation rank) before `fromSampleIndex`.
    /// Walks toward more-deviant beats.
    public func previousDeviationBeat(before fromSampleIndex: Int64?) -> MarkingsBeat? {
        let ranked = beatsRankedByDeviation
        guard !ranked.isEmpty else { return nil }
        guard let from = fromSampleIndex,
              let currentIdx = ranked.firstIndex(where: { $0.rPeakSampleIndex == from }) else {
            return ranked.first
        }
        let prevIdx = currentIdx - 1
        return prevIdx >= 0 ? ranked[prevIdx] : nil
    }

    private enum Keys {
        static let qtcFormula = "murmur.intervalMarkings.qtcFormula"
        static let enabledLayers = "murmur.intervalMarkings.enabledLayers"
        static let showIntervalSpans = "murmur.intervalMarkings.showIntervalSpans"
        static let tOffsetExclusionEnabled = "murmur.intervalMarkings.tOffsetExclusionEnabled"
        static let tOffsetExclusionScore = "murmur.intervalMarkings.tOffsetExclusionScore"
    }
}

/// MurmurCore-visible mirror of `MurmurMetrics.QTcFormula`. Kept
/// separate so MurmurCore stays uncoupled from the paid framework's
/// symbols (settings UI + persistence live here).
public enum MarkingsQTcFormula: String, Sendable, CaseIterable, Codable {
    case bazett
    case fridericia
    case framingham
    case hodges

    public var displayName: String {
        switch self {
        case .bazett: return "Bazett"
        case .fridericia: return "Fridericia"
        case .framingham: return "Framingham"
        case .hodges: return "Hodges"
        }
    }
}
