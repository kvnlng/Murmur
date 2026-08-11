//
//  ConventionalQTLeadTests.swift
//  MurmurTests
//
//  X108 (Murmur-Extensions#27) — conventional-lead SELECTION. Before X108
//  the "II (or V5) when present" preference existed only in prose: QT was
//  measured on whatever channel came first in the file. These tests pin
//  the policy that replaced the luck: II before V5, Mason–Likar prefixes
//  and case/whitespace normalized, as-recorded names preserved, empty
//  channels ignored, and non-conventional leads never selected.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Conventional QT lead selection (X108)")
struct ConventionalQTLeadTests {
    private func channel(_ name: String, sampleCount: Int64 = 1000) -> Channel {
        Channel(
            id: UUID(), name: name, unit: "mV", sampleRate: 250,
            startTimeUnixMS: 0, sampleCount: sampleCount,
            storageFileName: "\(name).bin", pyramid: [])
    }

    private func recording(_ channels: [Channel]) -> Recording {
        Recording(
            version: 1, id: UUID(), device: "test", createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "test.dat", channels: channels)
    }

    @Test("II comes before V5 regardless of file order")
    func orderingIsPolicyNotFileOrder() {
        let r = recording([channel("V5"), channel("V1"), channel("MLII")])
        #expect(r.conventionalQTChannels.map(\.name) == ["MLII", "V5"],
                "File order put V5 first; the §1.1 preference puts II first anyway")
    }

    @Test("Mason–Likar prefix, case, and whitespace all normalize; as-recorded names survive")
    func nameNormalization() {
        let r = recording([channel(" ii"), channel("MLV5")])
        #expect(r.conventionalQTChannels.map(\.name) == [" ii", "MLV5"])
    }

    @Test("Non-conventional leads are never selected — even when they are all there is")
    func nonConventionalNeverSelected() {
        let r = recording([channel("V1"), channel("aVR"), channel("resp")])
        #expect(r.conventionalQTChannels.isEmpty,
                "A record without II/V5 gets NO conventional selection (X109 owns what happens then)")
    }

    @Test("Empty channels are ignored; a lone conventional lead is a single-element selection")
    func emptyChannelsIgnored() {
        let r = recording([channel("II", sampleCount: 0), channel("V5")])
        #expect(r.conventionalQTChannels.map(\.name) == ["V5"])
    }

    @Test("Lead III is not lead II — the normalizer must not over-match")
    func leadIIIIsNotII() {
        let r = recording([channel("III"), channel("MLIII"), channel("V50")])
        #expect(r.conventionalQTChannels.isEmpty)
    }
}
