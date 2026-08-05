//
//  SessionOpenPlan.swift
//  MurmurCore
//
//  Turning an opened `.mur` into what the navigator shows (X63-C).
//
//  Extracted from `ContentView.openMurPackage` for the same reason
//  `SessionSaveSet` was extracted from the save command: logic that lives
//  inside a SwiftUI view body is reachable only by driving the UI, and the
//  open path is where a multi-record package either surfaces every record or
//  quietly drops some. That is worth a unit test, so it is worth being a type.
//
//  Pure apart from the recording loader it is handed — no view state, no
//  singletons.
//

import Foundation

struct SessionOpenPlan {

    /// One record, ready to become a navigator row and an `importStates` entry.
    struct Record {
        /// Key shared by the navigator row, `importStates`, and the flag store.
        /// The recording's UUID string, which is also its subtree name inside
        /// the package.
        let id: String
        let entry: RecordListEntry
        let directory: URL
        let recording: Recording
        /// Per-record viewport + saved paper (X59), applied when this record is
        /// activated rather than at open — with many records, "restore the
        /// analyst's paper" is a per-record rule.
        let sessionState: MurSessionState?
        /// What the record's numbers were made of at save (X26). Carried, never
        /// applied: the template is always recomputed, and this is the record of
        /// what it WAS, so a divergence stays visible.
        let provenance: MurProvenance?
    }

    let records: [Record]

    /// The record to select on open — whatever the analyst had active when they
    /// saved. Never nil for a well-formed package, since `read` refuses to
    /// return a record-less one.
    let activeID: String?

    /// Build the plan from a package read.
    ///
    /// `loadRecording` is injected so this stays testable without a
    /// `RecordingStore`, and so a failure to load ONE record surfaces as a
    /// thrown error rather than a silently shorter navigator — a package that
    /// lists four records and shows three is worse than one that refuses.
    static func make(
        from result: MurSessionPackage.ReadResult,
        loadRecording: (URL) throws -> Recording
    ) rethrows -> SessionOpenPlan {
        var records: [Record] = []
        for record in result.records {
            let recording = try loadRecording(record.recordingDirectory)
            records.append(
                Record(
                    id: recording.id.uuidString,
                    entry: RecordListEntry(sessionRecord: recording),
                    directory: record.recordingDirectory,
                    recording: recording,
                    sessionState: record.sessionJSON.flatMap {
                        try? JSONDecoder().decode(MurSessionState.self, from: $0)
                    },
                    provenance: record.provenanceJSON.flatMap {
                        try? JSONDecoder().decode(MurProvenance.self, from: $0)
                    }
                )
            )
        }
        return SessionOpenPlan(
            records: records,
            activeID: result.activeRecord.identity.recordingID.uuidString
        )
    }
}
