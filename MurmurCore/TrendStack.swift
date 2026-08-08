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

import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
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
                crossLaneOverlay
            }
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
        // Fixed-height lanes pin the row; natural lanes size to their cell,
        // whose content (headers, chips, captions) defines the height.
        if let height = lane.height {
            laneRowContent(lane)
                .frame(height: height)
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
                .frame(maxWidth: .infinity, maxHeight: lane.height == nil ? nil : .infinity)
                .overlay {
                    // The seek surface lives on the lane's plot cell, not on
                    // the cross-lane overlay: the cell's own geometry IS the
                    // shared x-mapping (every plot fills it edge-to-edge), so
                    // the click math here cannot drift from what was drawn.
                    if lane.seekable, let onSeek {
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            guard geo.size.width > 0 else { return }
                                            let f = min(1, max(0, value.location.x / geo.size.width))
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
            let plotX = Self.labelWidth + 10
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
        // Purely visual. The seek gesture lives on each seekable lane's plot
        // cell instead — this layer sits over ALL lanes, including the two
        // whose plots carry their own hover, chips, and bin-click drilldown,
        // and a gesture here would swallow those. (Its layout frame also only
        // spans its widest child, not the plot column, so a gesture here was
        // never hittable where the lanes actually are.)
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
            Color.clear.frame(width: Self.labelWidth + 10)
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
            .frame(height: Self.axisHeight)
            Color.clear.frame(width: Self.valueWidth + 10)
        }
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
