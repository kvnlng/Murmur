//
//  AnnotationClustering.swift
//  MurmurCore
//
//  Collapses runs of nearby same-category point annotations into single
//  visual aggregates when the analyst zooms out far enough that their
//  text labels would overlap. The overlay renders each cluster as one
//  badge with a count suffix ("PVC ×7") instead of a smear of identical
//  labels.
//
//  Pure function: no rendering, no environment access. Callers compute
//  `mergeWithinSamples` from the viewport's samples-per-pixel and pass
//  it in; we sort, group, and emit clusters in time order. Range
//  annotations pass through unmerged — they already have explicit
//  start/end extents that the renderer respects.
//

import Foundation

/// One item to render in the annotation overlay. May represent a single
/// annotation (count == 1) or an aggregate of several adjacent
/// same-category points (count > 1). `representative` is the first
/// annotation in the cluster — used for category color, label, hover
/// hit-testing, and disposition routing when the analyst clicks the
/// badge.
struct ClusteredAnnotation: Identifiable, Equatable {
    let id: UUID
    let count: Int
    let sampleIndex: Int64
    let category: String
    let representative: Annotation
    /// Annotation IDs of all members of this cluster. Order matches
    /// the original input order within the cluster window. Useful for
    /// "expand this cluster" UI in a future iteration.
    let memberIDs: [UUID]

    /// Convenience: the analyst-facing label, with count suffix when
    /// the cluster aggregates more than one annotation.
    var displayLabel: String {
        let base = representative.displayLabel
        return count > 1 ? "\(base) ×\(count)" : base
    }
}

enum AnnotationClustering {

    /// Builds the clustered view of `annotations` for a given merge
    /// window. Adjacent same-category point annotations whose sample
    /// distance is `<= mergeWithinSamples` collapse into a single
    /// cluster with `count > 1`. Range annotations pass through with
    /// `count == 1`; they're never merged because their own width
    /// already covers the cluster's would-be window.
    ///
    /// - Parameters:
    ///   - annotations: input set; need not be sorted.
    ///   - mergeWithinSamples: distance threshold. `0` means "no
    ///     clustering" (every annotation is its own cluster).
    /// - Returns: clusters sorted ascending by `sampleIndex`.
    static func cluster(
        _ annotations: [Annotation],
        mergeWithinSamples: Int64
    ) -> [ClusteredAnnotation] {
        // Range annotations never merge — emit each as a single-member
        // cluster preserved in time order.
        let ranges = annotations.filter { $0.kind == .range }
        let rangeClusters = ranges.map(Self.makeSingleton)

        // Point annotations are sorted ascending by sample so adjacent
        // ones are easy to consider in a single left-to-right pass.
        let points = annotations
            .filter { $0.kind == .point }
            .sorted { $0.sampleIndex < $1.sampleIndex }

        var pointClusters: [ClusteredAnnotation] = []
        var members: [Annotation] = []

        func flush() {
            guard let first = members.first else { return }
            let total = members.map(\.sampleIndex).reduce(0, +)
            let centroid = total / Int64(members.count)
            pointClusters.append(ClusteredAnnotation(
                id: first.id,
                count: members.count,
                sampleIndex: centroid,
                category: first.category,
                representative: first,
                memberIDs: members.map(\.id)
            ))
            members.removeAll(keepingCapacity: true)
        }

        for ann in points {
            if let last = members.last,
               last.category == ann.category,
               ann.sampleIndex - last.sampleIndex <= mergeWithinSamples {
                members.append(ann)
            } else {
                flush()
                members.append(ann)
            }
        }
        flush()

        return (pointClusters + rangeClusters)
            .sorted { $0.sampleIndex < $1.sampleIndex }
    }

    /// Wraps a single annotation in a count-1 cluster. Factored out so
    /// the range-passthrough path doesn't duplicate the constructor.
    private static func makeSingleton(_ ann: Annotation) -> ClusteredAnnotation {
        ClusteredAnnotation(
            id: ann.id,
            count: 1,
            sampleIndex: ann.sampleIndex,
            category: ann.category,
            representative: ann,
            memberIDs: [ann.id]
        )
    }
}
