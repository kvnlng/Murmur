//
//  BedsideView.swift
//  Plotting
//
//  Stacked channel panels driven by a shared `RecordingViewport`. The main
//  waveform is GPU-rendered (Metal) via `WaveformCanvas`; SwiftUI overlays
//  draw the axis labels and annotation symbols on top.
//
//  Drag on a chart pans all channels in lock-step; pinch zooms. Click/drag
//  on the overview ribbon scrubs.
//

import Charts
import SwiftUI

struct BedsideView: View {
    let recording: Recording
    let recordingDirectory: URL

    @State private var viewport: RecordingViewport
    @State private var filter = FindingFilter()
    @State private var showFindings = true
    @State private var layoutMode: BedsideLayoutMode
    /// App-wide read/write latch. Governs the context-notes editor and the
    /// per-finding disposition trio; new annotation create/edit/delete will
    /// hang off the same latch.
    @State private var isEditing: Bool = false
    /// Analyst review state for this recording's findings — confirm /
    /// dismiss / reset. Persisted to `<bundle>/dispositions.json`.
    @State private var dispositionStore: DispositionStore

    static let initialDurationSeconds: Double = 10

    init(recording: Recording, recordingDirectory: URL) {
        self.recording = recording
        self.recordingDirectory = recordingDirectory
        // Viewport + focus mode key off the first *ECG* channel — trend
        // channels (1/60 Hz vitals, GMM states) live in their own strip and
        // shouldn't drive viewport math.
        let firstECG = recording.channels.first(where: { !$0.isTrendChannel })
            ?? recording.channels.first
        _viewport = State(initialValue: RecordingViewport(
            totalSamples: firstECG?.sampleCount ?? 0,
            sampleRate: firstECG?.sampleRate ?? 250,
            initialDurationSeconds: Self.initialDurationSeconds
        ))
        // Default: focus the first lead. Single-lead is the typical analyst
        // workflow; strips mode is opt-in for cross-lead comparison.
        _layoutMode = State(initialValue: firstECG.map { .focus($0.id) } ?? .strips)
        _dispositionStore = State(initialValue: DispositionStore(bundleDirectory: recordingDirectory))
    }

    /// ECG / pressure channels — rendered on the Metal canvas.
    private var ecgChannels: [Channel] {
        recording.channels.filter { !$0.isTrendChannel }
    }

    /// Low-rate channels split by intent. Alarms and state probabilities
    /// get their own dedicated strips; everything else (continuous-valued
    /// vital trends) goes through the sparkline strip.
    private var lowRatePartition: LowRatePartition {
        LowRatePartition(channels: recording.channels.filter(\.isTrendChannel))
    }

    /// Pure-numeric vital trends (HR, SpO₂, etCO₂, BPM, tidal volume…)
    /// rendered as sparklines in `ChannelTrendStrip`.
    private var vitalTrendChannels: [Channel] { lowRatePartition.trends }

    /// Boolean-valued alarm / status channels rendered in `AlarmStrip`.
    private var alarmChannels: [Channel] { lowRatePartition.alarms }

    /// Continuous quality / artifact-ratio channels rendered in `QualityStrip`.
    private var qualityChannels: [Channel] { lowRatePartition.quality }

    /// The matched `prob_state_*` channel pair for `StateBackdropStrip`.
    /// Either side may be nil — the strip still renders with whatever's
    /// present and falls silent only if both are missing.
    private var stateChannels: (spontaneous: Channel?, assist: Channel?) {
        (lowRatePartition.spontaneous, lowRatePartition.assistControl)
    }

    /// Annotations that survive the current filter. Drives the canvas, the
    /// findings panel, and the density timeline so all three stay in sync.
    private var filteredAnnotations: [Annotation] {
        recording.annotations.filter(filter.matches)
    }

    /// Unfiltered rollup for the summary chip row — chips show total counts
    /// across the recording regardless of the active filter, so the user
    /// always sees "47 PVCs" instead of "8 of 47 shown."
    private var unfilteredSummary: AnnotationSummary {
        AnnotationSummary.build(
            from: recording.annotations,
            recordingDurationSamples: recording.channels.first?.sampleCount,
            sampleRate: recording.channels.first?.sampleRate ?? 250
        )
    }

    private var focusedChannel: Channel? {
        guard case .focus(let id) = layoutMode else { return nil }
        return ecgChannels.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            LeadChipBar(
                channels: ecgChannels,
                layoutMode: $layoutMode
            )
            Divider()
            bedsideContent
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bedside-view")
        .inspector(isPresented: $showFindings) {
            FindingsPanel(
                annotations: recording.annotations,
                viewport: viewport,
                sampleRate: recording.channels.first?.sampleRate ?? 250,
                filter: $filter,
                dispositionStore: dispositionStore,
                isEditing: isEditing
            )
            .inspectorColumnWidth(min: 220, ideal: 320, max: 480)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isEditing.toggle()
                } label: {
                    Label(
                        isEditing ? "Editing" : "Locked",
                        systemImage: isEditing ? "lock.open.fill" : "lock.fill"
                    )
                }
                .help(isEditing
                      ? "Editing on — notes and annotations are editable. Click to lock."
                      : "Read-only. Click to unlock and edit notes and annotations.")
                .tint(isEditing ? Color.accentColor : nil)
                .accessibilityIdentifier("edit-mode-toggle")
            }
            ToolbarItem {
                Button {
                    showFindings.toggle()
                } label: {
                    Label("Findings", systemImage: "stethoscope.circle")
                }
                .help("Show or hide the findings panel")
                .accessibilityIdentifier("findings-toggle")
            }
        }
    }

    @ViewBuilder
    private var bedsideContent: some View {
        switch layoutMode {
        case .focus:
            if let channel = focusedChannel {
                VStack(alignment: .leading, spacing: 12) {
                    summaryHeader
                    findingsOverview
                    ChannelPanel(
                        channel: channel,
                        directory: recordingDirectory,
                        viewport: viewport,
                        annotations: filteredAnnotations,
                        sizing: .focus
                    )
                    .frame(maxHeight: .infinity)
                    trendStrip
                    alarmStrip
                    stateStrip
                    qualityStrip
                }
                .padding(16)
            } else {
                ContentUnavailableView(
                    "No lead selected",
                    systemImage: "waveform",
                    description: Text("Pick a lead from the bar above.")
                )
            }
        case .strips:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryHeader
                    findingsOverview
                    ForEach(ecgChannels) { channel in
                        ChannelPanel(
                            channel: channel,
                            directory: recordingDirectory,
                            viewport: viewport,
                            annotations: filteredAnnotations,
                            sizing: .strip
                        )
                    }
                    trendStrip
                    alarmStrip
                    stateStrip
                    qualityStrip
                }
                .padding(16)
            }
        }
    }

    /// Sparkline panel for the continuous-valued vital trend channels.
    /// Hidden when no such channels exist (the legacy single-rate case
    /// stays unchanged).
    @ViewBuilder
    private var trendStrip: some View {
        if !vitalTrendChannels.isEmpty {
            ChannelTrendStrip(
                channels: vitalTrendChannels,
                recordingDirectory: recordingDirectory,
                viewport: viewport
            )
        }
    }

    /// Per-channel alarm / status lanes. Hidden when the recording carries
    /// no alarm channels.
    @ViewBuilder
    private var alarmStrip: some View {
        if !alarmChannels.isEmpty, let primary = ecgChannels.first {
            AlarmStrip(
                channels: alarmChannels,
                recordingDirectory: recordingDirectory,
                totalSamplesPrimary: primary.sampleCount,
                primarySampleRate: primary.sampleRate,
                viewport: viewport
            )
        }
    }

    /// One-row colored strip showing ventilation state (spontaneous vs
    /// assist-control). Hidden when neither probability channel is present.
    @ViewBuilder
    private var stateStrip: some View {
        let (spontaneous, assist) = stateChannels
        if (spontaneous != nil || assist != nil), let primary = ecgChannels.first {
            StateBackdropStrip(
                spontaneousChannel: spontaneous,
                assistControlChannel: assist,
                recordingDirectory: recordingDirectory,
                totalSamplesPrimary: primary.sampleCount,
                primarySampleRate: primary.sampleRate,
                viewport: viewport
            )
        }
    }

    /// Heat-band strip for `ecg_artifact_ratio` and other 0-to-1 quality
    /// metrics. Hidden when the recording carries none.
    @ViewBuilder
    private var qualityStrip: some View {
        if !qualityChannels.isEmpty, let primary = ecgChannels.first {
            QualityStrip(
                channels: qualityChannels,
                recordingDirectory: recordingDirectory,
                totalSamplesPrimary: primary.sampleCount,
                primarySampleRate: primary.sampleRate,
                viewport: viewport
            )
        }
    }

    /// Summary chip row + recording-level finding-density timeline. Both
    /// reuse `recording.annotations` so there's no new derived state to
    /// keep in sync beyond `filter` — toggling a chip narrows the timeline
    /// and the canvas in lockstep.
    @ViewBuilder
    private var findingsOverview: some View {
        if !recording.annotations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FindingsSummaryHeader(
                    summary: unfilteredSummary,
                    filter: $filter,
                    dispositionTally: dispositionStore.tally(for: recording.annotations)
                )
                if let firstChannel = recording.channels.first {
                    FindingDensityTimeline(
                        annotations: filteredAnnotations,
                        totalSamples: firstChannel.sampleCount,
                        sampleRate: firstChannel.sampleRate,
                        viewport: viewport,
                        dispositionsByID: dispositionStore.records
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.thinMaterial)
            )
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.device)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("bedside-summary")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(summaryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(navigationHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 320, alignment: .leading)

            if !recording.headerComments.isEmpty || recording.notesFileName != nil {
                RecordContextPanel(
                    headerComments: recording.headerComments,
                    notesURL: recording.notesFileName.map {
                        recordingDirectory.appendingPathComponent($0)
                    },
                    isEditing: isEditing
                )
                .accessibilityIdentifier("context-panel")
            }
        }
    }

    private var summaryDetail: String {
        let channelCount = recording.channels.count
        let duration = Self.formatDuration(seconds: totalDurationSeconds)
        let start = recording.channels.first?.startDate
            .formatted(date: .numeric, time: .standard) ?? "—"
        var detail = "\(channelCount) channels  •  \(duration)  •  starts \(start)"
        if !recording.annotations.isEmpty {
            detail += "  •  \(recording.annotations.count) annotations"
        }
        return detail
    }

    private var navigationHint: String {
        "Drag to pan  •  Pinch to zoom  •  Click the ribbon to jump"
    }

    private var totalDurationSeconds: Double {
        recording.channels.first?.durationSeconds ?? 0
    }

    private static func formatDuration(seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }
}

// MARK: - ECG grid spec (used by both Metal renderer and SwiftUI axis overlays)

/// Picks the minor / major / landmark grid spacings (in seconds / mV) for a
/// viewport of the given duration. Three tiers mirror standard ECG paper:
///   • Minor    — thin lines, finest tick (e.g. 0.04 s × 0.1 mV)
///   • Major    — every 5th minor — the calibration grid (0.2 s × 0.5 mV)
///   • Landmark — every 5th major — the second/2.5-mV beat landmark
///                used to find "1 second from here" at a glance.
/// Adaptive density keeps the active gridline count bounded across every zoom
/// level so the chart never devolves into a pink wash.
struct ECGGridSpec: Equatable {
    let xMinor: Double          // seconds
    let xMajor: Double
    let xLandmark: Double
    let yMinor: Double          // mV (or matching unit)
    let yMajor: Double
    let yLandmark: Double

    static func forDuration(seconds: Double) -> ECGGridSpec {
        // Landmark is always 5× the major — the standard clinical "every 5th"
        // landmark on printed ECG paper. The y-landmark mirrors that across
        // every tier so the chart stays clinically calibrated end-to-end.
        switch seconds {
        case ..<30:
            return ECGGridSpec(
                xMinor: 0.04, xMajor: 0.2,  xLandmark: 1.0,
                yMinor: 0.1,  yMajor: 0.5,  yLandmark: 2.5
            )
        case ..<300:        // up to 5 min
            return ECGGridSpec(
                xMinor: 0.2,  xMajor: 1.0,  xLandmark: 5.0,
                yMinor: 0.1,  yMajor: 0.5,  yLandmark: 2.5
            )
        case ..<1800:       // up to 30 min
            return ECGGridSpec(
                xMinor: 1.0,  xMajor: 5.0,  xLandmark: 25.0,
                yMinor: 0.5,  yMajor: 1.0,  yLandmark: 5.0
            )
        case ..<7200:       // up to 2 hr
            return ECGGridSpec(
                xMinor: 5.0,  xMajor: 30.0, xLandmark: 150.0,
                yMinor: 0.5,  yMajor: 2.5,  yLandmark: 12.5
            )
        default:
            return ECGGridSpec(
                xMinor: 30.0, xMajor: 300.0, xLandmark: 1500.0,
                yMinor: 1.0,  yMajor: 5.0,   yLandmark: 25.0
            )
        }
    }
}

// MARK: - Layout mode

enum BedsideLayoutMode: Equatable {
    /// Single lead, full available height — the analyst's default.
    case focus(Channel.ID)
    /// All leads stacked in compact strips — opt-in cross-lead comparison.
    case strips
}

/// Horizontal lead-chip bar with a Focus/Strips mode toggle. Single-tap a lead
/// to focus it; toggle to strips to see them all stacked.
private struct LeadChipBar: View {
    let channels: [Channel]
    @Binding var layoutMode: BedsideLayoutMode

    var body: some View {
        HStack(spacing: 10) {
            modeToggle
            Divider().frame(maxHeight: 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(channels) { channel in
                        chip(for: channel)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityIdentifier("lead-chip-bar")
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeButton(
                systemImage: "rectangle.fill",
                label: "Focus",
                isOn: isFocusMode,
                action: switchToFocus
            )
            modeButton(
                systemImage: "rectangle.split.1x2.fill",
                label: "Strips",
                isOn: layoutMode == .strips,
                action: { layoutMode = .strips }
            )
        }
    }

    private func modeButton(systemImage: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isOn ? Color.accentColor : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityIdentifier("layout-mode-\(label.lowercased())")
    }

    private func chip(for channel: Channel) -> some View {
        let isFocused = (layoutMode == .focus(channel.id))
        return Button {
            layoutMode = .focus(channel.id)
        } label: {
            Text(channel.name)
                .font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isFocused ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                )
                .overlay(
                    Capsule()
                        .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lead-chip-\(channel.name)")
    }

    private var isFocusMode: Bool {
        if case .focus = layoutMode { return true }
        return false
    }

    private func switchToFocus() {
        if case .focus = layoutMode { return }
        if let first = channels.first { layoutMode = .focus(first.id) }
    }
}

// MARK: - Channel panel

private struct ChannelPanel: View {
    enum Sizing {
        /// Strips mode — compact stacked layout. Floor is small enough that a
        /// short window can still show a couple of leads at once.
        case strip
        /// Focus mode — chart fills the available vertical space. Floor is the
        /// smallest window-height the analyst is likely to ever want.
        case focus

        var canvasMinHeight: CGFloat {
            switch self {
            case .strip: return 130
            case .focus: return 220
            }
        }

        var expands: Bool {
            self == .focus
        }
    }

    let channel: Channel
    let directory: URL
    let viewport: RecordingViewport
    let annotations: [Annotation]
    var sizing: Sizing = .strip

    @State private var canvasSize: CGSize = .zero
    @State private var clippedRanges: [ClippedRange] = []

    // Per-gesture starting state so each gesture is computed against the
    // viewport as it was when the gesture began, not the most recent update.
    @State private var dragStartRange: Range<Int64>?
    @State private var zoomStartWidth: Int64?

    private static let yMin: Double = -5
    private static let yMax: Double =  5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            HStack(alignment: .top, spacing: 0) {
                WaveformVoltageAxis(yMin: Self.yMin, yMax: Self.yMax, durationSeconds: durationSeconds)
                    .frame(minHeight: sizing.canvasMinHeight)
                canvasArea
            }
            .frame(maxHeight: sizing.expands ? .infinity : nil)
            WaveformTimeAxis(startTime: startTime, endTime: endTime)
                .padding(.leading, 56)
            OverviewRibbon(
                channel: channel,
                directory: directory,
                viewport: viewport
            )
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("channel-panel-\(channel.name)")
        .task { await scanForOffScale() }
    }

    private var canvasArea: some View {
        ZStack(alignment: .topLeading) {
            WaveformCanvas(
                channel: channel,
                directory: directory,
                startSample: viewport.startSample,
                endSample: viewport.endSample,
                annotations: visibleAnnotations
            )
            .frame(minHeight: sizing.canvasMinHeight, maxHeight: sizing.expands ? .infinity : nil)

            WaveformClippingOverlay(
                clippedRanges: clippedRanges,
                startSample: viewport.startSample,
                endSample: viewport.endSample
            )

            WaveformAnnotationOverlay(
                annotations: visibleAnnotations,
                startSample: viewport.startSample,
                endSample: viewport.endSample
            )
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: CanvasSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(CanvasSizeKey.self) { canvasSize = $0 }
        .contentShape(Rectangle())
        .gesture(panGesture())
        .gesture(zoomGesture())
    }

    /// Annotations that overlap the current viewport. Point findings are visible
    /// when their sample falls inside the range; range findings are visible when
    /// their [start, end] interval intersects it. The list is sorted by sample
    /// index, so we can scan from a small lookahead window.
    private var visibleAnnotations: [Annotation] {
        guard !annotations.isEmpty else { return [] }
        let range = viewport.rangeSamples
        return annotations.filter { ann in
            switch ann.kind {
            case .point:
                return range.contains(ann.sampleIndex)
            case .range:
                let start = ann.sampleIndex
                let end   = ann.endSampleIndex ?? ann.sampleIndex
                return end >= range.lowerBound && start < range.upperBound
            }
        }
    }

    private var startTime: Double {
        Double(viewport.startSample) / channel.sampleRate
    }
    private var endTime: Double {
        Double(viewport.endSample) / channel.sampleRate
    }
    private var durationSeconds: Double { endTime - startTime }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(channel.name).font(.headline)
            Text(channel.unit.isEmpty ? "" : "(\(channel.unit))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !clippedRanges.isEmpty {
                Label("\(clippedRanges.count) off-scale", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("\(clippedRanges.count) segment\(clippedRanges.count == 1 ? "" : "s") exceed ±5 mV and aren't drawn")
            }
            Spacer()
            Text(timeWindowLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(Int(channel.sampleRate)) Hz")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timeWindowLabel: String {
        String(format: "%.2f – %.2f s", startTime, endTime)
    }

    /// One-time scan over the full channel at panel mount. The result feeds
    /// both the chevron overlay and the header off-scale badge.
    private func scanForOffScale() async {
        let url = directory.appendingPathComponent(channel.storageFileName)
        let total = channel.sampleCount
        guard total > 0 else { return }
        let result: [ClippedRange] = await Task.detached(priority: .utility) {
            guard let access = try? BinaryRecordingFile.mappedAccess(url: url) else {
                return []
            }
            let samples = access.samples(range: 0..<total)
            return ClippedRangeScanner.scan(
                samples: samples,
                clipMin: Float(Self.yMin),
                clipMax: Float(Self.yMax)
            )
        }.value
        await MainActor.run { clippedRanges = result }
    }

    // MARK: Gestures

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartRange == nil { dragStartRange = viewport.rangeSamples }
                guard let start = dragStartRange, canvasSize.width > 0 else { return }
                let width = start.upperBound - start.lowerBound
                let samplesPerPixel = Double(width) / Double(canvasSize.width)
                let deltaSamples = Int64(-value.translation.width * samplesPerPixel)
                viewport.setStart(start.lowerBound + deltaSamples)
            }
            .onEnded { _ in dragStartRange = nil }
    }

    private func zoomGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStartWidth == nil {
                    zoomStartWidth = viewport.endSample - viewport.startSample
                }
                guard let startWidth = zoomStartWidth else { return }
                let factor = 1.0 / max(0.01, value.magnification)
                let newWidth = Int64(Double(startWidth) * factor)
                viewport.setWidth(newWidth, anchorFraction: 0.5)
            }
            .onEnded { _ in zoomStartWidth = nil }
    }
}

// MARK: - Overview ribbon

private struct OverviewRibbon: View {
    let channel: Channel
    let directory: URL
    let viewport: RecordingViewport

    @State private var bins: [PyramidBin] = []
    @State private var loadError: String?

    /// Minimum on-screen width for the viewport indicator. At deep zoom (e.g.
    /// 10 s of a 30-min recording, ~0.5%), the proportional width is a few
    /// pixels — too thin to see. We floor at this so the user can always
    /// perceive where they are. Anything wider than this stays proportional.
    private static let minIndicatorPx: CGFloat = 18
    private static let ribbonHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    envelopeChart
                    viewportIndicator(width: geo.size.width)
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geo.size.width))
            }
            .frame(height: Self.ribbonHeight)
            scaleStrip
        }
        .padding(.top, 4)
        .accessibilityIdentifier("overview-ribbon-\(channel.name)")
        .task { await loadOverview() }
    }

    /// "0s ──── 5.2 min — 5.5 min ──── 30.0 min" style scale strip. Shows the
    /// recording's total extent at the edges and the current viewport in the
    /// middle so the analyst sees both "how much we're looking at" and "where
    /// we are" at a glance.
    private var scaleStrip: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(formatDuration(0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(currentWindowLabel)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(formatDuration(totalDurationSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(height: 12)
    }

    private var totalDurationSeconds: Double {
        guard viewport.sampleRate > 0 else { return 0 }
        return Double(viewport.totalSamples) / viewport.sampleRate
    }

    private var currentWindowLabel: String {
        guard viewport.sampleRate > 0 else { return "—" }
        let startSec = Double(viewport.startSample) / viewport.sampleRate
        let endSec   = Double(viewport.endSample)   / viewport.sampleRate
        let widthSec = endSec - startSec
        return "\(formatDuration(startSec)) – \(formatDuration(endSec))  •  \(formatDuration(widthSec)) window"
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return seconds < 10
                ? String(format: "%.1f s", seconds)
                : String(format: "%.0f s", seconds)
        }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }

    @ViewBuilder
    private var envelopeChart: some View {
        if let loadError {
            Text(loadError)
                .font(.caption2)
                .foregroundStyle(.red)
        } else if bins.isEmpty {
            Rectangle().fill(.quaternary)
        } else {
            Chart {
                ForEach(Array(bins.enumerated()), id: \.offset) { idx, bin in
                    if !bin.isNaN {
                        AreaMark(
                            x: .value("Bin", idx),
                            yStart: .value("Min", bin.min),
                            yEnd: .value("Max", bin.max)
                        )
                        .foregroundStyle(.secondary.opacity(0.55))
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...Double(max(1, bins.count - 1)))
        }
    }

    private func viewportIndicator(width: CGFloat) -> some View {
        let totalSamples = Double(viewport.totalSamples)
        guard totalSamples > 0 else { return AnyView(EmptyView()) }
        let leftFrac  = Double(viewport.startSample) / totalSamples
        let widthFrac = Double(viewport.endSample - viewport.startSample) / totalSamples
        // Proportional width, but never thinner than minIndicatorPx so the
        // indicator stays perceivable at deep zoom. The indicator's center
        // still tracks the viewport center after the floor kicks in, so the
        // user can see where they are in the recording.
        let propWidth = CGFloat(widthFrac) * width
        let visibleWidth = max(Self.minIndicatorPx, propWidth)
        let centerFrac = leftFrac + widthFrac / 2
        let centerX = CGFloat(centerFrac) * width
        let leftX = max(0, min(width - visibleWidth, centerX - visibleWidth / 2))
        return AnyView(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 1.25)
                )
                .frame(width: visibleWidth)
                .offset(x: leftX)
                .allowsHitTesting(false)
        )
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                let fraction = Double(value.location.x / width)
                viewport.jump(toFraction: fraction)
            }
    }

    private func loadOverview() async {
        guard let level = selectLevel() else { return }
        let url = directory.appendingPathComponent(level.storageFileName)
        do {
            let access = try PyramidLevelFile.mappedAccess(url: url)
            let allBins = access.bins(range: 0..<access.binCount)
            await MainActor.run { bins = allBins }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
        }
    }

    private func selectLevel() -> PyramidLevel? {
        guard !channel.pyramid.isEmpty else { return nil }
        let target: Int64 = 400
        return channel.pyramid.min(by: { abs($0.binCount - target) < abs($1.binCount - target) })
    }
}

// MARK: - Layout plumbing

private struct CanvasSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - Low-rate channel partitioning

/// Splits the low-rate (`isTrendChannel == true`) subset of a recording's
/// channels into three intent-based buckets so the bedside view can render
/// each kind in its own strip.
///
/// Matching is name-based and matches what the Medallion feature store
/// emits today; producers that want explicit control can name their
/// channels to opt in or out (e.g. naming a channel `notes_status` would
/// flag it as an alarm because of the `_status` suffix).
struct LowRatePartition {
    let trends: [Channel]
    let alarms: [Channel]
    let quality: [Channel]
    let spontaneous: Channel?
    let assistControl: Channel?

    init(channels: [Channel]) {
        var trends: [Channel] = []
        var alarms: [Channel] = []
        var quality: [Channel] = []
        var spontaneous: Channel? = nil
        var assist: Channel? = nil

        for channel in channels {
            let name = channel.name
            if name == "prob_state_spontaneous" {
                spontaneous = channel
            } else if name == "prob_state_assist_control" {
                assist = channel
            } else if Self.looksLikeAlarmFlag(name) {
                alarms.append(channel)
            } else if Self.looksLikeQualityRatio(name) {
                quality.append(channel)
            } else {
                trends.append(channel)
            }
        }

        self.trends = trends
        self.alarms = alarms
        self.quality = quality
        self.spontaneous = spontaneous
        self.assistControl = assist
    }

    /// Conservative — matches the Medallion-emitted alarm/status flags and
    /// any future channel whose name carries the same suffix.
    private static func looksLikeAlarmFlag(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("_alarm")
            || lower.hasSuffix("_status")
            || lower.hasSuffix("_silenced")
    }

    /// Quality / artifact-ratio channels — anything ending in `_ratio`
    /// or whose name contains `artifact_ratio`. The Medallion paper's
    /// canonical example is `ecg_artifact_ratio`.
    private static func looksLikeQualityRatio(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("_ratio") || lower.contains("artifact_ratio")
    }
}
