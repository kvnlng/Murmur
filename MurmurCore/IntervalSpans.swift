//
//  IntervalSpans.swift
//  MurmurCore
//
//  The intervals an analyst actually reads — PR, QRS, QT — as spans rather
//  than as six unconnected endpoints (#227).
//
//  The markings feature shipped its POINT half: six fiducials per beat. But
//  nobody reads six endpoints. They read PR, QRS and QT, which is exactly what
//  the beat card already states in words (`PR 132.8 ms  +23.4 ms`). Until now
//  those were two renderings of the same measurement that shared nothing — a
//  number in a side panel, and ticks on the trace the analyst had to pair up
//  mentally into the spans the number came from.
//
//  ## Deviation, not geometry
//
//  This is the part worth being explicit about, because it is the product's
//  thesis. Everything else in the markings feature is built on deviation from
//  THIS PATIENT'S own normal — the template, the caliper delta columns, the
//  ghost overlay, deviation-ranked navigation. The fiducial overlay was the
//  exception: it drew absolute positions, so `+23.4 ms` existed only as
//  arithmetic in a panel.
//
//  So a span carries both durations. The template's median is the ghost, this
//  beat's is solid, and the overhang between them IS the deviation — seen
//  rather than computed.
//
//  ## Why this is a model rather than a view
//
//  The same reason X61's summary moved into `FiducialRenderPolicy`: the
//  interesting part is the arithmetic, and arithmetic buried in a `ViewBuilder`
//  is reachable only through XCUI at specific window sizes. That has been the
//  least reliable testing in this project (#231, #236, #277). The view's job is
//  reduced to mapping samples to x.
//

import Foundation

/// One interval of one beat, with its own duration and the patient's normal.
public struct IntervalSpan: Sendable, Equatable, Identifiable {

    public enum Kind: String, Sendable, CaseIterable {
        case pr
        case qrs
        case qt

        /// What the analyst calls it. Matches the beat card's own labels so the
        /// trace and the card name the same object identically.
        public var label: String {
            switch self {
            case .pr:  return "PR"
            case .qrs: return "QRS"
            case .qt:  return "QT"
            }
        }

        /// The wave whose colour this interval borrows, so the spans join the
        /// letter vocabulary rather than introducing a second one: PR is about
        /// atrioventricular conduction (P), QT is repolarisation (T), QRS is
        /// itself.
        public var paletteLayer: MarkingsFiducialLayer {
            switch self {
            case .pr:  return .p
            case .qrs: return .qrs
            case .qt:  return .t
            }
        }

        /// Drawing order, top to bottom. Shortest first so the stack reads as
        /// nested magnitudes — QRS sits inside QT, and PR abuts it.
        public var row: Int {
            switch self {
            case .pr:  return 0
            case .qrs: return 1
            case .qt:  return 2
            }
        }
    }

    public let kind: Kind
    /// Where the span starts and ends in the recording.
    public let startSample: Int64
    public let endSample: Int64
    /// This beat's duration. Taken from the beat's own published measurement
    /// rather than recomputed from the endpoints — the beat card reports that
    /// number, and a span whose label disagreed with the card would be worse
    /// than no span.
    public let actualMs: Double
    /// The patient's own normal for this interval, when the template has one.
    /// Nil for a record with too few normal beats to build a template, or for
    /// an interval the template withheld.
    public let templateMs: Double?

    public var id: String { kind.rawValue }

    /// Signed deviation from the patient's normal — the quantity the whole
    /// feature is about. Nil when there is no normal to deviate from.
    public var deviationMs: Double? {
        guard let templateMs else { return nil }
        return actualMs - templateMs
    }

    /// Where the ghost span ends: the same start, run out to the template's
    /// duration. Nil when there is no template median, in which case there is
    /// nothing to compare and only the solid span draws.
    public func ghostEndSample(sampleRate: Double) -> Int64? {
        guard let templateMs, sampleRate > 0, templateMs > 0 else { return nil }
        let samples = templateMs / 1000 * sampleRate
        guard samples.isFinite, samples > 0 else { return nil }
        return startSample + Int64(samples.rounded())
    }
}

public enum IntervalSpans {

    /// The spans a beat can support, in drawing order.
    ///
    /// A span is emitted only when BOTH its endpoints were delineated AND the
    /// beat published a duration for it. Both conditions are load-bearing:
    /// endpoints without a duration means the measurement was withheld
    /// (X53's physical-implausibility exclusion, X58's unreliable T-offset),
    /// and drawing a span there would put a mark on the trace for a number the
    /// card is deliberately refusing to state.
    public static func spans(
        for beat: MarkingsBeat,
        template: MarkingsTemplate?
    ) -> [IntervalSpan] {
        var result: [IntervalSpan] = []

        if let start = beat.pOnset, let end = beat.qrsOnset, let ms = beat.prMs {
            result.append(IntervalSpan(
                kind: .pr,
                startSample: start.sampleIndex,
                endSample: end.sampleIndex,
                actualMs: ms,
                templateMs: template?.medianPRMs))
        }
        if let start = beat.qrsOnset, let end = beat.qrsOffset, let ms = beat.qrsMs {
            result.append(IntervalSpan(
                kind: .qrs,
                startSample: start.sampleIndex,
                endSample: end.sampleIndex,
                actualMs: ms,
                templateMs: template?.medianQRSMs))
        }
        // QT runs from the QRS onset to the T offset — the same start as QRS,
        // which is why the rows stack rather than share one line.
        if let start = beat.qrsOnset, let end = beat.tOffset, let ms = beat.qtMs {
            result.append(IntervalSpan(
                kind: .qt,
                startSample: start.sampleIndex,
                endSample: end.sampleIndex,
                actualMs: ms,
                templateMs: template?.medianQTMs))
        }

        return result.sorted { $0.kind.row < $1.kind.row }
    }
}
