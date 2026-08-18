//
//  LaunchShellView.swift
//  MurmurCore
//
//  The no-record launch shell — design handoff option 12a (#242, #252).
//
//  This replaced `WelcomeView`, a 458-line marketing card (wordmark,
//  tagline, feature bullets, an MIT-license positioning footer) that
//  greeted the analyst on every cold launch and every File ▸ New Window.
//  The product call (#242, 2026-08-14): a tool opened repeatedly should
//  not pitch itself to the person who already installed it. Everything
//  functional the card carried already had a menu-bar home — Open Record
//  is ⌘O, recents are File ▸ Open Recent — and the sample-recording and
//  drag-a-folder entry points were removed deliberately, not rehomed.
//
//  What renders instead is the 12a idea in miniature: the window looks
//  like the instrument, idle — an unhooked flatline over a quiet one-line
//  pointer at the primary action. No card, no border, no shadow. As the
//  redesign's regions land (#255, #257, #261, #263), each brings its own
//  em-dash empty state and this view recedes to just the viewer's slice;
//  the "frame never moves" discipline is theirs to enforce per region.
//

import SwiftUI

struct LaunchShellView: View {
    /// Invoked by the inline "Open Record Folder…" action — the same
    /// `fileImporter` the toolbar's overflow menu and ⌘O drive.
    let onOpenFolder: () -> Void

    /// #263 wired into the shell: the import strip renders in THIS bar while
    /// the shell is what's on screen — during a browse-pane import the
    /// detail pane is this view, and the strip is the one piece of chrome
    /// 12a lets change state between empty and loaded.
    @State private var importProgress = ImportProgressContext.shared

    /// A stable primary-lead id for the idle chip bar's constant binding —
    /// no channel carries it, so nothing renders selected.
    private static let idlePrimaryLead = UUID()

    var body: some View {
        // #304: the same window anatomy as `BedsideView.body` — chip bar,
        // one scrolling center column (stage first, context beneath), info
        // bar as the window's rail. The launch shell is the bedside, idle.
        VStack(spacing: 0) {
            LeadChipBar(
                channels: [],
                layoutMode: .constant(.focus(only: Self.idlePrimaryLead)),
                idle: true
            )
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    idleStage
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        idleContextBar
                        idleContext
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 0)
            // #305 / X83: the whole-record summary reads ABOVE the monitor —
            // the same top inset, the same strip, the same height cap as the
            // bedside's focus layout. With no recording the shared context is
            // clear, so the strip renders its unmeasured card: the launch
            // card IS the loaded card, values withheld.
            .safeAreaInset(edge: .top, spacing: 0) {
                VariabilityMetricsStrip()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.background)
                    .modifier(MetricsStripInsetHeight())
            }
            Divider()
            idleInfoBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // `UITestSupport` exists only under DEBUG — an unguarded
            // reference is a Release (archive) build break.
            #if DEBUG
            if UITestSupport.seedImportProgress {
                // #263 — same frozen mid-import state BedsideView seeds, so
                // the shell's strip is assertable without out-racing XCUI.
                ImportProgressContext.shared.update(
                    recordName: "synth-02",
                    fractionComplete: 0.41,
                    completedRecords: 3,
                    totalRecords: 12
                )
            }
            #endif
        }
    }

    // MARK: - The idle stage (#304)

    /// The pinned stage, idle: the same anatomy as `BedsideView.pinnedStage`
    /// — band ladder above, then the trace beside the docked column. The
    /// data-bound pieces (`OverviewMap`, `HourBand`, `ChannelPanel`) cannot
    /// render without a recording, so their places are held by mirrors that
    /// keep the loaded components' heights and identifiers; `BeatCalipers`
    /// CAN render empty (#246 made its nil-beat card a first-class state),
    /// so the beat card is the real component.
    private var idleStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            idleBand(label: "Record", height: 34, id: "overview-map")
            idleBand(label: "Hour", height: 32, id: "hour-band")
            HStack(alignment: .top, spacing: 12) {
                idleTraceStage
                idleDockedColumn
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pinned-stage")
    }

    /// One empty overview band: the loaded band's label column (76 pt, title
    /// over detail) beside an empty rounded box at the loaded band's height,
    /// so the record and hour bands appear by filling, not by mounting.
    private func idleBand(label: String, height: CGFloat, id: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.semibold))
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 76, alignment: .leading)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .frame(height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) band — no record")
        .accessibilityIdentifier(id)
    }

    /// The trace as a bordered stage: the unhooked flatline inside the
    /// viewer's frame with the mV badge in the loaded canvas's corner, the
    /// open line beneath the flatline INSIDE the box, and em-dash time-axis
    /// labels under it — the 12a wireframe's viewer, literally.
    private var idleTraceStage: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                VStack(spacing: 24) {
                    Spacer(minLength: 12)
                    Flatline()
                        .frame(height: 120)
                        .padding(.horizontal, 24)
                        .accessibilityHidden(true)
                    openLine
                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity)
                Text("— (mV)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
                    .accessibilityIdentifier("idle-trace-mv-badge")
            }
            .frame(minHeight: 280)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("idle-trace")
            idleTimeAxis
        }
    }

    /// Five em-dashes where the loaded axis draws its time labels — the
    /// axis exists before it has anything to say.
    private var idleTimeAxis: some View {
        HStack {
            ForEach(0..<5) { index in
                if index > 0 { Spacer() }
                Text("—")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time axis — no record")
        .accessibilityIdentifier("idle-time-axis")
    }

    /// The docked column at the loaded column's width: calibration controls
    /// idle, the beat card mounted with values withheld (the REAL
    /// `BeatCalipers` — its empty card is a designed state), the keyboard
    /// hint. Same identifiers as the bedside's, so the launch tests can
    /// assert set-equality across states.
    private var idleDockedColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            idleCalibrationControls
            BeatCalipers(
                beat: nil,
                sampleRate: 0,
                template: nil,
                qtcFormula: .fridericia,
                placeholderNote: "No record open"
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("docked-beat-inspector")
            Text("J / K next finding · ← → pan one window")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("stage-keyboard-hint")
        }
        .frame(width: BedsideGeometry.dockedColumnWidth, alignment: .topLeading)
    }

    /// `BedsideView.calibrationControls`, idle: same presets, same layout,
    /// same identifiers, every control disabled — the pane an analyst will
    /// use is already drawn, waiting for a record to give it something to
    /// act on.
    private var idleCalibrationControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Gain").font(.caption2).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                ForEach([5, 10, 20], id: \.self) { value in
                    Button("\(value)") {}
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(true)
                        .accessibilityIdentifier("gain-\(value)")
                }
                Text("mm/mV").font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 4) {
                Text("Speed").font(.caption2).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                ForEach([25, 50], id: \.self) { value in
                    Button("\(value)") {}
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(true)
                        .accessibilityIdentifier("speed-\(value)")
                }
                Text("mm/s").font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Button {} label: {
                    Label("Standard View", systemImage: "ruler")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .accessibilityIdentifier("standard-view-button")
                Button {} label: {
                    Image(systemName: "lock.open")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .accessibilityIdentifier("calibration-lock-button")
                .accessibilityLabel("Calibration unlocked")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calibration-controls")
    }

    /// #305 — the collapsed Context bar, idle: the loaded bar's anatomy
    /// (chevron, title, detail line) with the one honest thing it can say
    /// before a record supplies notes.md and the `.hea` comments. Disabled —
    /// there is no drawer to open yet — but present, so loading a record
    /// changes the detail text, never mounts a bar.
    private var idleContextBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Context")
                .font(.caption.weight(.semibold))
            Text("no record — notes.md loads with the record")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context. No record — notes.md loads with the record")
        .accessibilityIdentifier("context-bar")
    }

    /// #285 / 12a — "The trend stack renders all five lane rows with their
    /// accent rails, label columns, y-axis ticks and gridlines; plots are
    /// empty and values are em-dashes. The context region scrolls exactly as
    /// it does when loaded." The rows are `TrendStack`'s own geometry — not
    /// a redrawn likeness of it — so the skeleton cannot drift from the
    /// loaded stack's anatomy (the X61 rule, applied to layout).
    private var idleContext: some View {
        TrendStack(
            lanes: Self.idleLanes,
            recordingRange: 0...0,
            viewportRange: 0...0
        )
    }

    /// The five 12a lane rows, ids and titles matching the REAL lanes'
    /// (`BedsideTrendStack` + the `availableLanes` labels) so a record
    /// opening changes values, never which rows exist. Subtitles keep the
    /// static parts of the loaded lanes' provenance and em-dash the numbers
    /// a record would supply — inventing provenance for data that does not
    /// exist yet is the one trade DECISIONS forbids.
    ///
    /// #305: the y-axes draw each lane's DEFAULT scale (the design's values)
    /// rather than em-dashes — axes are furniture, and the decided reading
    /// of 12a is that only VALUES are blank. The quality lane keeps its
    /// em-dashes: a 26 pt row has no room for a scale.
    ///
    /// Internal (not private) so the snapshot suite can render the idle
    /// stack directly — the gutter is deliberately hidden from
    /// accessibility, so the scales can only be pinned visually.
    static let idleLanes: [TrendStackLane] = [
        TrendStackLane(
            id: BedsideTrendStack.hrLaneID,
            title: "Trends · HR",
            subtitle: "bpm · trend channel only",
            height: 86,
            accent: TrendStackLane.hrAccent
        ) { idlePlot(ticks: ["160", "100", "40"]) },
        TrendStackLane(
            id: "rmssd",
            title: "RMSSD",
            subtitle: "ms · rolling window",
            height: 86,
            accent: TrendStackLane.variabilityAccent
        ) { idlePlot(ticks: ["750", "375", "0"]) },
        TrendStackLane(
            id: "interval-trend",
            title: "Interval trend",
            subtitle: "— · — min bins",
            height: 86,
            accent: TrendStackLane.intervalAccent
        ) { idlePlot(ticks: ["500", "400", "300"]) },
        TrendStackLane(
            id: BedsideTrendStack.lfhfLaneID,
            title: "LF / HF",
            subtitle: "rolling 5 min",
            height: 86,
            accent: TrendStackLane.lfhfAccent
        ) { idlePlot(ticks: ["5.0", "2.5", "0"]) },
        TrendStackLane(
            id: BedsideTrendStack.qualityLaneID,
            title: "Quality",
            subtitle: "artifact ratio · outline over 10%",
            height: 26,
            accent: TrendStackLane.qualityAccent
        ) { idlePlot(ticks: ["—", "—", "—"]) },
    ]

    /// An empty plot cell that still draws the scale furniture 12a asks
    /// for: ticks in the shared y-gutter (top to bottom), faint gridlines at
    /// the same fractions. The gridline style matches `trendLaneYAxis()`'s
    /// `AxisGridLine`, so idle and loaded lanes share one visual grammar.
    private static func idlePlot(ticks labels: [String]) -> some View {
        let fractions: [Double] = [0.85, 0.5, 0.15]
        return HStack(spacing: 0) {
            TrendLaneScaleGutter(ticks: Array(zip(fractions, labels)))
            Canvas { context, size in
                for fraction in fractions {
                    let y = (1 - fraction) * size.height
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
                }
            }
        }
    }

    /// #285 / 12a — the info bar exists at launch with values blank. Same
    /// 28 pt, same styling, same `info-bar` identifier as the bedside's
    /// (X69), mirrored shape: what the record IS on the left, what the
    /// trace is DOING on the right — all of it em-dash, because there is
    /// no record and the bar must say so rather than vanish.
    private var idleInfoBar: some View {
        HStack(spacing: 10) {
            Text("—")
                .fontWeight(.medium)
            Text("— leads · — Hz · —")
            Spacer(minLength: 12)
            // #263 — the same global import strip the bedside bar mounts,
            // in the same position: while a browse-pane import runs, this
            // shell IS the detail pane, and the strip must not vanish just
            // because the record it announces isn't open yet.
            if let importSummary = importProgress.summary {
                ProgressView(value: importProgress.fractionComplete)
                    .controlSize(.small)
                    .frame(width: 90)
                Text(importSummary)
                Spacer(minLength: 12)
            }
            // #305 — the full trailing cluster, em-dashed. The loaded bar
            // omits a reading it does not have; the launch bar shows every
            // slot blank, because at launch absence IS the value and the
            // frame these slots occupy must not appear on load.
            Text("window —")
            Text("zoom tier —")
            Text("LOD —")
            Text("notes —")
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        // `.ignore` + explicit label rather than the bedside bar's
        // `.combine`: AX synthesis dropped this bar's em-dash-heavy children
        // and combined it into an element that spoke as nothing at all.
        // There is no button in here to lose a trait over (the X51 caveat),
        // so the one honest sentence is stated outright.
        .accessibilityElement(children: .ignore)
        // The explicit label must carry the strip too — `.ignore` means
        // nothing else will speak it.
        .accessibilityLabel(importProgress.summary
            .map { "— · — leads · — Hz · — · importing \($0) · window — · zoom tier — · LOD — · notes —" }
            ?? "— · — leads · — Hz · — · window — · zoom tier — · LOD — · notes —")
        .accessibilityIdentifier("info-bar")
    }

    /// One quiet line, deliberately not a card: `No record open ·
    /// Open Record Folder… ⌘O`. The identifiers are the welcome card's —
    /// `empty-state-prompt` / `empty-state-open-button` — so the launch
    /// tests keep asserting the same contract against the new chrome.
    private var openLine: some View {
        HStack(spacing: 6) {
            Text("No record open")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("empty-state-prompt")
            Text("·")
                .foregroundStyle(.tertiary)
            Button("Open Record Folder…") { onOpenFolder() }
                .buttonStyle(.link)
                .accessibilityIdentifier("empty-state-open-button")
            Text("⌘O")
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }
}

/// An unhooked lead: a near-zero baseline carrying faint mains noise.
/// Drawn once — the line is idle, not animated; a moving trace would claim
/// a signal exists.
private struct Flatline: View {
    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 0, y: midY))
            // Small-amplitude composite of two incommensurate frequencies —
            // reads as pickup noise, not as a rhythm. Fixed phase: the same
            // squiggle every launch, because it is furniture, not data.
            let step: CGFloat = 2
            var x: CGFloat = 0
            while x <= size.width {
                let t = x / size.width
                let noise = sin(t * 260) * 1.6 + sin(t * 47) * 0.9
                path.addLine(to: CGPoint(x: x, y: midY + noise))
                x += step
            }
            context.stroke(
                path,
                with: .color(.secondary.opacity(0.45)),
                lineWidth: 1
            )
        }
    }
}
