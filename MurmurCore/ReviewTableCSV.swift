//
//  ReviewTableCSV.swift
//  Murmur
//
//  The cohort review table (#330) — one CSV row per annotation across every
//  record in the open folder or session, carrying the analyst's disposition.
//
//  Every other export is scoped to ONE record: the Markdown report, the PNG
//  snapshot, the WFDB annotator file. That is the right shape for handing a
//  colleague a finding. It is the wrong shape for the other direction — an
//  analyst who has just reviewed two hundred records and wants their verdicts
//  back in whatever produced the annotations (a relabelling script, a
//  spreadsheet, a training pipeline). This file is that direction.
//
//  UNREVIEWED ROWS ARE INCLUDED. This is a review table, not the amber-only
//  WFDB export: the consumer needs the denominator — what was looked at and
//  left alone is as much a result as what was confirmed. `MarkdownReport` sets
//  the same precedent for a single record.
//
//  Pure and deterministic, like `MarkdownReport`: no I/O, no `Date()`, no
//  environment access. Callers pass everything in, so output is reproducible
//  and the tests can pin it exactly.
//

import Foundation

enum ReviewTableCSV {

    /// One annotation, in one record, with whatever review state it carries.
    struct Row: Equatable, Sendable {
        var record: String              // WFDB record name
        var recordPath: String          // navigator id — root-relative `.hea` path
        var annotationID: UUID
        var kind: String                // "point" | "range"
        var startSample: Int64
        var endSample: Int64?           // nil for points
        var startSeconds: Double?
        var endSeconds: Double?
        var lead: String?
        var category: String
        var label: String?
        var source: String
        var confidence: Double?
        var state: String               // "unreviewed" | "confirmed" | "dismissed"
        var confirmedKind: String?
        /// #331 — what the analyst says the finding IS. Present on every
        /// confirmed row, equal to `category` when they agreed with the
        /// producer's label and different when they overrode it, so a consumer
        /// can find the disagreements with one comparison.
        var confirmedCategory: String?
        var note: String?
        var reviewedBy: String?
        var reviewedAt: Date?
        var flagged: Bool
        var headerComments: [String]
    }

    static let columns = [
        "record", "record_path", "annotation_id", "kind",
        "start_sample", "end_sample", "start_seconds", "end_seconds",
        "lead", "category", "label", "source", "confidence",
        "state", "confirmed_kind", "confirmed_category", "note", "reviewed_by", "reviewed_at",
        "flagged", "header_comments",
    ]

    /// Header line plus one line per row, sorted by record path, then start
    /// sample, then annotation id — so the same review exports byte-identically
    /// every time regardless of navigator or dictionary ordering.
    ///
    /// The header row is always present, even with zero rows: a consumer
    /// reading an empty export should see an empty table, not an empty file.
    static func generate(rows: [Row]) -> String {
        let sorted = rows.sorted {
            if $0.recordPath != $1.recordPath { return $0.recordPath < $1.recordPath }
            if $0.startSample != $1.startSample { return $0.startSample < $1.startSample }
            return $0.annotationID.uuidString < $1.annotationID.uuidString
        }
        var lines = [columns.joined(separator: ",")]
        lines.append(contentsOf: sorted.map(line(for:)))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func line(for row: Row) -> String {
        let fields: [String] = [
            row.record,
            row.recordPath,
            row.annotationID.uuidString,
            row.kind,
            String(row.startSample),
            row.endSample.map(String.init) ?? "",
            row.startSeconds.map(formatSeconds) ?? "",
            row.endSeconds.map(formatSeconds) ?? "",
            row.lead ?? "",
            row.category,
            row.label ?? "",
            row.source,
            row.confidence.map { String(format: "%.4f", $0) } ?? "",
            row.state,
            row.confirmedKind ?? "",
            row.confirmedCategory ?? "",
            row.note ?? "",
            row.reviewedBy ?? "",
            row.reviewedAt.map(formatISO) ?? "",
            row.flagged ? "true" : "false",
            row.headerComments.joined(separator: " | "),
        ]
        return fields.map(escape).joined(separator: ",")
    }

    /// RFC 4180: a field containing a comma, a double quote, CR or LF is
    /// wrapped in double quotes, and embedded quotes are doubled. Everything
    /// else is emitted bare.
    static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"")
                || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Fixed-locale ISO 8601 with seconds and zone — stable regardless of the
    /// analyst's locale, matching `MarkdownReport.formatISO`.
    static func formatISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Three decimals — millisecond resolution, which is finer than any
    /// sample rate Murmur reads, without exporting float noise.
    static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
