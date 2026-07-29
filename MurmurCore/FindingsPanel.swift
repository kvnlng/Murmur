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

    @State private var sort: FindingSort = .structural
    @State private var expandedGroups: Set<String> = []
    @State private var showNormals: Bool = false
    @State private var candidateGroupExpanded: Bool = true

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
        purchaseStore.owns(.ecgMetrics) && markingsContext.template != nil
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
    }

    /// If the `--ui-test-expand-all-findings-groups` launch arg is
    /// set, expand every group's exemplar list so tests can address
    /// `finding-row-<category>` directly. Analyst behaviour is
    /// unchanged; the toggle path still works — the override just
    /// widens the set to include every category currently present.
    private func applyUITestExpandOverride() {
        #if DEBUG
        guard UITestSupport.expandAllFindingsGroups else { return }
        let allCategories = Set(annotations.map(\.category))
        expandedGroups = allCategories
        #endif
    }

    // MARK: - Header (triage tally + sort + filter)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review queue")
                    .font(.headline)
                Spacer()
                Text("\(flaggedFiltered.count) of \(flaggedAnnotations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            triageTally
            filterChips
            departureUnlockSeam
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

    private var triageTally: some View {
        // "To review" uses `.blue` — disposition state gets its own
        // token per the ratified 2026-07-05 amber de-confliction.
        // Amber (`.orange`) is now reserved for analyst-marked
        // findings; painting an unreviewed count amber would collide
        // with that meaning.
        HStack(spacing: 6) {
            tallyChip(count: tally.unreviewed, label: "To review", color: .blue)
            tallyChip(count: tally.confirmed, label: "Confirmed", color: .green)
            tallyChip(count: tally.dismissed, label: "Dismissed", color: .secondary)
        }
    }

    private func tallyChip(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: - Filter chip row

    private var filterChips: some View {
        HStack(spacing: 6) {
            sortMenu
            categoryMenu
            confidenceMenu
        }
    }

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

    /// Menu item title — appends "(ECG Metrics)" to `.departure` when
    /// the measurement layer can't back it, so the paid seam reads as
    /// what it is (a locked capability, not a mystery inert option).
    private func sortMenuTitle(_ mode: FindingSort) -> String {
        if mode == .departure && !departureSortAvailable {
            return "\(mode.displayName) — ECG Metrics"
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
    /// Hidden once ECG Metrics is owned AND a template exists — at
    /// that point the departure sort is a first-class picker option
    /// and the seam is no longer needed.
    @ViewBuilder
    private var departureUnlockSeam: some View {
        if !departureSortAvailable {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Rank by departure from this patient's normal — ECG Metrics")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityIdentifier("departure-sort-unlock-seam")
        }
    }

    private var categoryMenu: some View {
        Menu {
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
                    Label(humanLabel(for: cat), systemImage: filter.categories.contains(cat) ? "checkmark" : "")
                }
                .accessibilityIdentifier("findings-category-filter-\(cat)")
            }
        } label: {
            chipLabel(key: "Category", value: filter.categories.isEmpty ? "all" : "\(filter.categories.count)")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("findings-category-picker")
    }

    private var confidenceMenu: some View {
        Menu {
            ForEach([0.0, 0.5, 0.75, 0.9], id: \.self) { threshold in
                Button {
                    filter.minConfidence = threshold
                } label: {
                    let label = threshold == 0 ? "any" : "≥ \(Int(threshold * 100))%"
                    Label(label, systemImage: filter.minConfidence == threshold ? "checkmark" : "")
                }
            }
        } label: {
            let value = filter.minConfidence == 0 ? "≥ 0%" : "≥ \(Int(filter.minConfidence * 100))%"
            chipLabel(key: "Confidence", value: value)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // AX2: without an explicit id this image-bearing menu falls back to
        // its chevron symbol name ("chevron.down") in the tree. Match its
        // siblings findings-sort-picker / findings-category-picker.
        .accessibilityIdentifier("findings-confidence-picker")
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
        annotations.filter(filter.matches)
    }

    @ViewBuilder
    private var queueList: some View {
        if filtered.isEmpty && sortedCandidates.isEmpty {
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
                    Circle()
                        .fill(group.color)
                        .frame(width: 9, height: 9)
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
            .accessibilityIdentifier("finding-group-\(group.category)")

            if isExpanded {
                exemplarRows(for: group)
            }
        }
    }

    private func exemplarRows(for group: FindingGroup) -> some View {
        let exemplars = group.entries.prefix(6)
        return VStack(spacing: 1) {
            ForEach(exemplars, id: \.annotation.id) { entry in
                exemplarRow(entry: entry, groupColor: group.color)
            }
            if group.entries.count > exemplars.count {
                HStack {
                    Text("+ \(group.entries.count - exemplars.count) more, sorted by departure…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 4)
        .padding(.bottom, 4)
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
                    Text("\(collapsedNormals.count) beats within this patient's template")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("nothing flagged — normal beats collapse here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
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
        .accessibilityIdentifier("collapsed-normals-row")
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
                }
                Button("Confirm as VF") {
                    dispositionStore.confirm(annotation.id, kind: .vf)
                }
                Button("Confirm (unsure)") {
                    dispositionStore.confirm(annotation.id, kind: nil)
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
                humanLabel: humanLabel(for: category),
                subLabel: groupSubtitle(for: category),
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
    private func humanLabel(for category: String) -> String {
        let raw = category.trimmingCharacters(in: .whitespaces)
        // Case-sensitive WFDB codes — case is MEANINGFUL in the standard, so
        // match the raw symbol before the case-insensitive fallback below.
        // Verified against the WFDB ecgcodes table: `a` (4) aberrated atrial
        // premature ≠ `A` (8) atrial premature; `E` (10) ventricular escape;
        // `~` (14) signal-quality change. Uppercasing alone silently
        // conflated `a` into `A` and dropped the word "aberrated".
        switch raw {
        case "a":  return "Aberrated atrial premature"
        case "E":  return "Ventricular escape"
        case "~":  return "Signal-quality change"
        default:   break
        }
        let key = raw.uppercased()
        switch key {
        case "V":     return "Ventricular ectopy"
        case "PVC":   return "Ventricular ectopy — PVC"
        case "A":     return "Atrial premature"
        case "APC":   return "Atrial premature (APC)"
        case "N":     return "Normal beat"
        case "+":     return "Rhythm-change marker"
        case "|":     return "Isolated QRS-like artifact"
        case "\"":    return "Annotator comment"
        case "F":     return "Fusion beat"
        case "L":     return "LBBB beat"
        case "R":     return "RBBB beat"
        case "AFIB":  return "Atrial fibrillation"
        case "VT":    return "Ventricular tachycardia"
        case "VF":    return "Ventricular fibrillation"
        case "NOISE": return "Signal quality — noise"
        default:      return category
        }
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
        case "NOISE":     return "interval stats suppressed inside"
        default:          return nil
        }
    }

    /// The subtitle actually rendered under a group header. Adds the
    /// "ranked by …" ordering claim ONLY when the departure sort is in
    /// effect AND the category is departure-rankable, so the header never
    /// asserts an ordering the visible rows don't exhibit (AX5). Keeps the
    /// descriptor otherwise — the navigational framing is load-bearing.
    private func groupSubtitle(for category: String) -> String? {
        guard let base = subLabel(for: category) else { return nil }
        if effectiveSort == .departure && isDepartureRanked(category) {
            return "ranked by \(base)"
        }
        return base
    }

    private func isDepartureRanked(_ category: String) -> Bool {
        switch category.trimmingCharacters(in: .whitespaces).uppercased() {
        case "V", "PVC", "A", "APC", "F", "L", "R": return true
        default: return false
        }
    }

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

    /// Candidates ranked by model score (confidence), descending.
    private var sortedCandidates: [Annotation] {
        candidates.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
    }

    private var candidateGroupSection: some View {
        VStack(spacing: 0) {
            candidateGroupHeader
            if candidateGroupExpanded {
                VStack(spacing: 1) {
                    ForEach(Array(sortedCandidates.enumerated()), id: \.element.id) { index, cand in
                        candidateRow(rank: index, candidate: cand)
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
                        ruoBadge
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

    /// The RUO badge — one of the two allowed surfaces (the scan dialog
    /// header is the other). Keeping it to exactly these two is what keeps
    /// it credible (feedback_research_use_only_framing.md).
    private var ruoBadge: some View {
        Text("RUO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
            .foregroundStyle(.secondary)
            .help(regulatoryNotice)
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
                candidateDispositionButtons(rank: rank, start: start, end: end, hasRecord: state != nil)
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

    private func candidateDispositionButtons(rank: Int, start: Int64, end: Int64, hasRecord: Bool) -> some View {
        HStack(spacing: 3) {
            Menu {
                Button("Confirm as VT") {
                    confirmCandidate(start: start, end: end, kind: .vt)
                }
                Button("Confirm as VF") {
                    confirmCandidate(start: start, end: end, kind: .vf)
                }
                Button("Confirm (unsure)") {
                    confirmCandidate(start: start, end: end, kind: .unclassified)
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
