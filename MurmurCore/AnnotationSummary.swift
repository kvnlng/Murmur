//
//  AnnotationSummary.swift
//  Murmur
//
//  Pure aggregation over `[Annotation]` for the bedside "what's in this
//  recording?" surface. Drives both the summary chip header and the finding
//  density timeline, and is the same data the findings panel could use for
//  a future "X of Y" hint.
//
//  Display formatting lives in the views — this file only computes counts,
//  durations, and ordering.
//

import Foundation

/// One category's contribution to the per-recording summary.
struct CategoryRollup: Identifiable, Equatable {
    let category: String
    let totalCount: Int
    let pointCount: Int
    let rangeCount: Int
    /// Sum of `endSample - startSample` across every range in this category.
    /// Zero for point-only categories. Cumulative, not deduped — overlapping
    /// ranges add up.
    let totalRangeSamples: Int64
    /// Per-severity occurrence counts. Severities with zero events are
    /// omitted.
    let severityCounts: [Annotation.Severity: Int]
    /// Highest severity seen in this category. `.info` when the category is
    /// entirely informational or empty.
    let maxSeverity: Annotation.Severity

    var id: String { category }

    /// True when there's enough range-extent to make "total time spanned"
    /// the more informative headline number than "count of events." Range
    /// findings with zero or unset end samples fall back to the count form.
    var isRangeDominant: Bool {
        rangeCount > 0 && totalRangeSamples > 0
    }

    var criticalCount: Int { severityCounts[.critical] ?? 0 }
    var warningCount: Int  { severityCounts[.warning]  ?? 0 }
}

/// Per-recording rollup: one entry per category, plus a grand total.
struct AnnotationSummary: Equatable {
    /// Sorted: max severity descending (critical first), then total count
    /// descending, then category name as a deterministic tiebreaker.
    let rollups: [CategoryRollup]
    let totalCount: Int
    /// Total samples in the recording, if known. Lets the view compute
    /// "% of recording" labels for range-dominant categories.
    let recordingDurationSamples: Int64?
    let sampleRate: Double

    static let empty = AnnotationSummary(
        rollups: [],
        totalCount: 0,
        recordingDurationSamples: nil,
        sampleRate: 0
    )

    /// Builds the rollup. Pure, allocation-conscious — one pass through the
    /// annotation list, a second pass to sort by severity and count.
    static func build(
        from annotations: [Annotation],
        recordingDurationSamples: Int64?,
        sampleRate: Double
    ) -> AnnotationSummary {
        guard !annotations.isEmpty else {
            return AnnotationSummary(
                rollups: [],
                totalCount: 0,
                recordingDurationSamples: recordingDurationSamples,
                sampleRate: sampleRate
            )
        }

        var buckets: [String: Bucket] = [:]
        buckets.reserveCapacity(annotations.count)

        for ann in annotations {
            var bucket = buckets[ann.category] ?? Bucket(category: ann.category)
            bucket.totalCount += 1
            switch ann.kind {
            case .point:
                bucket.pointCount += 1
            case .range:
                bucket.rangeCount += 1
                if let endSample = ann.endSampleIndex {
                    let span = max(0, endSample - ann.sampleIndex)
                    bucket.totalRangeSamples += span
                }
            }
            bucket.severityCounts[ann.severity, default: 0] += 1
            if ann.severity > bucket.maxSeverity {
                bucket.maxSeverity = ann.severity
            }
            buckets[ann.category] = bucket
        }

        let rollups = buckets.values
            .map(\.rollup)
            .sorted { lhs, rhs in
                if lhs.maxSeverity != rhs.maxSeverity {
                    return lhs.maxSeverity > rhs.maxSeverity
                }
                if lhs.totalCount != rhs.totalCount {
                    return lhs.totalCount > rhs.totalCount
                }
                return lhs.category < rhs.category
            }

        return AnnotationSummary(
            rollups: rollups,
            totalCount: annotations.count,
            recordingDurationSamples: recordingDurationSamples,
            sampleRate: sampleRate
        )
    }

    /// Fraction of recording covered by `rollup`'s range total, in `0…1`.
    /// Returns `nil` when the recording duration isn't known or when the
    /// category contributes no range extent.
    func fractionOfRecording(_ rollup: CategoryRollup) -> Double? {
        guard let total = recordingDurationSamples, total > 0,
              rollup.totalRangeSamples > 0 else { return nil }
        return min(1.0, Double(rollup.totalRangeSamples) / Double(total))
    }

    // MARK: - Build-time scratch

    private struct Bucket {
        let category: String
        var totalCount: Int = 0
        var pointCount: Int = 0
        var rangeCount: Int = 0
        var totalRangeSamples: Int64 = 0
        var severityCounts: [Annotation.Severity: Int] = [:]
        var maxSeverity: Annotation.Severity = .info

        var rollup: CategoryRollup {
            CategoryRollup(
                category: category,
                totalCount: totalCount,
                pointCount: pointCount,
                rangeCount: rangeCount,
                totalRangeSamples: totalRangeSamples,
                severityCounts: severityCounts,
                maxSeverity: maxSeverity
            )
        }
    }
}
