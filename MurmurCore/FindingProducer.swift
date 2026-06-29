//
//  FindingProducer.swift
//  MurmurCore
//
//  The runtime contract between the free open-source viewer (MurmurCore)
//  and the paid extension frameworks (MurmurAnnotation, MurmurSilver,
//  MurmurInference). Every framework that examines a Recording and emits
//  Annotations conforms to this protocol. The host (BedsideView /
//  FindingsPanel) discovers conforming types via `ProducerRegistry` and
//  drives them through a uniform UI surface — progress bars, cancel
//  buttons, error reporting — regardless of whether the producer is a
//  deterministic Swift port, a Core ML model, or a synthetic fixture.
//
//  Design decisions captured 2026-06-29 (see ROADMAP "Phase 0"):
//
//   • Async over sync. ML inference is heavy; we don't want a sync→async
//     migration later.
//   • Output = AsyncThrowingStream of events, not a single returned
//     `[Annotation]`. The stream interleaves progress reports, batched
//     findings, and per-window warnings, so the UI can show partial
//     results as scanning advances rather than waiting for a single
//     terminal value.
//   • Cancellation is the caller's responsibility — `for try await event
//     in stream` honors Task cancellation naturally, and the producer
//     MUST call `try Task.checkCancellation()` on window boundaries.
//   • Per-window failures emit `.warning` events; the run continues.
//     Only a fully-irrecoverable error throws and terminates the stream.
//   • Confidence calibration is the producer's responsibility. The
//     `Annotation.confidence` field is documented as already calibrated
//     (Platt-scaled or equivalent); hosts treat it as comparable across
//     producers.
//   • Producer discovery via `ProducerRegistry` actor — IAP gating is
//     enforced at the call site by filtering the registry against
//     `PurchaseStore` entitlements; the registry itself is unaware of
//     entitlements.
//
//  TODO (when MurmurAnnotation / MurmurSilver / MurmurInference framework
//  targets land): promote this protocol and its supporting types to
//  `public`. Doing so requires a broader audit since `Annotation`,
//  `Recording`, and `Channel` are currently internal — they'll need to
//  become public alongside this protocol so out-of-module conformers
//  can construct findings against them.
//

import Foundation

// MARK: - Protocol

/// A pipeline that examines a `Recording` and emits `Annotation`s. The
/// free viewer registers `SyntheticFindingProducer` as a baseline impl;
/// each paid framework (`MurmurAnnotation`, `MurmurSilver`,
/// `MurmurInference`) registers its own conformance from the framework's
/// entry point at app launch.
///
/// Conformances should be value types (`struct`) or actors, not classes,
/// so producers stay `Sendable` for cross-task hand-off.
protocol FindingProducer: Sendable {
    /// Stable identifier — emitted as `annotations[].source` so a
    /// finding can be traced back to the producer that generated it.
    /// Also the registry key, so duplicates clobber. Convention:
    /// reverse-DNS with a producer suffix (`murmur.silver`,
    /// `murmur.vtdetect`, `murmur.synthetic`).
    var id: String { get }

    /// User-facing label shown in:
    ///   • IAP product cards (e.g., "Silver Layer Metrics")
    ///   • Findings-panel source filter chips
    ///   • Progress UI ("Scanning with Silver Layer Metrics…")
    /// Should be short and noun-phrase shaped, not a sentence.
    var displayName: String { get }

    /// Run the producer over `recording`. Returns a stream that yields
    /// progress updates, finding batches, and non-fatal warnings as
    /// analysis proceeds. The stream completes by exhaustion when the
    /// run finishes successfully, or terminates with a thrown error if
    /// the run is irrecoverable (e.g., model file missing for a paid
    /// framework, or input that cannot be decoded at all).
    ///
    /// Cancellation: callers can cancel the consuming `Task`; the
    /// stream tears down at the next yield. Producers MUST call
    /// `try Task.checkCancellation()` on window boundaries so the
    /// teardown isn't bottlenecked on a long window.
    func analyze(_ recording: Recording) -> AsyncThrowingStream<ProducerEvent, Error>
}

// MARK: - Events

/// One step in a producer's output stream. Producers emit a mix of
/// progress updates and finding batches; the stream completes when the
/// producer has nothing more to say.
enum ProducerEvent: Sendable {
    /// Progress report, suitable for driving a determinate progress bar
    /// or a "Scanning… 32%" label. Producers should emit at least one
    /// `.progress` before the first `.findings` so the UI can show a
    /// determinate bar instead of an indeterminate spinner.
    case progress(ProgressUpdate)

    /// One or more findings produced from a window of the recording.
    /// May be empty if the window produced no findings — emitting an
    /// empty `.findings` is meaningful in that it signals "this window
    /// was scanned cleanly" vs. silence (which is ambiguous). Hosts
    /// accumulate findings across all `.findings` events.
    case findings([Annotation])

    /// A non-fatal warning. Per-window decode failures, a single
    /// missing channel, a malformed sub-record — the run continues
    /// despite these and the host surfaces them in a "warnings"
    /// expander on the producer's status card.
    case warning(message: String, underlying: Error?)
}

/// Snapshot of producer progress.
struct ProgressUpdate: Sendable, Equatable {
    /// 0.0...1.0. Monotonically non-decreasing across a single run.
    /// Producers that can't estimate completion should still emit
    /// occasional updates with `fractionComplete: 0` so the UI knows
    /// the producer is alive (use the `stage` field to describe what
    /// it's doing).
    let fractionComplete: Double

    /// Short, free-form description of what's happening right now.
    /// Examples: "Window 12 / 48", "Loading model weights",
    /// "Scoring channel Lead II". Shown verbatim in the progress UI.
    let stage: String

    init(fractionComplete: Double, stage: String) {
        self.fractionComplete = max(0, min(1, fractionComplete))
        self.stage = stage
    }
}

// MARK: - Registry

/// Process-wide registry of available producers. Paid extension
/// frameworks register their conformances on framework load; the free
/// viewer registers `SyntheticFindingProducer` from `MurmurApp` at
/// launch. The registry is *entitlement-unaware* — callers that need
/// to gate by IAP should filter the registry's output against
/// `PurchaseStore.owns(_:)` themselves.
actor ProducerRegistry {
    /// Shared registry used by the app. Tests should construct their
    /// own instance to keep parallel test runs from clobbering each
    /// other's registrations.
    static let shared = ProducerRegistry()

    private var producers: [String: any FindingProducer] = [:]

    init() {}

    /// Register `producer`. Replaces any prior registration with the
    /// same `id` — last write wins so frameworks can swap in updated
    /// implementations mid-session (e.g., after a Core ML weights
    /// hot-swap; see VT IAP Phase 4).
    func register(_ producer: any FindingProducer) {
        producers[producer.id] = producer
    }

    /// Unregister the producer with `id`. No-op if absent.
    func unregister(id: String) {
        producers.removeValue(forKey: id)
    }

    /// Look up a producer by its `id`. Returns nil if not registered —
    /// callers should handle this gracefully (e.g., the user disabled
    /// the IAP and the framework unregistered itself).
    func producer(id: String) -> (any FindingProducer)? {
        producers[id]
    }

    /// All currently-registered producers, sorted by `id` for
    /// deterministic UI ordering across launches.
    func all() -> [any FindingProducer] {
        producers.values.sorted { $0.id < $1.id }
    }
}

// MARK: - App-target bootstrap

/// Registers the baseline producers that ship with the free viewer.
/// Called from `MurmurApp.init()` at launch. Public so the app target
/// can invoke it across the module boundary without needing direct
/// access to the registry types (which stay internal until the
/// public-API audit lands alongside paid framework targets).
///
/// In DEBUG, `SyntheticFindingProducer` is registered so the
/// producer-pipeline UI is exercisable without a paid framework
/// installed. In RELEASE this is a no-op; paid frameworks register
/// themselves on framework load once their IAPs are owned.
@MainActor
public func bootstrapBaselineProducers() async {
    #if DEBUG
    await ProducerRegistry.shared.register(SyntheticFindingProducer())
    #endif
}
