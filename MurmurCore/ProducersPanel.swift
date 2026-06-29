//
//  ProducersPanel.swift
//  MurmurCore
//
//  Modal sheet listing every registered `FindingProducer` and letting the
//  analyst run one against the currently-loaded recording. Drives the
//  shared producer pipeline UX — progress bar, cancel button, terminal
//  warnings — that paid IAP frameworks plug into without bringing their
//  own UI.
//
//  Scope for v1: list + run + accumulate findings + hand them back to the
//  host on completion. The host appends to `attachedAnnotations` and
//  persists to the bundle sidecar so producer output survives across
//  launches.
//
//  Currently surfaced via a DEBUG-gated toolbar button in `BedsideView`.
//  Once IAP frameworks land, the gate becomes "any producer registered"
//  instead of "DEBUG build" — same view, same protocol path, just a
//  different entitlement check upstream.
//

import SwiftUI

struct ProducersPanel: View {
    /// Called with the producer's accumulated findings when a run
    /// completes successfully. The caller appends them to its
    /// `attachedAnnotations` and persists to the bundle sidecar.
    let onCompleted: ([Annotation]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.activeRecording) private var activeRecording

    @State private var producers: [any FindingProducer] = []
    @State private var runState: RunState = .idle
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 480, height: 360)
        .task { await refreshProducers() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Run a producer")
                .font(.title3.weight(.semibold))
            Text("Producers analyze the loaded recording and emit findings. Output merges with the bundle's existing annotations.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .running(let active, let progress, let count, let warnings) = runState {
            runningView(active: active, progress: progress, findingsCount: count, warnings: warnings)
        } else {
            producerList
        }
    }

    private var producerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if producers.isEmpty {
                ContentUnavailableView(
                    "No producers registered",
                    systemImage: "wand.and.stars",
                    description: Text("Install an extension (Annotation Authoring, Silver Layer Metrics, VT Detection) to unlock producers.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(producers, id: \.id) { producer in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(producer.displayName)
                                .font(.body.weight(.medium))
                            Text(producer.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Run") { run(producer) }
                            .buttonStyle(.borderedProminent)
                            .disabled(activeRecording == nil)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("producer-row-\(producer.id)")
                }
                lastRunBanner
            }
        }
    }

    @ViewBuilder
    private var lastRunBanner: some View {
        switch runState {
        case .completed(let count):
            Label("Last run added \(count) finding\(count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .padding(.top, 4)
        case .cancelled:
            Label("Last run was cancelled", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 4)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
                .padding(.top, 4)
        case .idle, .running:
            EmptyView()
        }
    }

    private func runningView(
        active: any FindingProducer,
        progress: ProgressUpdate,
        findingsCount: Int,
        warnings: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Running \(active.displayName)…")
                .font(.body.weight(.medium))
            ProgressView(value: progress.fractionComplete)
                .progressViewStyle(.linear)
            HStack(spacing: 16) {
                Label("\(findingsCount) finding\(findingsCount == 1 ? "" : "s")", systemImage: "scope")
                    .font(.caption)
                if !warnings.isEmpty {
                    Label("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            Text(progress.stage)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var footer: some View {
        HStack {
            if case .running = runState {
                Button("Cancel run", role: .destructive) { runTask?.cancel() }
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
        }
    }

    // MARK: - Lifecycle

    private func refreshProducers() async {
        let registered = await ProducerRegistry.shared.all()
        // Filter to the producers the user is actually entitled to run.
        // Free producers (the synthetic baseline today) always pass;
        // paid producers only appear once the gating IAP is owned.
        let store = PurchaseStore.shared
        producers = registered.filter { store.canRun(producerID: $0.id) }
    }

    private func run(_ producer: any FindingProducer) {
        guard let recording = activeRecording else {
            runState = .failed("No recording loaded.")
            return
        }
        runState = .running(
            producer: producer,
            progress: ProgressUpdate(fractionComplete: 0, stage: "Starting"),
            findingsCount: 0,
            warnings: []
        )
        runTask = Task { @MainActor in
            var findings: [Annotation] = []
            var warnings: [String] = []
            var lastProgress = ProgressUpdate(fractionComplete: 0, stage: "Starting")
            do {
                for try await event in producer.analyze(recording) {
                    switch event {
                    case .progress(let p):
                        lastProgress = p
                    case .findings(let batch):
                        findings.append(contentsOf: batch)
                    case .warning(let msg, _):
                        warnings.append(msg)
                    }
                    runState = .running(
                        producer: producer,
                        progress: lastProgress,
                        findingsCount: findings.count,
                        warnings: warnings
                    )
                }
                onCompleted(findings)
                runState = .completed(findings.count)
            } catch is CancellationError {
                runState = .cancelled
            } catch {
                runState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Run state

    private enum RunState {
        case idle
        case running(
            producer: any FindingProducer,
            progress: ProgressUpdate,
            findingsCount: Int,
            warnings: [String]
        )
        case completed(Int)
        case cancelled
        case failed(String)
    }
}

// MARK: - Environment key for the active recording

private struct ActiveRecordingKey: EnvironmentKey {
    static let defaultValue: Recording? = nil
}

extension EnvironmentValues {
    var activeRecording: Recording? {
        get { self[ActiveRecordingKey.self] }
        set { self[ActiveRecordingKey.self] = newValue }
    }
}
