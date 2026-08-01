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
            // A new recording invalidates the previous recording's
            // candidates (the shared context tracks one active recording).
            .onChange(of: recordingContext.recording?.id) { _, _ in
                scanContext.clearCandidates()
            }
            .sheet(isPresented: $scanContext.showScanDialog) {
                sheetContent
            }
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
        if let model,
           let recording = recordingContext.recording,
           let directory = recordingContext.directory {
            VTVFScanView(
                model: model,
                recording: recording,
                directory: directory,
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
                    scanContext.showScanDialog = false
                },
                onCancel: { scanContext.showScanDialog = false }
            )
        } else {
            VTVFScanUnavailableView(
                error: modelLoadError,
                onDismiss: { scanContext.showScanDialog = false }
            )
        }
    }
}

/// Fallback sheet content shown while the model is still compiling on a
/// cold cache, or if it failed to load.
struct VTVFScanUnavailableView: View {
    let error: String?
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
