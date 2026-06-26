//
//  StateBackdropStrip.swift
//  Murmur
//
//  One-row colored strip showing the patient's ventilation state minute by
//  minute, derived from the Medallion feature store's GMM probability pair:
//
//    P(spontaneous)    — patient triggering breaths (high variance) → warm color
//    P(assist-control) — machine driving breaths (low variance)     → cool color
//
//  The view auto-detects the channel pair by name (`prob_state_spontaneous`
//  + `prob_state_assist_control`), so plain ECG records simply render
//  nothing. Each minute renders as a discrete cell colored by the dominant
//  state's confidence; the cell width is proportional to the recording's
//  total duration so the strip is time-aligned with the canvas above it.
//

import SwiftUI

struct StateBackdropStrip: View {
    /// The two probability channels (spontaneous, assist-control). Either
    /// may be `nil` if the producer only emits one; the view still shows
    /// whatever it has.
    let spontaneousChannel: Channel?
    let assistControlChannel: Channel?
    let recordingDirectory: URL
    let totalSamplesPrimary: Int64
    let primarySampleRate: Double
    let viewport: RecordingViewport

    @State private var spontaneousSamples: [Float] = []
    @State private var assistSamples: [Float] = []

    private static let stripHeight: CGFloat = 14
    private static let labelWidth: CGFloat = 110

    var body: some View {
        if spontaneousChannel == nil && assistControlChannel == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                header
                row
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("state-backdrop-strip")
            .task(id: channelIDs) {
                await loadSamples()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("State")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 8) {
            legendChip(label: "spontaneous", color: spontaneousColor)
            legendChip(label: "assist-control", color: assistColor)
        }
    }

    private func legendChip(label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text("ventilation")
                .font(.caption.monospaced())
                .frame(width: Self.labelWidth, alignment: .leading)
            cellBody
        }
    }

    private var cellBody: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.10))
                if !cells.isEmpty {
                    Canvas { ctx, size in
                        for cell in cells {
                            paint(cell, in: ctx, size: size)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let fraction = max(0, min(1, Double(location.x / max(geo.size.width, 1))))
                viewport.animateJump(toFraction: fraction)
            }
        }
        .frame(height: Self.stripHeight)
    }

    // MARK: - Cell derivation

    private struct Cell {
        let startSec: Double
        let endSec: Double
        let spontaneous: Double  // 0…1, NaN if unknown
        let assist: Double       // 0…1, NaN if unknown
    }

    /// Walks the longer of the two probability channels and emits one cell
    /// per sample. Each cell is `1 / sampleRate` seconds wide.
    private var cells: [Cell] {
        let donor: Channel?
        let donorSamples: [Float]
        let otherSamples: [Float]
        if let s = spontaneousChannel {
            donor = s
            donorSamples = spontaneousSamples
            otherSamples = assistSamples
        } else if let a = assistControlChannel {
            donor = a
            donorSamples = assistSamples
            otherSamples = spontaneousSamples
        } else {
            donor = nil
            donorSamples = []
            otherSamples = []
        }
        guard let donor, !donorSamples.isEmpty else { return [] }
        let rate = donor.sampleRate
        guard rate > 0 else { return [] }
        let dt = 1.0 / rate
        var out: [Cell] = []
        out.reserveCapacity(donorSamples.count)
        for i in 0..<donorSamples.count {
            let startSec = Double(i) * dt
            let endSec   = Double(i + 1) * dt
            let spontaneous: Double
            let assist: Double
            if spontaneousChannel != nil, !spontaneousSamples.isEmpty {
                spontaneous = Double(spontaneousSamples[min(i, spontaneousSamples.count - 1)])
            } else {
                spontaneous = .nan
            }
            if assistControlChannel != nil, !assistSamples.isEmpty {
                assist = Double(assistSamples[min(i, assistSamples.count - 1)])
            } else {
                assist = .nan
            }
            // Pull the unused-sample path through `otherSamples` so the
            // compiler doesn't warn about it on records that only carry
            // one of the two probability channels.
            _ = otherSamples
            out.append(Cell(
                startSec: startSec,
                endSec: endSec,
                spontaneous: spontaneous,
                assist: assist
            ))
        }
        return out
    }

    private func paint(_ cell: Cell, in ctx: GraphicsContext, size: CGSize) {
        let totalSec = primarySampleRate > 0
            ? Double(totalSamplesPrimary) / primarySampleRate
            : max(cell.endSec, 1)
        let x0 = CGFloat(max(0.0, cell.startSec / totalSec)) * size.width
        let x1 = CGFloat(min(1.0, cell.endSec   / totalSec)) * size.width
        let width = max(1, x1 - x0)
        let color = cellColor(spontaneous: cell.spontaneous, assist: cell.assist)
        ctx.fill(
            Path(CGRect(x: x0, y: 0, width: width, height: size.height)),
            with: .color(color)
        )
    }

    /// Blends between the two state colors weighted by their probabilities.
    /// Missing values default to 0 for the missing side so a one-channel
    /// record still produces a meaningful color.
    private func cellColor(spontaneous: Double, assist: Double) -> Color {
        let sp = spontaneous.isFinite ? max(0, min(1, spontaneous)) : 0
        let ac = assist.isFinite ? max(0, min(1, assist)) : 0
        let total = sp + ac
        if total <= 0 {
            return Color.secondary.opacity(0.20)
        }
        let spWeight = sp / total
        // Mix the two named colors by probability weight; opacity stays
        // proportional to *certainty* (max of either probability).
        let mixR = (1 - spWeight) * 0.30 + spWeight * 0.95
        let mixG = (1 - spWeight) * 0.50 + spWeight * 0.55
        let mixB = (1 - spWeight) * 0.85 + spWeight * 0.25
        let opacity = 0.30 + 0.55 * max(sp, ac)
        return Color(red: mixR, green: mixG, blue: mixB).opacity(opacity)
    }

    private var spontaneousColor: Color {
        Color(red: 0.95, green: 0.55, blue: 0.25).opacity(0.85)
    }

    private var assistColor: Color {
        Color(red: 0.30, green: 0.50, blue: 0.85).opacity(0.85)
    }

    // MARK: - Loading

    private var channelIDs: [Channel.ID] {
        [spontaneousChannel?.id, assistControlChannel?.id].compactMap { $0 }
    }

    @MainActor
    private func loadSamples() async {
        if let s = spontaneousChannel, spontaneousSamples.isEmpty {
            spontaneousSamples = await read(s)
        }
        if let a = assistControlChannel, assistSamples.isEmpty {
            assistSamples = await read(a)
        }
    }

    private func read(_ channel: Channel) async -> [Float] {
        await Task.detached(priority: .utility) {
            let url = recordingDirectory.appendingPathComponent(channel.storageFileName)
            guard let access = try? BinaryRecordingFile.mappedAccess(url: url),
                  channel.sampleCount > 0 else {
                return []
            }
            return access.samples(range: 0..<channel.sampleCount)
        }.value
    }
}
