//
//  FindingsPanel.swift
//  MurmurCore
//
//  The right-side review-queue rail. Findings are grouped by category
//  (human-labelled where possible), sorted by departure from the
//  per-patient normal template rather than file order, and topped with
//  a rhythm-context banner drawn from the record's own header. The
//  common mass of within-template beats collapses to a single line at
//  the bottom so 1,688 normals don't cost 1,688 rows of scroll.
//
//  Design spec: `project_findings_review_queue_design.md`.
//  Mockup: Planning/design/findings-review-queue.html.
//
//  Filter state lives in `FindingFilter`. The same filter is consumed
//  by the pinned overview map so a category toggle narrows both
//  surfaces in lock-step.
//

import SwiftUI

// MARK: - Sort model

/// Sort order for the review queue. Free-tier default is `.structural`
/// — non-normal classes surfaced above the collapsed normal mass,
/// ordered by frequency. `.departure` is the ECG Metrics unlock: it
/// ranks by how far each beat departs from the per-patient normal
/// template, which requires the paid measurement layer. Free-tier
/// callers may still pick `.departure`; without an owned template it
/// degrades to the structural ordering (no arithmetic ever runs in
/// MurmurCore — the sort just has nothing to sort by).
public enum FindingSort: String, CaseIterable, Identifiable {
    case structural
    case departure
    case time
    case confidence
    case category

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .structural: return "By kind"
        case .departure:  return "Departure ↓"
        case .time:       return "Time"
        case .confidence: return "Confidence"
        case .category:   return "Category"
        }
    }
}

// MARK: - Filter model

/// Which review state the queue is showing (X75).
///
/// Not part of `FindingFilter`, deliberately. Every other dimension there is a
/// property of the ANNOTATION — its category, its producer, its confidence —
/// and can be answered from the annotation alone. Disposition is a property of
/// the analyst's review of it, and lives in `DispositionStore`. Folding it into
/// `matches(_:)` would mean either passing the store into a value type or
/// giving that type a lookup it cannot perform.
enum DispositionFilter: String, CaseIterable, Sendable, Equatable {
    case toReview
    case confirmed
    case dismissed

    var label: String {
        switch self {
        case .toReview: return "To review"
        case .confirmed: return "Confirmed"
        case .dismissed: return "Dismissed"
        }
    }

    /// Does a finding in this review state belong in this bucket?
    ///
    /// ABSENCE is the unreviewed state — `DispositionStore` materialises no
    /// row until the analyst acts, so "to review" is `nil`, not a stored value.
    /// Reading it any other way would show an empty queue on a fresh record,
    /// which is the one case where the queue has the most to say.
    func admits(_ state: AnnotationDisposition.State?) -> Bool {
        switch self {
        case .toReview: return state == nil
        case .confirmed: return state == .confirmed
        case .dismissed: return state == .dismissed
        }
    }
}

public struct FindingFilter: Equatable {
    public var categories: Set<String> = []
    public var sources: Set<String> = []
    public var minConfidence: Double = 0.0

    public init() {}

    public var isActive: Bool {
        !categories.isEmpty || !sources.isEmpty || minConfidence > 0.0
    }

    public func matches(_ ann: Annotation) -> Bool {
        if !categories.isEmpty && !categories.contains(ann.category) { return false }
        if !sources.isEmpty    && !sources.contains(ann.source)      { return false }
        if minConfidence > 0, let conf = ann.confidence, conf < minConfidence { return false }
        return true
    }
}

// MARK: - Panel

struct FindingsPanel: View {
    let annotations: [Annotation]
    let viewport: RecordingViewport
    let sampleRate: Double
    /// Header comment lines from the recording — powers the rhythm-
    /// context banner. Empty is fine; the banner hides itself.
    let headerComments: [String]
    @Binding var filter: FindingFilter
    let dispositionStore: DispositionStore
    let isEditing: Bool
    /// When true, finding jumps preserve the current zoom (the 10 s window
    /// lock is engaged). Candidate jumps always preserve zoom regardless.
    var lockZoom: Bool = false

    /// VT/VF model candidates for the current recording, as range
    /// annotations (source `VTVFCandidateSource.id`). Rendered as ONE
    /// provenance-tagged group, ranked by model score WITHIN the group —
    /// never merged into the departure ordering (different measurements).
    /// Empty when no scan has been applied or the VT/VF IAP isn't owned.
    var candidates: [Annotation] = []
    /// Time-region-keyed dispositions for the candidates (survive rescan).
    /// Distinct from `dispositionStore`, which keys on annotation id.
    var candidateDispositionStore: VTVFCandidateDispositionStore? = nil
    /// RUO notice shown on the candidate group header (one of the two
    /// allowed RUO surfaces; the other is the scan dialog).
    var regulatoryNotice: String = "RESEARCH USE ONLY — not for diagnosis"
    /// Operating point the candidates were produced at (τ / min-dur /
    /// merge-gap / model) — the group's subtitle + citation payload.
    var parametersCaption: String?
    /// Structured model provenance recorded onto a disposition when the analyst
    /// confirms a candidate (sidecar only, never exported to WFDB). Defaulted
    /// nil so snapshot/other callers stay unaffected.
    var candidateProvenance: VTVFScanContext.ModelProvenance? = nil

    /// Arrhythmia-scan candidates (A2) for the current recording, as range
    /// annotations (source `ArrhythmiaCandidateSource.id`). Rendered as their
    /// OWN provenance-tagged group in TIME order — these are algorithmic
    /// detector spans, not model scores, so they never interleave with the
    /// VT/VF score ranking or the departure ranking. Empty when no scan ran.
    var arrhythmiaCandidates: [Annotation] = []
    /// Region-keyed dispositions for the arrhythmia candidates. A separate
    /// store (own sidecar) from the VT/VF one — the two detectors' spans
    /// overlap freely and must never inherit each other's review calls.
    var arrhythmiaDispositionStore: VTVFCandidateDispositionStore? = nil
    /// Operating points + per-recording quality read for the arrhythmia
    /// scan — the group's subtitle, per "provenance is not decoration".
    var arrhythmiaParametersCaption: String? = nil
    /// RUO notice for the arrhythmia group's badge. Kept separate from the
    /// VT/VF `regulatoryNotice`, which the orchestrator may source from
    /// model metadata — this detector has no model to speak for it.
    var arrhythmiaRegulatoryNotice: String = "RESEARCH USE ONLY — not for diagnosis"
    /// A3: the scan's calibrated per-window pre-flight read — rendered in
    /// the dials popover so the analyst sees what the σ lookup says about
    /// this recording's signal BEFORE weighing its candidates.
    var arrhythmiaPreflightWindows: [ArrhythmiaPreflightWindow] = []

    /// #250 — rename an analyst-authored finding. The panel offers the
    /// affordance; the OWNER performs the replace-and-persist, because the
    /// annotation stores live in BedsideView (same division as the jump and
    /// disposition hooks). Nil = no rename anywhere (previews, tests that
    /// don't care).
    var onRenameFinding: ((Annotation, String) -> Void)? = nil
    /// #250 — reports when the rename field is on screen, so the owner can
    /// raise `BedsideCommands.textEntryActive` and the bedside's plain-key
    /// shortcuts (J/K pan, disposition keys) stay out of the analyst's
    /// typing — the same wiring the notes editor has.
    var onRenameFieldActive: ((Bool) -> Void)? = nil

    /// The finding being renamed, driving the rename dialog. Text state is
    /// seeded from the row's current display label at open.
    @State private var renameTarget: Annotation?
    @State private var renameText: String = ""

    @State private var sort: FindingSort = .structural
    @State private var expandedGroups: Set<String> = []
    @State private var showNormals: Bool = false
    /// X48 §5: per-group RENDER bound (not a ranking or filter). A group shows
    /// at most this many rows until the analyst extends it; a group with more
    /// carries an explicit extend control. Keyed by group id; absent = default.
    @State private var groupRenderBounds: [String: Int] = [:]
    @State private var candidateGroupExpanded: Bool = true
    /// How many candidate rows are rendered. X75: the group opens collapsed to
    /// its top 5 because 25 near-identical rows push every category off-screen,
    /// and the categories are what the analyst is triaging by.
    @State private var candidateRenderBound: Int = FindingsPanel.candidateCollapsedBound
    @State private var arrhythmiaGroupExpanded: Bool = true
    /// X91: the rate-band dials popover, anchored to the group header's
    /// settings button.
    @State private var showingArrhythmiaDials = false
    @State private var scanSettings = ArrhythmiaScanSettings.shared
    /// Same X75 render bound rationale as the VT/VF group.
    @State private var arrhythmiaRenderBound: Int = FindingsPanel.candidateCollapsedBound
    /// Which review state the queue is showing. Defaults to the work that
    /// remains, which is what a queue is for.
    @State private var dispositionFilter: DispositionFilter = .toReview

    /// Findings the analyst has just acted on, which stay visible until they
    /// move to another bucket.
    ///
    /// Without this, confirming a finding in the "To review" bucket makes the
    /// row vanish under the cursor — taking its own Reset button with it, so a
    /// misclick becomes a two-step recovery through another bucket and the
    /// analyst loses their place in a list they were working down. Acting on
    /// something should not make it unreachable.
    ///
    /// Cleared when the bucket changes: the exemption is "you are still
    /// looking at this", not a permanent pin.
    @State private var recentlyActed: Set<UUID> = []

    static let candidateCollapsedBound = 5

    /// Read of the shared fiducial store so per-annotation departure
    /// scoring can consult the per-patient normal template. Empty
    /// context = no departure ranking (falls back to count-descending).
    @State private var markingsContext = IntervalMarkingsContext.shared

    /// Entitlement state — read live so a purchase completing while
    /// the panel is open flips the departure sort's locked chrome off
    /// without a relaunch.
    @State private var purchaseStore = PurchaseStore.shared

    /// True when the paid measurement layer can actually rank by
    /// departure. Ownership alone isn't enough — a per-patient template
    /// must exist, which requires beats + delineation to have finished.
    private var departureSortAvailable: Bool {
        purchaseStore.hasStudio && markingsContext.template != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !headerContextLines.isEmpty || !atrRhythmTokens.isEmpty {
                rhythmContextBanner
                Divider()
            }
            queueList
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("findings-panel")
        .onAppear(perform: applyUITestExpandOverride)
        // Attach-findings and producer runs add new categories after
        // onAppear fires. Re-apply the override when the annotation
        // list changes so newly-arrived categories (e.g. "ATTACH")
        // stay expanded for the test that dropped them in.
        .onChange(of: annotations.count) { _, _ in
            applyUITestExpandOverride()
        }
        // #250 — the rename dialog. An alert rather than an inline field:
        // inline editors in lists fight click-to-jump (the row IS a button),
        // and the issue names the context menu as the safer first cut.
        .alert(
            "Rename Finding",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { presented in
                    if !presented {
                        renameTarget = nil
                        onRenameFieldActive?(false)
                    }
                }
            )
        ) {
            TextField("Name", text: $renameText)
                .accessibilityIdentifier("finding-rename-field")
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let target = renameTarget, !trimmed.isEmpty {
                    onRenameFinding?(target, trimmed)
                }
            }
            .accessibilityIdentifier("finding-rename-save")
            Button("Cancel", role: .cancel) {}
        } message: {
            // The label-vs-caption split, stated where the analyst acts on it.
            Text("Renames this finding in the queue and exports. "
                 + "The measured citation is unchanged.")
        }
    }

    /// Under a UI test, expand every group's exemplar list so tests can
    /// address `finding-row-<category>` directly (X65 — expanded is now the
    /// default under XCUI; `--ui-test-collapse-findings-groups` opts back
    /// out). Analyst behaviour is unchanged; the toggle path still works —
    /// the override just widens the set to include every category present.
    private func applyUITestExpandOverride() {
        #if DEBUG
        guard UITestSupport.shouldExpandFindingsGroups else { return }
        let allCategories = Set(annotations.map(\.category))
        expandedGroups = allCategories
        #endif
    }

    // MARK: - Header (triage tally + sort + filter)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Review queue")
                    .font(.headline)
                Text("\(flaggedFiltered.count) of \(flaggedAnnotations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                // Sort keeps a VISIBLE control (DECISIONS §7): it changes the
                // meaning of the list order, and it carries the departure
                // unlock seam — a purchase seam inside an overflow menu is a
                // seam nobody finds.
                sortMenu
                overflowMenu
            }
            dispositionFilterBar
            ectopyBurdenLine
            departureUnlockSeam
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The disposition segments (X75).
    ///
    /// This REPLACES the passive triage tally rather than sitting beside it.
    /// The tally already showed exactly these three counts; adding a filter
    /// with the same numbers next to it would have put the same information on
    /// screen twice and left the analyst to work out which one was clickable.
    private var dispositionFilterBar: some View {
        HStack(spacing: 6) {
            ForEach(DispositionFilter.allCases, id: \.self) { bucket in
                dispositionChip(bucket)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("disposition-filter")
    }

    private func dispositionChip(_ bucket: DispositionFilter) -> some View {
        let isOn = dispositionFilter == bucket
        let count = dispositionCount(bucket)
        return Button {
            dispositionFilter = bucket
            // The just-acted exemption is "you are still looking at this".
            // Moving to another bucket ends that.
            recentlyActed.removeAll()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(dispositionColor(bucket))
                    .frame(width: 6, height: 6)
                Text(bucket.label)
                    .font(.caption2)
                    .foregroundStyle(isOn ? .primary : .secondary)
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(isOn
                ? Color.accentColor.opacity(0.18)
                : Color.secondary.opacity(0.08)))
            .overlay(Capsule().stroke(isOn
                ? Color.accentColor
                : Color.secondary.opacity(0.15), lineWidth: isOn ? 1 : 0.5))
        }
        .buttonStyle(.plain)
        .help("Show \(bucket.label.lowercased()) findings")
        .accessibilityLabel("\(bucket.label), \(count)\(isOn ? ", selected" : "")")
        .accessibilityIdentifier("disposition-filter-\(bucket.rawValue)")
    }

    /// "To review" uses `.blue` — disposition state gets its own token per the
    /// ratified 2026-07-05 amber de-confliction. Amber (`.orange`) is reserved
    /// for analyst-marked findings; painting an unreviewed count amber would
    /// collide with that meaning.
    private func dispositionColor(_ bucket: DispositionFilter) -> Color {
        switch bucket {
        case .toReview: return .blue
        case .confirmed: return .green
        case .dismissed: return .secondary
        }
    }

    private func dispositionCount(_ bucket: DispositionFilter) -> Int {
        switch bucket {
        case .toReview: return tally.unreviewed
        case .confirmed: return tally.confirmed
        case .dismissed: return tally.dismissed
        }
    }

    /// Category and confidence filters, plus the group controls.
    ///
    /// The button carries an active-filter dot. Without it a narrowed queue is
    /// indistinguishable from a quiet recording, and the control that narrowed
    /// it is behind a menu the analyst would have to open to find out.
    private var overflowMenu: some View {
        Menu {
            categoryMenuContent
            Divider()
            confidenceMenuContent
        } label: {
            Image(systemName: filter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .foregroundStyle(filter.isActive ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(filter.isActive ? "Filters active — category, confidence" : "Filter by category or confidence")
        .accessibilityLabel(filter.isActive ? "Filters, active" : "Filters")
        .accessibilityIdentifier("findings-filter-menu")
    }

    /// C7/X29: ventricular-ectopy burden + run grouping over the annotation
    /// stream — factual counts, never a verdict. Recording-level, so it reads
    /// the full annotation set (not the filtered subset).
    private var ectopySummary: EctopyRunSummary {
        EctopyAnalyzer.summarize(annotations)
    }

    @ViewBuilder
    private var ectopyBurdenLine: some View {
        let summary = ectopySummary
        if summary.hasEctopy {
            Text(ectopyBurdenText(summary))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ectopy-burden-line")
        }
    }

    private func ectopyBurdenText(_ summary: EctopyRunSummary) -> String {
        // X56 §4: name the population — a denominator without one can't be
        // reconciled against the other beat counts on screen (annotations,
        // template, QT-excluded), which are genuinely different populations.
        // X110 (§1.5): every run clause carries its rate — the count alone
        // can't separate NSVT-range from AIVR-range, and the analyst should
        // never have to compute what the intervals already say.
        var parts = [String(format: "Ventricular ectopy: %.1f%% of %d annotated beats",
                            summary.burdenPercent, summary.totalBeatCount)]
        parts.append(contentsOf: summary.runClauses(sampleRate: sampleRate))
        return parts.joined(separator: " · ")
    }

    /// The review workload = FLAGGED (non-normal) annotations only. The
    /// within-template normal mass is collapsed into its own "nothing
    /// flagged" row, so counting it in the queue total or the "to review"
    /// tally contradicts that row (X34). Normals are never a review task.
    private var flaggedAnnotations: [Annotation] {
        annotations.filter { !isNormalCategory($0.category) }
    }

    private var flaggedFiltered: [Annotation] {
        filtered.filter { !isNormalCategory($0.category) }
    }

    private var tally: DispositionStore.Tally {
        dispositionStore.tally(for: flaggedAnnotations)
    }

    // X75: `triageTally`, `tallyChip` and `filterChips` lived here.
    //
    // The tally's three counts BECAME the disposition filter — it already
    // showed exactly those numbers, so keeping both would have put the same
    // information on screen twice and left the analyst to work out which one
    // was clickable. The chip row's category and confidence menus moved into
    // the header's overflow; sort stayed visible (DECISIONS §7).

    private var sortMenu: some View {
        Menu {
            ForEach(FindingSort.allCases) { mode in
                Button {
                    sort = mode
                } label: {
                    Label(
                        sortMenuTitle(mode),
                        systemImage: sortCheckmark(mode)
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2)
                Text("Sort: \(effectiveSort.displayName)")
                    .font(.caption)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.10)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.30), lineWidth: 0.5))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort findings by \(effectiveSort.displayName.lowercased())")
        .accessibilityIdentifier("findings-sort-picker")
    }

    /// Menu item title — names the purchase that unlocks `.departure` when
    /// the measurement layer can't back it, so the paid seam reads as
    /// what it is (a locked capability, not a mystery inert option).
    /// Names "Murmur Studio", the actual product: the former "ECG Metrics"
    /// label pointed at a per-module IAP retired in the single-IAP pivot,
    /// so it sent the reader looking for something unbuyable.
    private func sortMenuTitle(_ mode: FindingSort) -> String {
        if mode == .departure && !departureSortAvailable {
            return "\(mode.displayName) — Murmur Studio"
        }
        return mode.displayName
    }

    /// Checkmark logic keys off `effectiveSort` so the picker's tick
    /// stays truthful about what's actually being applied — otherwise
    /// selecting `.departure` when locked would show a checkmark next
    /// to `.departure` while the queue still renders structurally.
    private func sortCheckmark(_ mode: FindingSort) -> String {
        return effectiveSort == mode ? "checkmark" : ""
    }

    /// Small caption under the sort chip that names the paid unlock
    /// when the analyst is looking at the free-tier structural view.
    /// Hidden once Murmur Studio is owned AND a template exists — at
    /// that point the departure sort is a first-class picker option
    /// and the seam is no longer needed.
    @ViewBuilder
    private var departureUnlockSeam: some View {
        if !departureSortAvailable {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Rank by departure from this patient's normal — Murmur Studio")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityIdentifier("departure-sort-unlock-seam")
        }
    }

    /// Rows only. X75 moved these into the overflow menu, so the chip label
    /// they used to carry — and the `findings-category-picker` id on it —
    /// no longer exist; the row ids the tests bind to are unchanged.
    @ViewBuilder
    private var categoryMenuContent: some View {
        Section("Category") {
            Button {
                filter.categories.removeAll()
            } label: {
                Label("All categories", systemImage: filter.categories.isEmpty ? "checkmark" : "")
            }
            .accessibilityIdentifier("findings-category-filter-all")
            ForEach(availableCategories, id: \.self) { cat in
                Button {
                    toggleCategory(cat)
                } label: {
                    Label(Self.humanLabel(for: cat), systemImage: filter.categories.contains(cat) ? "checkmark" : "")
                }
                .accessibilityIdentifier("findings-category-filter-\(cat)")
            }
        }
    }

    @ViewBuilder
    private var confidenceMenuContent: some View {
        Section("Confidence") {
            ForEach([0.0, 0.5, 0.75, 0.9], id: \.self) { threshold in
                Button {
                    filter.minConfidence = threshold
                } label: {
                    let label = threshold == 0 ? "any" : "≥ \(Int(threshold * 100))%"
                    Label(label, systemImage: filter.minConfidence == threshold ? "checkmark" : "")
                }
                .accessibilityIdentifier("findings-confidence-filter-\(Int(threshold * 100))")
            }
        }
    }

    private func chipLabel(key: String, value: String, highlighted: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(highlighted ? Color.accentColor : .primary)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(highlighted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08))
        )
        .overlay(
            Capsule().stroke(highlighted ? Color.accentColor.opacity(0.30) : Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    private var availableCategories: [String] {
        Array(Set(annotations.map(\.category))).sorted()
    }

    private func toggleCategory(_ category: String) {
        if filter.categories.contains(category) {
            filter.categories.remove(category)
        } else {
            filter.categories.insert(category)
        }
    }

    // MARK: - Rhythm-context banner

    /// Header-derived context lines — meds / patient notes / clinical
    /// annotations from the `.hea` file. These come from the recording
    /// header, NOT the annotation stream, so they get their own line
    /// per the ratified mockup review G provenance split (2026-07-05).
    private var headerContextLines: [String] {
        headerComments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Rhythm-change categories present in the recording's annotation
    /// stream (typically `.atr`) — the second half of the ratified
    /// provenance split. Renders as a compact list of unique rhythm
    /// tokens ("AFIB", "VT", "…") so the analyst can see at a glance
    /// which rhythms the annotator flagged over the recording.
    private var atrRhythmTokens: [String] {
        // WFDB `+` rhythm-change markers carry the annotator's rhythm label in
        // their AUX field, decoded into `note` at import (C2). Surface the
        // distinct labels VERBATIM, in time order. Displayed as-is (the app
        // never translates "AFIB" into "atrial fibrillation" in this row — the
        // label is the annotator's, not the app's reading).
        var seen = Set<String>()
        var ordered: [String] = []
        for ann in rhythmMarkers where ann.note != nil {
            guard let note = ann.note, !note.isEmpty else { continue }
            if seen.insert(note).inserted { ordered.append(note) }
        }
        return ordered
    }

    /// `+` rhythm-change markers in time order.
    private var rhythmMarkers: [Annotation] {
        annotations
            .filter { $0.category.trimmingCharacters(in: .whitespaces) == "+" }
            .sorted { $0.sampleIndex < $1.sampleIndex }
    }

    /// The rhythm label prevailing at the current viewport start — the last
    /// `+` marker at or before it, since a `+` sets the rhythm until the next
    /// one. Gives the analyst the "which rhythm am I in right now" context the
    /// review queue otherwise can't answer (C2). Verbatim annotator label.
    private var prevailingRhythm: String? {
        let start = viewport.startSample
        let labelled = rhythmMarkers.filter { $0.note?.isEmpty == false }
        return (labelled.last { $0.sampleIndex <= start } ?? labelled.first)?.note
    }

    private var rhythmContextBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            // SF Symbol replaces the earlier emoji — reads as a
            // Mac-native research instrument to the analyst audience
            // (mockup review H, ratified 2026-07-05).
            Image(systemName: "waveform.path.ecg")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Rhythm context")
                    .font(.caption.weight(.semibold))
                if let prevailing = prevailingRhythm {
                    provenanceLine(
                        label: "At viewport",
                        detail: prevailing,
                        source: "prevailing `.atr` rhythm marker at the current view"
                    )
                }
                if !atrRhythmTokens.isEmpty {
                    provenanceLine(
                        label: "Rhythms",
                        detail: atrRhythmTokens.joined(separator: " · "),
                        source: "from `.atr` rhythm markers"
                    )
                }
                if !headerContextLines.isEmpty {
                    provenanceLine(
                        label: "Clinical notes",
                        detail: headerContextLines.joined(separator: " · "),
                        source: "from `.hea` header — analyst-editable in Notes"
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rhythm-context-banner")
    }

    private func provenanceLine(label: String, detail: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(source)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Queue list

    private var filtered: [Annotation] {
        annotations
            .filter(filter.matches)
            .filter { annotation in
                // Normals are never a review task (X34) — they collapse into
                // their own row and must not vanish when the analyst looks at
                // "Confirmed", which would make that row's count contradict
                // the queue around it.
                if isNormalCategory(annotation.category) { return true }
                if recentlyActed.contains(annotation.id) { return true }
                return dispositionFilter.admits(dispositionStore.state(for: annotation.id))
            }
    }

    @ViewBuilder
    private var queueList: some View {
        if filtered.isEmpty && sortedCandidates.isEmpty && sortedArrhythmiaCandidates.isEmpty
            && !arrhythmiaScanRan {
            ContentUnavailableView(
                "No findings",
                systemImage: "magnifyingglass",
                description: Text(filter.isActive
                    ? "No findings match the current filters."
                    : "This recording has no annotated findings.")
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    // Model candidates lead the queue as one distinct
                    // group — its score ranking is not comparable with the
                    // departure ranking below, so it never interleaves.
                    if !sortedCandidates.isEmpty {
                        candidateGroupSection
                    }
                    // Arrhythmia detector candidates — their own group, in
                    // time order (not a score ranking), same non-interleave
                    // rule as the VT/VF group. X91: the group stays mounted
                    // whenever a scan RAN, even at zero candidates —
                    // otherwise tightening the dials until nothing qualifies
                    // would unmount the very controls needed to loosen them,
                    // and "0 at these thresholds" is itself a finding.
                    if !sortedArrhythmiaCandidates.isEmpty || arrhythmiaScanRan {
                        arrhythmiaGroupSection
                    }
                    ForEach(deviationRankedGroups) { group in
                        groupRow(group)
                    }
                    if !collapsedNormals.entries.isEmpty {
                        collapsedNormalsRow
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - Group rendering

    /// The fiducial boundaries a group's category is defined BY, or empty when
    /// it is not defined by any (#249).
    ///
    /// Deliberately a whitelist rather than a best-effort mapping. A category
    /// with no fiducial meaning must return empty and keep its group colour
    /// dot — the alternative is a letter that reads as a claim about the
    /// waveform.
    static func fiducialSpanLetters(for category: String) -> [MarkingsFiducialLayer] {
        switch category.trimmingCharacters(in: .whitespaces).uppercased() {
        case "QT-MANUAL": return [.qrs, .t]
        default:          return []
        }
    }

    private func groupRow(_ group: FindingGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)
        return VStack(spacing: 0) {
            Button {
                toggleGroup(group.id)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 9)
                    // #249 — the letter tags reach the queue only where a row
                    // actually denotes fiducial boundaries, which is one
                    // category: QT-MANUAL is "analyst-placed Q-onset →
                    // T-offset spans", so QRS and T are what it is bounded by.
                    //
                    // Every other group here is a WFDB annotation category —
                    // V/PVC, A/APC, E, ~, + — describing a BEAT or a rhythm
                    // transition, not a wave boundary. Giving those a P, QRS or
                    // T would be inventing a meaning the data does not carry,
                    // which is worse than an inconsistent-looking list: it
                    // would teach the analyst a vocabulary that is wrong.
                    if Self.fiducialSpanLetters(for: group.category).isEmpty {
                        Circle()
                            .fill(group.color)
                            .frame(width: FiducialPalette.queueGlyphDiameter,
                                   height: FiducialPalette.queueGlyphDiameter)
                    } else {
                        HStack(spacing: 1) {
                            ForEach(Self.fiducialSpanLetters(for: group.category),
                                    id: \.self) { layer in
                                FiducialLetterTag(
                                    layer: layer,
                                    pointSize: FiducialPalette.queueLetterPointSize)
                            }
                        }
                        .accessibilityIdentifier("queue-fiducial-letters")
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.humanLabel)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let subLabel = group.subLabel {
                            Text(subLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(group.count)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(group.color)
                        Text(group.provenanceLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isExpanded ? Color.secondary.opacity(0.05) : Color.clear)
            )
            // X51 §1 (REOPENED X56 §3): `.accessibilityLabel` ALONE on a Button
            // with a composed multi-Text label sets XCUIElement.label but does
            // NOT synthesise a real AX name — VoiceOver and the raw AX API still
            // read "button" with name=[missing value]. `.combine` collapses the
            // label's children into one leaf that carries an actual name, while
            // KEEPING the button trait (unlike `.ignore`, which strips it and
            // breaks `app.buttons["finding-group-…"]`). Combine first, then the
            // explicit name + id. See feedback_swiftui_accessibility_contain.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.groupRowAXLabel(group))
            .accessibilityIdentifier("finding-group-\(group.category)")
            .contextMenu { groupContextMenu(for: group) }

            if isExpanded {
                exemplarRows(for: group)
            }
        }
    }

    /// X90: right-click on a group header offers Dismiss All. Same latch as
    /// the per-row disposition buttons — outside edit mode the builder is
    /// empty and macOS shows no menu at all. Only UNREVIEWED findings are
    /// dismissed (`DispositionStore.dismissAll`); the title says so whenever
    /// that makes it fewer than the whole group, so the analyst is never
    /// surprised by which rows changed. Operates on the group AS RENDERED —
    /// the filtered entries — dismissing what the analyst is looking at, not
    /// rows a filter is hiding.
    @ViewBuilder
    private func groupContextMenu(for group: FindingGroup) -> some View {
        if isEditing {
            let unreviewed = group.entries.filter {
                dispositionStore.record(for: $0.annotation.id) == nil
            }
            Button(
                unreviewed.count == group.entries.count
                    ? "Dismiss All (\(unreviewed.count))"
                    : "Dismiss \(unreviewed.count) Unreviewed"
            ) {
                let acted = dispositionStore.dismissAll(unreviewed.map(\.annotation.id))
                recentlyActed.formUnion(acted)
            }
            .disabled(unreviewed.isEmpty)
            .accessibilityIdentifier("group-dismiss-all-\(group.category)")
        }
    }

    /// Composes the group row's spoken label from the same facts it displays.
    private static func groupRowAXLabel(_ group: FindingGroup) -> String {
        var parts = [group.humanLabel]
        if let sub = group.subLabel { parts.append(sub) }
        parts.append("\(group.count)")
        parts.append(group.provenanceLabel)
        return parts.joined(separator: ", ")
    }

    /// Default per-group render bound (X48 §5). A ROW count, not a pixel
    /// threshold — canvas-independent by construction. 1,825 rows in one group
    /// is unusable, so a group renders at most this many in the active sort
    /// order until the analyst extends it. Bounds RENDERING only; the ranking,
    /// the dispositions and the header count are untouched.
    static let defaultGroupRenderBound = 50

    private func exemplarRows(for group: FindingGroup) -> some View {
        let bound = groupRenderBounds[group.id] ?? Self.defaultGroupRenderBound
        let shown = Array(group.entries.prefix(bound))
        let remaining = group.entries.count - shown.count
        return VStack(spacing: 1) {
            ForEach(shown, id: \.annotation.id) { entry in
                exemplarRow(entry: entry, groupColor: group.color)
            }
            if remaining > 0 {
                extendGroupControl(group: group, remaining: remaining, currentBound: bound)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 4)
        .padding(.bottom, 4)
    }

    /// X48 §5: raises a group's render bound. Two steps — one page more, or the
    /// whole group. Phrased as a rendering choice ("showing N of M"), never as a
    /// filter that dropped beats; the group header keeps the full count.
    @ViewBuilder
    private func extendGroupControl(group: FindingGroup, remaining: Int, currentBound: Int) -> some View {
        HStack(spacing: 12) {
            Text("showing \(group.count - remaining) of \(group.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Button("Show \(min(remaining, Self.defaultGroupRenderBound)) more") {
                groupRenderBounds[group.id] = currentBound + Self.defaultGroupRenderBound
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .accessibilityIdentifier("group-show-more-\(group.category)")
            if remaining > Self.defaultGroupRenderBound {
                Button("Show all (\(group.count))") {
                    groupRenderBounds[group.id] = group.count
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("group-show-all-\(group.category)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func exemplarRow(entry: FindingEntry, groupColor: Color) -> some View {
        // Disposition buttons must be SIBLINGS of the row's jump button
        // (not children of it) so XCUI can address each disposition-*-<id>
        // element independently. Nesting them inside the outer Button's
        // label collapses the entire subtree into one hit target.
        HStack(alignment: .center, spacing: 8) {
            Button {
                jump(to: entry.annotation, preserveZoom: lockZoom)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(groupColor)
                        .frame(width: 6, height: 6)
                    Text(entry.annotation.displayLabel)
                        .font(.caption.weight(.semibold))
                    if let conf = entry.annotation.confidence {
                        Text("· \(confidenceLabel(for: entry.annotation, value: conf))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if let note = entry.annotation.note, !note.isEmpty {
                        // Annotator's verbatim label — e.g. a `+` marker's
                        // rhythm string ("AFIB") decoded from the .atr AUX
                        // field (C2). Never reworded into clinical prose;
                        // provenance is the .atr.
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let departureLabel = entry.departureLabel {
                        // Neutral ink per the ratified 2026-07-05 B-RUO
                        // rule — an app-computed departure magnitude in
                        // a caution hue reads as a verdict the RUO
                        // framing does not permit. Sign + magnitude
                        // carry the direction.
                        Text(departureLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.primary)
                    }
                    Text(formatTime(entry.annotation.sampleIndex))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("finding-row-\(entry.annotation.category)")

            if isEditing {
                dispositionButtons(for: entry.annotation)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(dispositionStore.record(for: entry.annotation.id)?.state == .dismissed ? 0.5 : 1.0)
        .contextMenu { rowContextMenu(for: entry.annotation) }
    }

    /// #250 — Rename, offered ONLY for analyst-authored findings. Imported
    /// WFDB annotations and producer findings keep their source-given
    /// labels: renaming someone else's annotation would falsify provenance,
    /// which is the same reason the groups are provenance-tagged. macOS
    /// shows no menu at all when the builder is empty, so read-only rows
    /// behave exactly as before.
    @ViewBuilder
    private func rowContextMenu(for annotation: Annotation) -> some View {
        // Behind the Editing latch, like the disposition buttons and every
        // other analyst edit — renaming is an authoring act that goes
        // through the same door authoring does.
        if isEditing,
           annotation.source == Annotation.analystAuthoredSource,
           onRenameFinding != nil {
            Button("Rename…") {
                renameText = annotation.displayLabel
                renameTarget = annotation
                onRenameFieldActive?(true)
            }
            .accessibilityIdentifier("finding-rename-\(annotation.id.uuidString)")
        }
    }

    /// Label for the numeric confidence value shown on exemplar rows.
    /// A `wfdb.atr`-sourced annotation carries expert ground truth, so
    /// the number is the fiducial store's morphology-cluster-assignment
    /// confidence — labelled as such rather than the bare "conf" which
    /// read as uncertainty about the reference annotation itself
    /// (mockup review F, 2026-07-05). Producer-sourced findings keep
    /// the "conf" label — that IS the producer's own confidence.
    private func confidenceLabel(for ann: Annotation, value: Double) -> String {
        let formatted = String(format: "%.2f", value)
        let source = ann.source.lowercased()
        if source.contains("wfdb.atr") || source.contains("wfdb-atr") {
            return "cluster match \(formatted)"
        }
        return "conf \(formatted)"
    }

    private func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) {
            expandedGroups.remove(id)
        } else {
            expandedGroups.insert(id)
        }
    }

    // MARK: - Collapsed normals row

    private var collapsedNormalsRow: some View {
        Button {
            showNormals.toggle()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(CategoryPalette.swiftUIColor(for: "N").opacity(0.55))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(collapsedNormalsTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("nothing flagged — these collapse here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                // X48 §4(a): attribute the grouping to its actual source, in the
                // same tertiary provenance chip the flagged sibling groups use.
                // The row is the annotator's normal-beat code, NOT an app-computed
                // template — so it must carry `wfdb.atr` like everything else and
                // must not speak in the app's voice ("this patient's template").
                Text(collapsedNormalsProvenance)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(showNormals ? "hide" : "show all")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        // X51 §1 (REOPENED X56 §3): `.combine` so this Button gets a real AX
        // name (not just an XCUIElement.label) while keeping its button trait —
        // the X48 XCUI assertion binds to the count + source here.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collapsedNormalsTitle), \(collapsedNormalsProvenance), nothing flagged")
        .accessibilityIdentifier("collapsed-normals-row")
    }

    /// X48 §4(a): the collapse row's title states what SELECTED these beats —
    /// the annotator's normal-beat code — rather than claiming they came from an
    /// app-computed "patient's template" (they don't; the template's beat
    /// membership is exactly this same annotator code, see
    /// `Recording.normalBeatSampleIndices`). Phrased for the annotator when the
    /// source is `wfdb.atr`; the provenance chip carries the source either way.
    private var collapsedNormalsTitle: String {
        let n = collapsedNormals.count
        if collapsedNormalsProvenance.hasPrefix("wfdb.atr") {
            return "\(n) beats the annotator coded normal"
        }
        return "\(n) beats coded normal"
    }

    /// Provenance for the collapsed-normals row, computed the same way the
    /// flagged sibling groups compute theirs — so "who said normal" reads
    /// consistently across the whole rail. (`entries` is `[Annotation]` here,
    /// so it can't reuse the `[FindingEntry]` overload directly.)
    private var collapsedNormalsProvenance: String {
        let sources = Set(collapsedNormals.entries.map(\.source))
        if sources.count == 1, let only = sources.first { return only }
        return "mixed (\(sources.count) sources)"
    }

    // MARK: - Disposition buttons (inline on expanded exemplars)

    private func dispositionButtons(for annotation: Annotation) -> some View {
        HStack(spacing: 3) {
            // Confirm uses a Menu so the analyst can narrow the call
            // to VT / VF / unsure. Matches the pre-redesign contract
            // the disposition XCUI tests exercise.
            Menu {
                Button("Confirm as VT") {
                    dispositionStore.confirm(annotation.id, kind: .vt)
                    recentlyActed.insert(annotation.id)
                }
                Button("Confirm as VF") {
                    dispositionStore.confirm(annotation.id, kind: .vf)
                    recentlyActed.insert(annotation.id)
                }
                Button("Confirm (unsure)") {
                    dispositionStore.confirm(annotation.id, kind: nil)
                    recentlyActed.insert(annotation.id)
                }
            } label: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Confirm this finding")
            // AX2: image-only control; without a label VoiceOver reads the
            // symbol's own description ("Selected") on every finding row.
            .accessibilityLabel("Confirm finding")
            .accessibilityIdentifier("disposition-confirm-\(annotation.id.uuidString)")

            Button {
                dispositionStore.dismiss(annotation.id)
                recentlyActed.insert(annotation.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this finding as a false positive")
            // AX2: image-only control; label it so VoiceOver doesn't read the
            // symbol name ("Close") on every finding row.
            .accessibilityLabel("Dismiss finding")
            .accessibilityIdentifier("disposition-dismiss-\(annotation.id.uuidString)")

            if dispositionStore.record(for: annotation.id) != nil {
                Button {
                    dispositionStore.reset(annotation.id)
                    recentlyActed.insert(annotation.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Mark as unreviewed")
                .accessibilityIdentifier("disposition-reset-\(annotation.id.uuidString)")
            }
        }
        .font(.caption)
    }

    // MARK: - Group derivation

    /// Groups sorted by aggregate departure (descending) for
    /// `.departure` sort, or by the requested mode otherwise. Normal-
    /// beat annotations are pulled out into `collapsedNormals` first.
    private var deviationRankedGroups: [FindingGroup] {
        var buckets: [String: [FindingEntry]] = [:]
        for ann in filtered where !isNormalCategory(ann.category) {
            let departure = departureScore(for: ann)
            let entry = FindingEntry(
                annotation: ann,
                departure: departure,
                departureLabel: departureLabel(for: ann, departure: departure)
            )
            buckets[ann.category, default: []].append(entry)
        }

        let groups: [FindingGroup] = buckets.map { category, entries in
            FindingGroup(
                category: category,
                humanLabel: Self.humanLabel(for: category),
                subLabel: subLabel(for: category),
                color: CategoryPalette.swiftUIColor(for: category),
                count: entries.count,
                aggregateDeparture: entries.compactMap(\.departure).max() ?? 0,
                provenanceLabel: uniqueSourceLabel(entries),
                entries: sortedEntries(entries)
            )
        }
        return groups.sorted { lhs, rhs in
            switch effectiveSort {
            case .structural:
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.category < rhs.category
            case .departure:
                if lhs.aggregateDeparture != rhs.aggregateDeparture {
                    return lhs.aggregateDeparture > rhs.aggregateDeparture
                }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.category < rhs.category
            case .time:
                let lhsMin = lhs.entries.map(\.annotation.sampleIndex).min() ?? 0
                let rhsMin = rhs.entries.map(\.annotation.sampleIndex).min() ?? 0
                return lhsMin < rhsMin
            case .confidence:
                let lhsMax = lhs.entries.compactMap(\.annotation.confidence).max() ?? 0
                let rhsMax = rhs.entries.compactMap(\.annotation.confidence).max() ?? 0
                if lhsMax != rhsMax { return lhsMax > rhsMax }
                return lhs.category < rhs.category
            case .category:
                return lhs.category < rhs.category
            }
        }
    }

    /// Resolved sort — collapses `.departure` to `.structural` when the
    /// measurement layer can't back it (no ownership or no template
    /// yet). No arithmetic runs in MurmurCore; the sort just has no
    /// scores to sort by, so falling back keeps the queue coherent.
    private var effectiveSort: FindingSort {
        if sort == .departure && !departureSortAvailable { return .structural }
        return sort
    }

    private func sortedEntries(_ entries: [FindingEntry]) -> [FindingEntry] {
        switch effectiveSort {
        case .structural:
            // Within a group, structural sort presents by time — the
            // group itself is the "kind" axis. Time keeps navigation
            // predictable across scrolls.
            return entries.sorted { $0.annotation.sampleIndex < $1.annotation.sampleIndex }
        case .departure:
            return entries.sorted { (lhs, rhs) in
                (lhs.departure ?? 0) > (rhs.departure ?? 0)
            }
        case .time:
            return entries.sorted { $0.annotation.sampleIndex < $1.annotation.sampleIndex }
        case .confidence:
            return entries.sorted { (lhs, rhs) in
                (lhs.annotation.confidence ?? 0) > (rhs.annotation.confidence ?? 0)
            }
        case .category:
            return entries.sorted { $0.annotation.sampleIndex < $1.annotation.sampleIndex }
        }
    }

    private func uniqueSourceLabel(_ entries: [FindingEntry]) -> String {
        let sources = Set(entries.map(\.annotation.source))
        if sources.count == 1, let only = sources.first { return only }
        return "mixed (\(sources.count) sources)"
    }

    /// The collapsed-normals summary. Aggregates every annotation whose
    /// category maps to "normal beat" — the mass the analyst opened the
    /// tool to escape.
    private var collapsedNormals: CollapsedNormalsSummary {
        let normals = filtered.filter { isNormalCategory($0.category) }
        return CollapsedNormalsSummary(count: normals.count, entries: normals)
    }

    private func isNormalCategory(_ category: String) -> Bool {
        let normalized = category.trimmingCharacters(in: .whitespaces).uppercased()
        return normalized == "N" || normalized == "NORMAL" || normalized == "SINUS"
    }

    // MARK: - Departure scoring

    /// How far this annotation departs from the per-patient template,
    /// in raw ms units. Returns nil when no defined score exists —
    /// which is the common case for range findings and comments; those
    /// still sort by count/time within their group.
    private func departureScore(for ann: Annotation) -> Double? {
        // Non-morphology markers and escape beats never carry a meaningful
        // QRS-width / QT departure: `~` (noise) and `+`/`|`/`"` are not
        // beats, and `E` (ventricular escape) is a LATE beat whose relevant
        // quantity is the preceding R-R, not a width departure (C1). Without
        // this guard a marker landing near a beat spuriously shows a
        // departure it has no business claiming (AX audit item 5).
        let rawCategory = ann.category.trimmingCharacters(in: .whitespaces)
        if ["~", "+", "|", "\"", "E"].contains(rawCategory) { return nil }
        // Beat-aligned point annotations can consult the fiducial
        // store. Match beat by rPeakSampleIndex ≈ annotation's
        // sampleIndex (nearest within a small tolerance).
        guard ann.kind == .point else { return nil }
        guard let template = markingsContext.template else { return nil }
        guard let beat = markingsContext.nearestBeat(toSampleIndex: ann.sampleIndex) else {
            return nil
        }
        let tolerance = Int64(sampleRate * 0.15)   // 150 ms
        guard abs(beat.rPeakSampleIndex - ann.sampleIndex) <= tolerance else { return nil }
        if let qtc = beat.qtcMs, let m = template.medianQTcMs { return abs(qtc - m) }
        if let qrs = beat.qrsMs, let m = template.medianQRSMs { return abs(qrs - m) }
        if let qt = beat.qtMs, let m = template.medianQTMs { return abs(qt - m) }
        return nil
    }

    private func departureLabel(for ann: Annotation, departure: Double?) -> String? {
        guard let d = departure else { return nil }
        let sign = d >= 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.0f", abs(d))) ms"
    }

    // MARK: - Category → human label mapping

    /// Human-friendly label for common WFDB / producer category codes.
    /// Unknown categories pass through as-is so this layer stays open
    /// to whatever a producer emits.
    /// Case-sensitive WFDB codes — case is MEANINGFUL in the standard, so
    /// these match the raw symbol before the case-insensitive table below.
    /// Verified against the WFDB ecgcodes table: `a` (4) aberrated atrial
    /// premature ≠ `A` (8) atrial premature; `E` (10) ventricular escape;
    /// `~` (14) signal-quality change. Uppercasing alone silently
    /// conflated `a` into `A` and dropped the word "aberrated".
    private static let caseSensitiveLabels: [String: String] = [
        "a": "Aberrated atrial premature",
        "E": "Ventricular escape",
        "~": "Signal-quality change",
    ]

    private static let categoryLabels: [String: String] = [
        "V":     "Ventricular ectopy",
        "PVC":   "Ventricular ectopy — PVC",
        "A":     "Atrial premature",
        "APC":   "Atrial premature (APC)",
        "N":     "Normal beat",
        "+":     "Rhythm-change marker",
        "|":     "Isolated QRS-like artifact",
        "\"":    "Annotator comment",
        "F":     "Fusion beat",
        "L":     "LBBB beat",
        "R":     "RBBB beat",
        "QT-MANUAL": "Manual QT calipers",
        "AFIB":  "Atrial fibrillation",
        "VT":    "Ventricular tachycardia",
        "VF":    "Ventricular fibrillation",
        "NOISE": "Signal quality — noise",
        // #250 — the creation sites stamp this internal constant as the
        // category; the header was rendering it raw. The stored category is
        // untouched: only the display maps.
        "ANALYST_FINDING": "Analyst findings",
    ]

    /// Static and internal (not private) so the mapping is unit-testable —
    /// the raw `ANALYST_FINDING` token leaking into the queue header (#250)
    /// is exactly the regression a test on this function catches.
    static func humanLabel(for category: String) -> String {
        let raw = category.trimmingCharacters(in: .whitespaces)
        return Self.caseSensitiveLabels[raw]
            ?? Self.categoryLabels[raw.uppercased()]
            ?? category
    }

    /// Optional sub-label under the group title. Explains what
    /// "departure" is measuring for this category, so ranking never
    /// reads as a clinical verdict.
    /// Base measurement/descriptor for a group, WITHOUT any ordering claim.
    /// The "ranked by …" prefix is added conditionally by `groupSubtitle`
    /// only when the departure sort is actually in effect (AX5) — otherwise
    /// the header would assert an order the rows (chronological) don't show.
    private func subLabel(for category: String) -> String? {
        let raw = category.trimmingCharacters(in: .whitespaces)
        // Case-sensitive WFDB codes first (see humanLabel).
        switch raw {
        case "a":  return "coupling-interval departure"
        // `E` is a LATE beat (the sinus/AV node failed to deliver), the
        // opposite mechanism to ectopy — the meaningful quantity is the
        // preceding R-R (how long the pause was), never a QRS-width
        // departure. departureScore is suppressed for `E` accordingly.
        case "E":  return "preceding R-R interval"
        case "~":  return "annotator quality transitions"
        default:   break
        }
        let key = raw.uppercased()
        switch key {
        case "V", "PVC":  return "QRS-width departure from patient normal"
        case "A", "APC":  return "coupling-interval departure"
        case "+":         return "annotator rhythm transitions"
        case "|":         return "non-beat deflections flagged for exclusion"
        case "\"":        return "original database notes — verbatim"
        case "QT-MANUAL": return "analyst-placed Q-onset → T-offset spans"
        case "NOISE":     return "interval stats suppressed inside"
        default:          return nil
        }
    }

    // X20 (K9): the group subtitle is a stable DESCRIPTOR of what the group's
    // departure measures ("QRS-width departure from patient normal"), never a
    // sort-conditional "ranked by …" claim. Per K9 the ranking is made
    // visible + falsifiable by the per-row departure magnitudes
    // (`departureLabel`), not asserted in the header — so this superseded the
    // Phase-B conditional-subtitle approach. subLabel(for:) is used directly.

    // MARK: - Jump

    /// Recenter the viewport on `ann`.
    ///
    /// `preserveZoom` keeps the analyst's current time window (only pans,
    /// centering on the finding's onset) — used for candidate jumps and for
    /// any jump while the 10 s window lock is on, so the window never shifts
    /// out from under someone thinking in fixed time spans. When false, a
    /// range finding zooms to fit its span with lead-in context.
    private func jump(to ann: Annotation, preserveZoom: Bool = false) {
        let total = viewport.totalSamples
        guard total > 0 else { return }
        if !preserveZoom, ann.kind == .range, let endSample = ann.endSampleIndex {
            let spanSamples = endSample - ann.sampleIndex
            let context = max(spanSamples * 2, Int64(sampleRate * 5))
            viewport.setWidth(spanSamples + context, anchorFraction: 0.5)
        }
        let centerSample = preserveZoom
            ? ann.sampleIndex                              // onset
            : (ann.sampleIndex + ann.renderEndSample) / 2  // midpoint
        viewport.animateJump(toFraction: Double(centerSample) / Double(total))
    }

    private func formatTime(_ sample: Int64) -> String {
        guard sampleRate > 0 else { return "—" }
        let s = Double(sample) / sampleRate
        if s >= 3600 {
            return String(format: "%d:%02d:%02d",
                          Int(s / 3600),
                          Int(s.truncatingRemainder(dividingBy: 3600) / 60),
                          Int(s.truncatingRemainder(dividingBy: 60)))
        }
        return String(format: "%d:%05.2f",
                      Int(s / 60),
                      s.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - VT/VF candidate group
    //
    // Candidates enter the EXISTING queue as ONE provenance-tagged group,
    // ranked by MODEL SCORE within the group only. Rows state COORDINATES,
    // never conclusions — the app never composes "VT detected". All model
    // output is NEUTRAL ink; amber appears only once a candidate is
    // confirmed into an analyst finding. Dispositions route to the
    // time-region store so they survive a rescan.
    // (project_vtvf_candidate_review_flow.md)

    /// Candidates ranked by model score (confidence), descending, in the
    /// current disposition bucket.
    ///
    /// The filter reaches candidates too, even though their dispositions live
    /// in a different store keyed on time region rather than annotation id.
    /// A filter that silently skipped one group would make "Confirmed" show
    /// every candidate alongside the confirmed findings — the analyst would
    /// reasonably read that as "these candidates are confirmed". The two
    /// stores stay separate and the two RANKINGS still never interleave; only
    /// the review-state question is asked of both.
    private var sortedCandidates: [Annotation] {
        candidates
            .filter { candidate in
                if recentlyActed.contains(candidate.id) { return true }
                let state = candidateDispositionStore?.state(
                    forStart: candidate.sampleIndex,
                    end: candidate.renderEndSample
                )
                return dispositionFilter.admits(state)
            }
            .sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
    }

    private var candidateGroupSection: some View {
        VStack(spacing: 0) {
            candidateGroupHeader
            if candidateGroupExpanded {
                let shown = Array(sortedCandidates.prefix(candidateRenderBound))
                let remaining = sortedCandidates.count - shown.count
                VStack(spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, cand in
                        candidateRow(rank: index, candidate: cand)
                    }
                    if remaining > 0 {
                        // Phrased as a rendering choice, never as a filter that
                        // dropped candidates — the group header keeps the full
                        // count, same rule as `extendGroupControl`.
                        HStack(spacing: 12) {
                            Text("top \(shown.count) of \(sortedCandidates.count)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            Button("Show \(remaining) more") {
                                candidateRenderBound = sortedCandidates.count
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier("vtvf-candidate-show-more")
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vtvf-candidate-group")
        // Reliable, addressable count leaf (the container id itself isn't
        // always matchable through the ScrollView/LazyVStack — see
        // project_swiftui_accessibility_contain).
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("vtvf-candidate-count")
                .accessibilityLabel("\(sortedCandidates.count)")
                .allowsHitTesting(false)
        }
    }

    private var candidateGroupHeader: some View {
        Button {
            candidateGroupExpanded.toggle()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: candidateGroupExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 9)
                // Neutral slate dot — model output is never painted in a
                // caution hue (RUO).
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Candidate VT/VF episodes")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        ruoBadge(regulatoryNotice)
                    }
                    Text(candidateSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("\(sortedCandidates.count)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(candidateGroupExpanded ? Color.secondary.opacity(0.05) : Color.clear)
        )
        .accessibilityIdentifier("vtvf-candidate-group-header")
    }

    /// The RUO badge — the findings-queue surface is one of the two allowed
    /// PER-OUTPUT RUO surfaces (the VT/VF scan-dialog header is the other).
    /// Both candidate groups' badges are THIS one surface; keeping output
    /// badges to exactly these two is what keeps them credible
    /// (feedback_research_use_only_framing.md). The once-only first-launch
    /// disclosure (X4b, `RUOFirstRunNotice`) is deliberately NOT counted
    /// here: it speaks about the app's posture before any output exists,
    /// not about an output — the two kinds must not be conflated, or the
    /// badge count starts growing by analogy.
    private func ruoBadge(_ notice: String) -> some View {
        Text("RUO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
            .foregroundStyle(.secondary)
            .help(notice)
            .accessibilityLabel("Research use only")
    }

    private var candidateSubtitle: String {
        var parts = ["Ranked by model score — not comparable with departure ranking"]
        if let caption = parametersCaption, !caption.isEmpty {
            parts.append(caption)
        }
        return parts.joined(separator: " · ")
    }

    private func candidateRow(rank: Int, candidate: Annotation) -> some View {
        let start = candidate.sampleIndex
        let end = candidate.renderEndSample
        let state = candidateDispositionStore?.state(forStart: start, end: end)
        let score = candidate.confidence ?? 0
        return HStack(alignment: .center, spacing: 8) {
            Button {
                jump(to: candidate, preserveZoom: true)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    candidateStateGlyph(state)
                    VStack(alignment: .leading, spacing: 1) {
                        // Coordinates, never a conclusion.
                        Text("\(formatTime(start))–\(formatTime(end))")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(candidateDurationLabel(start: start, end: end)) · score \(String(format: "%.2f", score))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    candidateScoreBar(score)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("vtvf-candidate-row-\(rank)")

            if isEditing, candidateDispositionStore != nil {
                candidateDispositionButtons(rank: rank, id: candidate.id, start: start, end: end, hasRecord: state != nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(state == .dismissed ? 0.5 : 1.0)
        // Addressable disposition state for XCUI wire-up assertions. A
        // dedicated hidden leaf carrying the state as its accessibilityLabel
        // reads reliably from XCUI (the ui-test-viewport-state pattern) —
        // a value on a children:.contain container does not.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("vtvf-candidate-state-\(rank)")
                .accessibilityLabel(candidateStateLabel(state))
                .allowsHitTesting(false)
        }
    }

    /// Confirmed = amber (the only place amber is allowed for a candidate).
    /// Unreviewed / dismissed stay neutral.
    @ViewBuilder
    private func candidateStateGlyph(_ state: AnnotationDisposition.State?) -> some View {
        switch state {
        case .confirmed:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .dismissed:
            Image(systemName: "xmark.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case nil:
            Circle()
                .fill(Color.secondary)
                .frame(width: 6, height: 6)
        }
    }

    private func candidateStateLabel(_ state: AnnotationDisposition.State?) -> String {
        switch state {
        case .confirmed: return "confirmed"
        case .dismissed: return "dismissed"
        case nil:        return "unreviewed"
        }
    }

    private func candidateDurationLabel(start: Int64, end: Int64) -> String {
        guard sampleRate > 0 else { return "—" }
        let seconds = Double(end - start) / sampleRate
        if seconds >= 60 {
            return String(format: "%d:%02d min", Int(seconds / 60), Int(seconds.truncatingRemainder(dividingBy: 60)))
        }
        return String(format: "%.1f s", seconds)
    }

    /// Neutral score bar — magnitude only, no caution colouring.
    private func candidateScoreBar(_ score: Double) -> some View {
        let clamped = min(1, max(0, score))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.12))
            GeometryReader { geo in
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: geo.size.width * clamped)
            }
        }
        .frame(width: 44, height: 5)
    }

    /// Confirms a candidate region, stamping the current model provenance onto
    /// the disposition record (sidecar only — never exported to WFDB).
    private func confirmCandidate(start: Int64, end: Int64, kind: AnnotationDisposition.ConfirmedKind?) {
        candidateDispositionStore?.confirm(
            start: start,
            end: end,
            kind: kind,
            modelIdentifier: candidateProvenance?.modelIdentifier,
            modelVersion: candidateProvenance?.modelVersion,
            tauAtConfirmation: candidateProvenance?.tau
        )
    }

    private func candidateDispositionButtons(rank: Int, id: UUID, start: Int64, end: Int64, hasRecord: Bool) -> some View {
        HStack(spacing: 3) {
            Menu {
                Button("Confirm as VT") {
                    confirmCandidate(start: start, end: end, kind: .vt)
                    recentlyActed.insert(id)
                }
                Button("Confirm as VF") {
                    confirmCandidate(start: start, end: end, kind: .vf)
                    recentlyActed.insert(id)
                }
                Button("Confirm (unsure)") {
                    confirmCandidate(start: start, end: end, kind: .unclassified)
                    recentlyActed.insert(id)
                }
            } label: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Confirm this candidate as an analyst finding")
            .accessibilityIdentifier("vtvf-candidate-confirm-\(rank)")

            Button {
                candidateDispositionStore?.dismiss(start: start, end: end)
                recentlyActed.insert(id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this candidate as a false positive")
            .accessibilityIdentifier("vtvf-candidate-dismiss-\(rank)")

            if hasRecord {
                Button {
                    candidateDispositionStore?.reset(start: start, end: end)
                    recentlyActed.insert(id)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Mark as unreviewed")
                .accessibilityIdentifier("vtvf-candidate-reset-\(rank)")
            }
        }
        .font(.caption)
    }

    // MARK: - Arrhythmia candidate group (A2)
    //
    // Same shape as the VT/VF group: candidates enter the EXISTING queue as
    // ONE provenance-tagged group; rows state facts (kind, span, "median 50
    // bpm"), never conclusions; all output is NEUTRAL ink; dispositions
    // route to a region-keyed store so they survive a rescan. The one
    // deliberate difference: rows are in TIME order. These spans come from
    // algorithmic detectors whose `confidence` is measurement reliability —
    // ranking by it would present reliability as a severity score.

    /// True when the arrhythmia scan has published for this recording —
    /// the caption travels with every publish, so its presence IS the
    /// "scan ran" signal (nil in the free viewer and before first publish).
    private var arrhythmiaScanRan: Bool {
        arrhythmiaParametersCaption?.isEmpty == false
    }

    /// Arrhythmia candidates in time order, in the current disposition
    /// bucket. Same reasoning as `sortedCandidates` for why the disposition
    /// filter reaches them.
    private var sortedArrhythmiaCandidates: [Annotation] {
        arrhythmiaCandidates
            .filter { candidate in
                if recentlyActed.contains(candidate.id) { return true }
                let state = arrhythmiaDispositionStore?.state(
                    forStart: candidate.sampleIndex,
                    end: candidate.renderEndSample
                )
                return dispositionFilter.admits(state)
            }
            .sorted { $0.sampleIndex < $1.sampleIndex }
    }

    private var arrhythmiaGroupSection: some View {
        VStack(spacing: 0) {
            arrhythmiaGroupHeader
            if arrhythmiaGroupExpanded {
                let shown = Array(sortedArrhythmiaCandidates.prefix(arrhythmiaRenderBound))
                let remaining = sortedArrhythmiaCandidates.count - shown.count
                VStack(spacing: 1) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, cand in
                        arrhythmiaCandidateRow(rank: index, candidate: cand)
                    }
                    if remaining > 0 {
                        HStack(spacing: 12) {
                            Text("first \(shown.count) of \(sortedArrhythmiaCandidates.count)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            Button("Show \(remaining) more") {
                                arrhythmiaRenderBound = sortedArrhythmiaCandidates.count
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier("arrhythmia-candidate-show-more")
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("arrhythmia-candidate-group")
        // Addressable count leaf — same pattern as `vtvf-candidate-count`.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("arrhythmia-candidate-count")
                .accessibilityLabel("\(sortedArrhythmiaCandidates.count)")
                .allowsHitTesting(false)
        }
    }

    private var arrhythmiaGroupHeader: some View {
        HStack(spacing: 0) {
            arrhythmiaGroupHeaderButton
            arrhythmiaDialsButton
        }
    }

    private var arrhythmiaGroupHeaderButton: some View {
        Button {
            arrhythmiaGroupExpanded.toggle()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: arrhythmiaGroupExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 9)
                // Neutral slate dot — detector output is never painted in a
                // caution hue (RUO).
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Candidate rhythm events")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        ruoBadge(arrhythmiaRegulatoryNotice)
                    }
                    Text(arrhythmiaSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("\(sortedArrhythmiaCandidates.count)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(arrhythmiaGroupExpanded ? Color.secondary.opacity(0.05) : Color.clear)
        )
        .accessibilityIdentifier("arrhythmia-candidate-group-header")
    }

    // MARK: - Rate-band dials (X91)

    /// Sits BESIDE the header button, not inside its label — a control
    /// nested in another Button's label would swallow the header's
    /// expand/collapse click.
    private var arrhythmiaDialsButton: some View {
        Button {
            showingArrhythmiaDials.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Rate-band detection thresholds")
        .accessibilityLabel("Rate-band detection settings")
        .accessibilityIdentifier("arrhythmia-scan-settings")
        .padding(.trailing, 10)
        .popover(isPresented: $showingArrhythmiaDials, arrowEdge: .bottom) {
            arrhythmiaDialsPopover
        }
    }

    /// The analyst's dials. Every change republishes through the scan
    /// orchestrator (its task keys on these values), and the values in
    /// effect are echoed in the group caption — the X58 discipline: the
    /// numbers on screen always name the thresholds that produced them.
    private var arrhythmiaDialsPopover: some View {
        @Bindable var settings = scanSettings
        return VStack(alignment: .leading, spacing: 12) {
            Text("Rate-band detection")
                .font(.subheadline.weight(.semibold))
            arrhythmiaDialRow(
                label: "Bradycardia below",
                value: $settings.lowBpm,
                unit: "bpm",
                step: 5,
                identifier: "arrhythmia-dial-low"
            )
            arrhythmiaDialRow(
                label: "Tachycardia above",
                value: $settings.highBpm,
                unit: "bpm",
                step: 5,
                identifier: "arrhythmia-dial-high"
            )
            arrhythmiaDialRow(
                label: "Run of at least",
                value: $settings.minRunBeats,
                unit: "beats",
                step: 1,
                identifier: "arrhythmia-dial-beats"
            )
            arrhythmiaDialRow(
                label: "Sustained at least",
                value: $settings.minDurationSeconds,
                unit: "s",
                step: 5,
                identifier: "arrhythmia-dial-window"
            )
            Text("The beat minimum is time at the run's own rate — beats are "
                + "never counted. 0 = no minimum. Thresholds define "
                + "candidates, not diagnoses; changing them rescans the "
                + "recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A3: the pre-flight read — the σ lookup's verdict on this
            // recording's signal, stated up front so the analyst weighs the
            // candidates knowing what the measurements were worth. The app
            // states its confidence; the analyst sets the bar.
            if let preflight = ArrhythmiaScanContext.preflightSummary(
                windows: arrhythmiaPreflightWindows) {
                Divider()
                Text("Signal-quality pre-flight")
                    .font(.subheadline.weight(.semibold))
                Text(preflight)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arrhythmia-preflight-read")
            }
            HStack {
                Spacer()
                Button("Reset to 45–120 bpm, ≥ 5 beats") {
                    settings.resetToDefaults()
                }
                .disabled(settings.isDefault)
                .accessibilityIdentifier("arrhythmia-dials-reset")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func arrhythmiaDialRow(
        label: String,
        value: Binding<Double>,
        unit: String,
        step: Double,
        identifier: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
            Spacer(minLength: 8)
            TextField("", value: value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .accessibilityIdentifier(identifier)
            Stepper("", value: value, step: step)
                .labelsHidden()
                .accessibilityLabel(label)
            Text(unit)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
        }
    }

    private var arrhythmiaSubtitle: String {
        var parts = ["In time order — detector spans, not a ranking"]
        if let caption = arrhythmiaParametersCaption, !caption.isEmpty {
            parts.append(caption)
        }
        return parts.joined(separator: " · ")
    }

    private func arrhythmiaCandidateRow(rank: Int, candidate: Annotation) -> some View {
        let start = candidate.sampleIndex
        let end = candidate.renderEndSample
        let state = arrhythmiaDispositionStore?.state(forStart: start, end: end)
        return HStack(alignment: .center, spacing: 8) {
            Button {
                jump(to: candidate, preserveZoom: true)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    candidateStateGlyph(state)
                    VStack(alignment: .leading, spacing: 1) {
                        // Kind + the service's factual detail — coordinates
                        // and measurements, never a conclusion.
                        HStack(spacing: 6) {
                            Text(candidate.displayLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let note = candidate.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 6) {
                            Text("\(formatTime(start))–\(formatTime(end))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(candidateDurationLabel(start: start, end: end))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            if let conf = candidate.confidence {
                                // A3: measurement confidence made legible —
                                // the number is the calibrated reliability of
                                // the beat measurement under this span's
                                // signal quality, and saying so is what keeps
                                // it from reading as a severity score.
                                Text(String(format: "conf %.2f", conf))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .help("Measurement confidence — the calibrated reliability of the beat detection under this span's signal quality. Not a severity score; rows stay in time order.")
                            }
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("arrhythmia-candidate-row-\(rank)")

            if isEditing, arrhythmiaDispositionStore != nil {
                arrhythmiaDispositionButtons(rank: rank, id: candidate.id, start: start, end: end, hasRecord: state != nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(state == .dismissed ? 0.5 : 1.0)
        // Addressable disposition state for XCUI wire-up assertions — same
        // hidden-leaf pattern as the VT/VF rows.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("arrhythmia-candidate-state-\(rank)")
                .accessibilityLabel(candidateStateLabel(state))
                .allowsHitTesting(false)
        }
    }

    /// Confirm is a plain action (no kind menu): the row already states the
    /// candidate's factual kind, and confirming adjudicates THAT observation
    /// — the analyst isn't reclassifying it into a different arrhythmia.
    private func arrhythmiaDispositionButtons(rank: Int, id: UUID, start: Int64, end: Int64, hasRecord: Bool) -> some View {
        HStack(spacing: 3) {
            Button {
                arrhythmiaDispositionStore?.confirm(start: start, end: end, kind: nil)
                recentlyActed.insert(id)
            } label: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Confirm this candidate as an analyst finding")
            .accessibilityLabel("Confirm candidate")
            .accessibilityIdentifier("arrhythmia-candidate-confirm-\(rank)")

            Button {
                arrhythmiaDispositionStore?.dismiss(start: start, end: end)
                recentlyActed.insert(id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this candidate as a false positive")
            .accessibilityLabel("Dismiss candidate")
            .accessibilityIdentifier("arrhythmia-candidate-dismiss-\(rank)")

            if hasRecord {
                Button {
                    arrhythmiaDispositionStore?.reset(start: start, end: end)
                    recentlyActed.insert(id)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Mark as unreviewed")
                .accessibilityLabel("Reset candidate review state")
                .accessibilityIdentifier("arrhythmia-candidate-reset-\(rank)")
            }
        }
        .font(.caption)
    }
}

// MARK: - Data types

private struct FindingGroup: Identifiable {
    let category: String
    let humanLabel: String
    let subLabel: String?
    let color: Color
    let count: Int
    let aggregateDeparture: Double
    let provenanceLabel: String
    let entries: [FindingEntry]

    var id: String { category }
}

private struct FindingEntry {
    let annotation: Annotation
    let departure: Double?
    let departureLabel: String?
}

private struct CollapsedNormalsSummary {
    let count: Int
    let entries: [Annotation]
}
