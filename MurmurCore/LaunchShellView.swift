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

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            Flatline()
                .frame(height: 120)
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .accessibilityHidden(true)
            openLine
                .padding(.top, 28)
            idleContext
                .padding(.top, 28)
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

    /// #285 / 12a — "The trend stack renders all five lane rows with their
    /// accent rails, label columns, y-axis ticks and gridlines; plots are
    /// empty and values are em-dashes. The context region scrolls exactly as
    /// it does when loaded." The rows are `TrendStack`'s own geometry — not
    /// a redrawn likeness of it — so the skeleton cannot drift from the
    /// loaded stack's anatomy (the X61 rule, applied to layout).
    private var idleContext: some View {
        ScrollView {
            TrendStack(
                lanes: Self.idleLanes,
                recordingRange: 0...0,
                viewportRange: 0...0
            )
            .frame(maxWidth: 720)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    /// The five 12a lane rows, ids and titles matching the REAL lanes'
    /// (`BedsideTrendStack` + the `availableLanes` labels) so a record
    /// opening changes values, never which rows exist. Subtitles keep the
    /// static parts of the loaded lanes' provenance and em-dash the numbers
    /// a record would supply — inventing provenance for data that does not
    /// exist yet is the one trade DECISIONS forbids.
    private static let idleLanes: [TrendStackLane] = [
        TrendStackLane(
            id: BedsideTrendStack.hrLaneID,
            title: "Trends · HR",
            subtitle: "bpm · trend channel only",
            height: 86,
            accent: TrendStackLane.hrAccent
        ) { idlePlot() },
        TrendStackLane(
            id: "rmssd",
            title: "RMSSD",
            subtitle: "ms · rolling window",
            height: 86,
            accent: TrendStackLane.variabilityAccent
        ) { idlePlot() },
        TrendStackLane(
            id: "interval-trend",
            title: "Interval trend",
            subtitle: "— · — min bins",
            height: 86,
            accent: TrendStackLane.intervalAccent
        ) { idlePlot() },
        TrendStackLane(
            id: BedsideTrendStack.lfhfLaneID,
            title: "LF / HF",
            subtitle: "rolling 5 min",
            height: 86,
            accent: TrendStackLane.lfhfAccent
        ) { idlePlot() },
        TrendStackLane(
            id: BedsideTrendStack.qualityLaneID,
            title: "Quality",
            subtitle: "artifact ratio · outline over 10%",
            height: 26,
            accent: TrendStackLane.qualityAccent
        ) { idlePlot() },
    ]

    /// An empty plot cell that still draws the scale furniture 12a asks
    /// for: em-dash ticks in the shared y-gutter, faint gridlines at the
    /// same fractions. The gridline style matches `trendLaneYAxis()`'s
    /// `AxisGridLine`, so idle and loaded lanes share one visual grammar.
    private static func idlePlot() -> some View {
        let fractions: [Double] = [0.15, 0.5, 0.85]
        return HStack(spacing: 0) {
            TrendLaneScaleGutter(ticks: fractions.map { ($0, "—") })
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
            Text("window —")
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
            .map { "— · — leads · — Hz · — · importing \($0) · window —" }
            ?? "— · — leads · — Hz · — · window —")
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
