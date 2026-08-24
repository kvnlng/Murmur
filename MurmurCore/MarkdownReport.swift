//
//  MarkdownReport.swift
//  MurmurCore
//
//  Renders a recording's analyst-facing review state as a Markdown
//  document — recording metadata, triage tally, and the full findings
//  table with disposition state per row. The result is plain text, so
//  it's diffable, version-controllable, and reads cleanly inside any
//  markdown viewer or pasted into a clinical-note system.
//
//  Pure function: no I/O, no `Date()` calls, no environment access.
//  Callers pass `now` explicitly so report contents are deterministic
//  for tests and reproducible across analyst sessions.
//

import Foundation

enum MarkdownReport {

    /// Builds the report. Returns a single string with trailing newline.
    /// Sections in order:
    ///   1. Title
    ///   2. Recording metadata
    ///   3. Triage summary (the `tally`)
    ///   4. Findings table — sorted by time
    ///   5. Generated-at footer
    static func generate(
        recording: Recording,
        annotations: [Annotation],
        dispositions: [UUID: AnnotationDisposition],
        tally: DispositionStore.Tally,
        notes: [AnchoredNote] = [],
        // #357 — which channel every finding's measurements ran on, and
        // why. The caller resolves it (it needs the bundle directory,
        // which this pure function never touches); nil renders no line
        // rather than a fabricated one — a trend-only recording has no
        // analysis lead to report.
        analysisLead: AnalysisLeadResolution? = nil,
        // #358 — the analyst's declaration of what the analysis lead's
        // recorded name physically means, when one exists. The caller
        // resolves it (it needs `LeadPlacementMapContext`, which this pure
        // function never touches — jurisdiction rule); `nil` (the default)
        // renders the line byte-identical to #357's.
        declaredPlacement: (declaration: LeadPlacementDeclaration, isOverride: Bool)? = nil,
        now: Date
    ) -> String {
        var lines: [String] = []

        lines.append("# Murmur Studio — Recording Report")
        lines.append("")

        // -- Recording metadata
        lines.append("## Recording")
        lines.append("- **Device**: \(recording.device)")
        lines.append("- **Source file**: `\(recording.sourceFileName)`")
        if let firstChannel = recording.channels.first {
            let duration = Double(firstChannel.sampleCount) / firstChannel.sampleRate
            lines.append("- **Duration**: \(formatDuration(duration))")
            lines.append("- **Start**: \(formatISO(firstChannel.startDate))")
            lines.append("- **Sample rate (primary channel)**: \(Int(firstChannel.sampleRate)) Hz")
        }
        lines.append("- **Channels**: \(recording.channels.count)")
        if let analysisLead {
            // The EXPORT vocabulary (`exportReason`), not the in-app header
            // disclosure's (`AnalysisLeadHeaderLine`) — the two are worded
            // differently on purpose (the header states a reviewer + date;
            // the export states a score), and this report shares its
            // wording with the review-table CSV, not the on-screen line.
            //
            // #358: the declared-placement parenthetical, when present,
            // follows the NAME — the same composition
            // `AnalysisLeadHeaderLine.label(for:declaration:)` uses — but
            // the reason after the em dash keeps the export's own wording.
            let placementSuffix = declaredPlacement.map {
                " " + LeadPlacementDisclosure.parenthetical(
                    for: $0.declaration, isOverride: $0.isOverride)
            } ?? ""
            lines.append(
                "- **Analysis lead**: \(analysisLead.channel.name)\(placementSuffix) — "
                + analysisLead.provenance.exportReason
            )
        }
        lines.append("")

        // -- Triage summary
        lines.append("## Triage summary")
        lines.append("- Confirmed: \(tally.confirmed)")
        lines.append("- Dismissed: \(tally.dismissed)")
        lines.append("- Unreviewed: \(tally.unreviewed)")
        lines.append("- **Total**: \(tally.total)")
        lines.append("")

        // -- Findings table
        let sampleRate = recording.channels.first?.sampleRate ?? 250
        let sorted = annotations.sorted { $0.sampleIndex < $1.sampleIndex }
        if sorted.isEmpty {
            lines.append("## Findings")
            lines.append("")
            lines.append("_No findings on this recording._")
        } else {
            lines.append("## Findings (\(sorted.count))")
            lines.append("")
            lines.append("| Time | Category | Confidence | Disposition | Source |")
            lines.append("|---|---|---|---|---|")
            for ann in sorted {
                let time = formatTime(seconds: Double(ann.sampleIndex) / sampleRate)
                let confidence = ann.confidence.map { String(format: "%.2f", $0) } ?? "—"
                let disposition = formatDisposition(dispositions[ann.id], annotation: ann)
                lines.append("| \(time) | \(escape(ann.category)) | \(confidence) | \(disposition) | \(escape(ann.source)) |")
            }
        }
        lines.append("")

        // -- Analyst notes (X72). The CALLER filters to the notes the analyst
        // flagged "Include in exported report" — this function renders what
        // it is given and never decides inclusion itself. Section absent when
        // nothing was flagged: an empty heading would imply notes exist.
        if !notes.isEmpty {
            lines.append("## Analyst notes (\(notes.count))")
            lines.append("")
            for note in notes.sorted(by: { $0.startSample < $1.startSample }) {
                // X84: the record-level kind states its scope; a fabricated
                // "0:00.0–0:00.0" would read as an anchor at the record start.
                if note.isLocationless {
                    lines.append("- **Record note**")
                } else {
                    let start = formatTime(seconds: Double(note.startSample) / sampleRate)
                    let end = formatTime(seconds: Double(note.endSample) / sampleRate)
                    let lead = note.leadName.map { " · lead \($0)" } ?? ""
                    lines.append("- **\(start)–\(end)**\(lead)")
                }
                for textLine in note.text.components(separatedBy: .newlines) {
                    lines.append("  \(textLine)")
                }
            }
            lines.append("")
        }

        // -- Footer
        lines.append("---")
        lines.append("")
        lines.append("*Generated by Murmur Studio at \(formatISO(now))*")

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Formatters

    /// Recording-duration formatter that picks units sensibly. Keeps
    /// one decimal across the board so eyeballing is easy.
    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f hr", seconds / 3600)
    }

    /// Per-finding timecode — "MM:SS.ss". Always renders the minutes
    /// place even when zero so the column aligns across rows.
    static func formatTime(seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total / 60)
        let remainder = total - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, remainder)
    }

    /// Disposition column. Mirrors the in-app vocabulary so analysts
    /// reading the report recognize the states.
    static func formatDisposition(
        _ disposition: AnnotationDisposition?,
        annotation: Annotation? = nil
    ) -> String {
        guard let d = disposition else { return "unreviewed" }
        switch d.state {
        case .confirmed:
            // #331 — an analyst who confirmed the finding AS something else
            // said the most important thing in the row; lead with it. Agreeing
            // with the producer's own label reads as plain "confirmed", so the
            // two cases stay distinguishable.
            if let annotation, d.overridesCategory(of: annotation),
               let category = d.confirmedCategory {
                return "confirmed (as \(category))"
            }
            if let kind = d.confirmedKind, kind != .unclassified {
                return "confirmed (\(kind.shortLabel))"
            }
            return "confirmed"
        case .dismissed:
            return "dismissed"
        }
    }

    /// Fixed-locale ISO 8601 for stable output regardless of analyst
    /// locale. Internet date-time format includes seconds + zone.
    static func formatISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Escapes the few characters that would break a markdown table
    /// row. We don't need a full markdown escape — categories and
    /// sources are short identifiers; the table-breaker is `|`, and
    /// newlines would split rows.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
