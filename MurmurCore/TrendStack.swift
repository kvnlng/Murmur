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
        height: CGFloat? = nil,
        seekable: Bool = false,
        @ViewBuilder plot: () -> some View
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.height = height
        self.seekable = seekable
        self.plot = AnyView(plot())
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
    var onSeek: ((Double) -> Void)?

    static let labelWidth: CGFloat = 150
    static let valueWidth: CGFloat = 52
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
    static let axisGutter: CGFloat = 45
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

    /// Where every lane's data starts, measured from the card's leading edge.
    static var plotOriginX: CGFloat { labelWidth + 10 + axisGutter }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(lanes) { lane in
                    laneRow(lane)
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
        if let height = lane.height {
            laneRowContent(lane)
                .frame(minHeight: height)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            laneRowContent(lane)
                .fixedSize(horizontal: false, vertical: true)
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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.labelWidth, alignment: .leading)
            .padding(.leading, 10)

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
                    if lane.seekable, let onSeek {
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            let plotWidth = geo.size.width - Self.axisGutter
                                            guard plotWidth > 0 else { return }
                                            let f = min(1, max(0, (value.location.x - Self.axisGutter) / plotWidth))
                                            onSeek(recordingRange.lowerBound
                                                   + Double(f) * (recordingRange.upperBound - recordingRange.lowerBound))
                                        }
                                )
                        }
                    }
                }

            Text(lane.value ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(lane.value == nil ? .tertiary : .primary)
                .frame(width: Self.valueWidth, alignment: .trailing)
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
                windowBox(plotX: plotX, plotWidth: plotWidth, height: geo.size.height)
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
}
