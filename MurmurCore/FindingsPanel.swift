//
//  FindingsPanel.swift
//  Murmur
//
//  Right-side inspector listing every annotation in the current recording,
//  with category / severity / source / confidence filter chips. Clicking a
//  finding jumps the shared `RecordingViewport` to its location.
//
//  Filter state lives in `FindingFilter`. The same filter is consumed by the
//  bedside canvas so filtered-out findings stop rendering as well.
//

import SwiftUI

// MARK: - Sort model

/// Sort order for the findings list. Analysts often need to scan by
/// severity first when triaging, by confidence when calibrating a
/// producer, or by category when looking at one finding type at a time
/// — so the panel exposes a picker that switches between these.
/// Time-ascending stays the default since it matches the canvas's
/// left-to-right reading direction.
enum FindingSort: String, CaseIterable, Identifiable {
    case time
    case severity
    case confidence
    case category

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .time:       return "Time"
        case .severity:   return "Severity"
        case .confidence: return "Confidence"
        case .category:   return "Category"
        }
    }

    /// Returns `annotations` sorted under this mode. Stable secondary
    /// ordering by `sampleIndex` so equal-rank rows still read
    /// left-to-right on the canvas.
    func apply(to annotations: [Annotation]) -> [Annotation] {
        switch self {
        case .time:
            return annotations.sorted { $0.sampleIndex < $1.sampleIndex }
        case .severity:
            // critical → warning → notice → info; ties break by time.
            return annotations.sorted { lhs, rhs in
                if lhs.severity != rhs.severity {
                    return lhs.severity > rhs.severity
                }
                return lhs.sampleIndex < rhs.sampleIndex
            }
        case .confidence:
            // Highest confidence first. Findings with no confidence
            // value sort after all valued ones, then by time so the
            // bottom of the list still reads left-to-right.
            return annotations.sorted { lhs, rhs in
                switch (lhs.confidence, rhs.confidence) {
                case (let l?, let r?):
                    if l != r { return l > r }
                    return lhs.sampleIndex < rhs.sampleIndex
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return lhs.sampleIndex < rhs.sampleIndex
                }
            }
        case .category:
            return annotations.sorted { lhs, rhs in
                if lhs.category != rhs.category {
                    return lhs.category < rhs.category
                }
                return lhs.sampleIndex < rhs.sampleIndex
            }
        }
    }
}

// MARK: - Filter model

struct FindingFilter: Equatable {
    var categories: Set<String> = []           // empty = all categories
    var severities: Set<Annotation.Severity> = []   // empty = all severities
    var sources: Set<String> = []              // empty = all sources
    var minConfidence: Double = 0.0            // applies only when confidence != nil

    var isActive: Bool {
        !categories.isEmpty
            || !severities.isEmpty
            || !sources.isEmpty
            || minConfidence > 0.0
    }

    func matches(_ ann: Annotation) -> Bool {
        if !categories.isEmpty && !categories.contains(ann.category) { return false }
        if !severities.isEmpty && !severities.contains(ann.severity) { return false }
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
    @Binding var filter: FindingFilter
    /// Source of truth for analyst review state. Passed in so the bedside
    /// view owns its lifetime and the same store feeds the canvas overlays
    /// and the density timeline alongside the panel.
    let dispositionStore: DispositionStore
    /// Read/write latch from the toolbar — disposition buttons only appear
    /// when editing is unlocked.
    let isEditing: Bool

    /// Active sort order. Lives in panel state since the choice is a
    /// pure-display concern — no other surface needs to react to it.
    @State private var sort: FindingSort = .time

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            FilterChipsBar(annotations: annotations, filter: $filter)
            Divider()
            findingsList
        }
    }

    private var tally: DispositionStore.Tally {
        dispositionStore.tally(for: annotations)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Findings")
                    .font(.headline)
                Spacer()
                sortPicker
            }
            Text("\(filtered.count) of \(annotations.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Compact disposition tally so the analyst sees triage progress
            // without opening the panel rows.
            HStack(spacing: 8) {
                tallyChip(count: tally.confirmed, label: "confirmed",
                          systemImage: "checkmark.circle.fill",
                          color: .green)
                tallyChip(count: tally.dismissed, label: "dismissed",
                          systemImage: "xmark.circle.fill",
                          color: .secondary)
                tallyChip(count: tally.unreviewed, label: "unreviewed",
                          systemImage: "questionmark.circle",
                          color: .orange)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sortPicker: some View {
        Picker("Sort by", selection: $sort) {
            ForEach(FindingSort.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .font(.caption)
        .help("Sort findings by \(sort.displayName.lowercased())")
        .accessibilityIdentifier("findings-sort-picker")
    }

    private func tallyChip(count: Int, label: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text("\(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
        }
        .accessibilityLabel("\(count) \(label)")
    }

    private var filtered: [Annotation] {
        sort.apply(to: annotations.filter(filter.matches))
    }

    @ViewBuilder
    private var findingsList: some View {
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { ann in
                        FindingRow(
                            annotation: ann,
                            sampleRate: sampleRate,
                            disposition: dispositionStore.record(for: ann.id),
                            isEditing: isEditing,
                            onJump: { jump(to: ann) },
                            onConfirm: { kind in dispositionStore.confirm(ann.id, kind: kind) },
                            onDismiss: { dispositionStore.dismiss(ann.id) },
                            onReset: { dispositionStore.reset(ann.id) }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private func jump(to ann: Annotation) {
        let centerSample = (ann.sampleIndex + ann.renderEndSample) / 2
        let total = viewport.totalSamples
        guard total > 0 else { return }
        // For ranges, widen the viewport to show some context around them.
        if ann.kind == .range, let endSample = ann.endSampleIndex {
            let spanSamples = endSample - ann.sampleIndex
            let context = max(spanSamples * 2, Int64(sampleRate * 5))
            viewport.setWidth(spanSamples + context, anchorFraction: 0.5)
        }
        let fraction = Double(centerSample) / Double(total)
        viewport.animateJump(toFraction: fraction)
    }
}

// MARK: - Filter chip bar

private struct FilterChipsBar: View {
    let annotations: [Annotation]
    @Binding var filter: FindingFilter

    private var categories: [String] {
        Array(Set(annotations.map(\.category))).sorted()
    }
    private var sources: [String] {
        Array(Set(annotations.map(\.source))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            scrollableChips(label: "Categories", items: categories, isOn: { filter.categories.contains($0) }) { cat, on in
                if on { filter.categories.insert(cat) } else { filter.categories.remove(cat) }
            } colorFor: { CategoryPalette.swiftUIColor(for: $0) }

            scrollableChips(
                label: "Severity",
                items: Annotation.Severity.allCases.map(\.rawValue),
                isOn: { filter.severities.contains(Annotation.Severity(rawValue: $0) ?? .info) }
            ) { rawValue, on in
                guard let sev = Annotation.Severity(rawValue: rawValue) else { return }
                if on { filter.severities.insert(sev) } else { filter.severities.remove(sev) }
            } colorFor: { _ in .secondary }

            if sources.count > 1 {
                scrollableChips(label: "Source", items: sources, isOn: { filter.sources.contains($0) }) { src, on in
                    if on { filter.sources.insert(src) } else { filter.sources.remove(src) }
                } colorFor: { _ in .secondary }
            }

            HStack {
                Text("Confidence ≥ \(Int(filter.minConfidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $filter.minConfidence, in: 0...1)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func scrollableChips(
        label: String,
        items: [String],
        isOn: @escaping (String) -> Bool,
        toggle: @escaping (String, Bool) -> Void,
        colorFor: @escaping (String) -> Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items, id: \.self) { item in
                        FilterChip(
                            label: item,
                            isOn: isOn(item),
                            color: colorFor(item)
                        ) {
                            toggle(item, !isOn(item))
                        }
                    }
                }
            }
        }
    }
}

private struct FilterChip: View {
    let label: String
    let isOn: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption2.monospaced())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isOn ? color.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(isOn ? color : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct FindingRow: View {
    let annotation: Annotation
    let sampleRate: Double
    let disposition: AnnotationDisposition?
    let isEditing: Bool
    let onJump: () -> Void
    let onConfirm: (AnnotationDisposition.ConfirmedKind?) -> Void
    let onDismiss: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onJump) {
                HStack(alignment: .top, spacing: 8) {
                    kindIndicator
                    VStack(alignment: .leading, spacing: 3) {
                        titleRow
                        metadataRow
                        if let note = annotation.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("finding-row-\(annotation.category)")

            if isEditing {
                dispositionTrio
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .opacity(disposition?.state == .dismissed ? 0.55 : 1.0)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            stateMarker
            Text(annotation.displayLabel)
                .font(.body.weight(.semibold))
                .foregroundStyle(CategoryPalette.swiftUIColor(for: annotation.category))
                .strikethrough(disposition?.state == .dismissed)
            if case .confirmed = disposition?.state, let kind = disposition?.confirmedKind {
                Text(kind.shortLabel)
                    .font(.caption2.weight(.bold).monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
                    .foregroundStyle(.green)
            }
            Spacer()
            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            SeverityBadge(severity: annotation.severity)
            if let conf = annotation.confidence {
                Text("\(Int(conf * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(annotation.source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// Small leading marker reflecting the disposition state — visible in
    /// both editing and locked modes so the analyst's prior decisions are
    /// readable at a glance.
    @ViewBuilder
    private var stateMarker: some View {
        switch disposition?.state {
        case .confirmed:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .dismissed:
            Image(systemName: "xmark.seal.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        switch disposition?.state {
        case .confirmed:
            Color.green.opacity(0.07)
        case .dismissed:
            Color.secondary.opacity(0.05)
        case nil:
            Color.clear
        }
    }

    private var dispositionTrio: some View {
        HStack(spacing: 4) {
            // Confirm: a menu lets the analyst pick VT/VF or "unsure."
            Menu {
                Button("Confirm as VT") { onConfirm(.vt) }
                Button("Confirm as VF") { onConfirm(.vf) }
                Button("Confirm (unsure)") { onConfirm(nil) }
            } label: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Confirm this finding")
            .accessibilityIdentifier("disposition-confirm-\(annotation.id.uuidString)")

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this finding as a false positive")
            .accessibilityIdentifier("disposition-dismiss-\(annotation.id.uuidString)")

            if disposition != nil {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Mark as unreviewed")
                .accessibilityIdentifier("disposition-reset-\(annotation.id.uuidString)")
            }
        }
        .font(.title3)
        .imageScale(.large)
    }

    private var timeLabel: String {
        let startSec = Double(annotation.sampleIndex) / sampleRate
        if annotation.kind == .range, let endSample = annotation.endSampleIndex {
            let endSec = Double(endSample) / sampleRate
            return "\(format(startSec)) – \(format(endSec))"
        }
        return format(startSec)
    }

    private func format(_ seconds: Double) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d",
                          Int(seconds / 3600),
                          Int(seconds.truncatingRemainder(dividingBy: 3600) / 60),
                          Int(seconds.truncatingRemainder(dividingBy: 60)))
        }
        return String(format: "%d:%05.2f",
                      Int(seconds / 60),
                      seconds.truncatingRemainder(dividingBy: 60))
    }

    @ViewBuilder
    private var kindIndicator: some View {
        switch annotation.kind {
        case .point:
            Image(systemName: "smallcircle.filled.circle")
                .foregroundStyle(CategoryPalette.swiftUIColor(for: annotation.category))
        case .range:
            Image(systemName: "rectangle.compress.vertical")
                .foregroundStyle(CategoryPalette.swiftUIColor(for: annotation.category))
        }
    }
}

private struct SeverityBadge: View {
    let severity: Annotation.Severity

    var body: some View {
        Text(severity.rawValue.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch severity {
        case .info:     return .secondary
        case .notice:   return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}
