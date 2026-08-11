//
//  RRCVFlagTests.swift
//  MurmurTests
//
//  X111 (#187, cardiologist review §2.1) — the exposed R–R CV
//  rate-instability flag's wording: cites the mechanism (steady-state
//  formulas failing above the bound), states that values stay shown,
//  and stays silent when there is nothing to say.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("R–R CV instability note (X111)")
struct RRCVFlagTests {
    @Test("The note cites the bound and the mechanism — never a patient verdict")
    func noteWording() {
        let suffix = " — steady-state rate correction is unreliable above "
            + "that bound (exposed threshold; values still shown)."
        #expect(IntervalTrendLane.rrInstabilityNote(flaggedBins: 3, thresholdPercent: 15)
            == "3 bins exceed R–R CV 15%" + suffix)
        #expect(IntervalTrendLane.rrInstabilityNote(flaggedBins: 1, thresholdPercent: 10)
            == "1 bin exceeds R–R CV 10%" + suffix)
    }

    @Test("Silent when the flag is off or nothing exceeded it")
    func noVacuousNote() {
        #expect(IntervalTrendLane.rrInstabilityNote(flaggedBins: 0, thresholdPercent: 15) == nil)
        #expect(IntervalTrendLane.rrInstabilityNote(flaggedBins: 4, thresholdPercent: 0) == nil,
                "Flag off → no note, whatever the CVs were")
    }
}
