//
//  QTAbstentionTests.swift
//  MurmurTests
//
//  X109 (#185, cardiologist review §2.4) — the unit-testable half of QT
//  abstention: the markings context carries a withheld status with the same
//  lifecycle as the data it explains.
//
//  #357 §1.5 retired the ONE producer this plumbing had — the "conventional
//  leads absent" record-wide withholding — because QT is now measured on the
//  analysis lead, which every record with a populated ECG channel has. The
//  channel itself stays: it is the contract any future record-wide
//  withholding renders through, and the manual-caliper override (§2.4's
//  sanctioned path) still relies on the surfaces it feeds. The fixture's
//  no-conventional-name case moved to AnalysisLeadQTTests, where the record
//  is measured and DISCLOSED instead of abstained on.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("QT withheld-status plumbing (X109)")
struct QTAbstentionTests {
    @Test("The withheld reason lives and dies with the published data")
    @MainActor
    func reasonLifecycle() {
        let context = IntervalMarkingsContext()
        #expect(context.qtWithheldReason == nil)

        let beat = MarkingsBeat(
            rPeakSampleIndex: 100, rPeakConfidence: 1,
            pOnset: nil, pOffset: nil, qrsOnset: nil, qrsOffset: nil,
            tOnset: nil, tOffset: nil,
            prMs: 160, qrsMs: 90, qtMs: nil, qtcMs: nil,
            precedingRRMs: 800, jtMs: nil, jtcMs: nil,
            tOffsetCensored: false, qtCalibratedHalfWidthMs: nil,
            tOffsetIsoelectricSampleIndex: nil,
            isImplausible: false, isUnreliable: false)
        let reason = "QT: withheld for this recording."
        context.set(beats: [beat], sampleRate: 250, template: nil,
                    qtWithheldReason: reason)
        #expect(context.qtWithheldReason == reason)

        // A re-publish WITHOUT the reason (a swap to a measurable recording)
        // must drop the stale status.
        context.set(beats: [beat], sampleRate: 250, template: nil)
        #expect(context.qtWithheldReason == nil)

        context.set(beats: [beat], sampleRate: 250, template: nil,
                    qtWithheldReason: reason)
        context.clear()
        #expect(context.qtWithheldReason == nil)
    }
}
