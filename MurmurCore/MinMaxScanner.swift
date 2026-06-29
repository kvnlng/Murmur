//
//  MinMaxScanner.swift
//  MurmurCore
//
//  Single-pass min / max over a channel's sample buffer. Pure function
//  with NaN handling, extracted from any specific view so the math has
//  a testable home. Used at panel mount to populate the per-channel
//  range badge in the header.
//
//  Foundation for the (future) per-channel Y-axis autoscale roadmap
//  item — that feature will reuse the same min/max and add padding +
//  uniform updates. Keeping the scan separate from the renderer means
//  the computation is testable in isolation against synthetic input.
//

import Foundation

enum MinMaxScanner {

    /// Result of scanning a sample buffer. The values are in the same
    /// units as the input (mV for ECG channels). `valid` counts the
    /// number of finite samples observed — useful for deciding whether
    /// a degenerate result (e.g., all-NaN buffer) is meaningful.
    struct Range: Equatable, Sendable {
        let min: Float
        let max: Float
        let validSampleCount: Int

        /// True when the scan saw no finite samples at all. Callers
        /// should treat the `min` / `max` values as undefined in that
        /// case.
        var isEmpty: Bool { validSampleCount == 0 }
    }

    /// Default fraction of the observed span added as padding above and
    /// below when deriving a display range. 10% gives the trace room to
    /// breathe at the top/bottom of the chart without cropping during
    /// brief excursions outside the steady-state band.
    static let defaultPaddingFraction: Double = 0.1

    /// Smallest display-range span the autoscale path will produce.
    /// Prevents a near-flat signal (constant DC offset, all-zero
    /// recording) from collapsing the y-axis to a slice that hides any
    /// genuine variation. 0.5 mV is one major paper division.
    static let defaultMinDisplaySpan: Double = 0.5

    /// Scans `samples` for the minimum and maximum finite values.
    /// Non-finite samples (`.nan`, `.infinity`, `-.infinity`) are
    /// skipped — they represent gaps in the recording rather than
    /// observed voltages and shouldn't shift the range.
    ///
    /// Returns nil when `samples` is empty or contains no finite
    /// values, so callers can distinguish "no data" from "data with
    /// a meaningful zero range".
    static func scan<S: Sequence>(samples: S) -> Range? where S.Element == Float {
        var seenAny = false
        var lo: Float = .greatestFiniteMagnitude
        var hi: Float = -.greatestFiniteMagnitude
        var count = 0
        for sample in samples {
            guard sample.isFinite else { continue }
            seenAny = true
            count += 1
            if sample < lo { lo = sample }
            if sample > hi { hi = sample }
        }
        guard seenAny else { return nil }
        return Range(min: lo, max: hi, validSampleCount: count)
    }
}

extension MinMaxScanner.Range {
    /// Display range derived from the observed min/max. Adds proportional
    /// padding above and below; widens out to `minSpan` when the
    /// observed signal is tighter than that floor so the chart doesn't
    /// devolve to a slice. Caller picks `padding` and `minSpan`; the
    /// defaults match the Y-axis autoscale UX (`0.1` / `0.5`).
    func displayRange(
        padding: Double = MinMaxScanner.defaultPaddingFraction,
        minSpan: Double = MinMaxScanner.defaultMinDisplaySpan
    ) -> ClosedRange<Double> {
        let lo = Double(min)
        let hi = Double(max)
        let observedSpan = Swift.max(hi - lo, 0)   // guard against degenerate min > max
        let span = Swift.max(observedSpan, minSpan)
        // Center the padded range on the observed midpoint when we hit
        // the minSpan floor — so a flat 0 mV signal renders as ±span/2,
        // not 0 to span.
        let mid = (lo + hi) / 2
        let halfSpan = span / 2
        let pad = span * padding
        return (mid - halfSpan - pad)...(mid + halfSpan + pad)
    }
}
