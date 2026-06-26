//
//  RecordingViewport.swift
//  Murmur
//
//  Shared time-window state for one recording's bedside view. Every channel
//  panel in a Recording renders the same range so leads scroll and zoom in
//  lock-step — matching the convention every clinical bedside monitor uses.
//
//  Pan/zoom gestures and overview-ribbon scrubs all funnel through this object,
//  and each ChannelPanel observes changes via the Observation framework.
//

import Foundation

@MainActor
@Observable
final class RecordingViewport {
    let totalSamples: Int64
    let sampleRate: Double
    /// Smallest allowed window — we never let users zoom below 100 ms.
    let minSamples: Int64

    private(set) var startSample: Int64
    private(set) var endSample: Int64

    /// Active animation (jump or momentum). Cancelled whenever a new
    /// animation starts or the user grabs the chart for a fresh gesture.
    @ObservationIgnored
    private var animationTask: Task<Void, Never>?

    init(totalSamples: Int64, sampleRate: Double, initialDurationSeconds: Double = 10) {
        let total = max(0, totalSamples)
        let rate = max(1, sampleRate)
        self.totalSamples = total
        self.sampleRate = rate
        self.minSamples = max(2, Int64(0.1 * rate))

        let initialWidth = min(total, max(2, Int64(initialDurationSeconds * rate)))
        self.startSample = 0
        self.endSample = max(2, initialWidth)
    }

    var rangeSamples: Range<Int64> { startSample..<endSample }

    var durationSeconds: Double { Double(endSample - startSample) / sampleRate }

    /// Pan by an arbitrary sample delta, clamped to recording bounds.
    func pan(bySamples delta: Int64) {
        cancelAnimation()
        setStartInternal(startSample + delta)
    }

    /// Move the window so it starts at `newStart`, preserving width.
    func setStart(_ newStart: Int64) {
        cancelAnimation()
        setStartInternal(newStart)
    }

    /// Change the window width, keeping `anchorFraction` of the current viewport
    /// (0 = left edge, 0.5 = center, 1 = right edge) anchored to the same sample.
    func setWidth(_ newWidth: Int64, anchorFraction: Double) {
        cancelAnimation()
        let clampedWidth = min(max(minSamples, newWidth), max(minSamples, totalSamples))
        let currentWidth = endSample - startSample
        guard clampedWidth != currentWidth else { return }

        let anchorSample = startSample + Int64(Double(currentWidth) * anchorFraction)
        let proposedStart = anchorSample - Int64(Double(clampedWidth) * anchorFraction)
        let maxStart = max(0, totalSamples - clampedWidth)
        let clampedStart = min(max(0, proposedStart), maxStart)
        startSample = clampedStart
        endSample = clampedStart + clampedWidth
    }

    /// Center the viewport around `fraction` (0...1) of the total recording,
    /// preserving the current width.
    func jump(toFraction fraction: Double) {
        cancelAnimation()
        let f = min(1.0, max(0.0, fraction))
        let target = Int64(Double(totalSamples) * f)
        let width = endSample - startSample
        setStart(target - width / 2)
    }

    /// Smooth, eased version of `jump(toFraction:)`. Used by discrete tap
    /// actions (clicking a finding row, tapping a density-timeline tick)
    /// where an abrupt cut would make it harder for the eye to track where
    /// the new viewport came from. Real-time scrubbing (overview ribbon
    /// drag) keeps using `jump` directly.
    func animateJump(toFraction fraction: Double, duration: TimeInterval = 0.25) {
        cancelAnimation()
        let f = min(1.0, max(0.0, fraction))
        let width = endSample - startSample
        let target = Int64(Double(totalSamples) * f)
        let startStart = startSample
        let targetStart = clampStart(target - width / 2, width: width)
        guard startStart != targetStart, duration > 0 else {
            setStart(targetStart)
            return
        }
        animationTask = Task { @MainActor [weak self] in
            await self?.runStartInterpolation(
                from: startStart,
                to: targetStart,
                duration: duration
            )
        }
    }

    /// Begin a momentum-driven pan after a drag-flick. Eases the residual
    /// motion to a stop over `duration` so released drags glide instead of
    /// snapping to a halt. A no-op for very low velocities.
    func startPanMomentum(velocitySamplesPerSec: Double, duration: TimeInterval = 0.4) {
        cancelAnimation()
        let absV = abs(velocitySamplesPerSec)
        guard absV > 200, duration > 0 else { return }   // ignore tiny releases
        let width = endSample - startSample
        // Mean velocity over a constant-decel-to-zero glide is v/2;
        // total displacement is v/2 * duration.
        let totalDelta = velocitySamplesPerSec * duration * 0.5
        let startStart = startSample
        let targetStart = clampStart(startStart + Int64(totalDelta), width: width)
        guard startStart != targetStart else { return }
        animationTask = Task { @MainActor [weak self] in
            await self?.runStartInterpolation(
                from: startStart,
                to: targetStart,
                duration: duration
            )
        }
    }

    /// Cancels any active animation. Called automatically on every direct
    /// pan/jump/setStart/setWidth so user gestures always win over
    /// in-flight animations.
    func cancelAnimation() {
        animationTask?.cancel()
        animationTask = nil
    }

    @MainActor
    private func runStartInterpolation(from startStart: Int64, to targetStart: Int64, duration: TimeInterval) async {
        // 120 Hz target so ProMotion displays get one tick per frame.
        let stepCount = max(2, Int(duration * 120))
        let stepNanos = UInt64(duration * 1_000_000_000 / Double(stepCount))
        let span = Double(targetStart - startStart)
        for step in 1...stepCount {
            if Task.isCancelled { return }
            let t = Double(step) / Double(stepCount)
            let eased = 1 - pow(1 - t, 3)   // ease-out cubic
            let newStart = startStart + Int64(span * eased)
            setStartInternal(newStart)
            try? await Task.sleep(nanoseconds: stepNanos)
        }
        if !Task.isCancelled { setStartInternal(targetStart) }
        animationTask = nil
    }

    private func clampStart(_ proposed: Int64, width: Int64) -> Int64 {
        let maxStart = max(0, totalSamples - width)
        return min(max(0, proposed), maxStart)
    }

    /// `setStart` used by the animation loop — bypasses the public path so
    /// the animation can advance without cancelling itself.
    private func setStartInternal(_ newStart: Int64) {
        let width = endSample - startSample
        let clamped = clampStart(newStart, width: width)
        startSample = clamped
        endSample = clamped + width
    }
}
