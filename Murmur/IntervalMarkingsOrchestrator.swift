//
//  IntervalMarkingsOrchestrator.swift
//  Murmur (app target)
//
//  Invisible glue view that computes fiducials + normal template for
//  the currently-loaded recording and publishes them to
//  `IntervalMarkingsContext.shared` for BedsideView's overlays to
//  render. Same pattern as `VariabilityLaneOrchestrator`.
//
//  Enforces the ECG Metrics entitlement gate on the paid-framework
//  side of the boundary — MurmurCore never sees fiducials unless the
//  IAP is owned, matching "no arithmetic on measurements in
//  MurmurCore" from `project_metrics_module_boundaries.md`.
//
//  Delineation is a fair amount of work per recording (thousands of
//  beats × per-beat window computations). Runs on a background
//  detached Task so we don't block the main actor while the analyst
//  opens a large recording.
//

import Foundation
import MurmurCore
import MurmurMetrics
import SwiftUI

struct IntervalMarkingsOrchestrator: View {

    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var markingsContext = IntervalMarkingsContext.shared
    @State private var store = PurchaseStore.shared
    @State private var morphologyContext = MorphologyContext.shared

    /// Task key changes whenever recompute is warranted.
    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
        let qtcFormula: MarkingsQTcFormula
        // X58: the analyst's T-offset gate governs the template and the
        // per-beat unreliable flags — moving the dial is a recompute.
        let tOffsetExclusionEnabled: Bool
        let tOffsetExclusionScore: Int
        // X112c: endorsing or withdrawing a morphology baseline rebuilds
        // the template from the endorsed beats.
        let endorsements: [MorphologyEndorsement]
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio,
                qtcFormula: markingsContext.qtcFormula,
                tOffsetExclusionEnabled: markingsContext.tOffsetExclusionEnabled,
                tOffsetExclusionScore: markingsContext.tOffsetExclusionScore,
                endorsements: morphologyContext.endorsements
            )) {
                await recompute()
            }
    }

    private func recompute() async {
        #if DEBUG
        // X52 §5: when a UI test has injected a deterministic fiducial store for
        // the QTc-lane wire-up assertion, do NOT run real delineation over it —
        // that would overwrite the known values the test asserts against.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-test-inject-qtc-lane") }) {
            return
        }
        #endif
        // Gate on entitlement + presence of a recording; clear
        // otherwise so a mid-session unmount doesn't leave stale
        // fiducials rendering on the next recording.
        guard store.hasStudio,
              let recording = recordingContext.recording,
              let directory = recordingContext.directory,
              let ecgChannel = recording.primaryECGChannel else {
            await MainActor.run { markingsContext.clear() }
            return
        }
        let beatSampleIndices = recording.normalBeatSampleIndices()
        // X108 (cardiologist review §1.1): QT is measured on the CONVENTIONAL
        // leads when the recording carries any — II, then V5, per-beat median
        // across them when both exist. Before X108 the lead was whatever
        // channel came first in the file (the packet's "II when present" was
        // channel-order luck, not policy). With NO conventional lead the
        // legacy first-channel path still runs — §2.4's principled
        // abstention replaces it in X109.
        let conventionalLeads = recording.conventionalQTLeads(inDirectory: directory)
        let legacySamples = conventionalLeads.isEmpty
            ? recording.primaryECGSamples(inDirectory: directory)
            : nil
        guard !beatSampleIndices.isEmpty,
              !(conventionalLeads.isEmpty && legacySamples == nil) else {
            await MainActor.run { markingsContext.clear() }
            return
        }
        // Leads share the primary channel's sample rate (true for standard
        // multi-lead records — the same assumption `ecgLeadSamples` documents).
        let sampleRate = ecgChannel.sampleRate
        // Reproducibility provenance (C3/C4): the lead(s) the intervals are
        // measured in, and the sample span the template beats span. The
        // multi-lead citation names the method, not just the leads.
        let leadName: String = {
            switch conventionalLeads.count {
            case 0:  return ecgChannel.name
            case 1:  return conventionalLeads[0].channel.name
            default: return "median of "
                + conventionalLeads.map(\.channel.name).joined(separator: ", ")
            }
        }()
        let spanStart = beatSampleIndices.min()
        let spanEnd = beatSampleIndices.max()
        let qtcFormula = await MainActor.run { markingsContext.qtcFormula }
        // X58: the analyst's dial. Off means "include low-confidence beats" —
        // no score reaches Int.max, so nothing is flagged or excluded. The
        // X53 plausibility rules stay on either way: physical impossibility
        // is not the analyst's dial.
        let reliabilityThreshold = await MainActor.run {
            markingsContext.tOffsetExclusionEnabled
                ? markingsContext.tOffsetExclusionScore
                : Int.max
        }

        let qtWithheldReason = conventionalLeads.isEmpty
            ? "QT: Conventional leads (II, V5) absent."
            : nil

        // X112c: with endorsements on record, the baseline(s) rebuild from
        // the endorsed clusters' beats — same pipeline, per mode. Falls
        // through to the unadjudicated default when nothing re-attaches
        // (orphaned endorsements — the drawer surfaces those).
        let endorsements = await MainActor.run { morphologyContext.endorsements }
        if !endorsements.isEmpty {
            let annotatedBeats = recording.annotatedBeats()
            let clusterSamples = conventionalLeads.first?.samples ?? legacySamples
            if let clusterSamples, !annotatedBeats.isEmpty {
                let input = EndorsedComputeInput(
                    conventionalLeadSamples: conventionalLeads.map(\.samples),
                    legacySamples: legacySamples,
                    clusterSamples: clusterSamples,
                    sampleRate: sampleRate,
                    annotatedBeats: annotatedBeats,
                    endorsements: endorsements,
                    qtcFormula: Self.metricsFormula(from: qtcFormula),
                    reliabilityThreshold: reliabilityThreshold,
                    leadName: leadName)
                let published = await Task.detached(priority: .userInitiated) {
                    Self.endorsedComputed(input)
                }.value
                guard !Task.isCancelled else { return }
                if let published {
                    await MainActor.run {
                        markingsContext.set(
                            beats: published.beats,
                            sampleRate: sampleRate,
                            template: published.template,
                            qtWithheldReason: qtWithheldReason,
                            modes: published.modes)
                    }
                    return
                }
            }
        }

        // Delineate + measure + build template off the main actor.
        // Even a multi-hour recording (~100k beats) is a few hundred
        // milliseconds per lead; we don't want to jitter the canvas while
        // it runs.
        let computed = await Task.detached(priority: .userInitiated) { () -> (
            beats: [MarkingsBeat],
            template: NormalTemplate
        ) in
            if conventionalLeads.isEmpty, let samples = legacySamples {
                // X109 (§2.4): no conventional QT lead → the pipeline still
                // delineates for PR/QRS and the overlays, but every
                // T-boundary claim (QT, QTc, JT, JTc, T fiducials, censoring,
                // CI) is WITHHELD — a structural null, not a flagged number.
                return Self.singleLeadComputed(
                    samples: samples, sampleRate: sampleRate,
                    beatSampleIndices: beatSampleIndices,
                    qtcFormula: Self.metricsFormula(from: qtcFormula),
                    reliabilityThreshold: reliabilityThreshold,
                    withholdQT: true)
            }
            return Self.conventionalComputed(
                leadSamples: conventionalLeads.map(\.samples),
                sampleRate: sampleRate,
                beatSampleIndices: beatSampleIndices,
                qtcFormula: Self.metricsFormula(from: qtcFormula),
                reliabilityThreshold: reliabilityThreshold)
        }.value

        let coreTemplate = Self.coreTemplate(
            from: computed.template, leadName: leadName,
            spanStart: spanStart, spanEnd: spanEnd, adjudicationBasis: nil)

        await MainActor.run {
            if computed.beats.isEmpty {
                markingsContext.clear()
            } else {
                markingsContext.set(
                    beats: computed.beats,
                    sampleRate: sampleRate,
                    template: coreTemplate,
                    qtWithheldReason: qtWithheldReason
                )
            }
        }
    }

    // MARK: - Enum bridging

    private static func metricsFormula(from mirror: MarkingsQTcFormula) -> QTcFormula {
        switch mirror {
        case .bazett:     return .bazett
        case .fridericia: return .fridericia
        case .framingham: return .framingham
        case .hodges:     return .hodges
        }
    }

    // MARK: - Fiducial bridging

    private static func coreFiducial(_ f: Fiducial) -> MarkingsFiducial {
        MarkingsFiducial(
            kind: coreKind(f.kind),
            sampleIndex: f.sampleIndex,
            confidence: f.confidence
        )
    }

    private static func coreKind(_ kind: FiducialKind) -> MarkingsFiducialKind {
        switch kind {
        case .pOnset:    return .pOnset
        case .pOffset:   return .pOffset
        case .qrsOnset:  return .qrsOnset
        case .rPeak:     return .rPeak
        case .qrsOffset: return .qrsOffset
        case .tOnset:    return .tOnset
        case .tOffset:   return .tOffset
        }
    }
}

// MARK: - Compute paths

private extension IntervalMarkingsOrchestrator {
    /// The pre-X108 single-lead pipeline, unchanged: runs only when the
    /// recording has NO conventional QT lead (first-channel fallback —
    /// X109 replaces this with §2.4's principled abstention).
    ///
    /// Uses `WaveletBeatDelineator.delineateWithFeatures` (v2, the frozen
    /// tangent primitive validated end-to-end on ECGRDVQ + QTDB + LUDB).
    /// `features` feeds the per-beat uncertainty pipeline: `tOffsetCensored`
    /// drives the "QT ≥ X ms" render; `tOffsetRiskScore` looks up the
    /// calibrated CI half-width.
    static func singleLeadComputed(
        samples: [Float],
        sampleRate: Double,
        beatSampleIndices: [Int64],
        qtcFormula: QTcFormula,
        reliabilityThreshold: Int,
        withholdQT: Bool = false
    ) -> (beats: [MarkingsBeat], template: NormalTemplate) {
        let (store, features) = WaveletBeatDelineator.delineateWithFeatures(
            samples: samples,
            sampleRate: sampleRate,
            rPeaks: beatSampleIndices
        )
        let readouts = IntervalMeasurement.measureAll(store: store)
        // X53: exclude physically impossible beats from the template; X58:
        // also exclude unreliable T-offsets. Same rules, same threshold as
        // the per-beat flags below, so they can never disagree.
        //
        // X109: with QT withheld, the template keeps PR/QRS baselines only —
        // built from readouts whose QT is structurally nil, so no QT/QTc
        // statistic can exist to leak downstream.
        let template = withholdQT
            ? NormalTemplateBuilder.build(
                from: readouts.map { IntervalReadout(
                    rPeakSampleIndex: $0.rPeakSampleIndex,
                    prMs: $0.prMs, qrsMs: $0.qrsMs,
                    qtMs: nil, precedingRRMs: $0.precedingRRMs) },
                qtcFormula: qtcFormula)
            : NormalTemplateBuilder.build(
                from: store,
                qtcFormula: qtcFormula,
                excluding: QTPlausibilityFilter.defaultRules,
                features: features,
                reliabilityThreshold: reliabilityThreshold
            )
        let implausibleMask = QTPlausibilityFilter.mask(for: store)
        let calibration = CalibrationTable.builtInTOffset
        let beats = store.beats.indices.map { i -> MarkingsBeat in
            let bf = store.beats[i]
            let ro = readouts[i]
            let feat = i < features.count ? features[i] : .absent
            if withholdQT {
                // No T-boundary claims of any kind: values, fiducial
                // markers, censoring, CI, and the QT-derived flags all
                // withhold together, so no surface can reconstruct a QT
                // the pipeline refused to state.
                return Self.markingsBeat(
                    bf: bf.withoutTBoundaries(), feat: .absent,
                    values: BeatValues(
                        prMs: ro.prMs, qrsMs: ro.qrsMs,
                        qtMs: nil, qtcMs: nil,
                        precedingRRMs: ro.precedingRRMs,
                        jtMs: nil, jtcMs: nil,
                        tOffsetCensored: false,
                        ciHalfWidthMs: nil,
                        isImplausible: false,
                        isUnreliable: false
                    ))
            }
            return Self.markingsBeat(bf: bf, feat: feat, values: BeatValues(
                prMs: ro.prMs, qrsMs: ro.qrsMs,
                qtMs: ro.qtMs,
                qtcMs: ro.qtcMs(formula: qtcFormula),
                precedingRRMs: ro.precedingRRMs,
                jtMs: ro.jtMs,
                jtcMs: ro.jtcMs(formula: qtcFormula),
                tOffsetCensored: feat.tOffsetCensored,
                ciHalfWidthMs: calibration.bin(forScore: feat.tOffsetRiskScore)?.p95AbsErr,
                isImplausible: i < implausibleMask.count ? implausibleMask[i] : false,
                isUnreliable: !TOffsetReliability.isReliable(feat, threshold: reliabilityThreshold)
            ))
        }
        return (beats, template)
    }

    /// X108: the conventional-lead path — II, then V5, delineated
    /// independently by the same validated pipeline; the per-beat QT (and
    /// everything downstream of it: QTc, JT, JTc, censoring, CI) is the
    /// cross-lead composite from `MultiLeadQT`. Fiducial overlays and the
    /// depolarization intervals (PR/QRS) stay the DISPLAY lead's — index 0,
    /// lead II when present. With one conventional lead the composite
    /// degenerates to that lead's own gated measurement.
    static func conventionalComputed(
        leadSamples: [[Float]],
        sampleRate: Double,
        beatSampleIndices: [Int64],
        qtcFormula: QTcFormula,
        reliabilityThreshold: Int
    ) -> (beats: [MarkingsBeat], template: NormalTemplate) {
        let delineated = leadSamples.map {
            WaveletBeatDelineator.delineateWithFeatures(
                samples: $0, sampleRate: sampleRate, rPeaks: beatSampleIndices)
        }
        let (primaryStore, primaryFeatures) = delineated[0]
        let perLead = delineated.map {
            MultiLeadQT.perLeadBeats(
                store: $0.0, features: $0.1,
                reliabilityThreshold: reliabilityThreshold)
        }
        let composites = primaryStore.beats.indices.map { i in
            MultiLeadQT.compose(perLead.map { $0[i] })
        }
        let template = MultiLeadQT.template(
            primaryStore: primaryStore, composites: composites, qtcFormula: qtcFormula)
        let readouts = IntervalMeasurement.measureAll(store: primaryStore)
        let calibration = CalibrationTable.builtInTOffset
        let beats = primaryStore.beats.indices.map { i -> MarkingsBeat in
            let bf = primaryStore.beats[i]
            let ro = readouts[i]
            let feat = i < primaryFeatures.count ? primaryFeatures[i] : .absent
            let comp = composites[i]
            // Value provenance: the composite when any lead measured; the
            // display lead's raw readout (flagged) when none did — the same
            // show-but-flag contract the single-lead path keeps.
            let qtMs = comp.qtMs ?? ro.qtMs
            let qtcMs: Double?
            let jtMs: Double?
            let jtcMs: Double?
            if let compositeQT = comp.qtMs {
                qtcMs = ro.precedingRRMs.map {
                    QTcFormula.corrected(qtMs: compositeQT, rrMs: $0, formula: qtcFormula)
                }
                jtMs = ro.qrsMs.map { compositeQT - $0 }
                jtcMs = qtcMs.flatMap { qtc in ro.qrsMs.map { qtc - $0 } }
            } else {
                qtcMs = ro.qtcMs(formula: qtcFormula)
                jtMs = ro.jtMs
                jtcMs = ro.jtcMs(formula: qtcFormula)
            }
            return Self.markingsBeat(bf: bf, feat: feat, values: BeatValues(
                prMs: ro.prMs, qrsMs: ro.qrsMs,
                qtMs: qtMs, qtcMs: qtcMs,
                precedingRRMs: ro.precedingRRMs,
                jtMs: jtMs, jtcMs: jtcMs,
                tOffsetCensored: comp.qtMs != nil ? comp.censored : feat.tOffsetCensored,
                ciHalfWidthMs: comp.ciHalfWidthMs
                    ?? calibration.bin(forScore: feat.tOffsetRiskScore)?.p95AbsErr,
                isImplausible: comp.excludedImplausible,
                isUnreliable: comp.excludedUnreliable || comp.censored
            ))
        }
        return (beats, template)
    }

    /// The measured values + flags one beat carries, from whichever
    /// compute path produced them — bundled so the shared assembly below
    /// has a single provenance-bearing argument.
    struct BeatValues {
        let prMs: Double?
        let qrsMs: Double?
        let qtMs: Double?
        let qtcMs: Double?
        let precedingRRMs: Double?
        let jtMs: Double?
        let jtcMs: Double?
        let tOffsetCensored: Bool
        let ciHalfWidthMs: Double?
        let isImplausible: Bool
        let isUnreliable: Bool
    }

    /// Shared `MarkingsBeat` assembly — fiducials from the display lead's
    /// store, values from whichever path computed them.
    static func markingsBeat(
        bf: BeatFiducials,
        feat: BeatConfidenceFeatures,
        values v: BeatValues
    ) -> MarkingsBeat {
        MarkingsBeat(
            rPeakSampleIndex: bf.rPeakSampleIndex,
            rPeakConfidence: bf.rPeakConfidence,
            pOnset: bf.pOnset.map(Self.coreFiducial(_:)),
            pOffset: bf.pOffset.map(Self.coreFiducial(_:)),
            qrsOnset: bf.qrsOnset.map(Self.coreFiducial(_:)),
            qrsOffset: bf.qrsOffset.map(Self.coreFiducial(_:)),
            tOnset: bf.tOnset.map(Self.coreFiducial(_:)),
            tOffset: bf.tOffset.map(Self.coreFiducial(_:)),
            prMs: v.prMs,
            qrsMs: v.qrsMs,
            qtMs: v.qtMs,
            qtcMs: v.qtcMs,
            precedingRRMs: v.precedingRRMs,
            jtMs: v.jtMs,
            jtcMs: v.jtcMs,
            tOffsetCensored: v.tOffsetCensored,
            qtCalibratedHalfWidthMs: v.ciHalfWidthMs,
            tOffsetIsoelectricSampleIndex: feat.tOffsetIsoelectricSampleIndex,
            isImplausible: v.isImplausible,
            isUnreliable: v.isUnreliable
        )
    }
}

private extension BeatFiducials {
    /// X109: the same beat with every T-boundary claim removed — the
    /// abstention path publishes no T fiducials, so the overlay cannot
    /// render boundary markers for a measurement the pipeline withheld.
    func withoutTBoundaries() -> BeatFiducials {
        BeatFiducials(
            rPeakSampleIndex: rPeakSampleIndex,
            rPeakConfidence: rPeakConfidence,
            pOnset: pOnset,
            pOffset: pOffset,
            qrsOnset: qrsOnset,
            qrsOffset: qrsOffset,
            tOnset: nil,
            tOffset: nil
        )
    }
}

// MARK: - X112c endorsed-baseline rebuild

private extension IntervalMarkingsOrchestrator {

    /// One endorsed mode, resolved to its member beats. `name` is the
    /// drawer's cluster letter — the analyst's vocabulary, kept identical so
    /// "mode B" in a readout is the card the analyst endorsed.
    struct ModeSpec {
        let name: String
        let beatSampleIndices: [Int64]
    }

    /// NormalTemplate → MarkingsTemplate mirror (primitive types across the
    /// module boundary), shared by the default and per-mode builds.
    static func coreTemplate(
        from template: NormalTemplate,
        leadName: String,
        spanStart: Int64?,
        spanEnd: Int64?,
        adjudicationBasis: String?
    ) -> MarkingsTemplate? {
        guard template.sampleCount > 0 else { return nil }
        return MarkingsTemplate(
            sampleCount: template.sampleCount,
            medianPRMs: template.medianPRMs,
            iqrPRMs: template.iqrPRMs,
            medianQRSMs: template.medianQRSMs,
            iqrQRSMs: template.iqrQRSMs,
            medianQTMs: template.medianQTMs,
            iqrQTMs: template.iqrQTMs,
            qtcFormulaName: template.qtcFormula.displayName,
            medianQTcMs: template.medianQTcMs,
            iqrQTcMs: template.iqrQTcMs,
            sourceLead: leadName,
            spanStartSample: spanStart,
            spanEndSample: spanEnd,
            excludedBeatCount: template.excludedBeatCount,
            excludedImplausibleCount: template.excludedImplausibleCount,
            excludedUnreliableCount: template.excludedUnreliableCount,
            adjudicationBasis: adjudicationBasis
        )
    }

    /// Re-attach the endorsements to the record's recomputed clusters —
    /// the same deterministic clustering, fold rule, and letters as the
    /// drawer panel, so the rebuild and the cards can never disagree about
    /// which cluster "B" is. Empty when nothing re-attaches (orphans only).
    static func endorsedModeSpecs(
        clusterSamples: [Float],
        sampleRate: Double,
        annotatedBeats: [(sampleIndex: Int64, symbol: String)],
        endorsements: [MorphologyEndorsement]
    ) -> [ModeSpec] {
        let parameters = MorphologyClustering.Parameters()
        let clustering = MorphologyClustering.summarize(
            samples: clusterSamples, sampleRate: sampleRate,
            rPeaks: annotatedBeats.map(\.sampleIndex),
            parameters: parameters)
        let total = clustering.totalBeats
        let majors = clustering.clusters.filter {
            !($0.count < 30 && Double($0.count) < 0.01 * Double(total))
        }
        var endorsedRanks = Set<Int>()
        for endorsement in endorsements {
            var best: (rank: Int, distance: Double)?
            for (rank, cluster) in majors.enumerated() {
                guard cluster.representative.count == endorsement.representative.count
                else { continue }
                let d = MorphologyClustering.distance(
                    endorsement.representative, cluster.representative)
                if best == nil || d < best!.distance { best = (rank, d) }
            }
            if let best, best.distance <= parameters.distanceThreshold {
                endorsedRanks.insert(best.rank)
            }
        }
        return endorsedRanks.sorted().map { rank in
            ModeSpec(
                name: String(UnicodeScalar(UInt8(65 + min(rank, 25)))),
                beatSampleIndices: majors[rank].memberBeatIndices
                    .map { annotatedBeats[$0].sampleIndex }
                    .sorted())
        }
    }

    /// The endorsed rebuild: each endorsed mode's beats run through the SAME
    /// pipeline as the single-template case (X53/X58 exclude-and-count per
    /// mode), majority mode first. The published template is the majority
    /// mode's, carrying the §5 endorsement provenance; with ≥ 2 modes every
    /// beat is tagged with its mode so the inspector names its baseline.
    /// nil when no endorsement re-attaches — caller falls back to the
    /// unadjudicated default.
    /// Inputs for the endorsed rebuild, bundled (SwiftLint parameter budget —
    /// same medicine as `BeatValues`).
    struct EndorsedComputeInput: Sendable {
        let conventionalLeadSamples: [[Float]]
        let legacySamples: [Float]?
        let clusterSamples: [Float]
        let sampleRate: Double
        let annotatedBeats: [(sampleIndex: Int64, symbol: String)]
        let endorsements: [MorphologyEndorsement]
        let qtcFormula: QTcFormula
        let reliabilityThreshold: Int
        let leadName: String
    }

    /// What the endorsed rebuild publishes.
    struct EndorsedBaseline {
        let beats: [MarkingsBeat]
        let template: MarkingsTemplate?
        let modes: [MarkingsMode]
    }

    /// One mode's pipeline output, before the majority sort.
    private struct BuiltMode {
        let name: String
        let beats: [MarkingsBeat]
        let template: NormalTemplate
        let spanStart: Int64?
        let spanEnd: Int64?
    }

    static func endorsedComputed(_ input: EndorsedComputeInput) -> EndorsedBaseline? {
        let specs = endorsedModeSpecs(
            clusterSamples: input.clusterSamples, sampleRate: input.sampleRate,
            annotatedBeats: input.annotatedBeats, endorsements: input.endorsements)
        guard !specs.isEmpty else { return nil }

        var built: [BuiltMode] = []
        for spec in specs {
            let result: (beats: [MarkingsBeat], template: NormalTemplate)
            if input.conventionalLeadSamples.isEmpty {
                guard let samples = input.legacySamples else { continue }
                // X109: no conventional lead → T-boundary claims withheld,
                // endorsed or not.
                result = singleLeadComputed(
                    samples: samples, sampleRate: input.sampleRate,
                    beatSampleIndices: spec.beatSampleIndices,
                    qtcFormula: input.qtcFormula,
                    reliabilityThreshold: input.reliabilityThreshold,
                    withholdQT: true)
            } else {
                result = conventionalComputed(
                    leadSamples: input.conventionalLeadSamples,
                    sampleRate: input.sampleRate,
                    beatSampleIndices: spec.beatSampleIndices,
                    qtcFormula: input.qtcFormula,
                    reliabilityThreshold: input.reliabilityThreshold)
            }
            built.append(BuiltMode(
                name: spec.name, beats: result.beats, template: result.template,
                spanStart: spec.beatSampleIndices.min(),
                spanEnd: spec.beatSampleIndices.max()))
        }
        guard !built.isEmpty else { return nil }
        // Majority first (§8.2: one band renders — the majority mode's);
        // letter order breaks ties so the outcome is deterministic.
        built.sort { ($0.beats.count, $1.name) > ($1.beats.count, $0.name) }

        // The provenance date is the LATEST endorsement — the moment the
        // current baseline configuration came to exist.
        let endorsedAt = input.endorsements.map(\.endorsedAt).max() ?? .distantPast
        let basis = IntervalMarkingsContext.endorsedBasis(
            modes: built.map { ($0.name, $0.beats.count) },
            endorsedAt: endorsedAt)

        let leadName = input.leadName
        let modes: [MarkingsMode] = built.compactMap { mode in
            coreTemplate(from: mode.template, leadName: leadName,
                         spanStart: mode.spanStart, spanEnd: mode.spanEnd,
                         adjudicationBasis: nil)
                .map { MarkingsMode(name: mode.name, beatCount: mode.beats.count, template: $0) }
        }
        let published = coreTemplate(
            from: built[0].template, leadName: leadName,
            spanStart: built[0].spanStart, spanEnd: built[0].spanEnd,
            adjudicationBasis: basis)
        let tagged = built.count > 1
            ? built.flatMap { mode in mode.beats.map { $0.named(mode: mode.name) } }
            : built.flatMap(\.beats)
        return EndorsedBaseline(beats: tagged, template: published, modes: modes)
    }
}
