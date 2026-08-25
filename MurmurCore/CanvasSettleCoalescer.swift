//
//  CanvasSettleCoalescer.swift
//  Murmur
//
//  #375: decides WHEN a canvas-size change re-derives the viewport width
//  from the canonical paper speed (#359/#373). The policy in one place,
//  out of the view, so it is unit-testable.
//

import CoreGraphics
import Foundation

/// #375: the review-queue pane toggles (and live window resizes) animate the
/// focused panel, so `calibration.canvasSize` publishes a new size on every
/// animation frame. Re-deriving the viewport width per frame fought the
/// animation three ways: the correction rendered one pass behind the canvas
/// width it was derived from (stretched-then-corrected, every frame), the
/// width/start quantised to whole `Int64` samples while the canvas glided,
/// and every `setWidth` cancelled any in-flight viewport animation. This
/// coalescer holds the re-derivation until the size SETTLES — during the
/// animation the trace stretches (continuous, smooth — the pre-#373
/// behaviour for a nil speed), then a single re-derivation lands: more
/// paper, same boxes, centre preserved.
///
/// The first VALID layout (width was zero) still applies immediately: X50's
/// open snap, #359's restore-into-any-window and #373's deferred
/// implied-speed capture all resolve on that transition, and none of them
/// should wait out a quiet window that exists only to smooth animations.
/// The `onChange(initial:)` fire (old == new) is treated the same way, so a
/// rebuilt view re-derives without delay.
@MainActor
final class CanvasSettleCoalescer {
    /// Quiet window before a mid-flight size counts as settled. Pane
    /// animations emit a size every frame (8–16 ms apart), so 150 ms
    /// comfortably outlasts the inter-frame gap without adding a
    /// perceptible pause after the animation ends.
    nonisolated static let defaultSettleNanoseconds: UInt64 = 150_000_000

    private let settleNanoseconds: UInt64
    private var settleTask: Task<Void, Never>?

    init(settleNanoseconds: UInt64 = CanvasSettleCoalescer.defaultSettleNanoseconds) {
        self.settleNanoseconds = settleNanoseconds
    }

    /// Route one canvas-size change: apply now on the first valid layout
    /// (or the `initial:` fire), otherwise defer until no further change
    /// arrives for the settle window. Each call supersedes any pending
    /// deferred apply, so a burst collapses to exactly one.
    func canvasChanged(
        from oldSize: CGSize,
        to newSize: CGSize,
        apply: @escaping @MainActor () -> Void
    ) {
        settleTask?.cancel()
        settleTask = nil
        if oldSize.width <= 0 || oldSize == newSize {
            apply()
            return
        }
        settleTask = Task { @MainActor [settleNanoseconds] in
            try? await Task.sleep(nanoseconds: settleNanoseconds)
            guard !Task.isCancelled else { return }
            apply()
        }
    }
}
