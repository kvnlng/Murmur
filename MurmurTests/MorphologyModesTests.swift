//
//  MorphologyModesTests.swift
//  MurmurTests
//
//  X112c (#188) — the free-side contracts of the endorsed-baseline rebuild:
//  the §5 provenance wording, the per-beat delta-baseline lookup, and the
//  inspector's provenance line for an endorsed template.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Endorsed-baseline provenance wording (X112c §5)")
struct EndorsedBasisTests {
    private let date = Date(timeIntervalSince1970: 1_786_492_800)   // 2026-08-12 UTC

    @Test("One endorsed mode: provenance and date, no mode chatter")
    func singleMode() {
        #expect(IntervalMarkingsContext.endorsedBasis(
            modes: [("A", 214)], endorsedAt: date)
            == "analyst-endorsed · 2026-08-12")
    }

    @Test("Two modes: count, date, the rendered band, and the §6 off-band count")
    func dualMode() {
        #expect(IntervalMarkingsContext.endorsedBasis(
            modes: [("A", 1890), ("B", 312)], endorsedAt: date)
            == "analyst-endorsed · 2 modes · 2026-08-12 · band: mode A · off-band: mode B 312 beats")
    }

    @Test("Three modes: every non-band mode is counted, none silently absorbed")
    func tripleMode() {
        let basis = IntervalMarkingsContext.endorsedBasis(
            modes: [("A", 900), ("B", 300), ("C", 45)], endorsedAt: date)
        #expect(basis.contains("3 modes"))
        #expect(basis.contains("band: mode A"))
        #expect(basis.contains("mode B 300 beats"))
        #expect(basis.contains("mode C 45 beats"))
    }
}

@Suite("Per-beat delta baseline (X112c §6)")
struct DeltaTemplateTests {
    private func template(qrs: Double) -> MarkingsTemplate {
        MarkingsTemplate(
            sampleCount: 100, medianPRMs: nil, iqrPRMs: nil,
            medianQRSMs: qrs, iqrQRSMs: nil, medianQTMs: nil, iqrQTMs: nil,
            qtcFormulaName: "Fridericia", medianQTcMs: nil, iqrQTcMs: nil)
    }

    @Test("A mode-tagged beat compares against ITS mode's template")
    func modeBeatUsesOwnTemplate() {
        let modes = [MarkingsMode(name: "A", beatCount: 900, template: template(qrs: 92)),
                     MarkingsMode(name: "B", beatCount: 300, template: template(qrs: 142))]
        let beat = MarkingsBeat(rPeakSampleIndex: 500).named(mode: "B")
        let resolved = IntervalMarkingsContext.deltaTemplate(
            for: beat, modes: modes, fallback: modes[0].template)
        #expect(resolved?.medianQRSMs == 142,
                "A wide-mode beat measured against the narrow baseline would fabricate a delta")
    }

    @Test("An untagged beat (or unknown mode) falls back to the published template")
    func fallback() {
        let modes = [MarkingsMode(name: "A", beatCount: 900, template: template(qrs: 92))]
        let untagged = MarkingsBeat(rPeakSampleIndex: 500)
        #expect(IntervalMarkingsContext.deltaTemplate(
            for: untagged, modes: modes, fallback: modes[0].template)?.medianQRSMs == 92)
        let unknown = MarkingsBeat(rPeakSampleIndex: 500).named(mode: "Z")
        #expect(IntervalMarkingsContext.deltaTemplate(
            for: unknown, modes: modes, fallback: modes[0].template)?.medianQRSMs == 92)
    }

    @Test("named(mode:) tags without disturbing the measurement fields")
    func namedPreservesFields() {
        let beat = MarkingsBeat(
            rPeakSampleIndex: 750, rPeakConfidence: 0.9,
            prMs: 160, qrsMs: 96, qtMs: 400, qtcMs: 420,
            precedingRRMs: 800, tOffsetCensored: true, isUnreliable: true)
        let tagged = beat.named(mode: "B")
        #expect(tagged.nearestModeName == "B")
        #expect(tagged.rPeakSampleIndex == 750)
        #expect(tagged.prMs == 160)
        #expect(tagged.qrsMs == 96)
        #expect(tagged.qtcMs == 420)
        #expect(tagged.tOffsetCensored)
        #expect(tagged.isUnreliable)
        #expect(tagged.named(mode: nil) == beat)
    }
}

@Suite("Endorsed template in the inspector (X112c)")
struct EndorsedProvenanceFooterTests {
    @Test("The provenance line states the endorsement, not the unadjudicated default")
    func endorsedFooter() {
        let template = MarkingsTemplate(
            sampleCount: 312, medianPRMs: nil, iqrPRMs: nil,
            medianQRSMs: nil, iqrQRSMs: nil, medianQTMs: nil, iqrQTMs: nil,
            qtcFormulaName: "Fridericia", medianQTcMs: 410, iqrQTcMs: 12,
            adjudicationBasis: "analyst-endorsed · 2026-08-12")
        let text = BeatCalipers.templateProvenanceText(template, sampleRate: 250)
        #expect(text.contains("Patient normal (analyst-endorsed · 2026-08-12): 312 beats"))
        #expect(!text.contains("unadjudicated"))
    }

    @Test("Without a basis the X112b unadjudicated wording stands, verbatim")
    func unadjudicatedFooter() {
        let template = MarkingsTemplate(
            sampleCount: 312, medianPRMs: nil, iqrPRMs: nil,
            medianQRSMs: nil, iqrQRSMs: nil, medianQTMs: nil, iqrQTMs: nil,
            qtcFormulaName: "Fridericia", medianQTcMs: 410, iqrQTcMs: 12)
        let text = BeatCalipers.templateProvenanceText(template, sampleRate: 250)
        #expect(text.contains("Patient normal (unadjudicated — annotator-coded): 312 beats"))
    }
}

// #357: `MorphologyCacheKey` is the app-target static that builds the
// morphology panel's derived-cache `parametersKey`. It's exercised directly
// (no `@testable import Murmur` — MurmurTests never does that) via the same
// symlink mechanism as `ArrhythmiaScanCacheKey` and `QRSProminenceLeadScorer`:
// the file is a dependency-free standalone type, symlinked from Murmur/ into
// MurmurTests/ so the file-system-synchronized group compiles it into this
// module too.
@Suite("Morphology cache key carries the analysis lead (#357)")
struct MorphologyCacheKeyTests {
    @Test("Two keys differing only by lead name are different — designating invalidates the cache")
    func keyCarriesLead() {
        let a = MorphologyCacheKey.make(analysisLeadName: "MLII")
        let b = MorphologyCacheKey.make(analysisLeadName: "V5")
        #expect(a != b)
    }

    @Test("The same lead name produces identical keys")
    func keyStableAcrossRuns() {
        let a = MorphologyCacheKey.make(analysisLeadName: "MLII")
        let b = MorphologyCacheKey.make(analysisLeadName: "MLII")
        #expect(a == b)
    }
}
