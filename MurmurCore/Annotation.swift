//
//  Annotation.swift
//  Murmur
//
//  Rich annotation model for clinical findings. Findings come from upstream
//  analysis (a cluster of machines processing telemetry) and arrive in the
//  recording folder as `<recordName>.annotations.json`. The WFDB `.atr` path
//  remains a legacy adapter that maps beat-symbol annotations into the same
//  model with `source = "wfdb.atr"`.
//
//  Time can be expressed in two forms in the producer JSON:
//    • `startSample` / `endSample`  — already aligned to the WFDB record
//    • `startUnixMS`  / `endUnixMS` — absolute time; viewer resolves to sample
//                                     index using the channel's startTimeUnixMS
//                                     and sampleRate at load time
//
//  Both forms can appear in a single file; the importer prefers sample fields
//  when both are present.
//

import Foundation

// MARK: - In-memory model

public struct Annotation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: Kind
    public let sampleIndex: Int64           // resolved start sample (always set after import)
    public let endSampleIndex: Int64?       // resolved end sample for ranges; nil for points
    public let unixMillisStart: Int64?      // original producer-side absolute time, if any
    public let unixMillisEnd: Int64?
    public let category: String             // semantic finding category, e.g. "VF_onset", "PVC"
    public let label: String?               // short display token; falls back to category
    public let confidence: Double?          // 0…1 from the producer model, optional
    public let source: String               // producer ID, e.g. "vf-onset-detector-v2"
    public let note: String?                // free-form analyst-readable text
    public let lead: String?                // channel/lead label if finding is lead-specific
    public let evidenceContextSeconds: Double?  // viewer-side scroll-into-view hint
    public let citationCaption: String?     // immutable reproducibility payload for analyst-authored findings (label vs caption split)

    public enum Kind: String, Codable, Sendable {
        case point
        case range
    }

    /// `source` value stamped on findings the analyst authors directly (e.g.
    /// drag-to-author range findings on the trend lane), as distinct from
    /// model/producer output. Matches the Annotation-authoring producer id so
    /// `PurchaseStore.requiredProduct(forProducerID:)` gates it. Authored
    /// findings are "amber" by nature and export to WFDB without needing a
    /// disposition.
    public static let analystAuthoredSource = "murmur.annotation"

    /// Historical `Severity` enum was removed 2026-07-04. An
    /// app-assigned "critical" on a beat is a clinical verdict —
    /// it breaks Murmur Studio's RUO stance (thresholds are
    /// user-set guides; the app never asserts a diagnosis).
    /// The review queue now ranks by objective departure from the
    /// per-patient normal template. Old `annotations.json` files
    /// that carry a severity field are still accepted at import
    /// time (see AnnotationFile.Finding) — the field is decoded
    /// and dropped.

    public var displayLabel: String { label ?? category }

    /// The end sample for rendering purposes — equals `sampleIndex` for point events.
    public var renderEndSample: Int64 { endSampleIndex ?? sampleIndex }

    /// True when this annotation should render on the channel named
    /// `channelName`. Lead-less annotations (the common case for
    /// whole-recording observations like AFib) match every channel;
    /// lead-tagged annotations match only the channel whose name
    /// normalizes equal to the `lead` field. Normalization trims
    /// whitespace and lowercases so producer outputs like `" II "`
    /// or `"ii"` match a channel named `"II"`.
    public func matchesChannel(_ channelName: String) -> Bool {
        guard let raw = lead else { return true }
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized == channelName.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Keyboard navigation helpers

    /// First annotation whose `sampleIndex` lies strictly after `position`.
    /// Used by the J keyboard shortcut to jump the viewport to the next
    /// finding. Nil when there are no findings after `position` (analyst
    /// is at the end of the recording's annotated stretch).
    static func nextFinding(after position: Int64, in annotations: [Annotation]) -> Annotation? {
        annotations
            .sorted { $0.sampleIndex < $1.sampleIndex }
            .first { $0.sampleIndex > position }
    }

    /// Last annotation whose `sampleIndex` lies strictly before
    /// `position`. Pairs with `nextFinding(after:in:)` for the K
    /// keyboard shortcut.
    static func previousFinding(before position: Int64, in annotations: [Annotation]) -> Annotation? {
        annotations
            .sorted { $0.sampleIndex < $1.sampleIndex }
            .last { $0.sampleIndex < position }
    }

    /// Annotation whose `sampleIndex` minimises the absolute distance
    /// to `position`. Used by the D / X disposition keyboard shortcuts
    /// to operate on whatever finding the analyst has the viewport
    /// centered on. Returns nil for empty input. Ties (two annotations
    /// equidistant from `position`) resolve to the earlier one for
    /// determinism.
    static func closest(to position: Int64, in annotations: [Annotation]) -> Annotation? {
        annotations.min { lhs, rhs in
            let lhsDist = abs(lhs.sampleIndex - position)
            let rhsDist = abs(rhs.sampleIndex - position)
            if lhsDist != rhsDist { return lhsDist < rhsDist }
            return lhs.sampleIndex < rhs.sampleIndex
        }
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        sampleIndex: Int64,
        endSampleIndex: Int64? = nil,
        unixMillisStart: Int64? = nil,
        unixMillisEnd: Int64? = nil,
        category: String,
        label: String? = nil,
        confidence: Double? = nil,
        source: String,
        note: String? = nil,
        lead: String? = nil,
        evidenceContextSeconds: Double? = nil,
        citationCaption: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sampleIndex = sampleIndex
        self.endSampleIndex = endSampleIndex
        self.unixMillisStart = unixMillisStart
        self.unixMillisEnd = unixMillisEnd
        self.category = category
        self.label = label
        self.confidence = confidence
        self.source = source
        self.note = note
        self.lead = lead
        self.evidenceContextSeconds = evidenceContextSeconds
        self.citationCaption = citationCaption
    }
}

// MARK: - JSON wire format (producer-facing)

/// The `<recordName>.annotations.json` file format. Producers emit this; the
/// viewer resolves time fields into `Annotation` values at import time.
struct AnnotationFile: Codable, Sendable {
    let schemaVersion: Int
    let source: String?              // default `source` for findings without an explicit one
    let findings: [Finding]

    struct Finding: Codable, Sendable {
        let id: UUID?
        let kind: Annotation.Kind
        // Time — either sample-index form or unix-millis form (or both)
        let startSample: Int64?
        let endSample: Int64?
        let startUnixMS: Int64?
        let endUnixMS: Int64?
        // Semantics
        let category: String
        let label: String?
        let confidence: Double?
        /// Historical field: severity was removed from the in-
        /// memory model 2026-07-04 (RUO — see Annotation.swift
        /// header comment). The wire format still accepts it so
        /// older producers keep importing cleanly; the value is
        /// decoded here and dropped in `resolve(finding:…)`.
        let severity: String?
        let source: String?
        let note: String?
        let lead: String?
        let evidenceContextSeconds: Double?
    }

    static let currentSchemaVersion = 1
}

enum AnnotationFileError: LocalizedError {
    case unreadable(URL)
    case unsupportedSchema(Int)
    case unresolvableTimestamp(category: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read annotation file: \(url.lastPathComponent)."
        case .unsupportedSchema(let v):
            return "Unsupported annotations schemaVersion \(v) (this viewer understands version \(AnnotationFile.currentSchemaVersion))."
        case .unresolvableTimestamp(let cat):
            return "Finding \"\(cat)\" has neither a sample nor a unix-millis timestamp."
        }
    }
}

enum AnnotationLoader {

    /// Parses an `<recordName>.annotations.json` file and resolves all findings
    /// into `Annotation` values, converting absolute timestamps to sample
    /// indices using the recording's start time and sample rate.
    static func load(
        url: URL,
        recordingStartUnixMS: Int64,
        sampleRate: Double,
        fallbackSource: String? = nil
    ) throws -> [Annotation] {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            throw AnnotationFileError.unreadable(url)
        }
        return try parse(
            data: data,
            recordingStartUnixMS: recordingStartUnixMS,
            sampleRate: sampleRate,
            fallbackSource: fallbackSource
        )
    }

    /// Pure-data variant used by tests.
    static func parse(
        data: Data,
        recordingStartUnixMS: Int64,
        sampleRate: Double,
        fallbackSource: String? = nil
    ) throws -> [Annotation] {
        let decoder = JSONDecoder()
        let file = try decoder.decode(AnnotationFile.self, from: data)
        guard file.schemaVersion == AnnotationFile.currentSchemaVersion else {
            throw AnnotationFileError.unsupportedSchema(file.schemaVersion)
        }
        let defaultSource = file.source ?? fallbackSource ?? "external"
        return try file.findings.map { finding in
            try resolve(
                finding: finding,
                defaultSource: defaultSource,
                recordingStartUnixMS: recordingStartUnixMS,
                sampleRate: sampleRate
            )
        }
    }

    /// Resolves one wire-format `Finding` into an in-memory `Annotation`.
    /// Sample-index fields take precedence over unix-millis when both are set.
    static func resolve(
        finding: AnnotationFile.Finding,
        defaultSource: String,
        recordingStartUnixMS: Int64,
        sampleRate: Double
    ) throws -> Annotation {
        let startSample: Int64
        if let s = finding.startSample {
            startSample = s
        } else if let ms = finding.startUnixMS {
            startSample = sampleIndex(forUnixMS: ms, startUnixMS: recordingStartUnixMS, sampleRate: sampleRate)
        } else {
            throw AnnotationFileError.unresolvableTimestamp(category: finding.category)
        }

        var endSample: Int64?
        if let e = finding.endSample {
            endSample = e
        } else if let ms = finding.endUnixMS {
            endSample = sampleIndex(forUnixMS: ms, startUnixMS: recordingStartUnixMS, sampleRate: sampleRate)
        }

        return Annotation(
            id: finding.id ?? UUID(),
            kind: finding.kind,
            sampleIndex: startSample,
            endSampleIndex: endSample,
            unixMillisStart: finding.startUnixMS,
            unixMillisEnd: finding.endUnixMS,
            category: finding.category,
            label: finding.label,
            confidence: finding.confidence,
            source: finding.source ?? defaultSource,
            note: finding.note,
            lead: finding.lead,
            evidenceContextSeconds: finding.evidenceContextSeconds
        )
    }

    private static func sampleIndex(forUnixMS unixMS: Int64, startUnixMS: Int64, sampleRate: Double) -> Int64 {
        Int64(Double(unixMS - startUnixMS) * sampleRate / 1000.0)
    }
}

// MARK: - WFDB .atr adapter

extension Annotation {
    /// Converts a beat-style WFDB annotation into the rich finding model.
    /// All `.atr` events become `point` annotations sourced from `wfdb.atr`.
    init(fromWFDB wfdb: WFDBAnnotation) {
        // The AUX payload on a `+` rhythm marker carries the annotator's
        // rhythm label (e.g. "(AFIB"). Preserve it VERBATIM as the note,
        // stripping only MIT-BIH's syntactic leading `(` — never translated
        // into clinical prose (RUO: transcription, not interpretation). The
        // provenance stays wfdb.atr.
        let note: String? = wfdb.aux.map { raw in
            raw.hasPrefix("(") ? String(raw.dropFirst()) : raw
        }
        self.init(
            id: UUID(),
            kind: .point,
            sampleIndex: wfdb.sampleIndex,
            category: wfdb.label,
            label: wfdb.label,
            source: "wfdb.atr",
            note: note
        )
    }
}
