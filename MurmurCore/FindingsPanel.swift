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

/// Sort order for the review queue. Default is `.departure` — the
/// analyst's triage question is "how does this beat depart from THIS
/// patient's normal?", not "when did it happen?". Time / category /
/// confidence remain available for the rare cases those help.
public enum FindingSort: String, CaseIterable, Identifiable {
    case departure
    case time
    case confidence
    case category

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
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

    @State private var sort: FindingSort = .departure
    @State private var expandedGroups: Set<String> = []
    @State private var showNormals: Bool = false

    /// Read of the shared fiducial store so per-annotation departure
    /// scoring can consult the per-patient normal template. Empty
    /// context = no departure ranking (falls back to count-descending).
    @State private var markingsContext = IntervalMarkingsContext.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !rhythmContextLines.isEmpty {
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
                Text("\(filtered.count) of \(annotations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            triageTally
            filterChips
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tally: DispositionStore.Tally {
        dispositionStore.tally(for: annotations)
    }

    private var triageTally: some View {
        HStack(spacing: 6) {
            tallyChip(count: tally.unreviewed, label: "To review", color: .orange)
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
                    Label(mode.displayName, systemImage: sort == mode ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2)
                Text("Sort: \(sort.displayName)")
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
        .help("Sort findings by \(sort.displayName.lowercased())")
        .accessibilityIdentifier("findings-sort-picker")
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

    private var rhythmContextLines: [String] {
        headerComments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var rhythmContextBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("🫀")
                .font(.body)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rhythm context")
                    .font(.caption.weight(.semibold))
                Text(rhythmContextLines.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("from the recording's `.hea` header — analyst-editable in Notes")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
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

    // MARK: - Queue list

    private var filtered: [Annotation] {
        annotations.filter(filter.matches)
    }

    @ViewBuilder
    private var queueList: some View {
        if filtered.isEmpty {
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
                jump(to: entry.annotation)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(groupColor)
                        .frame(width: 6, height: 6)
                    Text(entry.annotation.displayLabel)
                        .font(.caption.weight(.semibold))
                    if let conf = entry.annotation.confidence {
                        Text("· conf \(String(format: "%.2f", conf))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if let departureLabel = entry.departureLabel {
                        Text(departureLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.orange)
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
            .accessibilityIdentifier("disposition-confirm-\(annotation.id.uuidString)")

            Button {
                dispositionStore.dismiss(annotation.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this finding as a false positive")
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
                subLabel: subLabel(for: category),
                color: CategoryPalette.swiftUIColor(for: category),
                count: entries.count,
                aggregateDeparture: entries.compactMap(\.departure).max() ?? 0,
                provenanceLabel: uniqueSourceLabel(entries),
                entries: sortedEntries(entries)
            )
        }
        return groups.sorted { lhs, rhs in
            switch sort {
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

    private func sortedEntries(_ entries: [FindingEntry]) -> [FindingEntry] {
        switch sort {
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
        let key = category.trimmingCharacters(in: .whitespaces).uppercased()
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
    private func subLabel(for category: String) -> String? {
        let key = category.trimmingCharacters(in: .whitespaces).uppercased()
        switch key {
        case "V", "PVC":  return "ranked by QRS-width departure from patient normal"
        case "A", "APC":  return "coupling-interval departure"
        case "+":         return "annotator rhythm transitions"
        case "|":         return "non-beat deflections flagged for exclusion"
        case "\"":        return "original database notes — verbatim"
        case "NOISE":     return "interval stats suppressed inside"
        default:          return nil
        }
    }

    // MARK: - Jump

    private func jump(to ann: Annotation) {
        let centerSample = (ann.sampleIndex + ann.renderEndSample) / 2
        let total = viewport.totalSamples
        guard total > 0 else { return }
        if ann.kind == .range, let endSample = ann.endSampleIndex {
            let spanSamples = endSample - ann.sampleIndex
            let context = max(spanSamples * 2, Int64(sampleRate * 5))
            viewport.setWidth(spanSamples + context, anchorFraction: 0.5)
        }
        let fraction = Double(centerSample) / Double(total)
        viewport.animateJump(toFraction: fraction)
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
