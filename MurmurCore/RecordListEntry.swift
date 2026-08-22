//
//  RecordListEntry.swift
//  MurmurCore
//
//  One row in the record navigator (X63-C).
//
//  The navigator has two sources now: a scanned folder of WFDB records, and a
//  multi-record `.mur` session. The spec is explicit that opening a session
//  populates the EXISTING navigator rather than growing a second record list,
//  so both sources produce this one row model and everything downstream —
//  selection, the flag, the detail pane — stays single-pathed.
//
//  Deliberately a DISPLAY model. It carries the strings a row renders and
//  nothing else; where the record's bytes live is `ContentView`'s
//  `importStates`, keyed by the same `id`.
//

import Foundation

struct RecordListEntry: Identifiable, Equatable {

    /// Stable key for selection and for `importStates`. A folder scan uses the
    /// `.hea` filename; a session uses the record's UUID string, which is also
    /// its subtree name inside the package.
    let id: String

    /// What the analyst calls this record — the WFDB record name, or the
    /// recording's device for a session record.
    let title: String

    /// One line of record-specific detail.
    let subtitle: String

    /// Everything the navigator's search field matches against (#328).
    ///
    /// Wider than what the row displays: the subtitle truncates to one line,
    /// but a 45,000-record corpus is only navigable if you can search the
    /// values that got truncated away — a `Dx` code list, say. Holds the
    /// title, every metadata key and value, and every raw comment line.
    let searchText: String

    /// A scanned WFDB record.
    init(_ record: WFDBRecordEntry) {
        id = record.filename
        title = record.header.recordName
        var parts: [String] = []
        if record.durationSeconds > 0 {
            parts.append(Self.duration(record.durationSeconds))
        }
        // X56 §3: "N sig • H Hz • M min" is identical for all 48 MIT-BIH
        // records, so it discriminates nothing while costing a row of height.
        // The first `.hea` comment is record-specific (the patient line, or a
        // rhythm note like 212's rate-related RBBB), so surface it — anything
        // record-specific beats a constant.
        //
        // X68 went further and dropped signal count and sample rate too. The
        // redesign's info bar carries both for the OPEN record, and repeating
        // them on all twenty rows is the same height-for-a-constant trade X56
        // rejected. Duration stays because it varies on every corpus.
        //
        // #328: PhysioNet's modern corpora put structured `Key: value` metadata
        // in those comments (`Age`, `Sex`, `Dx`…). When a record has any, show
        // ALL of it rather than only the first line — on the arrhythmia corpus
        // the first comment is `Age: 85` for every row, which discriminates
        // nothing, exactly the failure X56 rejected. Records without key/value
        // comments (MIT-BIH) keep the original first-comment behaviour.
        // Sentinel-valued fields (`Rx: Unknown` and friends) are dropped from
        // the SUBTITLE only — they are identical on every row of a corpus, and
        // `searchText` below still carries them. See `carriesInformation`.
        let metadata = record.header.metadata
        let informative = metadata.filter(\.carriesInformation)
        if informative.isEmpty {
            if let note = record.header.comments
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty }) {
                parts.append(note)
            }
        } else {
            parts.append(contentsOf: informative.map(\.display))
        }
        subtitle = parts.joined(separator: " · ")

        var searchable: [String] = [record.header.recordName]
        for field in metadata {
            searchable.append(field.key)
            searchable.append(field.value)
        }
        searchable.append(contentsOf: record.header.comments)
        searchText = searchable.joined(separator: " ")
    }

    /// A record inside an opened `.mur` session. Built from the recording
    /// itself rather than a `.hea`, because a session record has no header —
    /// it was reconstituted from the package's embedded source.
    init(sessionRecord recording: Recording) {
        id = recording.id.uuidString
        title = recording.device
        let primary = recording.primaryECGChannel ?? recording.channels.first
        var parts: [String] = []
        if let rate = primary?.sampleRate, rate > 0,
           let count = primary?.sampleCount, count > 0 {
            parts.append(Self.duration(Double(count) / rate))
        }
        // The source filename is what distinguishes two records that a session
        // may have drawn from different folders — the session equivalent of the
        // `.hea` comment above.
        if !recording.sourceFileName.isEmpty {
            parts.append(recording.sourceFileName)
        }
        subtitle = parts.joined(separator: " · ")
        // A session record has no `.hea` to mine, so its searchable text is
        // just what the row already shows.
        searchText = "\(title) \(subtitle)"
    }

    /// `h`, not `hr` — the redesign's info bar and navigator both read
    /// `72.4 h`, and two spellings of the same unit in one window is the kind
    /// of drift nobody files a bug about but everybody notices.
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        if seconds < 3600 { return String(format: "%.1f min", seconds / 60) }
        return String(format: "%.1f h", seconds / 3600)
    }
}

/// Where the navigator's records came from. The two differ in exactly one
/// behaviour — selecting a row in a folder triggers an import, while a session
/// record is already reconstituted on disk — so the distinction is carried
/// rather than inferred.
enum RecordListSource: Equatable {
    case folder(URL)
    case session(URL)

    /// Title for the navigator column.
    var displayName: String {
        switch self {
        case .folder(let url), .session(let url):
            return url.lastPathComponent
        }
    }
}
