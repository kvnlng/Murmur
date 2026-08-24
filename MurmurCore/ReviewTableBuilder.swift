//
//  ReviewTableBuilder.swift
//  Murmur
//
//  Collects the cohort review table's rows (#330) from whatever the navigator
//  currently holds. Split from `ContentView` deliberately: the row-collection
//  rule has real edge cases worth testing on their own, and `ContentView` is
//  already the longest file in the target.
//
//  IMPORT IS NEVER TRIGGERED HERE. A record the analyst has not opened has no
//  bundle, so it has no annotations and no dispositions — and importing 45,000
//  records to satisfy an export would be a multi-hour surprise. Those records
//  are COUNTED and reported instead, so the caller can say plainly how many
//  were skipped. Silent truncation would let an export read as "the whole
//  cohort" when it covered a fraction of it.
//

import Foundation

enum ReviewTableBuilder {

    /// What one navigator row contributed.
    struct Source {
        /// Navigator id — the root-relative `.hea` path for a folder record.
        let recordPath: String
        /// The imported bundle, or nil when the analyst never opened this row.
        let imported: Imported?

        struct Imported {
            let recording: Recording
            let dispositions: [UUID: AnnotationDisposition]
            /// `.hea` comment lines, carried so the table can echo the
            /// record's own metadata beside each finding.
            let headerComments: [String]
            /// The imported bundle directory — where `analysis_lead.json`
            /// (and every other sidecar) lives. #357: resolved once per
            /// record via `Recording.analysisLead(inBundle:)`, not
            /// per-annotation; every row for this record repeats it.
            let bundleDirectory: URL
        }
    }

    struct Result: Equatable {
        var csv: String
        /// Records that contributed at least the chance of a row — i.e. were imported.
        var recordsIncluded: Int
        var annotationRows: Int
        /// Records skipped because they were never imported.
        var notImported: Int

        /// One sentence for the completion banner. Names the skipped count
        /// whenever it is non-zero — see the file header.
        var summary: String {
            var s = "Exported \(annotationRows) "
                + (annotationRows == 1 ? "finding" : "findings")
                + " across \(recordsIncluded) "
                + (recordsIncluded == 1 ? "record" : "records") + "."
            if notImported > 0 {
                s += " \(notImported) "
                    + (notImported == 1 ? "record was" : "records were")
                    + " not imported and were skipped."
            }
            return s
        }
    }

    static func build(sources: [Source], flaggedIDs: Set<String>) -> Result {
        var rows: [ReviewTableCSV.Row] = []
        var included = 0
        var skipped = 0

        for source in sources {
            guard let imported = source.imported else {
                skipped += 1
                continue
            }
            included += 1
            let recording = imported.recording
            let flagged = flaggedIDs.contains(source.recordPath)
            let rate = (recording.primaryECGChannel ?? recording.channels.first)?.sampleRate ?? 0
            // #357 — nil when the record has no populated non-trend channel
            // (e.g. a trend-only record); both columns stay empty for every
            // row, the same rendering never-imported rows already get.
            let lead = recording.analysisLead(inBundle: imported.bundleDirectory)

            for annotation in recording.annotations {
                let disposition = imported.dispositions[annotation.id]
                rows.append(ReviewTableCSV.Row(
                    record: recording.device,
                    recordPath: source.recordPath,
                    annotationID: annotation.id,
                    kind: annotation.kind.rawValue,
                    startSample: annotation.sampleIndex,
                    endSample: annotation.endSampleIndex,
                    startSeconds: seconds(annotation.sampleIndex, rate: rate),
                    endSeconds: annotation.endSampleIndex.flatMap { seconds($0, rate: rate) },
                    lead: annotation.lead,
                    category: annotation.category,
                    label: annotation.label,
                    source: annotation.source,
                    confidence: annotation.confidence,
                    // Absence of a disposition record IS "unreviewed" — the
                    // store never materialises a row per annotation.
                    state: disposition?.state.rawValue ?? "unreviewed",
                    confirmedKind: disposition?.confirmedKind?.rawValue,
                    confirmedCategory: disposition?.confirmedCategory,
                    note: disposition?.note,
                    reviewedBy: disposition?.reviewedBy,
                    reviewedAt: disposition?.reviewedAt,
                    flagged: flagged,
                    headerComments: imported.headerComments,
                    analysisLead: lead?.channel.name,
                    analysisLeadReason: lead?.provenance.exportReason
                ))
            }
        }

        return Result(
            csv: ReviewTableCSV.generate(rows: rows),
            recordsIncluded: included,
            annotationRows: rows.count,
            notImported: skipped
        )
    }

    private static func seconds(_ sample: Int64, rate: Double) -> Double? {
        guard rate > 0 else { return nil }
        return Double(sample) / rate
    }

    /// Reads a bundle's disposition sidecar. A missing or unreadable file means
    /// "nothing reviewed yet", which is a legitimate state, not an error.
    static func dispositions(inBundle directory: URL) -> [UUID: AnnotationDisposition] {
        let url = directory.appendingPathComponent(DispositionFile.bundleFileName)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(DispositionFile.self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: file.dispositions.map { ($0.annotationID, $0) })
    }

    /// Save-panel filename for a cohort export: `<folder-or-session>-review.csv`.
    static func suggestedFilename(sourceDisplayName: String) -> String {
        let base = (sourceDisplayName as NSString).deletingPathExtension
        let stem = base.isEmpty ? "cohort" : base
        return "\(stem)-review.csv"
    }
}
