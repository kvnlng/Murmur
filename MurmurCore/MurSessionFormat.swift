//
//  MurSessionFormat.swift
//  MurmurCore
//
//  The native Murmur Studio SAVE format — `.mur` — per
//  project_mur_save_format_spec.md. SAVE writes the analyst's whole session at
//  Murmur Studio's OWN detail (a superset of WFDB); EXPORT projects DOWN to a
//  plain WFDB annotator (`.mrm`, see WFDBAnnotationExport). You SAVE to Murmur
//  (up), you EXPORT to WFDB (down).
//
//  `.mur` is an Apple DOCUMENT PACKAGE — a directory Finder presents as one
//  file (LSTypeIsPackage; UTType registration is X14-D).
//
//  X63-A: a session holds MANY records, not one. An analyst works a DIRECTORY,
//  flags the records that matter, and saves them as one file — which is the
//  only thing that makes them a set.
//
//      Session.mur/
//        manifest.json          versioned contract — first thing read; carries
//                               `records`, and that array IS the analyst's order
//        session.json           SESSION-LEVEL state (MurCollectionState): which
//                               record was active at save
//        records/
//          <recordingID>/       one subtree per record, keyed by UUID
//            source/            embedded copy of the raw recording, LZFSE
//                               (reopens with no original WFDB present)
//            annotations/       analyst layer — the bundle sidecars, reused as-is
//            dispositions/      annotation + candidate dispositions
//            guides/            interval-trend threshold guides
//            provenance.json    what the numbers were MADE OF (X26)
//            session.json       PER-RECORD state: viewport, saved paper,
//                               focused lead (X59)
//            cache/             derived, REBUILDABLE, version-stamped (X14-C)
//
//  Subtrees are keyed by `recordingID` rather than source filename: two records
//  in one directory can share a base name, and once X63-D adds encryption a
//  filename on the outside of the package would identify its contents.
//
//  The two `session.json` files answer different questions and must not be
//  merged — a reopen has to restore both WHICH record was active and WHERE the
//  analyst was inside it.
//
//  NO COMPATIBILITY READER, deliberately. Nothing has been released, so the
//  multi-record layout is the only layout this code has ever supported;
//  `formatVersion` stays in the manifest as the mechanism for the NEXT change,
//  not this one. Packages written by earlier development builds do not open.
//

import Foundation

/// The versioned contract at the head of every `.mur` package. Small, human-
/// diffable, and the first thing read — a newer `formatVersion` than the app
/// understands is a clear refusal, never a silent misread.
public struct MurSessionManifest: Codable, Equatable, Sendable {

    /// Bump when the on-disk layout changes incompatibly. Reads gate on this.
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    /// App short version string that wrote the package (best-effort).
    public let appVersion: String
    public let createdAt: Date
    public let modifiedAt: Date

    /// Every record in this session, in the analyst's order.
    ///
    /// X63-A: a `.mur` holds MANY records. This array IS the ordering — the
    /// session-level `session.json` deliberately does not carry a second copy,
    /// because two authorities on order is how they drift apart.
    ///
    /// Each entry's `recordingID` is the name of its subtree under `records/`.
    ///
    /// X63-D: **absent on an encrypted package.** `sourceFileName` identifies a
    /// recording, and a record count is itself information, so neither may sit
    /// on the outside of a sealed file. The identities live inside the
    /// ciphertext; a reader learns them only after the passphrase opens it.
    public let records: [SourceIdentity]?

    /// Present when this package is encrypted; nil when it is plaintext.
    /// Carries the parameters needed to re-derive the key — never the key.
    public let encryption: EncryptionParameters?

    /// How the payload was sealed. Recorded per package so raising the
    /// iteration count later cannot strand files written before the change.
    public struct EncryptionParameters: Codable, Equatable, Sendable {
        public let kdf: String
        public let iterations: Int
        public let salt: Data
        public let cipher: String

        public init(kdf: String, iterations: Int, salt: Data, cipher: String) {
            self.kdf = kdf
            self.iterations = iterations
            self.salt = salt
            self.cipher = cipher
        }
    }

    /// How each record's `source/` subtree is stored — `none` for raw copies,
    /// `lzfse` after X14-B. Read uses this to decide whether to inflate.
    public let sourceStorage: SourceStorage
    /// Top-level parts present in this package (`records`, `session.json`).
    /// X63-D: absent on an encrypted package — a contents list describes the
    /// shape of what was sealed.
    public let contents: [String]?

    public enum SourceStorage: String, Codable, Sendable {
        case none        // raw files copied verbatim
        case lzfse       // AppleArchive/Compression (X14-B)
    }

    /// Enough to identify the recording without inflating the source — shown in
    /// pickers and used to sanity-check a reopen.
    public struct SourceIdentity: Codable, Equatable, Sendable {
        public let recordingID: UUID
        public let sourceFileName: String
        public let sampleRate: Double
        public let channelCount: Int
        public let sampleCount: Int64
        /// Optional absolute time base (Unix ms) for the first sample, present
        /// only when the SOURCE genuinely carries wall-clock time (C6).
        /// MIT-BIH/WFDB and the CSV importer don't, so this stays nil today —
        /// the field exists so the format can carry an absolute base (for the
        /// circadian / encounter-time analysis the ICU-telemetry buyer works
        /// in) the moment a source provides one, without a format-version
        /// bump. Never populated from a synthetic/import-derived timestamp.
        /// Optional so older `.mur` files decode unchanged.
        public let absoluteStartUnixMillis: Int64?
    }
}

/// X72 — a time-anchored analyst note.
///
/// SESSION work product, not a durable record annotation (DECISIONS §4):
/// lives in `MurSessionState` → `.mur/records/<id>/session.json`, written by
/// File ▸ Save Session and never autosaved to the bundle. No new bundle-local
/// file — `notes.md` stays exactly what it was, the record-level document
/// with its own debounced bundle-local autosave.
public struct AnchoredNote: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The anchor, in samples of the primary ECG channel — the same
    /// coordinate the viewport speaks, so a jump back is exact rather than
    /// re-derived through a seconds conversion.
    public var startSample: Int64
    public var endSample: Int64
    /// The lead focused when the note was taken. Provenance, not a filter —
    /// "anchored to a 10 s range in lead II" is part of what the note means.
    public var leadName: String?
    public var text: String
    public var createdAt: Date
    public var modifiedAt: Date
    /// "Include in exported report". Optional so notes saved before the field
    /// existed decode; absent reads as false.
    public var includeInReport: Bool?
    /// X84 — the location-less kind. `true` marks a RECORD-LEVEL note: no
    /// anchor, no marker on any band, no jump. `startSample`/`endSample` are
    /// stored as 0 and mean nothing. Optional for the same reason as
    /// `includeInReport`: notes saved before the field existed decode, and
    /// absent reads as the location-marked kind they all were.
    public var isRecordLevel: Bool?

    /// The X84 kind split, readably. Every consumer that draws an anchor,
    /// offers a jump, or captions a range must branch on this rather than
    /// trusting the stored samples.
    public var isLocationless: Bool { isRecordLevel == true }

    public init(
        id: UUID = UUID(),
        startSample: Int64,
        endSample: Int64,
        leadName: String? = nil,
        text: String = "",
        createdAt: Date,
        modifiedAt: Date,
        includeInReport: Bool? = nil,
        isRecordLevel: Bool? = nil
    ) {
        self.id = id
        self.startSample = startSample
        self.endSample = endSample
        self.leadName = leadName
        self.text = text
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.includeInReport = includeInReport
        self.isRecordLevel = isRecordLevel
    }
}

/// The `session.json` schema — UI/session state so a reopen lands the analyst
/// back where they were. Plain snapshot; all optional so partial/older sessions
/// decode. The app composes/consumes it (X14-D); this is the shape it round-trips.
public struct MurSessionState: Codable, Equatable, Sendable {
    public var viewportStartSample: Int64?
    public var viewportEndSample: Int64?
    public var focusedChannelName: String?
    /// X96 (#146) — the full lead overlay, in selection order, first name
    /// primary. `focusedChannelName` is singular, so a save used to drop
    /// every overlaid lead on the floor. Dual-field by design:
    ///   - SAVE writes this only when the selection is multi-lead (a
    ///     single-lead package stays byte-identical to pre-X96), and always
    ///     writes the singular alongside it, so an older app version
    ///     restores the primary exactly as before.
    ///   - RESTORE prefers this list when present (`restoredLeadNames`);
    ///     the singular is the legacy fallback.
    /// Order is load-bearing: X64-C assigns trace inks by selection rank,
    /// so a reordered restore would silently recolor traces.
    public var focusedChannelNames: [String]?
    public var windowLockedTo10s: Bool?
    public var selectedTrendMetric: String?
    public var selectedBinPreset: String?
    /// X50(b) — the analyst's saved paper (mm/mV). Present only when the
    /// session was saved with a resolved gain; `nil` means "this package
    /// carries no paper", and the open falls back to Standard View exactly as
    /// a raw import does. The time scale (mm/s) is not stored separately: it is
    /// implied by the saved viewport width against the canvas.
    public var gainMillimetersPerMillivolt: Double?
    /// #359 — the timebase half of the saved paper (mm/s), making both axes
    /// calibration-canonical on restore: a session saved at 25 mm/s reopens
    /// at 25 mm/s in any window size (the width re-derives against the new
    /// canvas). `nil` when no canonical speed was in effect at save — the
    /// analyst had zoomed to an extent, or the display couldn't prove mm —
    /// and the restore then lands the saved sample width exactly as before,
    /// so older packages and older readers are both unaffected.
    public var speedMillimetersPerSecond: Double?
    /// VT/VF scan operating point in effect.
    public var tau: Double?
    public var minDurationSeconds: Double?
    public var mergeGapSeconds: Double?
    public var scanScopeWholeRecording: Bool?
    /// X72 — the analyst's time-anchored notes. `nil` (not `[]`) when there
    /// are none, so a session saved before notes existed and one saved with
    /// zero notes are byte-identical.
    public var anchoredNotes: [AnchoredNote]?
    /// X112 — the analyst's morphology-cluster endorsements. Same
    /// nil-when-empty discipline as `anchoredNotes`: a session saved before
    /// endorsements existed and one saved with none are byte-identical.
    /// Cluster identity is by representative waveform, re-attached on load
    /// by the App's morphology orchestrator (#381 — the verdict is paid
    /// compute, published via `MorphologyContext.attachments`).
    public var morphologyEndorsements: [MorphologyEndorsement]?

    public init(
        viewportStartSample: Int64? = nil,
        viewportEndSample: Int64? = nil,
        focusedChannelName: String? = nil,
        focusedChannelNames: [String]? = nil,
        windowLockedTo10s: Bool? = nil,
        selectedTrendMetric: String? = nil,
        selectedBinPreset: String? = nil,
        gainMillimetersPerMillivolt: Double? = nil,
        speedMillimetersPerSecond: Double? = nil,
        tau: Double? = nil,
        minDurationSeconds: Double? = nil,
        mergeGapSeconds: Double? = nil,
        scanScopeWholeRecording: Bool? = nil,
        anchoredNotes: [AnchoredNote]? = nil,
        morphologyEndorsements: [MorphologyEndorsement]? = nil
    ) {
        self.viewportStartSample = viewportStartSample
        self.viewportEndSample = viewportEndSample
        self.focusedChannelName = focusedChannelName
        self.focusedChannelNames = focusedChannelNames
        self.windowLockedTo10s = windowLockedTo10s
        self.selectedTrendMetric = selectedTrendMetric
        self.selectedBinPreset = selectedBinPreset
        self.gainMillimetersPerMillivolt = gainMillimetersPerMillivolt
        self.speedMillimetersPerSecond = speedMillimetersPerSecond
        self.tau = tau
        self.minDurationSeconds = minDurationSeconds
        self.mergeGapSeconds = mergeGapSeconds
        self.scanScopeWholeRecording = scanScopeWholeRecording
        self.anchoredNotes = anchoredNotes
        self.morphologyEndorsements = morphologyEndorsements
    }

    /// X96 — the ordered lead names a restore should stage, resolving the
    /// dual-field schema: the plural list wins when present and non-empty
    /// (first name primary); the legacy singular is the fallback; a package
    /// carrying neither restores no lead state at all. Pure, so the
    /// preference order is pinned by unit tests rather than re-derived at
    /// the restore site.
    public var restoredLeadNames: [String] {
        if let names = focusedChannelNames, !names.isEmpty { return names }
        if let single = focusedChannelName { return [single] }
        return []
    }

    /// X59/X11 — replace only the fields the bedside view owns, preserving the
    /// ones other surfaces own (the scan dials).
    ///
    /// The bedside view republishes on every viewport change; assigning a state
    /// built solely from its own `@State` would silently wipe an operating point
    /// the scan sheet had just set. Stated once here rather than inline at the
    /// call site, so the ownership split is testable and hard to get wrong.
    public func replacingViewState(with other: MurSessionState) -> MurSessionState {
        var copy = self
        copy.viewportStartSample = other.viewportStartSample
        copy.viewportEndSample = other.viewportEndSample
        copy.focusedChannelName = other.focusedChannelName
        // X96: the overlay list is view-owned exactly like the singular —
        // dropping it here would wipe the staged leads on the first pan
        // (the X11 failure mode, again).
        copy.focusedChannelNames = other.focusedChannelNames
        copy.windowLockedTo10s = other.windowLockedTo10s
        copy.gainMillimetersPerMillivolt = other.gainMillimetersPerMillivolt
        // #359: the timebase half of the paper is view-owned like the gain —
        // dropping it here would wipe the saved speed on the first pan.
        copy.speedMillimetersPerSecond = other.speedMillimetersPerSecond
        // X72: anchored notes are drawn and edited in the bedside view, so
        // they are view-owned. Omitting this line is exactly the X11 failure
        // mode DECISIONS §4 warns about — the view republishes on every
        // viewport change, and a merge that drops the field would wipe the
        // analyst's notes on the first pan.
        copy.anchoredNotes = other.anchoredNotes
        // X112: endorsements are made and withdrawn in the bedside view's
        // drawer, so they are view-owned — same X11 wipe risk as notes.
        copy.morphologyEndorsements = other.morphologyEndorsements
        return copy
    }
}

/// The `provenance.json` schema — what the analyst's numbers were MADE OF at
/// save time (X26). The package already reconstitutes enough to recompute a
/// template, but a recomputed number is not the saved one: the delineator, the
/// exclusion rules, or the formula default can all move between versions.
/// Recording the population alongside the value is what makes the saved
/// measurement auditable rather than merely repeatable — X48's rule (a number
/// without its population is not reproducible) applied to the file format.
///
/// All optional so partial/older packages decode. App version and record
/// identity already live on the manifest and are deliberately not duplicated.
public struct MurProvenance: Codable, Equatable, Sendable {

    /// The patient-normal template as it stood when the session was saved.
    public struct NormalTemplate: Codable, Equatable, Sendable {
        /// Beats that CONTRIBUTED to the medians.
        public var beatCount: Int?
        /// Beats withheld — physically impossible (X53) or unreliable T-offset
        /// (X58). Merged, as the builder merges them; do not attribute this to
        /// a single cause when rendering it.
        public var excludedBeatCount: Int?
        /// The lead the intervals were measured in — the analysis lead's
        /// NAME exactly as recorded (#357), never prose. A QT without its
        /// lead is not comparable (the X58 rec-212 lesson). §1.5's "not a
        /// conventional QT lead (II/V5)" disclosure is NOT stored here; the
        /// QT-bearing surfaces append it at render time via
        /// `QTLeadDisclosure`, so a saved session carries the fact and the
        /// reader states the caveat.
        public var sourceLead: String?
        public var spanStartSample: Int64?
        public var spanEndSample: Int64?
        /// Rate-correction formula in effect — the app never arbitrates it
        /// (X44), so the saved number is only interpretable alongside it.
        public var qtcFormulaName: String?
        /// The template median AS SAVED, so a later recompute can be compared
        /// against it rather than silently replacing it.
        public var medianQTcMs: Double?

        public init(
            beatCount: Int? = nil,
            excludedBeatCount: Int? = nil,
            sourceLead: String? = nil,
            spanStartSample: Int64? = nil,
            spanEndSample: Int64? = nil,
            qtcFormulaName: String? = nil,
            medianQTcMs: Double? = nil
        ) {
            self.beatCount = beatCount
            self.excludedBeatCount = excludedBeatCount
            self.sourceLead = sourceLead
            self.spanStartSample = spanStartSample
            self.spanEndSample = spanEndSample
            self.qtcFormulaName = qtcFormulaName
            self.medianQTcMs = medianQTcMs
        }
    }

    public var normalTemplate: NormalTemplate?

    public init(normalTemplate: NormalTemplate? = nil) {
        self.normalTemplate = normalTemplate
    }
}

extension MurProvenance.NormalTemplate {
    /// Snapshot a live template for saving. `nil` when there is no template —
    /// absent must stay absent rather than becoming a zero-beat template.
    public init?(_ template: MarkingsTemplate?) {
        guard let template else { return nil }
        self.init(
            beatCount: template.sampleCount,
            excludedBeatCount: template.excludedBeatCount,
            sourceLead: template.sourceLead,
            spanStartSample: template.spanStartSample,
            spanEndSample: template.spanEndSample,
            qtcFormulaName: template.qtcFormulaName,
            medianQTcMs: template.medianQTcMs
        )
    }
}

/// The SESSION-LEVEL `session.json` — state that belongs to the SET of records
/// rather than to any one of them (X63-A).
///
/// Deliberately tiny. Record ordering lives in `MurSessionManifest.records` and
/// is not duplicated here; per-record viewport / paper / focused lead stay in
/// each record's own `session.json` (`MurSessionState`). The split matters: a
/// reopen has to restore both *which* record was active and *where* the analyst
/// was inside it, and those are different questions.
public struct MurCollectionState: Codable, Equatable, Sendable {

    /// The record the analyst was looking at when they saved, so a reopen lands
    /// somewhere they chose rather than on whichever record sorted first. `nil`
    /// means "no preference" — the reader falls back to the first record.
    public var activeRecordingID: UUID?

    public init(activeRecordingID: UUID? = nil) {
        self.activeRecordingID = activeRecordingID
    }
}

public enum MurSessionError: LocalizedError, Equatable {
    case missingManifest
    case unsupportedFormatVersion(Int)
    case malformedPackage(String)
    /// A session must contain at least one record; an empty package is a bug
    /// at the call site, not a file to write.
    case noRecords
    /// Two records with the same `recordingID` would collide in `records/`.
    case duplicateRecordingID(UUID)
    /// The package is encrypted and no passphrase was supplied.
    case passphraseRequired
    /// The supplied passphrase did not open the package. Deliberately NOT
    /// reported as damage — see MurSessionCrypto.open.
    case wrongPassphrase

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "This .mur file is missing its manifest and can't be opened."
        case .unsupportedFormatVersion(let v):
            return "This .mur file was written by a newer version of Murmur Studio (format \(v)). Update to open it."
        case .malformedPackage(let detail):
            return "This .mur file is damaged: \(detail)."
        case .noRecords:
            return "A Murmur session must contain at least one recording."
        case .duplicateRecordingID(let id):
            return "This session lists the same recording twice (\(id))."
        case .passphraseRequired:
            return "This session is encrypted. Enter its passphrase to open it."
        case .wrongPassphrase:
            return "That passphrase didn't open this session."
        }
    }
}

/// The one field a manifest of ANY format version is contractually required to
/// carry. Decoded on its own so the version refusal survives a future layout
/// change — see `MurSessionPackage.read`.
struct FormatVersionProbe: Decodable {
    let formatVersion: Int
}
