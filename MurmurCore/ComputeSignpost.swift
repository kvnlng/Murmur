//
//  ComputeSignpost.swift
//  MurmurCore
//
//  Uniform timing instrumentation for the expensive paid computations.
//
//  Why this exists: the eight orchestrators in the app target each recompute
//  off a `.task(id:)` key, but they do not share a concurrency posture — some
//  hop to `Task.detached`, some run their whole body on the main actor. When a
//  multi-hour record makes the app sluggish there is currently no way to say
//  WHICH component spent the time; a Time Profiler trace shows a pile of
//  symbols with no subsystem boundary drawn around them. This draws that
//  boundary once, so every component reports on the same axis.
//
//  Two consumers, deliberately:
//
//  1. Instruments / `XCTOSSignpostMetric`. Emission uses the same subsystem
//     and `.pointsOfInterest` category as `waveformRenderLog`, and the same
//     C-style `os_signpost` API — NOT the `OSSignposter` wrapper, whose
//     intervals don't reliably surface cross-process (see WaveformCanvas.swift
//     for the original finding). `MurmurUIPerformanceTests` already reads
//     `UpdateNSView` / `Sync` / `RendererDraw` this way; component names
//     registered here plug into the same harness.
//
//  2. The unified log, but only past `ComputeMeasurement.slowThresholdSeconds`.
//     A user reporting "it got slow on my 24-hour record" has no debugger and
//     no Instruments — the same reasoning that made `PurchaseStore` log its
//     StoreKit round-trip at `.notice`. Logging EVERY recompute would drown
//     that signal, so only the ones a person could actually feel are persisted.
//
//  This file is measurement only. It deliberately changes no concurrency
//  posture and no compute scope — those decisions should follow the numbers,
//  not precede them.
//

import Foundation
import os.log
import os.signpost

/// Shared handle for compute-side signposts.
///
/// `.pointsOfInterest` because that category is emitted unconditionally —
/// most categories need an active subscriber, which would make a trace
/// recorded after the fact come back empty.
public let computeSignpostLog = OSLog(
    subsystem: "com.kevinlong.murmur",
    category: .pointsOfInterest
)

/// One completed component measurement. Pure value type so the "is this worth
/// persisting, and what should it say" policy is testable without a signpost
/// subscriber attached.
public struct ComputeMeasurement: Equatable, Sendable {

    /// Duration at or beyond which a measurement is persisted to the unified
    /// log rather than only emitted as a signpost.
    ///
    /// 100 ms, not one frame (16.7 ms). A frame-scale compute is worth seeing
    /// in Instruments but not worth a line in a log a user might be asked to
    /// send; 100 ms is past the point where a person perceives the UI as
    /// having stalled rather than merely stuttered.
    public static let slowThresholdSeconds: Double = 0.1

    /// Component name, matching the signpost name (e.g. `VariabilityLane`).
    public let name: String

    /// Size of the input the component chewed through — beats, samples, or
    /// windows depending on the component. Correlating this against duration
    /// is what separates "expensive algorithm" from "expensive input".
    public let workSize: Int?

    public let durationSeconds: Double

    public init(name: String, workSize: Int? = nil, durationSeconds: Double) {
        self.name = name
        self.workSize = workSize
        self.durationSeconds = durationSeconds
    }

    public var durationMilliseconds: Int {
        Int((durationSeconds * 1000).rounded())
    }

    public var isSlow: Bool {
        durationSeconds >= Self.slowThresholdSeconds
    }

    public var summary: String {
        guard let workSize else {
            return "\(name) took \(durationMilliseconds) ms"
        }
        return "\(name) took \(durationMilliseconds) ms over \(workSize) items"
    }
}

/// An in-flight interval. Opaque on purpose — callers hold it between
/// `begin` and `end` and nothing else.
public struct ComputeSignpostToken: Sendable {
    fileprivate let name: StaticString
    fileprivate let signpostID: OSSignpostID
    fileprivate let startedUptimeNanoseconds: UInt64
}

public enum ComputeSignpost {

    /// Slow computes land here. Separate category from `purchases` so
    /// `log show --predicate 'subsystem == "com.kevinlong.murmur"'` can be
    /// narrowed to either.
    private static let diagnostics = Logger(
        subsystem: "com.kevinlong.murmur",
        category: "compute"
    )

    /// Open an interval.
    ///
    /// Paired with `end(_:workSize:)`. This form — rather than a closure —
    /// is the one to use for anything asynchronous: the compute in several of
    /// these components spans a `Task.detached` boundary, and a closure-taking
    /// async wrapper would have to take the body as a non-isolated closure,
    /// which risks silently moving `@MainActor` work off the main actor. The
    /// token crosses that boundary without touching isolation.
    public static func begin(_ name: StaticString) -> ComputeSignpostToken {
        let signpostID = OSSignpostID(log: computeSignpostLog)
        os_signpost(.begin, log: computeSignpostLog, name: name, signpostID: signpostID)
        return ComputeSignpostToken(
            name: name,
            signpostID: signpostID,
            startedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    /// Close an interval opened by `begin`, and persist it if it was slow.
    public static func end(_ token: ComputeSignpostToken, workSize: Int? = nil) {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds
            &- token.startedUptimeNanoseconds
        let measurement = ComputeMeasurement(
            name: token.name.description,
            workSize: workSize,
            durationSeconds: Double(elapsedNanoseconds) / 1_000_000_000
        )
        os_signpost(
            .end,
            log: computeSignpostLog,
            name: token.name,
            signpostID: token.signpostID,
            "%{public}ld ms, work %{public}ld",
            measurement.durationMilliseconds,
            workSize ?? -1
        )
        if measurement.isSlow {
            diagnostics.notice("Slow compute — \(measurement.summary, privacy: .public)")
        }
    }

    /// Convenience for a fully synchronous component.
    ///
    /// Safe for `@MainActor` callers: a synchronous closure runs inline in the
    /// caller's context, so wrapping introduces no hop. `workSize` is a
    /// closure so a caller can report a count computed inside `body`.
    @discardableResult
    public static func measure<T>(
        _ name: StaticString,
        workSize: () -> Int? = { nil },
        _ body: () throws -> T
    ) rethrows -> T {
        let token = begin(name)
        defer { end(token, workSize: workSize()) }
        return try body()
    }
}
