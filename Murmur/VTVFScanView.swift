//
//  VTVFScanView.swift
//  Murmur (app target)
//
//  The VT/VF scan dialog — Stage 1 (tune) + Stage 2 (apply) of the
//  scan-tune-triage flow (project_vtvf_candidate_review_flow.md).
//
//  The model over-fires on noisy recordings and its probability scale
//  shifts recording to recording, so tuning happens BEFORE results reach
//  the queue, against a LIVE candidate count. Inference runs ONCE on the
//  previewed span; dragging the dials re-derives the candidate list from
//  the CACHED window scores — it never re-runs the model. Applying to the
//  whole recording runs the two-pass streaming scan with per-pass progress.
//

import Foundation
import MurmurCore
import MurmurInference
import MurmurMetrics
import SwiftUI

// MARK: - View-model

@MainActor
@Observable
final class VTVFScanModel {

    enum Scope: String, CaseIterable, Identifiable {
        case currentView
        case wholeRecording
        var id: String { rawValue }
        var label: String {
            switch self {
            case .currentView:    return "Current view"
            case .wholeRecording: return "Whole recording"
            }
        }
    }

    // Dials. X11: each writes back to the session state on change, so the
    // operating point survives closing and reopening the sheet — and rides the
    // `.mur` round trip (X59). Property observers don't fire for the seeding
    // assignments in `init`, so this can't write defaults back over a restore.
    var scope: Scope = .currentView { didSet { persistDials() } }
    var tau: Double { didSet { persistDials() } }
    var minimumDurationSeconds: Double = 4 { didSet { persistDials() } }
    var mergeGapSeconds: Double = 5 { didSet { persistDials() } }
    var showAdvanced = false

    // Preview state (Stage 1).
    private(set) var previewScores: [VTVFWindowScore] = []
    private(set) var previewLoading = false
    private(set) var previewError: String?

    // Pre-flight signal quality (A3) — the calibrated QRS-quality read on
    // the span the scan would spend compute on, per scope. Computed once
    // alongside the preview from the same loaded samples.
    private(set) var preflightView: (flagged: Int, total: Int)?
    private(set) var preflightWhole: (flagged: Int, total: Int)?

    // Apply state (Stage 2).
    private(set) var isApplying = false
    private(set) var applyPass: VTVFScanProgress.Pass?
    private(set) var applyFraction: Double = 0

    // Immutable context.
    let model: VTVFModel
    private let recording: Recording
    private let directory: URL
    /// #357 — the analysis lead, resolved by the caller (where `directory`
    /// is in hand) and handed in rather than picked here: one designated
    /// channel for every calculation, disclosed once.
    private let analysisLeadChannel: Channel
    private let viewStartSample: Int64
    private let viewEndSample: Int64
    private let nativeRate: Double
    private let leadName: String?

    private var fullSamples: [Float]?
    private var applyTask: Task<Void, Never>?

    init(
        model: VTVFModel, recording: Recording, directory: URL,
        analysisLeadChannel: Channel, viewStartSample: Int64, viewEndSample: Int64
    ) {
        self.model = model
        self.recording = recording
        self.directory = directory
        self.analysisLeadChannel = analysisLeadChannel
        self.viewStartSample = viewStartSample
        self.viewEndSample = viewEndSample
        self.nativeRate = analysisLeadChannel.sampleRate
        self.leadName = analysisLeadChannel.name

        // X11: seed the dials from the session state so reopening the sheet
        // resumes the analyst's operating point instead of snapping back to
        // defaults. Absent fields keep their default — a session written before
        // scan capture (or a fresh recording) must not be given a fabricated
        // operating point.
        let session = CurrentRecordingContext.shared.liveSessionState
        self.tau = session.tau ?? model.thresholdTau
        if let seconds = session.minDurationSeconds { self.minimumDurationSeconds = seconds }
        if let gap = session.mergeGapSeconds { self.mergeGapSeconds = gap }
        if let whole = session.scanScopeWholeRecording {
            self.scope = whole ? .wholeRecording : .currentView
        }
    }

    /// X11 — mirror the dials into the shared session state, which `⌘S` writes
    /// into the `.mur` (X59) and a reopen seeds from. Only the four fields this
    /// surface owns are touched; the rest of the state is left alone.
    private func persistDials() {
        var state = CurrentRecordingContext.shared.liveSessionState
        state.tau = tau
        state.minDurationSeconds = minimumDurationSeconds
        state.mergeGapSeconds = mergeGapSeconds
        state.scanScopeWholeRecording = (scope == .wholeRecording)
        CurrentRecordingContext.shared.liveSessionState = state
    }

    // MARK: - Derived

    var parameters: VTVFScanParameters {
        VTVFScanParameters(
            tau: tau,
            minimumDurationSeconds: minimumDurationSeconds,
            mergeGapSeconds: mergeGapSeconds
        )
    }

    /// Candidates for the previewed span at the current dials — pure
    /// re-clustering of the cached window scores, recomputed every time a
    /// dial moves. No inference.
    var liveCandidates: [VTVFCandidate] {
        VTVFEpisodeClustering.cluster(
            scores: previewScores,
            parameters: parameters,
            sampleRateHz: model.sampleRateHz
        )
    }

    /// Operating-point summary for the candidate group subtitle + citation.
    var caption: String {
        let tauText = String(format: "τ %.2f", tau)
        let minText = String(format: "min %.0fs", minimumDurationSeconds)
        let gapText = String(format: "gap %.0fs", mergeGapSeconds)
        return "\(tauText) · \(minText) · \(gapText) · \(model.modelID)"
    }

    // MARK: - Stage 1: preview on the current view

    func loadAndPreview() async {
        previewLoading = true
        previewError = nil
        defer { previewLoading = false }

        guard let samples = await loadSamplesIfNeeded() else {
            previewError = "Couldn't read the ECG samples for this recording."
            return
        }
        let start = max(0, Int(viewStartSample))
        let end = min(samples.count, Int(viewEndSample))
        guard end - start > 1 else {
            previewError = "The current view is too short to scan."
            return
        }
        let slice = Array(samples[start..<end])
        let native = nativeRate
        let modelRate = model.sampleRateHz
        let m = model

        // Pre-flight signal quality (A3) on both scopes, from the samples
        // already in hand — cheap arithmetic, no model. The read informs the
        // analyst BEFORE the apply spends real compute; it never gates it.
        let preflight = await Task.detached(priority: .userInitiated) { () -> (view: (Int, Int), whole: (Int, Int)) in
            func counts(_ s: [Float]) -> (Int, Int) {
                let windows = QRSQualityPreflight.read(samples: s, sampleRate: native)
                return (windows.filter(\.flagged).count, windows.count)
            }
            return (counts(slice), counts(samples))
        }.value
        preflightView = preflight.view
        preflightWhole = preflight.whole

        let scores = await Task.detached(priority: .userInitiated) { () -> [VTVFWindowScore] in
            let resampled = ECGResampler.resample(slice, fromRate: native, toRate: modelRate)
            let source = ArrayVTVFSampleSource(samples: resampled, sampleRateHz: modelRate)
            let scanner = VTVFScanner(model: m)
            // Preview scores the whole span at the model's default tau so the
            // histogram shows the full score mass; the dials threshold later.
            let result = try? scanner.scan(
                source: source,
                parameters: VTVFScanParameters(tau: 0)
            )
            return result?.windowScores ?? []
        }.value
        previewScores = scores
    }

    /// The pre-flight line for the ACTIVE scope, or nil when the span is too
    /// short for a single stable quality window.
    var preflightCaption: String? {
        let read = scope == .wholeRecording ? preflightWhole : preflightView
        guard let read else { return nil }
        return VTVFScanContext.preflightQualityCaption(
            flaggedWindows: read.flagged,
            totalWindows: read.total,
            flaggedSensitivity: QRSQualityCalibration.builtInNSTDBElectrodeMotion.bands[0].sensitivity
        )
    }

    // MARK: - Stage 2: commit

    /// Commit the previewed current-view candidates (no new inference).
    func commitCurrentView() -> [Annotation] {
        makeAnnotations(from: liveCandidates, nativeOffset: viewStartSample)
    }

    /// Run the full two-pass scan over the whole recording, then commit.
    /// Progress updates land on `applyPass` / `applyFraction`.
    func applyWhole(completion: @escaping ([Annotation]) -> Void) {
        guard !isApplying else { return }
        isApplying = true
        applyPass = .baseline
        applyFraction = 0

        applyTask = Task { [weak self] in
            guard let self else { return }
            guard let samples = await self.loadSamplesIfNeeded() else {
                self.isApplying = false
                return
            }
            let native = self.nativeRate
            let modelRate = self.model.sampleRateHz
            let m = self.model
            let params = self.parameters

            let scores = await Task.detached(priority: .userInitiated) { () -> [VTVFWindowScore] in
                let resampled = ECGResampler.resample(samples, fromRate: native, toRate: modelRate)
                let source = ArrayVTVFSampleSource(samples: resampled, sampleRateHz: modelRate)
                let scanner = VTVFScanner(model: m)
                let result = try? scanner.scan(
                    source: source,
                    parameters: params,
                    isCancelled: { Task.isCancelled },
                    progress: { progress in
                        Task { @MainActor [weak self] in
                            self?.applyPass = progress.pass
                            self?.applyFraction = progress.fractionComplete
                        }
                    }
                )
                return result?.windowScores ?? []
            }.value

            if Task.isCancelled {
                self.isApplying = false
                return
            }

            let candidates = VTVFEpisodeClustering.cluster(
                scores: scores,
                parameters: params,
                sampleRateHz: modelRate
            )
            let annotations = self.makeAnnotations(from: candidates, nativeOffset: 0)
            self.isApplying = false
            completion(annotations)
        }
    }

    func cancelApply() {
        applyTask?.cancel()
        applyTask = nil
        isApplying = false
    }

    // MARK: - Helpers

    private func loadSamplesIfNeeded() async -> [Float]? {
        if let fullSamples { return fullSamples }
        let recording = self.recording
        let directory = self.directory
        let channel = self.analysisLeadChannel
        let loaded = await Task.detached(priority: .userInitiated) {
            recording.samples(of: channel, inDirectory: directory)
        }.value
        fullSamples = loaded
        return loaded
    }

    /// Map candidate coordinates (model-rate, source-relative) back to the
    /// recording's native whole-recording sample timeline the queue uses.
    private func makeAnnotations(from candidates: [VTVFCandidate], nativeOffset: Int64) -> [Annotation] {
        let scale = nativeRate / model.sampleRateHz
        return candidates.map { c in
            let start = nativeOffset + Int64((Double(c.startSample) * scale).rounded())
            let end = nativeOffset + Int64((Double(c.endSample) * scale).rounded())
            return VTVFCandidateSource.makeAnnotation(
                startSample: start,
                endSample: end,
                score: c.aggregateScore,
                lead: leadName
            )
        }
    }
}

// MARK: - View

struct VTVFScanView: View {
    let model: VTVFModel
    let recording: Recording
    let directory: URL
    let analysisLeadChannel: Channel
    let viewStartSample: Int64
    let viewEndSample: Int64
    let onCommit: ([Annotation], String) -> Void
    let onCancel: () -> Void

    @State private var scanModel: VTVFScanModel

    init(
        model: VTVFModel,
        recording: Recording,
        directory: URL,
        analysisLeadChannel: Channel,
        viewStartSample: Int64,
        viewEndSample: Int64,
        onCommit: @escaping ([Annotation], String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.recording = recording
        self.directory = directory
        self.analysisLeadChannel = analysisLeadChannel
        self.viewStartSample = viewStartSample
        self.viewEndSample = viewEndSample
        self.onCommit = onCommit
        self.onCancel = onCancel
        _scanModel = State(initialValue: VTVFScanModel(
            model: model,
            recording: recording,
            directory: directory,
            analysisLeadChannel: analysisLeadChannel,
            viewStartSample: viewStartSample,
            viewEndSample: viewEndSample
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            scopePicker
            preflightQuality
            meter
            dials
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520)
        .task { await scanModel.loadAndPreview() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vtvf-scan-dialog")
    }

    // MARK: - Header (RUO surface #1)

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan for VT/VF candidates")
                    .font(.title3.weight(.semibold))
                Text("Candidates for review — never a diagnosis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("RUO")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                .foregroundStyle(.secondary)
                .help(model.regulatoryNotice)
                .accessibilityLabel("Research use only")
        }
    }

    // MARK: - Scope

    private var scopePicker: some View {
        Picker("Scope", selection: $scanModel.scope) {
            ForEach(VTVFScanModel.Scope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("vtvf-scope-picker")
    }

    // MARK: - Pre-flight signal quality (A3)

    /// The σ read for the active scope — stated before the analyst spends
    /// compute, never a gate. Absent when the span can't produce one stable
    /// quality window (omitted, not fabricated).
    @ViewBuilder
    private var preflightQuality: some View {
        if let caption = scanModel.preflightCaption {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help("""
            Calibrated on MIT-BIH NSTDB (electrode-motion noise, 24 to −6 dB): \
            in windows below the quality bar, R-peak detection sensitivity drops \
            to ≈ 0.88 and timing error P90 to ≈ 97 ms; elsewhere sensitivity is \
            ≥ 0.98. The scan still runs everywhere — this read is for deciding \
            whether the span is worth the compute.
            """)
            .accessibilityIdentifier("vtvf-preflight-quality")
        }
    }

    // MARK: - Live count + histogram

    private var meter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if scanModel.previewLoading {
                    ProgressView().controlSize(.small)
                    Text("Previewing current view…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(scanModel.liveCandidates.count)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("vtvf-live-count")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(scanModel.liveCandidates.count == 1 ? "candidate" : "candidates")
                            .font(.callout)
                        Text("in the current view at these settings")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = scanModel.previewError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                histogram
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    /// Window-score histogram with a movable tau cutline, so "drag left to
    /// widen, right to tighten" is legible instead of blind.
    private var histogram: some View {
        let bins = Self.histogramBins(scanModel.previewScores, binCount: 24)
        let maxCount = max(1, bins.max() ?? 1)
        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Array(bins.enumerated()), id: \.offset) { index, count in
                        let binCenter = (Double(index) + 0.5) / Double(bins.count)
                        Rectangle()
                            .fill(binCenter >= scanModel.tau
                                  ? Color.secondary.opacity(0.75)   // positive side
                                  : Color.secondary.opacity(0.25))  // below tau
                            .frame(height: max(1, h * CGFloat(count) / CGFloat(maxCount)))
                            .frame(maxWidth: .infinity)
                    }
                }
                // Tau cutline.
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5)
                    .offset(x: w * CGFloat(scanModel.tau))
            }
        }
        .frame(height: 60)
        .accessibilityHidden(true)
    }

    // MARK: - Dials

    private var dials: some View {
        VStack(alignment: .leading, spacing: 14) {
            dialRow(
                title: "Threshold (τ)",
                value: String(format: "%.2f", scanModel.tau),
                help: "Higher = fewer, more-confident candidates. Default read from the model.",
                accessibility: "vtvf-tau-slider"
            ) {
                Slider(value: $scanModel.tau, in: 0...1)
            }

            dialRow(
                title: "Minimum duration",
                value: String(format: "%.0f s", scanModel.minimumDurationSeconds),
                help: "Drops runs shorter than this — a brief run vs sustained VT.",
                accessibility: "vtvf-min-duration-slider"
            ) {
                Slider(value: $scanModel.minimumDurationSeconds, in: 0...30, step: 1)
            }

            DisclosureGroup(isExpanded: $scanModel.showAdvanced) {
                dialRow(
                    title: "Merge gap",
                    value: String(format: "%.0f s", scanModel.mergeGapSeconds),
                    help: "Positive spans closer than this merge into one episode.",
                    accessibility: "vtvf-merge-gap-slider"
                ) {
                    Slider(value: $scanModel.mergeGapSeconds, in: 0...15, step: 1)
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced").font(.callout.weight(.medium))
            }
        }
    }

    private func dialRow<Control: View>(
        title: String,
        value: String,
        help: String,
        accessibility: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            control()
                .accessibilityIdentifier(accessibility)
            Text(help).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Footer (apply / cancel + progress)

    @ViewBuilder
    private var footer: some View {
        if scanModel.isApplying {
            applyingProgress
        } else {
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(applyButtonTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(scanModel.previewLoading && scanModel.scope == .currentView)
                    .accessibilityIdentifier("vtvf-apply-button")
            }
        }
    }

    private var applyButtonTitle: String {
        switch scanModel.scope {
        case .currentView:    return "Apply to current view"
        case .wholeRecording: return "Apply to whole recording"
        }
    }

    private var applyingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            progressBar(
                label: "Pass 1 · baseline",
                fraction: scanModel.applyPass == .baseline ? scanModel.applyFraction : (scanModel.applyPass == .scoring ? 1 : 0)
            )
            progressBar(
                label: "Pass 2 · windows",
                fraction: scanModel.applyPass == .scoring ? scanModel.applyFraction : 0
            )
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { scanModel.cancelApply() }
            }
        }
        .accessibilityIdentifier("vtvf-apply-progress")
    }

    private func progressBar(label: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: min(1, max(0, fraction)))
        }
    }

    // MARK: - Actions

    private func apply() {
        switch scanModel.scope {
        case .currentView:
            onCommit(scanModel.commitCurrentView(), scanModel.caption)
        case .wholeRecording:
            let caption = scanModel.caption
            scanModel.applyWhole { annotations in
                onCommit(annotations, caption)
            }
        }
    }

    // MARK: - Histogram binning

    static func histogramBins(_ scores: [VTVFWindowScore], binCount: Int) -> [Int] {
        var bins = [Int](repeating: 0, count: binCount)
        for s in scores {
            let clamped = min(0.9999, max(0, s.score))
            let idx = Int(clamped * Double(binCount))
            bins[min(binCount - 1, idx)] += 1
        }
        return bins
    }
}
