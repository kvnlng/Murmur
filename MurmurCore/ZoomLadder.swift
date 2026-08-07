//
//  ZoomLadder.swift
//  MurmurCore
//
//  The stage's zoom ladder (X70): fixed viewport widths an analyst can jump
//  between, rather than only relative zoom.
//
//  Why it exists: at the target profile — 12 leads, 250 Hz, up to 72 hours —
//  "zoom out" as a repeated gesture is not navigation. Getting from a 10 s
//  window to the whole record is ~14 doublings, and getting back to a
//  different 10 s window is 14 more. The ladder makes the useful widths one
//  click apart.
//
//  The steps are the design's, and they are not arbitrary: whole record, an
//  hour, five minutes, ten seconds, two seconds — each roughly an order of
//  magnitude apart, and each corresponding to a question an analyst actually
//  asks ("where in the night", "where in this hour", "what happened around
//  here", "what does this beat look like").
//

import Foundation

/// One rung. `seconds` is the viewport width the rung sets.
public struct ZoomLadderStep: Equatable, Sendable, Identifiable {
    public let seconds: Double
    public let label: String

    public var id: Double { seconds }

    public init(seconds: Double, label: String) {
        self.seconds = seconds
        self.label = label
    }
}

public enum ZoomLadder {

    /// The full ladder, widest first — reading order matches the bands above
    /// the trace, which also go whole-record → hour → window.
    public static let allSteps: [ZoomLadderStep] = [
        ZoomLadderStep(seconds: 72 * 3600, label: "72 h"),
        ZoomLadderStep(seconds: 3600,      label: "1 h"),
        ZoomLadderStep(seconds: 300,       label: "5 m"),
        ZoomLadderStep(seconds: 10,        label: "10 s"),
        ZoomLadderStep(seconds: 2,         label: "2 s"),
    ]

    /// The rungs worth showing for a record of `durationSeconds`.
    ///
    /// A rung wider than the record would clamp to the whole record, so several
    /// of them would be the same button repeated — on a 30-minute MIT-BIH
    /// record the design's literal ladder gives `72 h` and `1 h` both meaning
    /// "all of it". Instead the widest rung that fits is kept and a single
    /// `All` rung represents the whole record, so every button lands somewhere
    /// different.
    ///
    /// The narrow end is never trimmed: 2 s is legible on any record, and a
    /// ladder that silently loses its finest rung on a short record would make
    /// the shortest recordings the hardest to inspect.
    public static func steps(forDurationSeconds duration: Double) -> [ZoomLadderStep] {
        guard duration > 0 else { return [] }
        // A fixed rung within a hair of the record's own length is the SAME
        // view as the whole-record rung — a 72.4 h record would otherwise get
        // two buttons both reading "72 h", one of them 20 minutes narrower
        // than the other. Drop the fixed one and let whole-record stand for it.
        var steps = allSteps.filter { step in
            step.seconds < duration
                && abs(step.seconds - duration) / duration > nearWholeRecordTolerance
        }
        steps.insert(
            ZoomLadderStep(seconds: duration, label: wholeRecordLabel(duration)),
            at: 0
        )
        return steps
    }

    /// How close a fixed rung has to be to the record's length before it is
    /// treated as the same view. 2% of 72 h is ~87 minutes, which is well
    /// inside "the eye cannot tell these two buttons apart".
    private static let nearWholeRecordTolerance: Double = 0.02

    /// Which rung the viewport is currently sitting on, if any.
    ///
    /// Matched with a relative tolerance rather than by equality: the viewport
    /// is stored in whole samples, so a 10 s rung on a 360 Hz record lands at
    /// 3600 samples and reads back as 10.0 s, but a 5-minute rung on an odd
    /// rate need not round-trip exactly. Returns nil after a manual pinch, so
    /// the ladder shows nothing selected rather than claiming a rung the
    /// analyst is not on.
    public static func currentStep(
        forDurationSeconds duration: Double,
        in steps: [ZoomLadderStep],
        tolerance: Double = 0.02
    ) -> ZoomLadderStep? {
        guard duration > 0 else { return nil }
        return steps.first { step in
            guard step.seconds > 0 else { return false }
            return abs(step.seconds - duration) / step.seconds <= tolerance
        }
    }

    private static func wholeRecordLabel(_ duration: Double) -> String {
        if duration >= 3600 { return String(format: "%.0f h", (duration / 3600).rounded()) }
        if duration >= 60 { return String(format: "%.0f m", (duration / 60).rounded()) }
        return String(format: "%.0f s", duration.rounded())
    }
}
