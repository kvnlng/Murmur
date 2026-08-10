//
//  SessionFlagStore.swift
//  MurmurCore
//
//  Which records the analyst has picked out of a directory (X63-B).
//
//  An analyst opens a folder of records, works through it, and finds four that
//  matter. The flag is how they say so, and File → Save Session writes the
//  flagged set into one `.mur` — which is the only thing that makes those four
//  a set rather than four unrelated files.
//
//  ## One selection concept, not two
//
//  The flag in the record sidebar is the ONLY way to pick records for a save.
//  There is deliberately no basket, no multi-select, no "add to session"
//  command. If a future surface needs to express "these records", it uses this.
//
//  ## Why the App target reads this instead of ContentView's state
//
//  Save Session is a menu command in the App target, which cannot reach
//  ContentView's `@State`. Same shape as `CurrentRecordingContext.liveSessionState`:
//  the view publishes, the menu reads.
//

import Foundation
import Observation

/// A record that is imported and therefore savable, paired with the bundle its
/// analyst layer lives in.
public struct FlaggedRecord: Identifiable, Sendable, Equatable {
    /// The sidebar's identity for this record — its `.hea` filename. Unique
    /// within a folder, which is the scope a flag lives in.
    public let id: String
    public let recording: Recording
    public let directory: URL

    public init(id: String, recording: Recording, directory: URL) {
        self.id = id
        self.recording = recording
        self.directory = directory
    }
}

@MainActor
@Observable
public final class SessionFlagStore {

    /// Shared instance the app uses. Tests construct their own so parallel
    /// runs stay isolated.
    public static let shared = SessionFlagStore()

    public init() {}

    /// Records the analyst has flagged, by sidebar id.
    public private(set) var flaggedIDs: Set<String> = []

    /// Imported records available to save, in sidebar order. ContentView is
    /// the only writer — it is the surface that knows what has been imported
    /// and where each bundle landed.
    public private(set) var available: [FlaggedRecord] = []

    /// Records whose pre-flag default has already been decided, so clearing a
    /// flag STAYS cleared. Pre-flagging is a default, not a lock: an analyst
    /// who unflags a record they had annotated must not find it flagged again
    /// the next time they navigate back to it.
    private var defaulted: Set<String> = []

    /// The set a save would write, in sidebar order.
    public var flaggedRecords: [FlaggedRecord] {
        available.filter { flaggedIDs.contains($0.id) }
    }

    public func isFlagged(_ id: String) -> Bool { flaggedIDs.contains(id) }

    public func toggle(_ id: String) {
        // Toggling is an explicit decision either way, so it also settles the
        // default — see `defaulted`.
        defaulted.insert(id)
        if flaggedIDs.contains(id) {
            flaggedIDs.remove(id)
        } else {
            flaggedIDs.insert(id)
        }
    }

    /// Flag a record outright, and settle its pre-flag default. Used when a
    /// session is opened: its records are already the analyst's chosen set.
    public func flag(_ id: String) {
        defaulted.insert(id)
        flaggedIDs.insert(id)
    }

    /// Register (or re-register) an imported record. Idempotent: re-importing
    /// the same record replaces its entry without disturbing its flag.
    public func register(_ record: FlaggedRecord) {
        if let index = available.firstIndex(where: { $0.id == record.id }) {
            available[index] = record
        } else {
            available.append(record)
        }
    }

    /// Apply the pre-flag default ONCE for a record: flag it when its bundle
    /// carries analyst work. Does nothing if the analyst has already expressed
    /// a preference for this record.
    public func applyDefaultFlag(for id: String, directory: URL) {
        guard !defaulted.contains(id) else { return }
        defaulted.insert(id)
        if AnalystLayerProbe.hasAnalystWork(in: directory) {
            flaggedIDs.insert(id)
        }
    }

    /// X86 — the same pre-flag default, for analyst work that exists only in
    /// memory: unsaved notes being carried across a record switch never touch
    /// the bundle, so the disk probe above cannot see them. Same contract —
    /// fires once, and an analyst's explicit unflag stays unflagged.
    public func applyDefaultFlag(for id: String) {
        guard !defaulted.contains(id) else { return }
        defaulted.insert(id)
        flaggedIDs.insert(id)
    }

    /// Clear everything — a different folder is a different working set.
    public func reset() {
        flaggedIDs.removeAll()
        available.removeAll()
        defaulted.removeAll()
    }
}

/// Does this bundle carry evidence that the ANALYST worked this record?
///
/// X63-B: the spec says a record "carrying an analyst layer (findings, notes,
/// or dispositions)" pre-flags. Taken literally that pre-flags everything,
/// because:
///
///   - `WFDBImporter` writes `annotations.json` on EVERY import, from the
///     record's own `.atr` / producer JSON. Those are the source's findings,
///     not the analyst's.
///   - It also copies any notes file out of the source folder, so a notes file
///     is likewise evidence about the SOURCE, not about the analyst.
///
/// A default that fires for every record tells the analyst nothing, so this
/// keys on artefacts only an analyst action can produce: a disposition (they
/// confirmed or dismissed something) or an annotation they authored themselves.
/// Narrower than the spec's wording and deliberately so — the flag is manual,
/// and this only saves keystrokes in the unambiguous cases.
public enum AnalystLayerProbe {

    public static func hasAnalystWork(in directory: URL) -> Bool {
        hasDispositions(in: directory) || hasAuthoredAnnotations(in: directory)
    }

    /// Confirm / dismiss on a finding, or an adjudicated VT/VF candidate.
    /// Written only by analyst action.
    static func hasDispositions(in directory: URL) -> Bool {
        let fm = FileManager.default
        for name in [DispositionFile.bundleFileName, RegionDispositionFile.bundleFileName]
        where fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            return true
        }
        return false
    }

    /// A range finding the analyst drew themselves, distinguished from imported
    /// findings by its source tag.
    static func hasAuthoredAnnotations(in directory: URL) -> Bool {
        guard let annotations = BundleAnnotationsFile.read(from: directory) else { return false }
        return annotations.contains { $0.source == Annotation.analystAuthoredSource }
    }
}

/// What a save is about to write, in the analyst's words.
///
/// X63-B: the save panel STATES its scope before writing. An analyst must not
/// discover afterwards that "Save Session" meant four records — or meant one
/// when they thought they had flagged four.
///
/// Lives here rather than in the App target so the copy is testable; the panel
/// is system-modal and cannot be driven by XCUI.
public enum SessionSaveScope {

    public static func message(recordCount: Int) -> String {
        recordCount == 1
            ? "Saving 1 recording."
            : "Saving \(recordCount) flagged recordings into one session."
    }

    /// A single-record save keeps its record's name, which is what an analyst
    /// expects from the gesture they have always used. A set has no one name,
    /// so it gets a neutral one rather than borrowing whichever record happened
    /// to sort first.
    public static func defaultFileName(recordCount: Int, singleSourceFileName: String?) -> String {
        guard recordCount == 1, let name = singleSourceFileName else { return "Session.mur" }
        let base = (name as NSString).deletingPathExtension
        return "\(base.isEmpty ? "Session" : base).mur"
    }
}

/// Which records a save writes, and which of them carries the live state.
///
/// X63-B. Extracted from the App target's save command so the RULE is
/// unit-tested: that command is a menu handler around an `NSSavePanel`, which
/// is system-modal and cannot be driven by XCUI, so anything decided in there
/// is untestable by construction.
public enum SessionSaveSet {

    /// - Parameters:
    ///   - flagged: the sidebar's flagged set, in the analyst's order.
    ///   - openRecording/openDirectory: whatever is on screen right now.
    ///   - sessionJSON/provenanceJSON: state describing the OPEN record only.
    ///   - carriedSessionJSONByID: X86 — session state parked by a record
    ///     switch, keyed by sidebar id. Unlike the open record's viewport,
    ///     this IS knowable for a non-open record: it is that record's own
    ///     state, captured the moment the analyst switched away.
    ///
    /// With nothing flagged this returns the open record alone, so the
    /// single-record gesture behaves exactly as it always has.
    ///
    /// Only the open record receives `sessionJSON` and `provenanceJSON`. Those
    /// describe where the analyst is and what the on-screen numbers were made
    /// of. Copying the open record's viewport onto every record in the set
    /// would be a fabricated coordinate — the same error class as X32's
    /// invented start time; a CARRIED state is the opposite of fabricated,
    /// so a flagged record that has one gets it. Provenance stays open-only:
    /// it describes the on-screen template, which is recomputed live and was
    /// never captured for a parked record.
    public static func payloads(
        flagged: [FlaggedRecord],
        openRecording: Recording?,
        openDirectory: URL?,
        sessionJSON: Data?,
        provenanceJSON: Data?,
        carriedSessionJSONByID: [String: Data] = [:]
    ) -> [MurSessionPackage.RecordPayload] {
        guard !flagged.isEmpty else {
            guard let openRecording, let openDirectory else { return [] }
            return [
                MurSessionPackage.RecordPayload(
                    recording: openRecording,
                    recordingDirectory: openDirectory,
                    provenanceJSON: provenanceJSON,
                    sessionJSON: sessionJSON
                ),
            ]
        }
        return flagged.map { record in
            let isOpen = record.recording.id == openRecording?.id
            return MurSessionPackage.RecordPayload(
                recording: record.recording,
                recordingDirectory: record.directory,
                provenanceJSON: isOpen ? provenanceJSON : nil,
                sessionJSON: isOpen ? sessionJSON : carriedSessionJSONByID[record.id]
            )
        }
    }
}
