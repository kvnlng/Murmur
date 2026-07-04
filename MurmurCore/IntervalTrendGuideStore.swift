//
//  IntervalTrendGuideStore.swift
//  MurmurCore
//
//  Analyst-authored threshold guides for the interval trend lane. Per
//  the design spec (project_interval_trend_lanes_design.md), the app
//  never ships built-in clinical cutoffs — a hardcoded "500 ms = Long
//  QT" line would be a diagnostic assertion. Instead the analyst
//  places labeled guides, and this store persists them alongside the
//  recording so a paper-in-progress keeps its threshold choices
//  across sessions.
//
//  Persists to `<bundle>/interval_guides.json`. Guides are scoped by
//  metric so a QTc-500ms guide doesn't clutter the PR trend.
//

import Foundation

/// One analyst-placed threshold guide on the interval trend lane.
public struct IntervalTrendGuide: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    /// Which metric this guide applies to. Guides are only rendered
    /// when the lane's active metric matches.
    public let metric: IntervalTrendMetric
    /// Threshold value in ms (the lane's y-axis unit).
    public let valueMs: Double
    /// Analyst-set label — echoed on the guide's tag on the lane.
    /// The store forces "(user-set)" onto the rendered label so the
    /// analyst reader can never mistake the guide for a built-in
    /// clinical cutoff.
    public let label: String

    public init(
        id: UUID = UUID(),
        metric: IntervalTrendMetric,
        valueMs: Double,
        label: String
    ) {
        self.id = id
        self.metric = metric
        self.valueMs = valueMs
        self.label = label
    }
}

/// On-disk wire format. `schemaVersion` starts at 1 — future
/// evolutions (e.g. per-guide notes, sharing between recordings) bump
/// it and the loader ignores unknown versions.
struct IntervalTrendGuideFile: Codable, Sendable {
    let schemaVersion: Int
    let guides: [IntervalTrendGuide]

    static let currentSchemaVersion = 1
}

@MainActor
@Observable
public final class IntervalTrendGuideStore {

    private let bundleDirectory: URL

    /// Live guide list. Public read-only so views observe it directly.
    public private(set) var guides: [IntervalTrendGuide] = []

    public init(bundleDirectory: URL) {
        self.bundleDirectory = bundleDirectory
        self.guides = Self.load(from: Self.fileURL(in: bundleDirectory))
    }

    // MARK: - Read

    /// Guides for the given metric only, sorted by value ascending so
    /// the lane renders them stably.
    public func guides(for metric: IntervalTrendMetric) -> [IntervalTrendGuide] {
        guides
            .filter { $0.metric == metric }
            .sorted { $0.valueMs < $1.valueMs }
    }

    // MARK: - Mutate

    public func add(metric: IntervalTrendMetric, valueMs: Double, label: String) {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = normalized.isEmpty
            ? String(format: "%.0f %@", valueMs, metric.unit)
            : normalized
        guides.append(
            IntervalTrendGuide(
                metric: metric,
                valueMs: valueMs,
                label: effective
            )
        )
        persist()
    }

    public func remove(_ guideID: UUID) {
        guides.removeAll { $0.id == guideID }
        persist()
    }

    public func removeAll(for metric: IntervalTrendMetric) {
        guides.removeAll { $0.metric == metric }
        persist()
    }

    // MARK: - Persistence

    private static func fileURL(in bundleDirectory: URL) -> URL {
        bundleDirectory.appendingPathComponent("interval_guides.json")
    }

    private static func load(from url: URL) -> [IntervalTrendGuide] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let file = try? JSONDecoder().decode(IntervalTrendGuideFile.self, from: data) else {
            return []
        }
        guard file.schemaVersion == IntervalTrendGuideFile.currentSchemaVersion else {
            return []
        }
        return file.guides
    }

    private func persist() {
        let url = Self.fileURL(in: bundleDirectory)
        let file = IntervalTrendGuideFile(
            schemaVersion: IntervalTrendGuideFile.currentSchemaVersion,
            guides: guides
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Guide persistence is a best-effort convenience — a
            // write failure shouldn't crash the viewer or block the
            // analyst's read flow. Silently swallow.
        }
    }
}
