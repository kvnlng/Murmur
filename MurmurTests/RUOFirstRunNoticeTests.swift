//
//  RUOFirstRunNoticeTests.swift
//  MurmurTests
//
//  X4b: the first-run RUO disclosure's launch gate and wording. The gate
//  is pure so its whole truth table pins here; the XCUI side only has to
//  prove the sheet actually presents, acknowledges, and stays suppressed
//  under ordinary test launches.
//

import Testing
@testable import MurmurCore

@Suite("RUOFirstRunNotice — launch gate")
struct RUOFirstRunNoticeGateTests {

    @Test("Fresh normal launch presents; acknowledged launch doesn't")
    func normalLaunches() {
        #expect(RUOFirstRunNotice.shouldPresent(
            hasAcknowledged: false, isUITestRun: false, forcedByTest: false))
        #expect(!RUOFirstRunNotice.shouldPresent(
            hasAcknowledged: true, isUITestRun: false, forcedByTest: false))
    }

    @Test("Ordinary UI-test launches are suppressed regardless of stored state")
    func uiTestSuppression() {
        // Every existing XCUI test would otherwise meet a modal it never
        // asked for.
        #expect(!RUOFirstRunNotice.shouldPresent(
            hasAcknowledged: false, isUITestRun: true, forcedByTest: false))
        #expect(!RUOFirstRunNotice.shouldPresent(
            hasAcknowledged: true, isUITestRun: true, forcedByTest: false))
    }

    @Test("The force flag presents even over a stored acknowledgement")
    func forceOverridesStoredState() {
        // XCUI runs share the app container's defaults — an acknowledgement
        // persisted by an earlier run must not make the notice test flaky.
        #expect(RUOFirstRunNotice.shouldPresent(
            hasAcknowledged: true, isUITestRun: true, forcedByTest: true))
        #expect(RUOFirstRunNotice.shouldPresent(
            hasAcknowledged: false, isUITestRun: true, forcedByTest: true))
    }
}

@Suite("RUOFirstRunNotice — wording")
struct RUOFirstRunNoticeWordingTests {

    @Test("The disclosure states the posture facts")
    func statesTheFacts() {
        let body = RUOFirstRunNotice.paragraphs.joined(separator: " ")
        #expect(RUOFirstRunNotice.title == "Research use only")
        #expect(body.contains("not a medical device"))
        #expect(body.contains("diagnosis"))
        #expect(body.contains("research"))
    }

    @Test("Acknowledge is a plain acknowledgement, not consent theater")
    func acknowledgeLabel() {
        #expect(RUOFirstRunNotice.acknowledgeLabel == "I understand")
    }
}
