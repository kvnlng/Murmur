//
//  SyntheticFindingProducer.swift
//  MurmurCore
//
//  First concrete `FindingProducer` impl. Ships with the free viewer as a
//  baseline so the producer pipeline (registry, progress UI, cancellation,
//  warning handling) exercises end-to-end without needing any paid
//  framework or ML model installed. Also doubles as the deterministic
//  fixture for `FindingProducerTests` — same type, seed parameter
//  controls reproducibility.
//
//  Behaviour: walks the recording in 2-second windows and emits a single
//  point finding per window when a deterministic LCG (seeded from the
//  configured `seed`) clears the configured `findingProbability`
//  threshold. The category cycles through a small set so the host UI
//  can demonstrate category-aware filtering / haptic-on-new-category
//  / etc.
//
//  This is intentionally not "synthetic ECG analysis" — it's a fixture
//  that emits findings in a predictable pattern. Real arrhythmia
//  detection lives in `MurmurInference.VTDetectionService`.
//

import Foundation

struct SyntheticFindingProducer: FindingProducer {
    let id: String = "murmur.synthetic"
    let displayName: String = "Synthetic test producer"

    /// Seed for the deterministic LCG. Same seed + same input = same
    /// findings, every run. Used by tests to assert against a known
    /// output set.
    let seed: UInt64

    /// Probability (0...1) that any given window emits a finding.
    /// Default 0.25 — gives a sparse-but-visible scatter on typical
    /// short recordings.
    let findingProbability: Double

    /// Window length in seconds. The producer steps through the
    /// recording one window at a time, emitting (potentially) one
    /// finding per window with `category` rotating through
    /// `categoryRotation`.
    let windowSeconds: Double

    /// Categories the producer rotates through. Configurable so tests
    /// can pin a single-category scenario, but defaults exercise the
    /// host's category-filter chips and palette-color rendering.
    let categoryRotation: [String]

    init(
        seed: UInt64 = 0x9E37_79B9_7F4A_7C15,    // any non-zero is fine
        findingProbability: Double = 0.25,
        windowSeconds: Double = 2.0,
        categoryRotation: [String] = ["PVC", "AFib", "VT", "Noise"]
    ) {
        self.seed = seed
        self.findingProbability = max(0, min(1, findingProbability))
        self.windowSeconds = max(0.1, windowSeconds)
        self.categoryRotation = categoryRotation.isEmpty ? ["Synthetic"] : categoryRotation
    }

    func analyze(_ recording: Recording) -> AsyncThrowingStream<ProducerEvent, Error> {
        // Snapshot the producer's config + the recording's relevant
        // numbers into local lets so the stream closure doesn't capture
        // self or the Recording across an `await` boundary.
        let producerSeed = seed
        let probability = findingProbability
        let window = windowSeconds
        let categories = categoryRotation
        let producerID = id
        let primaryChannel = recording.channels.first { !$0.isTrendChannel }
            ?? recording.channels.first

        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let channel = primaryChannel else {
                    // Nothing to scan — terminate cleanly with no findings.
                    continuation.yield(.progress(ProgressUpdate(fractionComplete: 1, stage: "No channels")))
                    continuation.finish()
                    return
                }
                let sampleRate = channel.sampleRate
                let totalSamples = channel.sampleCount
                let windowSamples = Int64(window * sampleRate)
                guard windowSamples > 0, totalSamples > 0 else {
                    continuation.yield(.progress(ProgressUpdate(fractionComplete: 1, stage: "Empty recording")))
                    continuation.finish()
                    return
                }
                let windowCount = max(1, Int((totalSamples + windowSamples - 1) / windowSamples))

                // Initial determinate-progress signal so the host can
                // swap an indeterminate spinner for a real bar before
                // the first window finishes.
                continuation.yield(.progress(ProgressUpdate(
                    fractionComplete: 0,
                    stage: "Scanning \(windowCount) windows"
                )))

                var rng = SplitMix64(state: producerSeed)
                for windowIndex in 0..<windowCount {
                    // Required cancellation check per protocol contract.
                    do {
                        try Task.checkCancellation()
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }

                    let sampleStart = Int64(windowIndex) * windowSamples
                    let sampleEnd = min(totalSamples, sampleStart + windowSamples)

                    // Decide whether this window produces a finding.
                    if rng.nextUniform() < probability {
                        let category = categories[windowIndex % categories.count]
                        // Place the point finding at the centre of the window
                        // — deterministic position lets tests assert exact
                        // sample indices.
                        let sampleIndex = (sampleStart + sampleEnd) / 2
                        let finding = Annotation(
                            kind: .point,
                            sampleIndex: sampleIndex,
                            category: category,
                            label: category,
                            confidence: 0.5 + 0.5 * rng.nextUniform(),
                            severity: .info,
                            source: producerID,
                            note: "Synthetic \(category) at window \(windowIndex + 1)/\(windowCount)"
                        )
                        continuation.yield(.findings([finding]))
                    }

                    continuation.yield(.progress(ProgressUpdate(
                        fractionComplete: Double(windowIndex + 1) / Double(windowCount),
                        stage: "Window \(windowIndex + 1) / \(windowCount)"
                    )))
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Deterministic RNG

/// SplitMix64 — small, fast, deterministic pseudo-random generator.
/// Used in place of the system RNG so the synthetic producer's output
/// is reproducible from `seed` alone. Not cryptographically secure;
/// that's not a goal here.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1).
    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
