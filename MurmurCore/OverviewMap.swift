//
//  OverviewMap.swift
//  MurmurCore
//
//  The pinned-stage "one map" — a merged whole-recording locator + finding
//  density strip that replaces the old two-widget setup (`OverviewRibbon`
//  envelope-under-canvas + `FindingDensityTimeline` per-category lanes).
//  The rationale is in `project_findings_review_queue_design.md`: the two
//  widgets were doing overlapping jobs, so the analyst was scanning two
//  places for one question. Now: one compact density strip with the current
//  viewport marked; expand on demand to see per-category lanes.
//
//  Compact mode is a single strip painted per-annotation at fractional
//  position (color = CategoryPalette). The viewport indicator sits on top.
//  Click / drag the strip to scrub the shared viewport.
//
//  Expanded mode adds one lane per surviving category beneath the strip,
//  preserving the tap-to-jump behavior the FindingDensityTimeline used to
//  provide (and the `density-lane-<category>` accessibility ids that UI
//  tests depend on).
//

import SwiftUI

struct OverviewMap: View {
    /// Filter-aware annotations — the map mirrors whatever the review
    /// queue has narrowed the recording to.
    let annotations: [Annotation]
    let totalSamples: Int64
    let sampleRate: Double
    let viewport: RecordingViewport
    /// The lead the pinned trace is showing, used only to preserve the
    /// legacy `overview-ribbon-<name>` accessibility id so UI tests
    /// that scrub the overview continue to resolve.
    let channelName: String
    /// Optional disposition state per annotation — powers the confirmed-
    /// ring / dismissed-dim treatment used in the expanded per-category
    /// lanes. Empty when disposition state isn't wired through yet.
    var dispositionsByID: [UUID: AnnotationDisposition] = [:]
    /// VT/VF model candidate episodes (range annotations) to mark on the
    /// locator strip so "where is the VT" is answerable at a glance on a
    /// long recording. Drawn in NEUTRAL ink (RUO) — the strip locates, the
    /// queue triages. Empty when no scan has been applied.
    var candidates: [Annotation] = []
    /// X72 — anchored-note anchors, drawn as accent ticks along the strip's
    /// bottom edge (the design's second tick layer). Purely a locator: the
    /// strip's existing scrub gesture already moves the trace there, and the
    /// drawer's list is where a note is *selected*.
    var noteAnchors: [ClosedRange<Int64>] = []

    @State private var isExpanded: Bool = false

    private static let stripHeight: CGFloat = 34
    private static let laneHeight: CGFloat = 14
    private static let minTickPx: CGFloat = 2
    private static let minIndicatorPx: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            stripArea
            axisRow
            if isExpanded {
                perCategoryLanes
            }
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-map")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // X51 §5: "one map" was the 2026-07-04 merge rationale leaking into
            // the caption; "Overview" alone is sufficient.
            Text("Overview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text(isExpanded ? "collapse" : "expand to per-category lanes")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview-map-expand-toggle")
        }
    }

    // MARK: - Compact strip

    private var stripArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.10))
                densityTicks(width: geo.size.width, height: geo.size.height)
                candidateBands(width: geo.size.width, height: geo.size.height)
                noteTicks(width: geo.size.width, height: geo.size.height)
                viewportIndicator(width: geo.size.width, height: geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geo.size.width))
        }
        .frame(height: Self.stripHeight)
        // Preserve the legacy id so UI tests that scrub the overview
        // still resolve on the new component.
        .accessibilityIdentifier("overview-ribbon-\(channelName)")
    }

    /// Colored ticks per annotation. Points are pinned at `minTickPx`;
    /// ranges keep their proportional width once they exceed it.
    private func densityTicks(width: CGFloat, height: CGFloat) -> some View {
        let total = Double(totalSamples)
        guard total > 0, !annotations.isEmpty else {
            return AnyView(EmptyView())
        }
        return AnyView(
            Canvas { ctx, size in
                for ann in annotations {
                    let start = Double(ann.sampleIndex)
                    let endSample = Double(ann.renderEndSample)
                    let x0 = CGFloat(max(0.0, min(1.0, start / total))) * size.width
                    let x1 = CGFloat(max(0.0, min(1.0, endSample / total))) * size.width
                    let widthPx = max(Self.minTickPx, x1 - x0)
                    let rect = CGRect(x: x0, y: 0, width: widthPx, height: size.height)
                    let color = CategoryPalette.swiftUIColor(for: ann.category)
                    let baseAlpha: Double = ann.kind == .point ? 0.75 : 0.45
                    let alpha = baseAlpha * dispositionDimmer(
                        dispositionsByID[ann.id]?.state
                    )
                    ctx.fill(Path(rect), with: .color(color.opacity(alpha)))
                }
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
        )
    }

    /// Neutral-ink bands marking VT/VF candidate episodes on the locator
    /// strip, each with a bolder top edge so a narrow episode still reads on
    /// a multi-hour recording. Model output stays neutral (RUO); the queue
    /// owns triage colour.
    private func candidateBands(width: CGFloat, height: CGFloat) -> some View {
        let total = Double(totalSamples)
        guard total > 0, !candidates.isEmpty else {
            return AnyView(EmptyView())
        }
        return AnyView(
            Canvas { ctx, size in
                for candidate in candidates {
                    let x0 = CGFloat(max(0.0, min(1.0, Double(candidate.sampleIndex) / total))) * size.width
                    let x1 = CGFloat(max(0.0, min(1.0, Double(candidate.renderEndSample) / total))) * size.width
                    let widthPx = max(3, x1 - x0)
                    let band = CGRect(x: x0, y: 0, width: widthPx, height: size.height)
                    ctx.fill(Path(band), with: .color(Color.secondary.opacity(0.28)))
                    let topEdge = CGRect(x: x0, y: 0, width: widthPx, height: 3)
                    ctx.fill(Path(topEdge), with: .color(Color.secondary.opacity(0.9)))
                }
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
        )
    }

    /// X72 — note ticks on the bottom edge, in accent ink so they read as
    /// the analyst's own marks against the neutral candidate bands and the
    /// category-coloured density above.
    private func noteTicks(width: CGFloat, height: CGFloat) -> some View {
        let total = Double(totalSamples)
        guard total > 0, !noteAnchors.isEmpty else {
            return AnyView(EmptyView())
        }
        let tickHeight: CGFloat = 4
        return AnyView(
            Canvas { ctx, size in
                for anchor in noteAnchors {
                    let x0 = CGFloat(max(0.0, min(1.0, Double(anchor.lowerBound) / total))) * size.width
                    let x1 = CGFloat(max(0.0, min(1.0, Double(anchor.upperBound) / total))) * size.width
                    let rect = CGRect(
                        x: x0,
                        y: size.height - tickHeight,
                        width: max(Self.minTickPx, x1 - x0),
                        height: tickHeight
                    )
                    ctx.fill(Path(rect), with: .color(Color.accentColor.opacity(0.9)))
                }
            }
            .frame(width: width, height: height)
            .allowsHitTesting(false)
        )
    }

    private func viewportIndicator(width: CGFloat, height: CGFloat) -> some View {
        let total = Double(totalSamples)
        guard total > 0 else { return AnyView(EmptyView()) }
        let leftFrac = Double(viewport.startSample) / total
        let widthFrac = Double(viewport.endSample - viewport.startSample) / total
        let propWidth = CGFloat(widthFrac) * width
        let visibleWidth = max(Self.minIndicatorPx, propWidth)
        let centerFrac = leftFrac + widthFrac / 2
        let centerX = CGFloat(centerFrac) * width
        let leftX = max(0, min(width - visibleWidth, centerX - visibleWidth / 2))
        return AnyView(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 1.25)
                )
                .frame(width: visibleWidth, height: height)
                .offset(x: leftX)
                .allowsHitTesting(false)
        )
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                let fraction = Double(value.location.x / width)
                viewport.jump(toFraction: fraction)
            }
    }

    // MARK: - Axis row

    private var axisRow: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(ViewportTimeFormat.elapsed(0, tenths: false))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(currentWindowLabel)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                // X51 §5 / X49 §3: its two siblings (time-window-label,
                // viewport-indicator) carry ids; give the overview span one too.
                // The Text's content is already its spoken name (VoiceOver /
                // XCUI value); this only adds the addressable identifier.
                .accessibilityIdentifier("overview-window-label")
            Spacer(minLength: 0)
            Text(ViewportTimeFormat.elapsed(totalDurationSeconds, tenths: false))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: 12)
    }

    // MARK: - Expanded per-category lanes

    private var perCategoryLanes: some View {
        VStack(spacing: 2) {
            ForEach(lanes) { lane in
                laneRow(lane)
            }
        }
        // `.contain` keeps the per-lane `density-lane-<category>`
        // identifiers reachable — without it, this container's
        // identifier collapses the whole subtree and the test's
        // `density-lane-VT` wait times out.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-map-lanes")
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
            .frame(width: 96, alignment: .leading)

            lanePlot(lane)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("density-lane-\(lane.category)")
    }

    private func lanePlot(_ lane: Lane) -> some View {
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
                viewport.animateJump(toFraction: fraction)
            }
        }
        .frame(height: Self.laneHeight)
    }

    private func paint(lane: Lane, into ctx: GraphicsContext, size: CGSize) {
        guard totalSamples > 0 else { return }
        let widthF = size.width
        let heightF = size.height
        let total = Double(totalSamples)

        for entry in lane.entries where entry.kind == .range {
            let x0 = CGFloat(max(0.0, Double(entry.start) / total)) * widthF
            let endSample = Double(entry.end)
            let x1 = CGFloat(min(1.0, endSample / total)) * widthF
            let rectWidth = max(2.0, x1 - x0)
            let rect = CGRect(x: x0, y: 0, width: rectWidth, height: heightF)
            let alpha = 0.55 * dispositionDimmer(entry.dispositionState)
            ctx.fill(Path(rect), with: .color(lane.color.opacity(alpha)))
            paintConfirmedAccent(entry: entry, rect: rect, in: ctx)
        }

        let pointWidth: CGFloat = 3
        for entry in lane.entries where entry.kind == .point {
            let x = CGFloat(max(0.0, min(1.0, Double(entry.start) / total))) * widthF
            let rect = CGRect(x: x - pointWidth * 0.5, y: 0, width: pointWidth, height: heightF)
            let alpha = 0.85 * dispositionDimmer(entry.dispositionState)
            ctx.fill(Path(rect), with: .color(lane.color.opacity(alpha)))
            paintConfirmedAccent(entry: entry, rect: rect, in: ctx)
        }
    }

    private func paintConfirmedAccent(entry: LaneEntry, rect: CGRect, in ctx: GraphicsContext) {
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

    // MARK: - Lane derivation

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
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.category < rhs.category
            }
    }

    // MARK: - Duration helpers

    private var totalDurationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(totalSamples) / sampleRate
    }

    private var currentWindowLabel: String {
        guard viewport.sampleRate > 0 else { return "—" }
        let startSec = Double(viewport.startSample) / viewport.sampleRate
        let endSec   = Double(viewport.endSample)   / viewport.sampleRate
        let widthSec = endSec - startSec
        // X49: the shared m:ss.d formatter — no more adaptive decimal minutes.
        return "\(ViewportTimeFormat.elapsed(startSec))–\(ViewportTimeFormat.elapsed(endSec))"
            + "  •  \(ViewportTimeFormat.elapsed(widthSec)) window"
    }

    // MARK: - Internal types

    struct Lane: Identifiable, Equatable {
        let category: String
        let color: Color
        let count: Int
        let entries: [LaneEntry]
        var id: String { category }
    }

    struct LaneEntry: Equatable {
        let start: Int64
        let end: Int64
        let kind: Annotation.Kind
        let dispositionState: AnnotationDisposition.State?
    }

    private struct LaneBuilder {
        let category: String
        let color: Color
        var entries: [LaneEntry] = []

        mutating func append(_ ann: Annotation, dispositionState: AnnotationDisposition.State?) {
            entries.append(
                LaneEntry(
                    start: ann.sampleIndex,
                    end: ann.renderEndSample,
                    kind: ann.kind,
                    dispositionState: dispositionState
                )
            )
        }

        var lane: Lane {
            Lane(category: category, color: color, count: entries.count, entries: entries)
        }
    }
}
