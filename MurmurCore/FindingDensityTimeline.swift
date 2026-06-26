//
//  FindingDensityTimeline.swift
//  Murmur
//
//  Recording-level "heatmap" of findings. One thin lane per category, points
//  drawn as dots, ranges drawn as bars proportional to their duration. The
//  visual answers "where in this recording does each category cluster?" —
//  the analyst's first navigation question when triaging a long record.
//
//  Click anywhere on a lane → jump the shared viewport to that fraction.
//  Filter-aware: lanes correspond to the surviving categories after the
//  current `FindingFilter`.
//

import SwiftUI

struct FindingDensityTimeline: View {
    /// Already-filtered annotations — the timeline mirrors whatever the
    /// findings panel / summary chips have narrowed the recording to.
    let annotations: [Annotation]
    let totalSamples: Int64
    let sampleRate: Double
    let viewport: RecordingViewport
    /// Optional jump override. Defaults to calling
    /// `viewport.jump(toFraction:)` directly.
    var onJump: ((Double) -> Void)? = nil
    /// Optional disposition state per annotation — drives the
    /// dimmed-for-dismissed / outlined-for-confirmed visual treatment.
    /// Empty dictionary keeps the timeline backward-compatible for
    /// callers that don't yet plumb disposition state.
    var dispositionsByID: [UUID: AnnotationDisposition] = [:]

    /// Lane height — tight enough that 8–10 categories fit without scrolling.
    private let laneHeight: CGFloat = 14
    private let labelWidth: CGFloat = 96

    var body: some View {
        if lanes.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(spacing: 2) {
                    ForEach(lanes) { lane in
                        laneRow(lane)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("finding-density-timeline")
        }
    }

    private var header: some View {
        HStack {
            Text("Where")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(durationLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 4)
    }

    private var durationLabel: String {
        guard totalSamples > 0, sampleRate > 0 else { return "" }
        return ChipDuration.format(seconds: Double(totalSamples) / sampleRate)
    }

    private func laneRow(_ lane: Lane) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(lane.color)
                    .frame(width: 7, height: 7)
                Text(lane.category)
                    .font(.caption.weight(.semibold).monospaced())
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(lane.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: labelWidth, alignment: .leading)

            plotArea(lane)
        }
        .accessibilityIdentifier("density-lane-\(lane.category)")
    }

    private func plotArea(_ lane: Lane) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.10))
                Canvas { ctx, size in
                    paint(lane: lane, into: ctx, size: size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let fraction = max(0, min(1, Double(location.x / max(geo.size.width, 1))))
                jump(toFraction: fraction)
            }
        }
        .frame(height: laneHeight)
    }

    private func paint(lane: Lane, into ctx: GraphicsContext, size: CGSize) {
        guard totalSamples > 0 else { return }
        let widthF = size.width
        let heightF = size.height
        let total = Double(totalSamples)

        // Draw ranges first so points sit on top.
        for entry in lane.entries where entry.kind == .range {
            let x0 = CGFloat(max(0.0, Double(entry.start) / total)) * widthF
            let endSample = Double(entry.end)
            let x1 = CGFloat(min(1.0, endSample / total)) * widthF
            let rectWidth = max(2.0, x1 - x0)         // ranges always visible
            let rect = CGRect(x: x0, y: 0, width: rectWidth, height: heightF)
            let alpha = severityAlpha(entry.severity, base: 0.55) * dispositionDimmer(entry.dispositionState)
            ctx.fill(
                Path(rect),
                with: .color(lane.color.opacity(alpha))
            )
            paintDispositionAccent(entry: entry, rect: rect, in: ctx)
        }

        // Points: 3-pt-wide vertical ticks.
        let pointWidth: CGFloat = 3
        for entry in lane.entries where entry.kind == .point {
            let x = CGFloat(max(0.0, min(1.0, Double(entry.start) / total))) * widthF
            let rect = CGRect(x: x - pointWidth * 0.5, y: 0, width: pointWidth, height: heightF)
            let alpha = severityAlpha(entry.severity, base: 0.85) * dispositionDimmer(entry.dispositionState)
            ctx.fill(
                Path(rect),
                with: .color(lane.color.opacity(alpha))
            )
            paintDispositionAccent(entry: entry, rect: rect, in: ctx)
        }
    }

    /// Confirmed entries get a small green ring; dismissed entries are
    /// already dimmed via `dispositionDimmer` so no extra paint is needed.
    private func paintDispositionAccent(entry: LaneEntry, rect: CGRect, in ctx: GraphicsContext) {
        guard entry.dispositionState == .confirmed else { return }
        let outline = rect.insetBy(dx: -1.5, dy: -1.5)
        ctx.stroke(
            Path(roundedRect: outline, cornerRadius: 2),
            with: .color(.green.opacity(0.85)),
            lineWidth: 1.2
        )
    }

    private func dispositionDimmer(_ state: AnnotationDisposition.State?) -> Double {
        switch state {
        case .dismissed: return 0.30
        case .confirmed: return 1.0
        case nil:        return 1.0
        }
    }

    private func severityAlpha(_ severity: Annotation.Severity, base: Double) -> Double {
        let bump: Double
        switch severity {
        case .info:     bump = 0.0
        case .notice:   bump = 0.10
        case .warning:  bump = 0.20
        case .critical: bump = 0.35
        }
        return min(1.0, base + bump)
    }

    private func jump(toFraction fraction: Double) {
        if let onJump {
            onJump(fraction)
        } else {
            viewport.animateJump(toFraction: fraction)
        }
    }

    // MARK: - Lane derivation

    /// Visible lanes — one per surviving category, sorted by max severity
    /// descending and count descending, matching the summary chip order.
    private var lanes: [Lane] {
        guard !annotations.isEmpty, totalSamples > 0 else { return [] }

        var buckets: [String: LaneBuilder] = [:]
        for ann in annotations {
            var builder = buckets[ann.category] ?? LaneBuilder(
                category: ann.category,
                color: CategoryPalette.swiftUIColor(for: ann.category)
            )
            builder.append(ann, dispositionState: dispositionsByID[ann.id]?.state)
            buckets[ann.category] = builder
        }
        return buckets.values
            .map(\.lane)
            .sorted { lhs, rhs in
                if lhs.maxSeverity != rhs.maxSeverity {
                    return lhs.maxSeverity > rhs.maxSeverity
                }
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return lhs.category < rhs.category
            }
    }

    // MARK: - Internal types

    struct Lane: Identifiable, Equatable {
        let category: String
        let color: Color
        let count: Int
        let maxSeverity: Annotation.Severity
        let entries: [LaneEntry]
        var id: String { category }
    }

    struct LaneEntry: Equatable {
        let start: Int64
        let end: Int64
        let kind: Annotation.Kind
        let severity: Annotation.Severity
        let dispositionState: AnnotationDisposition.State?
    }

    private struct LaneBuilder {
        let category: String
        let color: Color
        var entries: [LaneEntry] = []
        var maxSeverity: Annotation.Severity = .info

        mutating func append(_ ann: Annotation, dispositionState: AnnotationDisposition.State?) {
            entries.append(
                LaneEntry(
                    start: ann.sampleIndex,
                    end: ann.renderEndSample,
                    kind: ann.kind,
                    severity: ann.severity,
                    dispositionState: dispositionState
                )
            )
            if ann.severity > maxSeverity { maxSeverity = ann.severity }
        }

        var lane: Lane {
            Lane(
                category: category,
                color: color,
                count: entries.count,
                maxSeverity: maxSeverity,
                entries: entries
            )
        }
    }
}
