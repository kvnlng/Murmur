//
//  VTVFScanOrchestrator.swift
//  Murmur (app target)
//
//  Invisible glue view for the VT/VF Detection IAP — the same
//  App-orchestrator ↔ MurmurCore-context pattern as the variability and
//  interval-markings orchestrators. It:
//
//   1. Enforces the entitlement gate on the paid side: sets
//      `VTVFScanContext.isScanAvailable` only when the VT/VF IAP is owned
//      AND a recording is loaded, so the free viewer never links the model
//      or exposes the scan action.
//   2. Lazily loads + compiles the Core ML model (off-main) once entitled.
//   3. Presents the scan dialog when BedsideView requests it, and publishes
//      committed candidates back to `VTVFScanContext` for the review queue.
//
//  MurmurCore never imports MurmurInference — the model, the scan, and the
//  candidate→annotation minting all happen here.
//

import Foundation
import MurmurCore
import MurmurInference
import SwiftUI

struct VTVFScanOrchestrator: View {

    @State private var recordingContext = CurrentRecordingContext.shared
    @State private var scanContext = VTVFScanContext.shared
    @State private var store = PurchaseStore.shared

    @State private var model: VTVFModel?
    @State private var modelLoadError: String?

    private struct Key: Hashable {
        let recordingID: UUID?
        let owned: Bool
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .task(id: Key(
                recordingID: recordingContext.recording?.id,
                owned: store.hasStudio
            )) {
                await refreshAvailability()
            }
            // A new recording invalidates the previous recording's candidates
            // (the shared context tracks one active recording) — but the new
            // recording may have a committed scan of its own on disk, so this
            // is a SWAP, not a clear. Doing both here, in one place and
            // synchronously, is deliberate: if the restore lived in BedsideView
            // instead, this clear could land after it and wipe the restore.
            .onChange(of: recordingContext.recording?.id) { _, _ in
                loadCandidatesForCurrentRecording()
            }
            // The first recording of the session sets the id from nil, which
            // does fire `onChange` — but a recording already open when this
            // orchestrator mounts would not, so cover that too.
            .onAppear { loadCandidatesForCurrentRecording() }
            .sheet(isPresented: $scanContext.showScanDialog) {
                sheetContent
            }
    }

    /// Replace the live candidate set with whatever the current recording has
    /// committed on disk — nothing, when it has never been scanned.
    @MainActor
    private func loadCandidatesForCurrentRecording() {
        guard let directory = recordingContext.directory,
              let saved = VTVFCandidateStore(bundleDirectory: directory).load() else {
            scanContext.clearCandidates()
            return
        }
        scanContext.setCandidates(
            saved.candidates,
            parametersCaption: saved.parametersCaption,
            provenance: VTVFScanContext.ModelProvenance(
                modelIdentifier: saved.modelIdentifier,
                modelVersion: saved.modelVersion,
                tau: saved.tau
            )
        )
    }

    @MainActor
    private func refreshAvailability() async {
        #if DEBUG
        // XCUI candidate-injection bypass: the test publishes candidates
        // directly and needs the scan affordance available WITHOUT running
        // Core ML (compiling the model would add cold-start latency and the
        // flow under test doesn't need it). Mark available and skip both the
        // entitlement check and the model load.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-vtvf-candidates") {
            scanContext.isScanAvailable = recordingContext.recording != nil
            return
        }
        #endif
        let owned = store.hasStudio
        scanContext.isScanAvailable = owned && recordingContext.recording != nil

        // Load the model once, the first time the IAP is owned.
        guard owned, model == nil, modelLoadError == nil else { return }
        // Core ML model compile is a real cold-start cost the header calls
        // out; measure it like any other component.
        let signpost = ComputeSignpost.begin("VTVFModelLoad")
        defer { ComputeSignpost.end(signpost) }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try VTVFModel()
            }.value
            model = loaded
            scanContext.regulatoryNotice = loaded.regulatoryNotice
        } catch {
            modelLoadError = "\(error)"
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        // #357: resolve the analysis lead here, where `directory` is in
        // hand, and hand the channel to the view rather than letting it
        // pick one internally — one designated channel for every
        // calculation, disclosed once.
        if let model,
           let recording = recordingContext.recording,
           let directory = recordingContext.directory {
            if let resolution = recording.analysisLead(inBundle: directory) {
                VTVFScanView(
                    model: model,
                    recording: recording,
                    directory: directory,
                    analysisLeadChannel: resolution.channel,
                    viewStartSample: scanContext.currentViewStartSample,
                    viewEndSample: scanContext.currentViewEndSample,
                    onCommit: { annotations, caption in
                        scanContext.setCandidates(
                            annotations,
                            parametersCaption: caption,
                            provenance: VTVFScanContext.ModelProvenance(
                                modelIdentifier: model.modelID,
                                tau: model.thresholdTau
                            )
                        )
                        // Persist alongside the dispositions that will adjudicate
                        // it, with the operating point that produced it — a later
                        // model or τ must not silently redefine what was reviewed.
                        VTVFCandidateStore(bundleDirectory: directory).save(
                            candidates: annotations,
                            parametersCaption: caption,
                            modelIdentifier: model.modelID,
                            modelVersion: nil,
                            tau: model.thresholdTau
                        )
                        scanContext.showScanDialog = false
                    },
                    onCancel: { scanContext.showScanDialog = false }
                )
            } else {
                // A recording with no populated ECG channel — a data
                // problem, not a model load in progress. Distinct from
                // `modelLoadError` below: the model is fine, this
                // recording just has nothing to scan.
                VTVFScanUnavailableView(
                    error: nil,
                    dataProblem: "This recording has no analyzable ECG lead — "
                        + "the VT/VF scan needs a populated ECG channel.",
                    onDismiss: { scanContext.showScanDialog = false }
                )
            }
        } else {
            VTVFScanUnavailableView(
                error: modelLoadError,
                dataProblem: nil,
                onDismiss: { scanContext.showScanDialog = false }
            )
        }
    }
}

/// Fallback sheet content shown while the model is still compiling on a
/// cold cache, if it failed to load, or if the current recording has no
/// data the scan could run on.
struct VTVFScanUnavailableView: View {
    let error: String?
    let dataProblem: String?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let error {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("The VT/VF model couldn't be loaded.")
                    .font(.headline)
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let dataProblem {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("This recording can't be scanned.")
                    .font(.headline)
                Text(dataProblem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView("Preparing the VT/VF model…")
                Text("The model is compiling for this machine. This happens once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Close", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 420)
    }
}
