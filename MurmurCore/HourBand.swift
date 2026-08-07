//
//  HourBand.swift
//  MurmurCore
//
//  The middle tier of the stage's three-band ladder (X70): the hour enclosing
//  the current window, drawn as a min/max envelope, with the window marked
//  inside it.
//
//  Why a middle tier exists at all. Before X70 the stage offered exactly two
//  scales — the whole record, and the ~10 s window. On a 72-hour recording
//  that is a 26,000× jump, and the record band's pixels are worth ~4 minutes
//  each: an analyst who sees something at the record scale cannot aim at it,
//  and an analyst in the window has no idea what is on either side. The hour
//  is the scale at which "the run I saw a minute ago" is still on screen.
//
//  The envelope comes from the SAME pyramid the trace renders from, read at
//  whichever level gives roughly one bin per pixel across an hour — so this is
//  a cheap read (a few hundred bins), not a second decimation path with its
//  own arithmetic to drift from the renderer's.
//

import SwiftUI

struct HourBand: View {
    let channel: Channel
    let directory: URL
    let viewport: RecordingViewport

    /// Seconds spanned by the band. An hour by name and by default; kept a
    /// parameter because the arithmetic has nothing hour-specific in it and a
    /// test that has to build a 3600-second fixture to check the mapping is a
    /// test nobody writes.
    var spanSeconds: Double = HourBand.defaultSpanSeconds

    static let defaultSpanSeconds: Double = 3600

    @State private var envelope: [PyramidBin] = []
    @State private var loadedWindowIndex: Int64 = -1

    private static let height: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.06))

                envelopeShape(in: geo.size)
                    .fill(Color.secondary.opacity(0.55))

                windowBox(in: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(clickToRecentre(in: geo.size))
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("hour-band")
        .accessibilityLabel(spokenLabel)
        .task(id: windowIndex) { await loadEnvelope() }
    }

    // MARK: - The band's own time domain

    /// Which hour-sized slice of the record the band is showing.
    ///
    /// Quantised to fixed blocks rather than centred on the viewport: a band
    /// that slides continuously under a panning window gives the analyst no
    /// fixed frame to read position against, which is the whole point of
    /// having a middle tier. The window box moves across a stationary hour.
    private var windowIndex: Int64 {
        guard viewport.sampleRate > 0 else { return 0 }
        let startSeconds = Double(viewport.startSample) / viewport.sampleRate
        return Int64(startSeconds / spanSeconds)
    }

    var domainSeconds: ClosedRange<Double> {
        let start = Double(windowIndex) * spanSeconds
        return start...(start + spanSeconds)
    }

    private var domainSamples: Range<Int64> {
        let rate = max(1, viewport.sampleRate)
        let start = Int64(domainSeconds.lowerBound * rate)
        let end = min(channel.sampleCount, Int64(domainSeconds.upperBound * rate))
        return start..<max(start + 1, end)
    }

    // MARK: - Drawing

    /// The min/max silhouette. Drawn as one closed path — maxima left to right,
    /// then minima right to left — so it reads as a filled band rather than as
    /// two lines the eye has to pair up.
    private func envelopeShape(in size: CGSize) -> Path {
        Path { path in
            guard !envelope.isEmpty, size.width > 0 else { return }
            let (lo, hi) = envelopeRange
            guard hi > lo else { return }
            let midY = size.height / 2
            let scale = size.height / CGFloat(hi - lo)

            func y(_ value: Double) -> CGFloat {
                midY - CGFloat(value - (lo + hi) / 2) * scale
            }
            func x(_ index: Int) -> CGFloat {
                size.width * CGFloat(index) / CGFloat(max(1, envelope.count - 1))
            }

            path.move(to: CGPoint(x: x(0), y: y(Double(envelope[0].max))))
            for (i, bin) in envelope.enumerated() {
                path.addLine(to: CGPoint(x: x(i), y: y(Double(bin.max))))
            }
            for (i, bin) in envelope.enumerated().reversed() {
                path.addLine(to: CGPoint(x: x(i), y: y(Double(bin.min))))
            }
            path.closeSubpath()
        }
    }

    private var envelopeRange: (Double, Double) {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for bin in envelope {
            let mn = Double(bin.min), mx = Double(bin.max)
            if mn.isFinite { lo = Swift.min(lo, mn) }
            if mx.isFinite { hi = Swift.max(hi, mx) }
        }
        guard lo < hi else { return (0, 1) }
        return (lo, hi)
    }

    /// The current window, marked inside the hour.
    ///
    /// Floored to a visible width: at the 2 s rung inside a 3600 s band the box
    /// is 0.06% of the width — sub-pixel, i.e. invisible, i.e. the band stops
    /// answering "where am I" exactly at the zoom level where that question is
    /// hardest.
    private func windowBox(in size: CGSize) -> some View {
        let rate = max(1, viewport.sampleRate)
        let domain = domainSeconds
        let startSec = Double(viewport.startSample) / rate
        let endSec = Double(viewport.endSample) / rate
        let x0 = fraction(of: startSec, in: domain) * size.width
        let x1 = fraction(of: endSec, in: domain) * size.width
        let width = Swift.max(2, x1 - x0)
        return RoundedRectangle(cornerRadius: 2)
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.12)))
            .frame(width: width, height: size.height)
            .offset(x: Swift.min(Swift.max(0, x0), Swift.max(0, size.width - width)))
            .allowsHitTesting(false)
    }

    private func fraction(of seconds: Double, in domain: ClosedRange<Double>) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(Swift.min(1, Swift.max(0, (seconds - domain.lowerBound) / span)))
    }

    // MARK: - Interaction

    /// Click anywhere in the hour to bring the window there, keeping its width.
    private func clickToRecentre(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { value in
                guard size.width > 0 else { return }
                let f = Swift.min(1, Swift.max(0, value.location.x / size.width))
                let domain = domainSeconds
                let seconds = domain.lowerBound + Double(f) * (domain.upperBound - domain.lowerBound)
                viewport.center(onSample: Int64(seconds * max(1, viewport.sampleRate)))
            }
    }

    private var spokenLabel: String {
        let domain = domainSeconds
        return "Hour band, \(BedsideView.preciseClock(domain.lowerBound)) to "
            + "\(BedsideView.preciseClock(domain.upperBound)). "
            + "Window at \(BedsideView.preciseClock(Double(viewport.startSample) / max(1, viewport.sampleRate)))."
    }

    // MARK: - Loading

    /// Read the enclosing hour from the channel's pyramid.
    ///
    /// Picks the shallowest level that keeps the read under a few hundred bins,
    /// which is all a ~1000 pt band can show. Falls back to an empty envelope
    /// rather than reading raw samples: an hour at 250 Hz is 900,000 of them,
    /// and a band that stalls the stage to draw a silhouette is worse than a
    /// band that draws nothing.
    private func loadEnvelope() async {
        let index = windowIndex
        guard loadedWindowIndex != index else { return }
        let range = domainSamples
        let targetBins = 600
        let wanted = Double(range.count) / Double(targetBins)

        var chosen: (level: PyramidLevel, url: URL)?
        for level in channel.pyramid where Double(level.binSamples) <= wanted {
            chosen = (level, directory.appendingPathComponent(level.storageFileName))
        }
        guard let picked = chosen,
              let access = try? PyramidLevelFile.mappedAccess(url: picked.url) else {
            await MainActor.run {
                envelope = []
                loadedWindowIndex = index
            }
            return
        }
        let binSamples = Int64(picked.level.binSamples)
        let lo = range.lowerBound / binSamples
        let hi = Swift.min(access.binCount, (range.upperBound + binSamples - 1) / binSamples)
        guard lo < hi else {
            await MainActor.run {
                envelope = []
                loadedWindowIndex = index
            }
            return
        }
        let bins = access.bins(range: lo..<hi)
        await MainActor.run {
            envelope = bins
            loadedWindowIndex = index
        }
    }
}
