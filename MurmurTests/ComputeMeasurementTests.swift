//
//  ComputeMeasurementTests.swift
//  MurmurTests
//
//  Policy tests for the compute-instrumentation seam (`ComputeSignpost`).
//
//  The signpost emission itself is not observable in-process — that is what
//  `MurmurUIPerformanceTests`' `XCTOSSignpostMetric` cases are for. What IS
//  testable, and what goes wrong silently, is the decision about which
//  computes are slow enough to persist to the unified log and the wording
//  that lands there. A threshold that drifts, or a summary that drops the
//  work size, turns the field-diagnosis path into noise.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("ComputeMeasurement — slow-compute policy and summary wording")
struct ComputeMeasurementTests {

    @Test("A compute well under the threshold is not slow")
    func fastComputeIsNotSlow() {
        let m = ComputeMeasurement(
            name: "VariabilityLane",
            workSize: 1_200,
            durationSeconds: 0.004
        )
        #expect(m.isSlow == false)
    }

    @Test("A compute exactly at the threshold counts as slow")
    func thresholdComputeIsSlow() {
        let m = ComputeMeasurement(
            name: "VariabilityLane",
            workSize: nil,
            durationSeconds: 0.1
        )
        #expect(m.isSlow == true)
    }

    @Test("A multi-hour-record compute is slow")
    func longRecordComputeIsSlow() {
        // The nsrdb case: ~110k beats through the rolling computer.
        let m = ComputeMeasurement(
            name: "VariabilityLane",
            workSize: 110_000,
            durationSeconds: 2.4
        )
        #expect(m.isSlow == true)
    }

    @Test("Duration is reported in whole milliseconds, rounded")
    func durationRoundsToMilliseconds() {
        let m = ComputeMeasurement(
            name: "VariabilityMetrics",
            workSize: nil,
            durationSeconds: 0.4124
        )
        #expect(m.durationMilliseconds == 412)
    }

    @Test("Summary names the component, the duration, and the work size")
    func summaryCarriesWorkSize() {
        let m = ComputeMeasurement(
            name: "VariabilityLane",
            workSize: 110_000,
            durationSeconds: 2.4
        )
        #expect(m.summary == "VariabilityLane took 2400 ms over 110000 items")
    }

    @Test("Summary omits the work size when the caller did not supply one")
    func summaryOmitsAbsentWorkSize() {
        let m = ComputeMeasurement(
            name: "Morphology",
            workSize: nil,
            durationSeconds: 0.05
        )
        #expect(m.summary == "Morphology took 50 ms")
    }
}
