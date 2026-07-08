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
        // Layout per the mockup: a bordered strip with the density bars
        // inside, and the "<category> · density — neutral, not a heatmap"
        // label BELOW the strip. Putting the label inline at the leading
        // edge (the previous layout) crowded the strip and made the
        // "density lane, not a chip rail" reading harder to catch at a
        // glance.
        VStack(alignment: .leading, spacing: 2) {
            densityStrip
                .frame(height: Self.stripHeight)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.20), lineWidth: 0.5)
                )
            if let label = categoryLabel {
                Text("\(label) · density — neutral, not a heatmap")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("annotation-density-lane-label")
            }
        }
        .accessibilityIdentifier("annotation-density-lane")
    }

    private static let stripHeight: CGFloat = 20

    /// Canvas-drawn per-bucket density. Neutral primary ink; alpha is
    /// proportional to bucket count (clamped to 0.75 so a dense stretch
    /// still reads as ink and not a black bar). Bars are height-scaled
    /// too so a lightly-populated stretch reads as a shorter mark inside
    /// the reserved strip — matches the mockup's "column-height carries
    /// intensity" pattern.
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
            let usableHeight = max(0, size.height - 2)
            for (i, count) in buckets.enumerated() where count > 0 {
                let ratio = Double(count) / Double(maxCount)
                let alpha = min(0.75, ratio)
                let h = usableHeight * CGFloat(max(0.25, ratio))
                let rect = CGRect(
                    x: CGFloat(i) * bucketWidthPx,
                    y: size.height - 1 - h,
                    width: max(0.6, bucketWidthPx - 1),
                    height: h
                )
                context.fill(Path(rect), with: .color(Color.primary.opacity(alpha)))
            }
        }
    }
}
