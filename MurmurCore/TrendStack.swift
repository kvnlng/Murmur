//
//  TrendStack.swift
//  MurmurCore
//
//  The context column's trend lanes, on ONE shared time axis (X74).
//
//  Before this, each lane carried its own axis and its own time domain, and
//  two of them (RMSSD, HR) were scoped to the current viewport while the
//  interval trend spanned the record. So three lanes stacked vertically were
//  three different x-axes, and a feature at the same horizontal position in
//  two of them was at two different times. That is worse than no alignment,
//  because it looks like alignment.
//
//  One axis, one window box drawn once across every lane, one set of
//  low-quality stretches shaded through all of them. The analyst can now read
//  down a column and be reading one instant.
//
//  ## What this owns and what it does not
//
//  This owns GEOMETRY: the label / plot / value row anatomy, the shared
//  domain, and the three things drawn across the whole plot column (window
//  box, quality shading, axis). Each lane supplies only its plot, rendered
//  into a frame whose x-mapping is already decided.
//
//  It owns no arithmetic about measurements. The lanes still compute their
//  own values, and the caption still travels from whoever produced the
//  numbers — provenance is part of the design, not decoration, and is not
//  trimmed to save space.
//

import AppKit
import Charts
import SwiftUI

/// The stack's y-scale, drawn in the reserved gutter by a lane that is not a
/// Swift Charts view.
///
/// Charts lanes get the same gutter from `trendLaneYAxis()`. This is for the
/// `Canvas` lanes, which reserved nothing before #210 — which is why the HR
/// lane, alone among the trends, carried no scale at all. Height is what
/// decided whether a lane got a usable scale, and that was not a decision
/// anyone made.
struct TrendLaneScaleGutter: View {
    /// Ticks as `(fraction, label)`, fraction 0 at the bottom of the plot.
    let ticks: [(fraction: Double, label: String)]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                Text(tick.label)
                    .font(.caption2.monospacedDigit())
                    // Charts renders its own labels at secondary; a gutter
                    // that differed by lane would read as two kinds of scale.
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: TrendStack.axisLabelWidth, alignment: .trailing)
                    // Centred ON the value, the way Charts places its labels,
                    // then held inside the lane so the top tick of a 22 pt
                    // lane doesn't ride out of its own row.
                    .position(
                        x: TrendStack.axisLabelWidth / 2,
                        y: min(max(6, (1 - tick.fraction) * geo.size.height), geo.size.height - 6))
            }
        }
        .frame(width: TrendStack.axisGutter)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The stack's y-axis for a Swift Charts lane: three ticks in a gutter
    /// exactly `TrendStack.axisGutter` wide, so the lane's data starts where
    /// every other lane's does.
    ///
    /// The fixed-width label box is the whole point — left to size itself,
    /// Charts reserves whatever the widest label happens to need, so the plot
    /// origin became a function of the DATA. Two lanes with different
    /// magnitudes then disagreed about where time zero is.
    /// `desiredCount` exists for the short lanes: three ticks in a 46 pt row
    /// collide, which is how X92's LF/HF scale ended up unreadable.
    func trendLaneYAxis(decimals: Int = 0, desiredCount: Int = 3) -> some View {
        chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: desiredCount)) { value in
                AxisValueLabel(horizontalSpacing: TrendStack.axisLabelSpacing) {
                    Text(value.as(Double.self).map { String(format: "%.\(decimals)f", $0) } ?? "")
                        .font(.caption2.monospacedDigit())
                        .frame(width: TrendStack.axisLabelWidth, alignment: .trailing)
                }
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
            }
        }
    }
}

/// One row of the stack.
struct TrendStackLane: Identifiable {
    let id: String
    /// Row title, e.g. `Trends · HR`.
    let title: String
    /// Units and cadence, e.g. `bpm · trend channel only`.
    let subtitle: String
    /// The lane's current reading, right-aligned. Nil renders an em dash —
    /// a lane with no value is still a lane, and a blank cell reads as a
    /// layout bug rather than as "no reading here".
    let value: String?
    /// The reading's unit, drawn under the value in the 13a value column
    /// (`412` over `ms`). Separate from `value` so the value string stays
    /// exactly the number — the UI tests assert the rendered `1.50`/`75.0`
    /// verbatim, and folding the unit in would break that contract.
    let unit: String?
    /// The lane's 4 pt accent rail (13a). One hue per metric family, sampled
    /// from the handoff wireframe — see the palette extension below.
    let accent: Color
    /// Row height. Lanes differ: a heat band needs far less than an envelope.
    /// `nil` sizes the row to its content — for the caller-supplied lanes
    /// (RMSSD, interval trend) whose cells carry their own headers, chips and
    /// captions. X74 gave those fixed 54/66 pt rows, which LOOKED right on
    /// the unentitled fixture where both lanes are absent — on an entitled
    /// record the cells are several times taller and overflowed straight
    /// through the lanes beneath (found in X76's real-record pass).
    let height: CGFloat?
    /// Whether a click on this lane's plot should seek the viewport. Only
    /// lanes whose plots are inert opt in — the RMSSD and interval lanes
    /// carry their own hover, chips, and bin-click drilldown, and a stack
    /// gesture layered over those would swallow them.
    let seekable: Bool
    /// The plot, and only the plot. Anything the lane draws here is mapped
    /// against the stack's shared domain.
    let plot: AnyView

    init(
        id: String,
        title: String,
        subtitle: String,
        value: String? = nil,
        unit: String? = nil,
        height: CGFloat? = nil,
        seekable: Bool = false,
        accent: Color = Color.secondary.opacity(0.35),
        @ViewBuilder plot: () -> some View
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.unit = unit
        self.height = height
        self.seekable = seekable
        self.accent = accent
        self.plot = AnyView(plot())
    }
}

/// The 13a lane accent rails, sampled from the handoff wireframe
/// (docs/design/2026-08-15-main-window). One hue per metric family, so the
/// two HR lanes share green and any future variability lane shares blue.
/// Deliberately muted — the rail is a family badge, not a data encoding,
/// and the fiducial-tag palette (#249) must stay the louder one.
extension TrendStackLane {
    /// #7D9C86 — both HR lanes (trend channel and beat-derived).
    static let hrAccent = Color(red: 125 / 255, green: 156 / 255, blue: 134 / 255)
    /// #6B8BA8 — rolling variability (RMSSD).
    static let variabilityAccent = Color(red: 107 / 255, green: 139 / 255, blue: 168 / 255)
    /// #4F6F8C — the binned interval trend.
    static let intervalAccent = Color(red: 79 / 255, green: 111 / 255, blue: 140 / 255)
    /// #B58A4E — rolling LF/HF.
    static let lfhfAccent = Color(red: 181 / 255, green: 138 / 255, blue: 78 / 255)
    /// #9AA3AD — the quality heat band.
    static let qualityAccent = Color(red: 154 / 255, green: 163 / 255, blue: 173 / 255)
}

/// One legend entry: a small swatch drawn in the mark's own vocabulary,
/// then its name. The 13a legend names MARK TYPES, not lanes — the lane
/// labels already name the lanes, and a legend that repeated them would
/// be the #209 duplication again one row lower.
struct TrendStackLegendEntry: Identifiable {
    enum Swatch {
        /// Filled p25–p75 ribbon.
        case ribbon
        /// Dashed p5/p95 outline.
        case dashed
        /// Solid median polyline.
        case line
        /// Bin-median dot.
        case dot
        /// Thick IQR segment.
        case thickBar
        /// Thin full-range segment.
        case thinBar
        /// Excluded-bin stub.
        case stub
        /// Cross-lane low-quality shading.
        case shading
    }

    let swatch: Swatch
    let label: String
    var id: String { label }
}

/// Leading-aligned wrapping row for the legend. Exists because the
/// legend must stay width-compliant: the stack answers every width
/// proposal with exactly that width (`stackIsNotGreedyHorizontally`),
/// and a fixed HStack of ~8 chips would put a ~700 pt floor under the
/// whole card — X97's split-view overflow again, via the legend.
struct TrendLegendFlow: Layout {
    var hSpacing: CGFloat = 12
    var vSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + hSpacing
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + hSpacing
        }
    }
}

struct TrendStack: View {
    let lanes: [TrendStackLane]
    /// The shared domain, in seconds from the recording start. Every lane's
    /// plot is drawn against this and nothing else.
    let recordingRange: ClosedRange<Double>
    /// The current viewport, drawn as one box spanning every lane.
    let viewportRange: ClosedRange<Double>
    /// Stretches to shade through all lanes, so the analyst can see which
    /// parts of EVERY trend to distrust rather than checking one lane for it.
    var lowQualitySpans: [ClosedRange<Double>] = []
    /// Provenance. Not trimmable — see the policy note in DECISIONS.
    var caption: String?
    /// Interaction hint, kept separate from provenance so the two can be
    /// styled differently without splitting the caption string.
    var hint: String?
    /// The 13a legend row (#261). Supplied by the assembler, because the
    /// stack cannot infer mark types from `AnyView` plots — only the code
    /// that chose the lanes knows which mark vocabulary is on screen.
    /// Empty renders no row.
    var legend: [TrendStackLegendEntry] = []
    var onSeek: ((Double) -> Void)?
    /// ⌥drag on a seekable lane zooms the viewport to the dragged range
    /// (13a / handoff README: "⌥drag on a band or lane zooms to the
    /// dragged range"). Nil disables the gesture; plain clicks still seek.
    var onZoomRange: ((ClosedRange<Double>) -> Void)?

    // 13a lane-row grid: [4 pt accent rail | 114 pt label | y-gutter | plot |
    // 66 pt value]. The wireframe's y-gutter is 30 pt; ours stays `axisGutter`
    // (45 pt) because that number is measured off what Swift Charts actually
    // reserves (see the contract below) — the design drew a narrower gutter
    // than Charts will honor, raised on #261 rather than silently adopted.
    static let railWidth: CGFloat = 4
    static let labelWidth: CGFloat = 114
    static let valueWidth: CGFloat = 66
    private static let axisHeight: CGFloat = 16

    // MARK: - The plot-geometry contract (#210)
    //
    // Every lane gets an identical plot cell — and until this, what each lane
    // did INSIDE that cell differed. The Swift Charts lanes let Charts reserve
    // a leading gutter for their y-labels, so their data began ~35 pt in and
    // (for the RMSSD lane, which also carried horizontal padding) ended ~12 pt
    // early. The `Canvas` lanes drew from the cell's left edge. Measured on a
    // 700 pt cell: HR 0…698, LF/HF 35…699, RMSSD 45…687.
    //
    // So four lanes stacked on "one axis" had three different x-mappings, and
    // the shared window box — deliberately drawn once — landed on the RMSSD
    // lane's y-labels rather than on its data. On a 25 h record the ~30 pt
    // offset is about 50 minutes of misreading.
    //
    // The contract: a lane's DATA occupies its cell inset by `axisGutter` on
    // the leading edge and by nothing on the trailing edge. Charts lanes hit it
    // via `trendLaneYAxis()`; `Canvas` lanes via `TrendLaneScaleGutter`. The
    // overlay and the axis row map to the same origin, so there is one mapping
    // and no way for a lane to hold a private one.

    /// Leading strip of every plot cell, reserved for the lane's y-scale.
    /// `nonisolated`: immutable and Sendable, and `optionDragRange` — a
    /// pure function tests call off the main actor — depends on it.
    nonisolated static let axisGutter: CGFloat = 45
    /// The label box inside that gutter. Four monospaced digits at
    /// `.caption2` — the interval lane plots RR in ms and reaches four
    /// figures, and a label box that clips is a scale that lies.
    static let axisLabelWidth: CGFloat = 26
    /// Gap between the label box and the data.
    static let axisLabelSpacing: CGFloat = 4
    /// What Swift Charts adds on top of label + spacing when it reserves a
    /// leading axis. Measured, not documented: label boxes of 20/28/28/40 pt
    /// at spacings of 4/4/10/4 put the data at 40/47/53/59 pt, i.e. a fixed
    /// 15 pt. `TrendStackGeometryTests` fails if a future Charts changes it.
    static let chartsAxisPadding: CGFloat = 15

    /// Where every lane's data starts, measured from the card's leading edge:
    /// the accent rail, then the label column, then the y-scale gutter.
    static var plotOriginX: CGFloat { railWidth + labelWidth + axisGutter }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                // Enumerated for the 13a zebra striping — every OTHER row gets
                // a whisper of fill, so adjacent lanes read as separate rows
                // even where their plots are visually quiet (the TestFlight
                // "tiny space between lanes" complaint behind #261).
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    laneRow(lane)
                        .background(index.isMultiple(of: 2)
                                    ? Color.clear : Color.secondary.opacity(0.04))
                    if lane.id != lanes.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            // Drawn ONCE, over every lane. A per-lane box would be four
            // boxes that agree only as long as four separate mappings do.
            //
            // `.overlay` rather than a `ZStack` sibling (#215): the overlay is
            // a `GeometryReader`, which has no intrinsic size and so accepts
            // whatever it is proposed. As a `ZStack` child it therefore VOTED
            // for the full proposal and the stack sized to it — offered 4000 pt
            // the card demanded 4000, against 309 pt of actual lanes. An
            // overlay is sized BY the view it decorates instead of voting on
            // that view's size, which is what "drawn across the lanes" means.
            .overlay { crossLaneOverlay }
            axisRow
            if !legend.isEmpty {
                legendRow
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .accessibilityIdentifier("trend-stack-caption")
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trend-stack")
    }

    @ViewBuilder
    private func laneRow(_ lane: TrendStackLane) -> some View {
        // A declared height is a FLOOR for the plot, not a ceiling for the
        // rail (#218).
        //
        // It used to be a hard `.frame(height:)`, which made the number a
        // claim the rail could not contradict. The quality lane declares 22 pt
        // — right for a thin heat band — while its rail (title over a wrapped
        // subtitle) wants 40, so it overflowed its row by 18 pt for as long as
        // it has existed. Nothing visibly broke only because it is the LAST
        // lane and the spill landed in the axis row's empty left gutter; a
        // lane added beneath it would have been crowded, which is #216 again.
        //
        // `minHeight` lets the row take what its own rail needs and keeps the
        // declared height as the plot's floor. That costs vertical space, and
        // before #220 that was the objection — it is why this shipped as a
        // decision rather than a fix. With the column scrolling, a taller
        // stack costs a scroll instead of a surface, so the general answer is
        // now also the cheap one.
        //
        // The rail is what may grow the row; the PLOT still may not, or a
        // Charts lane with no intrinsic height would size the row to whatever
        // it felt like. Hence the explicit ceiling on the cell in
        // `laneRowContent` — the two halves are a pair.
        Group {
            if let height = lane.height {
                laneRowContent(lane)
                    .frame(minHeight: height)
            } else {
                laneRowContent(lane)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // The 13a accent rail. An overlay, not an HStack child: an overlay is
        // sized BY the row, so the rail spans exactly the row's height —
        // including any growth the rail column above won — without voting on
        // that height the way a greedy `Color` child would under `fixedSize`.
        .overlay(alignment: .leading) {
            lane.accent.frame(width: Self.railWidth)
        }
    }

    private func laneRowContent(_ lane: TrendStackLane) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(lane.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(lane.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // Three lines, not two: the 13a label column is 114 pt
                    // where the old one was 150, and the provenance subtitles
                    // (estimator · window · step) are not trimmable — cutting
                    // provenance to fit a column is the one trade DECISIONS
                    // forbids. The taller 13a rows carry the extra line.
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .frame(width: Self.labelWidth, alignment: .topLeading)
            .padding(.leading, Self.railWidth)

            lane.plot
                // `minWidth: 0` is load-bearing (X97). With only `maxWidth`
                // set, a frame's MINIMUM follows its child — and the interval
                // lane's chips row (six .fixedSize() controls) has a ~520 pt
                // floor. That floor propagated up through the vertical
                // ScrollView into the split view's detail-minimum, and below
                // ~1115 pt of window the whole bedside column overflowed the
                // window at both edges, clipping the pinned stage. A
                // width-compliant slot keeps the column honest; a chips row
                // too wide for a pathologically narrow cell clips inside its
                // own row instead of shoving the primary surface off-screen.
                // Leading-aligned so a too-wide cell loses its TRAILING edge
                // only — clipping the leading edge would take the metric name
                // and the caption's start, which are the parts that identify
                // what the lane is.
                // The height half is #218's other pair-piece. A fixed-height
                // lane's plot is pinned to EXACTLY the declared height rather
                // than allowed to fill the row: with the row now free to grow
                // for its rail, a Charts lane — which has no intrinsic height
                // and accepts whatever it is proposed — would otherwise be the
                // thing that decided how tall the row was. The rail may grow
                // the row; the plot may not.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .frame(height: lane.height)
                .clipped()
                .overlay {
                    // The seek surface lives on the lane's plot cell, not on
                    // the cross-lane overlay: the cell's own geometry IS the
                    // shared x-mapping, so the click math here cannot drift
                    // from what was drawn — as long as it subtracts the same
                    // gutter the data was inset by (#210).
                    if lane.seekable, onSeek != nil || onZoomRange != nil {
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            // ⌥drag zooms to the dragged range
                                            // (13a). The modifier is read at
                                            // gesture END, matching how the
                                            // analyst decides: press ⌥, sweep,
                                            // release. A too-short ⌥drag falls
                                            // through to seek — a wobbly
                                            // ⌥click must not zoom to a
                                            // 4-point sliver.
                                            if let onZoomRange,
                                               NSEvent.modifierFlags.contains(.option),
                                               let range = Self.optionDragRange(
                                                   startX: value.startLocation.x,
                                                   endX: value.location.x,
                                                   plotCellWidth: geo.size.width,
                                                   recordingRange: recordingRange
                                               ) {
                                                onZoomRange(range)
                                            } else if let onSeek {
                                                let plotWidth = geo.size.width - Self.axisGutter
                                                guard plotWidth > 0 else { return }
                                                let f = min(1, max(0, (value.location.x - Self.axisGutter) / plotWidth))
                                                onSeek(recordingRange.lowerBound
                                                       + Double(f) * (recordingRange.upperBound - recordingRange.lowerBound))
                                            }
                                        }
                                )
                        }
                    }
                }

            // 13a value column: the reading over its unit, so the number is
            // scannable down the column without each lane restating its unit
            // inline. The value Text carries ONLY the number — the trend UI
            // tests assert the rendered `1.50`/`75.0` strings verbatim.
            VStack(alignment: .trailing, spacing: 1) {
                Text(lane.value ?? "—")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(lane.value == nil ? .tertiary : .primary)
                if lane.value != nil, let unit = lane.unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 7)
            .frame(width: Self.valueWidth, alignment: .topTrailing)
            .padding(.trailing, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trend-lane-\(lane.id)")
    }

    /// Window box + low-quality shading, spanning the plot column across every
    /// lane at once.
    private var crossLaneOverlay: some View {
        GeometryReader { geo in
            let plotX = Self.plotOriginX
            let plotWidth = max(0, geo.size.width - plotX - Self.valueWidth - 10)
            ZStack(alignment: .topLeading) {
                ForEach(Array(lowQualitySpans.enumerated()), id: \.offset) { _, span in
                    let x0 = fraction(span.lowerBound) * plotWidth
                    let x1 = fraction(span.upperBound) * plotWidth
                    Rectangle()
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: max(1, x1 - x0), height: geo.size.height)
                        .offset(x: plotX + x0)
                }
                // A zero-span domain has no meaningful window — the idle
                // launch stack (#285) passes `0...0`, and the box would
                // otherwise render as a stray 2 pt sliver at the plot origin.
                if recordingRange.upperBound > recordingRange.lowerBound {
                    windowBox(plotX: plotX, plotWidth: plotWidth, height: geo.size.height)
                }
            }
        }
        // Purely visual, and now emphatically so: as an overlay (#215) this
        // layer covers the lanes EXACTLY, where as a `ZStack` sibling its
        // layout frame only spanned its widest child. The seek gesture lives
        // on each seekable lane's plot cell instead — this sits over ALL
        // lanes, including the two whose plots carry their own hover, chips,
        // and bin-click drilldown, and a gesture here would swallow those.
        .allowsHitTesting(false)
    }

    private func windowBox(plotX: CGFloat, plotWidth: CGFloat, height: CGFloat) -> some View {
        let x0 = fraction(viewportRange.lowerBound) * plotWidth
        let x1 = fraction(viewportRange.upperBound) * plotWidth
        // Floored to a visible width. Against a 25-hour axis a 10-second
        // window is 0.01% — sub-pixel, i.e. the box vanishes at exactly the
        // zoom where "where am I" is hardest to answer.
        let width = max(2, x1 - x0)
        return RoundedRectangle(cornerRadius: 2)
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.10)))
            .frame(width: width, height: height)
            .offset(x: plotX + min(max(0, x0), max(0, plotWidth - width)))
            .allowsHitTesting(false)
    }

    /// The 13a legend row: mark-type swatches with names, wrapping at
    /// narrow widths rather than putting a floor under the card.
    private var legendRow: some View {
        TrendLegendFlow(hSpacing: 12, vSpacing: 3) {
            ForEach(legend) { entry in
                HStack(spacing: 4) {
                    swatch(entry.swatch)
                    Text(entry.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trend-stack-legend")
    }

    /// Each swatch is drawn in the mark's own vocabulary at caption
    /// scale, so the legend teaches the eye the exact shape it will
    /// find in the lanes rather than a generic color chip.
    @ViewBuilder
    private func swatch(_ kind: TrendStackLegendEntry.Swatch) -> some View {
        switch kind {
        case .ribbon:
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 14, height: 7)
        case .dashed:
            Canvas { ctx, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(path, with: .color(.accentColor.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(width: 14, height: 7)
        case .line:
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 1.5)
        case .dot:
            Circle()
                .fill(Color.primary)
                .frame(width: 4, height: 4)
        case .thickBar:
            Capsule()
                .fill(Color.primary.opacity(0.65))
                .frame(width: 3, height: 10)
        case .thinBar:
            Rectangle()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 1, height: 12)
        case .stub:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 3)
            }
            .frame(width: 8, height: 10)
        case .shading:
            Rectangle()
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 10, height: 10)
        }
    }

    private var axisRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.plotOriginX)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(axisTicks.enumerated()), id: \.offset) { _, tick in
                        Text(tick.label)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .offset(x: fraction(tick.seconds) * geo.size.width - 18)
                    }
                }
            }
            Color.clear.frame(width: Self.valueWidth + 10)
        }
        // Height on the ROW, not on the GeometryReader alone (#215). The two
        // `Color.clear` spacers are the stack's other greedy child: given a
        // width and no height they still accept whatever height they are
        // proposed, so the axis row — and the whole card with it — sized to
        // the container rather than to the 16 pt of axis it draws. Measured
        // before the fix: offered 700 pt a single-lane stack demanded 700.
        .frame(height: Self.axisHeight)
        .padding(.bottom, 2)
        .accessibilityHidden(true)
    }

    /// Five ticks across the span. Deliberately coarse: this axis labels a
    /// whole recording, and a dense ruler at that scale is noise the eye has
    /// to filter before it can use the shape above it.
    private var axisTicks: [(seconds: Double, label: String)] {
        let span = recordingRange.upperBound - recordingRange.lowerBound
        guard span > 0 else { return [] }
        return (0...4).map { i in
            let t = recordingRange.lowerBound + span * Double(i) / 4
            return (t, ViewportTimeFormat.elapsed(t, tenths: false))
        }
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        let span = recordingRange.upperBound - recordingRange.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(1, max(0, (seconds - recordingRange.lowerBound) / span)))
    }

    /// Pure mapping for the ⌥drag zoom: cell-local drag endpoints → the
    /// time range to zoom to, or nil when the drag is too short to be a
    /// deliberate sweep (< 4 pt — a wobbly ⌥click stays a seek). Uses
    /// the same gutter subtraction as the seek path, so the zoomed range
    /// is exactly the stretch of DATA the analyst swept, direction-
    /// agnostic. `nonisolated` + static so tests exercise the math
    /// without a gesture.
    nonisolated static func optionDragRange(
        startX: CGFloat,
        endX: CGFloat,
        plotCellWidth: CGFloat,
        recordingRange: ClosedRange<Double>
    ) -> ClosedRange<Double>? {
        let plotWidth = plotCellWidth - axisGutter
        guard plotWidth > 0, abs(endX - startX) >= 4 else { return nil }
        func time(atX x: CGFloat) -> Double {
            let f = min(1, max(0, (x - axisGutter) / plotWidth))
            return recordingRange.lowerBound
                + Double(f) * (recordingRange.upperBound - recordingRange.lowerBound)
        }
        let a = time(atX: startX)
        let b = time(atX: endX)
        guard a != b else { return nil }
        return min(a, b)...max(a, b)
    }
}
