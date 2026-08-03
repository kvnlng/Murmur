//
//  TimeDisplayModeTests.swift
//  MurmurTests
//
//  X28 — the wall-clock display toggle, and the rule it must never break.
//

import Testing
import Foundation
@testable import MurmurCore

@Suite("X28 — elapsed ↔ wall-clock time display")
struct TimeDisplayModeTests {

    /// THE load-bearing property. A recording without a real start time has no
    /// time of day, and X32's rule is that we never substitute the system clock.
    /// `coordinate` is the single place that fallback lives, so it is the single
    /// place worth guarding.
    @Test("Wall-clock requested without a time base falls back to elapsed — never a fabricated clock")
    func noTimeBaseNeverFabricates() {
        let elapsed = ViewportTimeFormat.elapsed(65.4)
        let asked = ViewportTimeFormat.coordinate(65.4, mode: .wallClock, startUnixMillis: nil)
        #expect(asked == elapsed, "no time base must yield elapsed, got \(asked)")
        // And it must not look like a clock.
        #expect(!asked.contains(":") || asked == elapsed)
    }

    @Test("With a real time base, wall-clock renders time of day")
    func rendersTimeOfDay() {
        // 1970-01-01T00:00:00Z + 12h, expressed in the LOCAL zone so the test
        // travels — we assert the offset behaviour, not a fixed wall string.
        let base: Int64 = 12 * 3600 * 1000
        let at0 = ViewportTimeFormat.wallClock(0, startUnixMillis: base, tenths: false)
        let at90 = ViewportTimeFormat.wallClock(90, startUnixMillis: base, tenths: false)
        #expect(at0.count == 8, "expected HH:mm:ss, got \(at0)")
        #expect(at90 != at0, "90 s later must read differently")

        // 90 s on is exactly +1:30 of clock time.
        func secs(_ s: String) -> Int {
            let p = s.split(separator: ":").compactMap { Int($0) }
            return p.count == 3 ? p[0]*3600 + p[1]*60 + p[2] : -1
        }
        #expect(secs(at90) - secs(at0) == 90)
    }

    @Test("Rounding rolls the clock rather than printing :60")
    func roundingRollsOver() {
        let base: Int64 = 0
        // 59.96 s must roll into the next minute, not render second 60.
        let s = ViewportTimeFormat.wallClock(59.96, startUnixMillis: base)
        #expect(!s.contains(":60"), "rolled badly: \(s)")
    }

    // TimeDisplayContext is @MainActor (every reader of it is a UI surface).
    @MainActor
    @Test("Preference persists, but effective mode collapses without a time base")
    func preferenceVsEffectiveMode() {
        let suite = UserDefaults(suiteName: "x28.tests.\(UUID().uuidString)")!
        let ctx = TimeDisplayContext(defaults: suite)
        #expect(ctx.mode == .elapsed, "default is elapsed")

        ctx.mode = .wallClock
        // Preference is remembered…
        let reloaded = TimeDisplayContext(defaults: suite)
        #expect(reloaded.mode == .wallClock, "preference must survive a relaunch")
        // …but a record with no time base still renders elapsed, and the toggle
        // is not offered.
        #expect(reloaded.effectiveMode(hasAbsoluteStart: false) == .elapsed)
        #expect(reloaded.isAvailable(hasAbsoluteStart: false) == false)
        // With a time base, the preference takes effect.
        #expect(reloaded.effectiveMode(hasAbsoluteStart: true) == .wallClock)
        #expect(reloaded.isAvailable(hasAbsoluteStart: true) == true)
    }

    @Test("Elapsed mode is unaffected by the presence of a time base")
    func elapsedIsStable() {
        let withBase = ViewportTimeFormat.coordinate(42.5, mode: .elapsed, startUnixMillis: 1_700_000_000_000)
        let without = ViewportTimeFormat.coordinate(42.5, mode: .elapsed, startUnixMillis: nil)
        #expect(withBase == without)
        #expect(withBase == ViewportTimeFormat.elapsed(42.5))
    }
}
