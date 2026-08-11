//
//  ArrhythmiaScanSettings.swift
//  MurmurCore
//
//  X91 (#140) — the analyst's dials for the rate-band arrhythmia detector:
//  bradycardia/tachycardia bpm thresholds, the minimum time a run must
//  spend in the band, and (X106) the minimum run length in beats.
//
//  The screen defaults are the cardiologist review's candidate-screen
//  bounds (cardiologist-review-packet.md §1.3): 45/120 bpm with a 5-beat
//  minimum run — the definitional 60/100 band "will bury the analyst in
//  unactionable data" on long recordings (sleep dips into the 40s, ordinary
//  ambulation exceeds 100). The definitional band remains one dial-turn
//  away; these are cited defaults, not app-chosen severity — the "expose
//  the quantity, don't impose a cutoff" stance carried from
//  RhythmBandConfig (whose own defaults stay definitional and policy-free).
//  Whatever is in effect is echoed verbatim into the scan caption (the X58
//  provenance discipline): a screenshot of the queue always names the
//  thresholds that produced it.
//
//  The beats dial is enforced rate-relatively (X106, Kevin's formulation):
//  the run's span must cover N beats' worth of time at the run's own median
//  rate — beats are never counted, so missed or noise-minted detections
//  cannot move the gate.
//
//  Persistence is app-wide UserDefaults — an analyst's review policy, not a
//  per-recording fact (per-recording provenance lives in the caption). Under
//  an XCUI run the store is IN-MEMORY only: tests always start from the
//  defaults and can never inherit a previous run's dials — the X100 lesson,
//  applied before it bites.
//

import Foundation

@Observable
public final class ArrhythmiaScanSettings {
    public static let shared = ArrhythmiaScanSettings()

    // Candidate-screen defaults, cited from the cardiologist review
    // (cardiologist-review-packet.md §1.3) — NOT the definitional 60/100
    // band, which stays the policy-free default in RhythmBandConfig and
    // stays reachable here by dialing.
    public static let defaultLowBpm: Double = 45
    public static let defaultHighBpm: Double = 120
    public static let defaultMinDurationSeconds: Double = 0
    public static let defaultMinRunBeats: Double = 5

    /// Dial bounds. Wide enough for any defensible review policy; the gap
    /// keeps the band non-degenerate (low < high always, by construction).
    public static let lowBpmRange: ClosedRange<Double> = 20...140
    public static let highBpmRange: ClosedRange<Double> = 60...250
    public static let minDurationRange: ClosedRange<Double> = 0...600
    public static let minRunBeatsRange: ClosedRange<Double> = 0...100
    public static let minBandGapBpm: Double = 10

    private enum Key {
        static let low = "murmur.arrhythmiaScan.lowBpm"
        static let high = "murmur.arrhythmiaScan.highBpm"
        static let window = "murmur.arrhythmiaScan.minDurationSeconds"
        static let beats = "murmur.arrhythmiaScan.minRunBeats"
    }

    /// nil = in-memory only (XCUI runs — deterministic dials every launch).
    private let defaults: UserDefaults?

    private var storedLow: Double
    private var storedHigh: Double
    private var storedWindow: Double
    private var storedBeats: Double

    /// Bradycardia threshold: instantaneous rate BELOW this is in-band.
    public var lowBpm: Double {
        get { storedLow }
        set {
            storedLow = newValue.clamped(to:
                Self.lowBpmRange.lowerBound...(storedHigh - Self.minBandGapBpm))
            persist()
        }
    }

    /// Tachycardia threshold: instantaneous rate ABOVE this is in-band.
    public var highBpm: Double {
        get { storedHigh }
        set {
            storedHigh = newValue.clamped(to:
                (storedLow + Self.minBandGapBpm)...Self.highBpmRange.upperBound)
            persist()
        }
    }

    /// Minimum time (seconds) a run must spend in the band to be an event.
    /// 0 = no time window (the detector's policy-free default).
    public var minDurationSeconds: Double {
        get { storedWindow }
        set {
            storedWindow = newValue.clamped(to: Self.minDurationRange)
            persist()
        }
    }

    /// X106: minimum run length in beats, enforced rate-relatively (the run
    /// must SPAN this many beats' worth of time at its own median rate —
    /// beats are never counted). Stored as Double for dial uniformity;
    /// whole-beat semantics, rounded at the config seam. ≤ 1 = off.
    public var minRunBeats: Double {
        get { storedBeats }
        set {
            storedBeats = newValue.rounded().clamped(to: Self.minRunBeatsRange)
            persist()
        }
    }

    public var isDefault: Bool {
        storedLow == Self.defaultLowBpm
            && storedHigh == Self.defaultHighBpm
            && storedWindow == Self.defaultMinDurationSeconds
            && storedBeats == Self.defaultMinRunBeats
    }

    public func resetToDefaults() {
        storedLow = Self.defaultLowBpm
        storedHigh = Self.defaultHighBpm
        storedWindow = Self.defaultMinDurationSeconds
        storedBeats = Self.defaultMinRunBeats
        persist()
    }

    /// The provenance echo for the scan caption — always states the band,
    /// and names the beat minimum / time window whenever one is in effect.
    /// What the analyst dialed is what the citation says.
    public static func rhythmCaption(
        lowBpm: Double, highBpm: Double, minDurationSeconds: Double,
        minRunBeats: Double = 0
    ) -> String {
        var caption = String(format: "outside %.0f–%.0f bpm", lowBpm, highBpm)
        if minRunBeats > 1 {
            caption += String(format: " · ≥ %.0f beats", minRunBeats)
        }
        if minDurationSeconds > 0 {
            caption += String(format: " · sustained ≥ %.0f s", minDurationSeconds)
        }
        return caption
    }

    public convenience init() {
        #if DEBUG
        self.init(defaults: UITestSupport.isRunningUITest ? nil : .standard)
        #else
        self.init(defaults: .standard)
        #endif
    }

    /// Injectable store for tests; `nil` keeps every value in memory.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        let low = defaults?.object(forKey: Key.low) as? Double ?? Self.defaultLowBpm
        let high = defaults?.object(forKey: Key.high) as? Double ?? Self.defaultHighBpm
        let window = defaults?.object(forKey: Key.window) as? Double
            ?? Self.defaultMinDurationSeconds
        let beats = defaults?.object(forKey: Key.beats) as? Double
            ?? Self.defaultMinRunBeats
        // Re-clamp on load: hand-edited or stale defaults must never produce
        // a degenerate band.
        let clampedHigh = high.clamped(to: Self.highBpmRange)
        storedHigh = clampedHigh
        storedLow = low.clamped(to:
            Self.lowBpmRange.lowerBound...(clampedHigh - Self.minBandGapBpm))
        storedWindow = window.clamped(to: Self.minDurationRange)
        storedBeats = beats.rounded().clamped(to: Self.minRunBeatsRange)
    }

    private func persist() {
        guard let defaults else { return }
        defaults.set(storedLow, forKey: Key.low)
        defaults.set(storedHigh, forKey: Key.high)
        defaults.set(storedWindow, forKey: Key.window)
        defaults.set(storedBeats, forKey: Key.beats)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
