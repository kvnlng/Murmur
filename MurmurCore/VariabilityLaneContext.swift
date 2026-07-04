//
//  VariabilityLaneContext.swift
//  MurmurCore
//
//  Shared observable state that lets the App target's orchestrator
//  hand computed variability-lane samples to `BedsideView` without
//  MurmurCore importing MurmurMetrics. Mirrors the same
//  App-writes / MurmurCore-reads pattern used by
//  `CurrentRecordingContext`.
//
//  The free viewer never computes samples (no arithmetic on
//  measurements in MurmurCore — that's a paid-extension responsibility
//  per project_metrics_module_boundaries.md). So an empty `samples`
//  array is the "no lane" state, whether the cause is a missing
//  entitlement, no recording loaded, or no beats in the recording.
//  `BedsideView` hides the lane in every empty case; the App target's
//  orchestrator is the only writer and it enforces the entitlement gate.
//
//  Also owns two other pieces of shared state:
//
//   - **Config** (window length, step, metric label). MurmurCore reads
//     it to render the picker + caption; the orchestrator writes to it
//     when the user changes a preset, and reads it back to recompute.
//     Persists via UserDefaults so the analyst's preferred window
//     survives app restarts.
//   - **Hover** (a time coordinate + which surface published it). The
//     signature "window-on-signal" interaction — hovering the lane or
//     the ECG publishes a time, both surfaces read it and draw
//     coordinated highlights.
//

import Foundation
import Observation

/// Which surface last published a hover event. Determines what UI
/// coordination downstream views apply (e.g. the ECG canvas only draws
/// a lane-window band when the LANE is the hover source).
public enum VariabilityHoverSource: Sendable, Equatable {
    case lane
    case ecg
}

/// Window length presets exposed to the analyst. Custom is deliberate
/// — the spec allows any positive value but presets clear-label the
/// three that appear in the literature: 1 min (short-term probe),
/// 5 min (Task Force 1996 standard), 10 min (denoised short-term).
public enum VariabilityWindowPreset: String, Sendable, CaseIterable, Codable {
    case oneMinute
    case fiveMinute
    case tenMinute
    case custom

    public var seconds: Double {
        switch self {
        case .oneMinute: return 60
        case .fiveMinute: return 300
        case .tenMinute: return 600
        case .custom: return 300  // default for custom until user tweaks it
        }
    }

    public var shortLabel: String {
        switch self {
        case .oneMinute: return "1 min"
        case .fiveMinute: return "5 min"
        case .tenMinute: return "10 min"
        case .custom: return "custom"
        }
    }
}

/// Live state for the rolling HRV lane rendered under the ECG canvas.
/// `@MainActor` because the UI surfaces that read it (BedsideView) all
/// run on main, and the orchestrator that writes it does too.
@MainActor
@Observable
public final class VariabilityLaneContext {

    /// Shared instance the app uses at runtime. Tests should construct
    /// a fresh `VariabilityLaneContext()` to keep parallel runs
    /// isolated from each other and from the live app state.
    public static let shared = VariabilityLaneContext()

    // MARK: - Sample state (written by orchestrator, read by BedsideView)

    /// The currently-published rolling samples. Empty means "no lane" —
    /// UI hides the lane surface entirely in that state.
    public private(set) var samples: [VariabilityLaneSample] = []

    /// Metric name displayed in the caption (e.g. "RMSSD").
    public private(set) var metricLabel: String = ""

    /// Unit string appended after values (e.g. "ms", "%", "bpm").
    public private(set) var unit: String = ""

    /// Optional caption describing window/step configuration
    /// (e.g. "5-min window · 30 s step"). `nil` suppresses the row.
    public private(set) var windowCaption: String?

    // MARK: - Config (window / step preset)

    /// Selected window-length preset. Persisted to UserDefaults;
    /// changes trigger orchestrator recompute.
    public var windowPreset: VariabilityWindowPreset {
        didSet { persist(preset: windowPreset, customWindowSeconds: customWindowSeconds, stepSeconds: stepSeconds) }
    }

    /// The window length in seconds — from the preset, or the
    /// user-set custom value when `windowPreset == .custom`.
    public var effectiveWindowSeconds: Double {
        windowPreset == .custom ? customWindowSeconds : windowPreset.seconds
    }

    /// The custom window length in seconds — active only when
    /// `windowPreset == .custom`. Persisted.
    public var customWindowSeconds: Double {
        didSet { persist(preset: windowPreset, customWindowSeconds: customWindowSeconds, stepSeconds: stepSeconds) }
    }

    /// Step (window-center-to-window-center distance) in seconds.
    /// Persisted. Independent of the window preset — a user can pick
    /// a 5-min window with a 60 s step for a coarser trace.
    public var stepSeconds: Double {
        didSet { persist(preset: windowPreset, customWindowSeconds: customWindowSeconds, stepSeconds: stepSeconds) }
    }

    // MARK: - Hover (window-on-signal linkage)

    /// The hovered time coordinate (seconds from recording start), or
    /// `nil` when nothing is being hovered. Set by whichever surface
    /// captured the hover; read by both the lane and the ECG to draw
    /// coordinated highlights.
    public private(set) var hoveredTimeSeconds: Double?

    /// Which surface published `hoveredTimeSeconds`. When `hoveredTimeSeconds`
    /// is nil this value is meaningless.
    public private(set) var hoveredSource: VariabilityHoverSource = .lane

    public init() {
        // Read persisted config. Defaults align with the spec:
        // RMSSD / 5-min window / 30 s step.
        let defaults = UserDefaults.standard
        let presetRaw = defaults.string(forKey: Keys.windowPreset) ?? VariabilityWindowPreset.fiveMinute.rawValue
        self.windowPreset = VariabilityWindowPreset(rawValue: presetRaw) ?? .fiveMinute
        let persistedCustom = defaults.double(forKey: Keys.customWindow)
        self.customWindowSeconds = persistedCustom > 0 ? persistedCustom : 300
        let persistedStep = defaults.double(forKey: Keys.step)
        self.stepSeconds = persistedStep > 0 ? persistedStep : 30
    }

    // MARK: - Writes (orchestrator)

    /// Publish a new set of lane samples.
    public func set(
        samples: [VariabilityLaneSample],
        metricLabel: String,
        unit: String,
        windowCaption: String?
    ) {
        self.samples = samples
        self.metricLabel = metricLabel
        self.unit = unit
        self.windowCaption = windowCaption
    }

    /// Publish the empty state — no recording, no entitlement, or no
    /// beats.
    public func clear() {
        samples = []
        metricLabel = ""
        unit = ""
        windowCaption = nil
    }

    // MARK: - Hover writes (either surface)

    /// Publish a hover at `timeSeconds`, tagged by which surface
    /// captured it. Passing `nil` clears the hover state — but ONLY
    /// when `source` matches `hoveredSource`, so a stale exit event
    /// from surface A (fired as the pointer moves onto surface B) can
    /// never clobber B's fresh hover. Prevents the race where the ECG
    /// canvas's `mouseExited` arrives after the lane's `mouseEntered`
    /// and wipes the lane's highlight.
    public func setHover(time timeSeconds: Double?, from source: VariabilityHoverSource) {
        if timeSeconds == nil && hoveredSource != source {
            return
        }
        self.hoveredTimeSeconds = timeSeconds
        self.hoveredSource = source
    }

    // MARK: - Sample lookup

    /// The sample whose window contains `timeSeconds`. When windows
    /// overlap (step < window) the sample whose CENTER is nearest to
    /// `timeSeconds` wins.
    public func sample(atTimeSeconds t: Double) -> VariabilityLaneSample? {
        var best: VariabilityLaneSample?
        var bestDistance = Double.infinity
        for s in samples where t >= s.windowStartSeconds && t <= s.windowEndSeconds {
            let d = abs(t - s.windowCenterSeconds)
            if d < bestDistance {
                bestDistance = d
                best = s
            }
        }
        return best
    }

    // MARK: - Persistence

    private enum Keys {
        static let windowPreset = "murmur.variabilityLane.windowPreset"
        static let customWindow = "murmur.variabilityLane.customWindowSeconds"
        static let step = "murmur.variabilityLane.stepSeconds"
    }

    private func persist(preset: VariabilityWindowPreset, customWindowSeconds: Double, stepSeconds: Double) {
        let defaults = UserDefaults.standard
        defaults.set(preset.rawValue, forKey: Keys.windowPreset)
        defaults.set(customWindowSeconds, forKey: Keys.customWindow)
        defaults.set(stepSeconds, forKey: Keys.step)
    }
}
