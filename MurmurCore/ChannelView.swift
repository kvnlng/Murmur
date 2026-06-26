//
//  ChannelView.swift
//  Murmur
//
//  Reading-side facade over a Channel and its on-disk binary files. Selects the
//  best level-of-detail for a requested zoom + viewport size and serves either
//  raw Float32 samples or pyramid min/max bins, whichever is more efficient.
//
//  Hold one of these for the lifetime of a chart panel — the memory-maps stay
//  open and random-access reads are cheap. Drop it to release the OS mappings.
//

import Foundation

struct LevelOfDetail: Equatable, Sendable {
    /// `nil` means raw samples (no downsampling).
    let pyramidIndex: Int?
    /// Raw samples each bin covers (1 for raw).
    let binSamples: Int

    static let raw = LevelOfDetail(pyramidIndex: nil, binSamples: 1)
}

enum SampleRendering: Sendable {
    case rawSamples([Float])
    case pyramidBins([PyramidBin], binSamples: Int)
}

@MainActor
final class ChannelView {
    let channel: Channel
    let directory: URL

    private let rawAccess: MappedSampleAccess
    private let pyramidAccesses: [MappedPyramidAccess]

    init(channel: Channel, directory: URL) throws {
        self.channel   = channel
        self.directory = directory
        let rawURL = directory.appendingPathComponent(channel.storageFileName)
        self.rawAccess = try BinaryRecordingFile.mappedAccess(url: rawURL)
        self.pyramidAccesses = try channel.pyramid.map { level in
            let url = directory.appendingPathComponent(level.storageFileName)
            return try PyramidLevelFile.mappedAccess(url: url)
        }
    }

    /// Picks the pyramid level whose bin size is the largest that still fits under
    /// `samplesPerPixel`. Falls back to raw when no level qualifies.
    func selectLevel(samplesPerPixel: Double) -> LevelOfDetail {
        guard samplesPerPixel > 1 else { return .raw }
        var chosen = LevelOfDetail.raw
        for (index, level) in channel.pyramid.enumerated() {
            if Double(level.binSamples) <= samplesPerPixel {
                chosen = LevelOfDetail(pyramidIndex: index, binSamples: level.binSamples)
            } else {
                break
            }
        }
        return chosen
    }

    /// Reads raw samples or pyramid bins for the given raw-sample range.
    func read(rawRange: Range<Int64>, level: LevelOfDetail) -> SampleRendering {
        switch level.pyramidIndex {
        case .none:
            let clamped = clampRawRange(rawRange)
            return .rawSamples(rawAccess.samples(range: clamped))
        case .some(let index):
            let binSamples = Int64(level.binSamples)
            let startBin   = rawRange.lowerBound / binSamples
            let endBin     = (rawRange.upperBound + binSamples - 1) / binSamples
            let access     = pyramidAccesses[index]
            let clamped    = clampBinRange(startBin..<endBin, totalBins: access.binCount)
            return .pyramidBins(access.bins(range: clamped), binSamples: level.binSamples)
        }
    }

    private func clampRawRange(_ range: Range<Int64>) -> Range<Int64> {
        let lo = max(0, range.lowerBound)
        let hi = min(channel.sampleCount, range.upperBound)
        guard lo < hi else { return 0..<0 }
        return lo..<hi
    }

    private func clampBinRange(_ range: Range<Int64>, totalBins: Int64) -> Range<Int64> {
        let lo = max(0, range.lowerBound)
        let hi = min(totalBins, range.upperBound)
        guard lo < hi else { return 0..<0 }
        return lo..<hi
    }
}
