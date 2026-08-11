//
//  TOffsetGateTests.swift
//  MurmurTests
//
//  X58 UI half — the analyst's T-offset reliability dial and the
//  exclude-AND-COUNT surfaces. The engine's gate (derivation, keep-mask,
//  template exclusion) is pinned in MurmurMetrics; here we pin the app's
//  wording (methods statements the analyst copies or reads verbatim) and
//  the dial's state handling.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("T-offset gate — analyst state (X58)")
@MainActor
struct TOffsetGateStateTests {

    /// Fresh context on cleared keys reads the shipped defaults.
    @Test("Defaults: exclude, at the derived operating point")
    func defaults() {
        clearKeys()
        let context = IntervalMarkingsContext()
        #expect(context.tOffsetExclusionEnabled)
        #expect(context.tOffsetExclusionScore == IntervalMarkingsContext.defaultTOffsetExclusionScore)
        #expect(IntervalMarkingsContext.defaultTOffsetExclusionScore == 1)
        clearKeys()
    }

    @Test("The score clamps to 1…6 — 0 would exclude the flag-free majority")
    func clamping() {
        clearKeys()
        let context = IntervalMarkingsContext()
        context.tOffsetExclusionScore = 0
        #expect(context.tOffsetExclusionScore == 1)
        context.tOffsetExclusionScore = 99
        #expect(context.tOffsetExclusionScore == 6)
        context.tOffsetExclusionScore = 3
        #expect(context.tOffsetExclusionScore == 3)
        clearKeys()
    }

    @Test("The dial persists across contexts (the analyst owns it, not the session)")
    func persistence() {
        clearKeys()
        let first = IntervalMarkingsContext()
        first.tOffsetExclusionEnabled = false
        first.tOffsetExclusionScore = 4
        let second = IntervalMarkingsContext()
        #expect(!second.tOffsetExclusionEnabled)
        #expect(second.tOffsetExclusionScore == 4)
        clearKeys()
    }

    private func clearKeys() {
        UserDefaults.standard.removeObject(forKey: "murmur.intervalMarkings.tOffsetExclusionEnabled")
        UserDefaults.standard.removeObject(forKey: "murmur.intervalMarkings.tOffsetExclusionScore")
    }
}

@Suite("T-offset gate — caption wording (X58)")
struct TOffsetGateCaptionTests {

    @Test("The gate caption states the setting either way")
    func gateCaption() {
        #expect(IntervalMarkingsContext.tOffsetGateCaption(enabled: true, score: 1)
                == "T-offset gate: exclude score ≥ 1")
        #expect(IntervalMarkingsContext.tOffsetGateCaption(enabled: false, score: 1)
                == "T-offset gate: off (low-confidence beats included)")
    }

    @Test("The repro caption counts exclusions per reason and echoes the gate")
    func reproCaptionSplit() {
        let caption = IntervalTrendComputer.reproCaption(
            metric: .qtc,
            binSeconds: 120,
            templateBeatCount: 4772,
            qtcFormulaName: "Fridericia",
            sourceLead: "II",
            templateSelectionBasis: "unadjudicated — annotator-coded normal (N)",
            spanStartSample: nil,
            spanEndSample: nil,
            sampleRate: 250,
            excludedImplausibleCount: 12,
            excludedUnreliableCount: 445,
            tOffsetGateCaption: IntervalMarkingsContext.tOffsetGateCaption(enabled: true, score: 1)
        )
        #expect(caption.contains("(457 excluded: 12 physically impossible · 445 unreliable T-offset)"))
        #expect(caption.contains("T-offset gate: exclude score ≥ 1"))
    }

    @Test("No exclusions means no parenthetical — a zero is not fabricated")
    func reproCaptionNoExclusions() {
        let caption = IntervalTrendComputer.reproCaption(
            metric: .qtc,
            binSeconds: 120,
            templateBeatCount: 30,
            qtcFormulaName: "Fridericia",
            sourceLead: nil,
            templateSelectionBasis: nil,
            spanStartSample: nil,
            spanEndSample: nil,
            sampleRate: 250,
            excludedImplausibleCount: 0,
            excludedUnreliableCount: 0,
            tOffsetGateCaption: nil
        )
        #expect(!caption.contains("excluded"))
        #expect(!caption.contains("T-offset gate"))
    }

    @Test("The gate echo is QTc-only — it touches no other metric's methods")
    func gateEchoQTcOnly() {
        let caption = IntervalTrendComputer.reproCaption(
            metric: .qrs,
            binSeconds: 120,
            templateBeatCount: 30,
            qtcFormulaName: "Fridericia",
            sourceLead: nil,
            templateSelectionBasis: nil,
            spanStartSample: nil,
            spanEndSample: nil,
            sampleRate: 250,
            excludedImplausibleCount: 0,
            excludedUnreliableCount: 0,
            tOffsetGateCaption: IntervalMarkingsContext.tOffsetGateCaption(enabled: true, score: 1)
        )
        #expect(!caption.contains("T-offset gate"))
    }

    @Test("The provenance footer names both exclusion causes")
    func provenanceSplit() {
        let template = MarkingsTemplate(
            sampleCount: 4772,
            medianPRMs: nil, iqrPRMs: nil,
            medianQRSMs: nil, iqrQRSMs: nil,
            medianQTMs: nil, iqrQTMs: nil,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 410, iqrQTcMs: 12,
            sourceLead: "II",
            excludedBeatCount: 457,
            excludedImplausibleCount: 12,
            excludedUnreliableCount: 445
        )
        let text = BeatCalipers.templateProvenanceText(template, sampleRate: 250)
        #expect(text.contains("457 excluded (12 physically impossible · 445 unreliable T-offset)"))
    }

    @Test("A template with no exclusions keeps the footer clean")
    func provenanceNoExclusions() {
        let template = MarkingsTemplate(
            sampleCount: 30,
            medianPRMs: nil, iqrPRMs: nil,
            medianQRSMs: nil, iqrQRSMs: nil,
            medianQTMs: nil, iqrQTMs: nil,
            qtcFormulaName: "Fridericia",
            medianQTcMs: 410, iqrQTcMs: 12
        )
        let text = BeatCalipers.templateProvenanceText(template, sampleRate: 250)
        #expect(!text.contains("excluded"))
    }
}
