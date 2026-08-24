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

import CryptoKit
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
        // #357 §1.5: every interval is measured on the ANALYSIS LEAD — the
        // analyst's designation, the import-time R-peak score, or
        // first-in-file, each disclosed as such. Nothing here consults a
        // lead's name to choose it.
        guard store.hasStudio,
              let recording = recordingContext.recording,
              let directory = recordingContext.directory,
              let resolution = recording.analysisLead(inBundle: directory) else {
            await MainActor.run { markingsContext.clear() }
            return
        }
        var measuredBeatCount = 0
        let signpost = ComputeSignpost.begin("IntervalMarkings")
        defer { ComputeSignpost.end(signpost, workSize: measuredBeatCount) }
        let beatSampleIndices = recording.normalBeatSampleIndices()
        measuredBeatCount = beatSampleIndices.count
        // The methods change (#357 §1.5): the X108 conventional-lead
        // composite — per-beat median of II and V5 — is RETIRED with the name
        // gate that was the only way to reach it. QT now runs on the analysis
        // lead alone, through the same `MultiLeadQT` machinery (compose of one
        // element is that element), so the gating, censoring and CI contracts
        // are unchanged; on records where II and V5 disagreed the number
        // changes, and the citation names one lead instead of the method.
        guard !beatSampleIndices.isEmpty,
              let leadSamples = recording.samples(of: resolution.channel, inDirectory: directory)
        else {
            await MainActor.run { markingsContext.clear() }
            return
        }
        // The analysis lead's OWN rate — the rate must describe the samples
        // it is applied to, never a neighbouring channel's.
        let sampleRate = resolution.channel.sampleRate
        // Reproducibility provenance (C3/C4): the lead the intervals are
        // measured in, and the sample span the template beats span. This
        // carries the lead's NAME, exactly as recorded — never prose. §1.5's
        // disclosure is appended by the surfaces that state a QT claim
        // (the QTc repro caption, the beat inspector's provenance footer),
        // so a PR caption never inherits a QT-specific sentence.
        let leadName = resolution.channel.name
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

        // #357 §1.5: the "QT: Conventional leads (II, V5) absent." withholding
        // is gone — QT always has a lead now, because the analysis lead is
        // resolved for every record that has a populated ECG channel at all.
        // X109's other gates are untouched: the per-beat plausibility (X53),
        // T-offset reliability (X58) and censoring rules still withhold and
        // count individual measurements.

        // X112c: with endorsements on record, the baseline(s) rebuild from
        // the endorsed clusters' beats — same pipeline, per mode. Falls
        // through to the unadjudicated default when nothing re-attaches
        // (orphaned endorsements — the drawer surfaces those).
        let endorsements = await MainActor.run { morphologyContext.endorsements }

        // Bundle cache. The key carries EVERYTHING the analyst can dial into
        // this pipeline — formula, reliability threshold, a digest of the
        // endorsements, and (#357) the lead the intervals were measured on —
        // because a stale fiducial store is a wrong clinical measurement, not
        // a cosmetic bug. Anything unkeyed is covered by the app-version stamp
        // (the algorithms land via exact-pin bumps).
        let parametersKey = "qtc=\(qtcFormula.rawValue);threshold=\(reliabilityThreshold);"
            + "endorsements=\(Self.endorsementsDigest(endorsements));"
            + "lead=\(resolution.channel.name)"
        if let hit = await Task.detached(priority: .userInitiated, operation: {
            BundleDerivedCache.load(
                MarkingsCachePayload.self, producer: "interval-markings",
                parametersKey: parametersKey, from: directory)
        }).value {
            measuredBeatCount = hit.beats.count
            guard !Task.isCancelled else { return }
            await publish(cached: hit, sampleRate: sampleRate)
            return
        }
        if !endorsements.isEmpty {
            let annotatedBeats = recording.annotatedBeats()
            if !annotatedBeats.isEmpty {
                let input = EndorsedComputeInput(
                    leadSamples: leadSamples,
                    sampleRate: sampleRate,
                    annotatedBeats: annotatedBeats,
                    endorsements: endorsements,
                    qtcFormula: Self.metricsFormula(from: qtcFormula),
                    reliabilityThreshold: reliabilityThreshold,
                    leadName: leadName)
                let handled = await publishEndorsed(
                    input: input, sampleRate: sampleRate,
                    parametersKey: parametersKey, directory: directory)
                if handled { return }
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
            Self.analysisLeadComputed(
                samples: leadSamples,
                sampleRate: sampleRate,
                beatSampleIndices: beatSampleIndices,
                qtcFormula: Self.metricsFormula(from: qtcFormula),
                reliabilityThreshold: reliabilityThreshold)
        }.value

        let coreTemplate = Self.coreTemplate(
            from: computed.template, leadName: leadName,
            spanStart: spanStart, spanEnd: spanEnd, adjudicationBasis: nil)

        Self.storeCache(
            MarkingsCachePayload(
                beats: computed.beats,
                template: computed.beats.isEmpty ? nil : coreTemplate,
                modes: []),
            parametersKey: parametersKey, directory: directory)
        await MainActor.run {
            if computed.beats.isEmpty {
                markingsContext.clear()
            } else {
                markingsContext.set(
                    beats: computed.beats,
                    sampleRate: sampleRate,
                    template: coreTemplate
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
    /// #357 §1.5: the analysis-lead path — ONE lead, delineated by the same
    /// validated pipeline (`WaveletBeatDelineator.delineateWithFeatures`, v2,
    /// the frozen tangent primitive validated end-to-end on ECGRDVQ + QTDB +
    /// LUDB), its per-beat QT gated by the same `MultiLeadQT` machinery the
    /// retired X108 composite used — `compose` of a one-element array is that
    /// element, so the gating, censoring and CI contracts are byte-for-byte
    /// the ones the composite applied to its per-lead inputs. What changed is
    /// which signal is measured: the analysis lead, never a name-chosen one.
    static func analysisLeadComputed(
        samples: [Float],
        sampleRate: Double,
        beatSampleIndices: [Int64],
        qtcFormula: QTcFormula,
        reliabilityThreshold: Int
    ) -> (beats: [MarkingsBeat], template: NormalTemplate) {
        let (primaryStore, primaryFeatures) = WaveletBeatDelineator.delineateWithFeatures(
            samples: samples, sampleRate: sampleRate, rPeaks: beatSampleIndices)
        let perLead = MultiLeadQT.perLeadBeats(
            store: primaryStore, features: primaryFeatures,
            reliabilityThreshold: reliabilityThreshold)
        let composites = primaryStore.beats.indices.map { i in
            MultiLeadQT.compose([perLead[i]])
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
            // Value provenance: the gated measurement when the lead produced
            // one; its raw readout (flagged) when the gates rejected it — the
            // show-but-flag contract, unchanged from the composite path.
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

    /// Shared `MarkingsBeat` assembly — fiducials from the analysis lead's
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

// #357 §1.5: `BeatFiducials.withoutTBoundaries()` is deleted with the
// record-wide abstention it served. Its only trigger was "this record has
// no conventional QT lead", and that condition cannot arise now that QT is
// measured on the analysis lead — every record with a populated ECG channel
// has one. X109's per-beat withholding (X53 plausibility, X58 reliability,
// censoring) is untouched and still runs on every beat below.

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
        /// The analysis lead's samples — the one signal the modes cluster on
        /// AND the one every interval is measured in (#357 §1.5); before, the
        /// clustering lead and the QT leads could be different channels.
        let leadSamples: [Float]
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
            clusterSamples: input.leadSamples, sampleRate: input.sampleRate,
            annotatedBeats: input.annotatedBeats, endorsements: input.endorsements)
        guard !specs.isEmpty else { return nil }

        var built: [BuiltMode] = []
        for spec in specs {
            let result = analysisLeadComputed(
                samples: input.leadSamples,
                sampleRate: input.sampleRate,
                beatSampleIndices: spec.beatSampleIndices,
                qtcFormula: input.qtcFormula,
                reliabilityThreshold: input.reliabilityThreshold)
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


/// What the bundle cache holds for this producer — both publish paths
/// (endorsed multi-mode and unadjudicated default) collapse to this shape;
/// empty `beats` means the delineation legitimately produced nothing and the
/// context should clear.
private struct MarkingsCachePayload: Codable, Sendable {
    let beats: [MarkingsBeat]
    let template: MarkingsTemplate?
    let modes: [MarkingsMode]
    // #357 §1.5: no `qtWithheldReason` — this producer no longer withholds
    // QT for a whole record. A payload cached by an earlier build still
    // decodes (the retired key is simply ignored), and its stale withholding
    // is dropped rather than re-served.
}

extension IntervalMarkingsOrchestrator {
    /// The X112c endorsed path's compute-and-publish half. Returns true when
    /// recompute should stop here: the endorsed pipeline published, or the
    /// task was cancelled mid-compute (falling through to the default path
    /// after cancellation would compute for a record that is gone). False —
    /// nothing re-attached — falls through to the unadjudicated default.
    fileprivate func publishEndorsed(
        input: EndorsedComputeInput, sampleRate: Double,
        parametersKey: String, directory: URL
    ) async -> Bool {
        let published = await Task.detached(priority: .userInitiated) {
            Self.endorsedComputed(input)
        }.value
        guard !Task.isCancelled else { return true }
        guard let published else { return false }
        Self.storeCache(
            MarkingsCachePayload(
                beats: published.beats, template: published.template,
                modes: published.modes),
            parametersKey: parametersKey, directory: directory)
        await MainActor.run {
            markingsContext.set(
                beats: published.beats,
                sampleRate: sampleRate,
                template: published.template,
                modes: published.modes)
        }
        return true
    }

    /// Publish a cache hit — the same empty-means-clear decision both
    /// compute paths make.
    @MainActor fileprivate func publish(cached hit: MarkingsCachePayload, sampleRate: Double) {
        if hit.beats.isEmpty {
            markingsContext.clear()
        } else {
            markingsContext.set(
                beats: hit.beats, sampleRate: sampleRate,
                template: hit.template,
                modes: hit.modes)
        }
    }

    /// Fire-and-forget cache write off the main actor. Losing one (record
    /// swapped mid-write, read-only bundle) costs a recompute, nothing more.
    fileprivate static func storeCache(
        _ payload: MarkingsCachePayload, parametersKey: String, directory: URL
    ) {
        Task.detached(priority: .utility) {
            BundleDerivedCache.store(
                payload, producer: "interval-markings",
                parametersKey: parametersKey, in: directory)
        }
    }

    /// Deterministic digest of the endorsements for the cache key. NOT
    /// `Hashable` — Swift's hasher is seeded per process, so its values
    /// cannot key anything persistent. Canonical form: each endorsement
    /// JSON-encoded with sorted keys, the encodings sorted, then SHA-256.
    static func endorsementsDigest(_ endorsements: [MorphologyEndorsement]) -> String {
        guard !endorsements.isEmpty else { return "none" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let parts = endorsements
            .compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .sorted()
        let canonical = Data(parts.joined(separator: "\n").utf8)
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}
