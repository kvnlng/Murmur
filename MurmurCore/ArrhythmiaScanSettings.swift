//
//  ArrhythmiaScanSettings.swift
//  MurmurCore
//
//  X91 (#140) — the analyst's dials for the rate-band arrhythmia detector:
//  bradycardia/tachycardia bpm thresholds and the minimum time a run must
//  spend in the band to qualify as an event.
//
//  The detector's defaults (60/100 bpm, no time window) are definitional
//  coordinates, not app-chosen severity — these dials let the analyst set
//  their OWN bounds, the "expose the quantity, don't impose a cutoff"
//  stance carried from RhythmBandConfig. Whatever is in effect is echoed
//  verbatim into the scan caption (the X58 provenance discipline): a
//  screenshot of the queue always names the thresholds that produced it.
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

    // Detector defaults (standard adult definitions, mirrored from
    // RhythmBandConfig so MurmurCore needs no MurmurMetrics import).
    public static let defaultLowBpm: Double = 60
    public static let defaultHighBpm: Double = 100
    public static let defaultMinDurationSeconds: Double = 0

    /// Dial bounds. Wide enough for any defensible review policy; the gap
    /// keeps the band non-degenerate (low < high always, by construction).
    public static let lowBpmRange: ClosedRange<Double> = 20...140
    public static let highBpmRange: ClosedRange<Double> = 60...250
    public static let minDurationRange: ClosedRange<Double> = 0...600
    public static let minBandGapBpm: Double = 10

    private enum Key {
        static let low = "murmur.arrhythmiaScan.lowBpm"
        static let high = "murmur.arrhythmiaScan.highBpm"
        static let window = "murmur.arrhythmiaScan.minDurationSeconds"
    }

    /// nil = in-memory only (XCUI runs — deterministic dials every launch).
    private let defaults: UserDefaults?

    private var storedLow: Double
    private var storedHigh: Double
    private var storedWindow: Double

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
    /// 0 = every in-band run qualifies (the detector's policy-free default).
    public var minDurationSeconds: Double {
        get { storedWindow }
        set {
            storedWindow = newValue.clamped(to: Self.minDurationRange)
            persist()
        }
    }

    public var isDefault: Bool {
        storedLow == Self.defaultLowBpm
            && storedHigh == Self.defaultHighBpm
            && storedWindow == Self.defaultMinDurationSeconds
    }

    public func resetToDefaults() {
        storedLow = Self.defaultLowBpm
        storedHigh = Self.defaultHighBpm
        storedWindow = Self.defaultMinDurationSeconds
        persist()
    }

    /// The provenance echo for the scan caption — always states the band,
    /// and names the time window whenever one is in effect. What the
    /// analyst dialed is what the citation says.
    public static func rhythmCaption(
        lowBpm: Double, highBpm: Double, minDurationSeconds: Double
    ) -> String {
        var caption = String(format: "outside %.0f–%.0f bpm", lowBpm, highBpm)
        if minDurationSeconds > 0 {
            caption += String(format: " sustained ≥ %.0f s", minDurationSeconds)
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
        // Re-clamp on load: hand-edited or stale defaults must never produce
        // a degenerate band.
        let clampedHigh = high.clamped(to: Self.highBpmRange)
        storedHigh = clampedHigh
        storedLow = low.clamped(to:
            Self.lowBpmRange.lowerBound...(clampedHigh - Self.minBandGapBpm))
        storedWindow = window.clamped(to: Self.minDurationRange)
    }

    private func persist() {
        guard let defaults else { return }
        defaults.set(storedLow, forKey: Key.low)
        defaults.set(storedHigh, forKey: Key.high)
        defaults.set(storedWindow, forKey: Key.window)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
