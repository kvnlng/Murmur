//
//  ArrhythmiaScanSettingsTests.swift
//  MurmurTests
//
//  X91 (#140) — the analyst's rate-band dials. What matters: the band can
//  never go degenerate (low < high by at least the gap, whatever order the
//  dials turn or whatever stale defaults load), values persist app-wide,
//  and the caption echo names exactly what is in effect.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Arrhythmia scan settings (X91)")
struct ArrhythmiaScanSettingsTests {
    /// A throwaway defaults suite so tests never touch the app's real
    /// preferences and parallel runs stay isolated.
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "ArrhythmiaScanSettingsTests-\(UUID().uuidString)"))
    }

    @Test("Fresh settings carry the detector's definitional defaults")
    func freshDefaults() throws {
        let settings = ArrhythmiaScanSettings(defaults: try makeDefaults())
        #expect(settings.lowBpm == 60)
        #expect(settings.highBpm == 100)
        #expect(settings.minDurationSeconds == 0)
        #expect(settings.isDefault)
    }

    @Test("The band cannot go degenerate from either direction")
    func bandStaysOrdered() throws {
        let settings = ArrhythmiaScanSettings(defaults: try makeDefaults())
        settings.lowBpm = 300          // tries to cross high (100)
        #expect(settings.lowBpm == 100 - ArrhythmiaScanSettings.minBandGapBpm)
        settings.highBpm = 10          // tries to cross low from above
        #expect(settings.highBpm == settings.lowBpm + ArrhythmiaScanSettings.minBandGapBpm)
        #expect(settings.lowBpm < settings.highBpm)
    }

    @Test("Dials clamp to their published ranges")
    func rangeClamping() throws {
        let settings = ArrhythmiaScanSettings(defaults: try makeDefaults())
        settings.lowBpm = -50
        #expect(settings.lowBpm == ArrhythmiaScanSettings.lowBpmRange.lowerBound)
        settings.highBpm = 999
        #expect(settings.highBpm == ArrhythmiaScanSettings.highBpmRange.upperBound)
        settings.minDurationSeconds = -1
        #expect(settings.minDurationSeconds == 0)
        settings.minDurationSeconds = 10_000
        #expect(settings.minDurationSeconds == ArrhythmiaScanSettings.minDurationRange.upperBound)
    }

    @Test("Values persist and reload; a degenerate stored band is repaired on load")
    func persistenceAndRepair() throws {
        let defaults = try makeDefaults()
        let settings = ArrhythmiaScanSettings(defaults: defaults)
        settings.lowBpm = 75
        settings.highBpm = 130
        settings.minDurationSeconds = 30

        let reloaded = ArrhythmiaScanSettings(defaults: defaults)
        #expect(reloaded.lowBpm == 75)
        #expect(reloaded.highBpm == 130)
        #expect(reloaded.minDurationSeconds == 30)

        // Hand-corrupt the store: low above high must repair, not crash.
        defaults.set(220.0, forKey: "murmur.arrhythmiaScan.lowBpm")
        defaults.set(80.0, forKey: "murmur.arrhythmiaScan.highBpm")
        let repaired = ArrhythmiaScanSettings(defaults: defaults)
        #expect(repaired.lowBpm < repaired.highBpm)
    }

    @Test("Reset returns every dial to defaults")
    func resetToDefaultsDial() throws {
        let settings = ArrhythmiaScanSettings(defaults: try makeDefaults())
        settings.lowBpm = 50
        settings.minDurationSeconds = 20
        #expect(!settings.isDefault)
        settings.resetToDefaults()
        #expect(settings.isDefault)
    }

    @Test("Caption names the band, and the window only when one is set")
    func captionEcho() {
        #expect(ArrhythmiaScanSettings.rhythmCaption(
            lowBpm: 60, highBpm: 100, minDurationSeconds: 0)
            == "outside 60–100 bpm")
        #expect(ArrhythmiaScanSettings.rhythmCaption(
            lowBpm: 55, highBpm: 120, minDurationSeconds: 8)
            == "outside 55–120 bpm sustained ≥ 8 s")
    }
}
