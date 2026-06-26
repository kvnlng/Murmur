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

struct Annotation: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: Kind
    let sampleIndex: Int64           // resolved start sample (always set after import)
    let endSampleIndex: Int64?       // resolved end sample for ranges; nil for points
    let unixMillisStart: Int64?      // original producer-side absolute time, if any
    let unixMillisEnd: Int64?
    let category: String             // semantic finding category, e.g. "VF_onset", "PVC"
    let label: String?               // short display token; falls back to category
    let confidence: Double?          // 0…1 from the producer model, optional
    let severity: Severity
    let source: String               // producer ID, e.g. "vf-onset-detector-v2"
    let note: String?                // free-form analyst-readable text
    let lead: String?                // channel/lead label if finding is lead-specific
    let evidenceContextSeconds: Double?  // viewer-side scroll-into-view hint

    enum Kind: String, Codable, Sendable {
        case point
        case range
    }

    enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case info
        case notice
        case warning
        case critical

        var rank: Int {
            switch self {
            case .info:     return 0
            case .notice:   return 1
            case .warning:  return 2
            case .critical: return 3
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    var displayLabel: String { label ?? category }

    /// The end sample for rendering purposes — equals `sampleIndex` for point events.
    var renderEndSample: Int64 { endSampleIndex ?? sampleIndex }

    init(
        id: UUID = UUID(),
        kind: Kind,
        sampleIndex: Int64,
        endSampleIndex: Int64? = nil,
        unixMillisStart: Int64? = nil,
        unixMillisEnd: Int64? = nil,
        category: String,
        label: String? = nil,
        confidence: Double? = nil,
        severity: Severity = .info,
        source: String,
        note: String? = nil,
        lead: String? = nil,
        evidenceContextSeconds: Double? = nil
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
        self.severity = severity
        self.source = source
        self.note = note
        self.lead = lead
        self.evidenceContextSeconds = evidenceContextSeconds
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
        let severity: Annotation.Severity?
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
            severity: finding.severity ?? .info,
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
        self.init(
            id: UUID(),
            kind: .point,
            sampleIndex: wfdb.sampleIndex,
            category: wfdb.label,
            label: wfdb.label,
            severity: .info,
            source: "wfdb.atr"
        )
    }
}
