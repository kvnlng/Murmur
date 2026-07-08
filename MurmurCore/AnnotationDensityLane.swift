//
//  AnnotationDensityLane.swift
//  MurmurCore
//
//  Neutral-ink density strip that renders BENEATH the trace at the
//  Context zoom tier per project_waveform_zoom_lod_spec.md. Beat-label
//  categories whose count in the viewport would blow past individually
//  locatable landmarks (roughly `count × minMarkSpacing > plotWidth`)
//  collapse into this lane; the trace itself stops trying to be the
//  overview at that scale and the lane carries the "where the ectopic
//  runs live" signal instead.
//
//  Discipline (ratified — do NOT re-decide):
//    - NEUTRAL INK ONLY. A category-hued density map would encode an
//      app-asserted severity call → breaks RUO (mockup-review B-RUO,
//      project_mockup_review_pass.md). Alpha carries "how many," not
//      the color.
//    - Label the lane in text so the analyst knows which category is
//      pooled inside; the color-in-the-strip does not carry that.
//    - Absent at other tiers — the lane is a Context-only affordance.
//

import SwiftUI

struct AnnotationDensityLane: View {

    /// Annotations already filtered to the viewport by the caller.
    /// Everything except normal-beat ("N") point annotations feeds
    /// into the lane; the caller decides which are bulk vs. landmark
    /// via `AnnotationDensityLane.partition(...)` and passes only the
    /// bulk-category annotations here.
    let bulkAnnotations: [Annotation]

    /// Viewport bounds in samples — used to map annotation positions
    /// into horizontal buckets across the lane.
    let startSample: Int64
    let endSample: Int64

    /// Category name to render as the lane's label. Nil hides the
    /// label (e.g., when multiple categories collapsed into the same
    /// lane and no single label is honest).
    var categoryLabel: String?

    /// Pixel-width per density bucket. Smaller = finer resolution,
    /// higher memory / draw cost. 4pt is a good default for a 14pt-tall
    /// lane.
    var bucketWidthPx: CGFloat = 4

    /// Split point + range annotations into two groups keyed on
    /// whether they'd fit as individual landmarks at the current
    /// on-screen scale. Rule (spec): `count × minMarkSpacing ≤
    /// plotWidthPoints` → landmark; else → bulk.
    ///
    /// "N" normal-beat annotations are excluded entirely from both
    /// groups — Context omits normals just as Scan does.
    static func partition(
        annotations: [Annotation],
        plotWidthPoints: CGFloat,
        minMarkSpacingPoints: CGFloat = 12
    ) -> (landmarks: [Annotation], bulk: [Annotation]) {
        let flagged = annotations.filter { $0.category != "N" }
        var byCategory: [String: [Annotation]] = [:]
        for ann in flagged {
            byCategory[ann.category, default: []].append(ann)
        }
        var landmarks: [Annotation] = []
        var bulk: [Annotation] = []
        for (_, group) in byCategory {
            let neededWidth = CGFloat(group.count) * minMarkSpacingPoints
            if neededWidth <= plotWidthPoints {
                landmarks.append(contentsOf: group)
            } else {
                bulk.append(contentsOf: group)
            }
        }
        return (landmarks, bulk)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let label = categoryLabel {
                Text("\(label) · density")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
                    .accessibilityIdentifier("annotation-density-lane-label")
            }
            densityStrip
        }
        .frame(height: 14)
        .accessibilityIdentifier("annotation-density-lane")
    }

    /// Canvas-drawn per-bucket density. Neutral primary ink; alpha is
    /// proportional to bucket count (clamped to 0.75 so a dense stretch
    /// still reads as ink and not a black bar). Empty viewports render
    /// as a blank strip — the reserved space signals "there'd be a lane
    /// here if the category were populated," which matches how the
    /// trace's rest state renders paper without a trace.
    private var densityStrip: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let span = max(1, endSample - startSample)
            let bucketCount = max(1, Int(size.width / bucketWidthPx))
            var buckets = [Int](repeating: 0, count: bucketCount)
            for ann in bulkAnnotations {
                let s = ann.sampleIndex
                guard s >= startSample, s <= endSample else { continue }
                let frac = Double(s - startSample) / Double(span)
                let idx = min(bucketCount - 1, max(0, Int(frac * Double(bucketCount))))
                buckets[idx] += 1
            }
            let maxCount = max(1, buckets.max() ?? 1)
            for (i, count) in buckets.enumerated() where count > 0 {
                let alpha = min(0.75, Double(count) / Double(maxCount))
                let rect = CGRect(
                    x: CGFloat(i) * bucketWidthPx,
                    y: 0,
                    width: bucketWidthPx - 1,
                    height: size.height
                )
                context.fill(Path(rect), with: .color(Color.primary.opacity(alpha)))
            }
        }
    }
}
