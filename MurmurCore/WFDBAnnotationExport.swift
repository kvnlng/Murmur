//
//  WFDBAnnotationExport.swift
//  MurmurCore
//
//  Exports an analyst's adjudicated findings to a plain WFDB annotation file
//  so they can be handed to a peer. Free (no entitlement gate): this is I/O
//  and data selection, not measurement — the tier rule is "pay to author,
//  never pay to keep."
//
//  Rule — EXPORT WHAT IS AMBER. Analyst-authored and confirmed findings leave;
//  everything else stays in the proprietary sidecars. The colour discipline
//  already draws this line on screen (amber = analyst-marked; neutral =
//  model/computed), so the filter needs no new judgement. Specifically it does
//  NOT export: unconfirmed candidates, dismissed candidates, per-window model
//  scores, tau / min-duration / merge-gap, computed measurements (QTc medians,
//  bands, CIs), or the immutable app-composed citation caption.
//
//  Span → point-event flattening (the resolved open design question):
//  a finding is a SPAN throughout Murmur, but WFDB's native way to write a
//  machine-readable span is a rhythm-state onset/offset pair — and writing an
//  offset asserts that some OTHER rhythm resumes at that sample, which the
//  analyst never claimed (confirming "VT here" is not confirming "sinus
//  resumes at sample N"). That assertion is the RUO violation, so it is
//  refused. Instead each finding is written as a single NOTE (comment)
//  annotation at its onset, carrying the analyst's own label text; a comment
//  asserts nothing about what precedes or follows it. The span's extent
//  therefore travels in the analyst's prose (the drag-to-author label already
//  spells out the time range), not as WFDB rhythm boundaries. The reduction is
//  lossy and is surfaced at the moment of export.
//

import Foundation

enum WFDBAnnotationExport {

    /// One analyst finding selected for export, normalised across the two
    /// disposition stores. `text` is the analyst's voice — never app-composed
    /// clinical language, never the citation caption.
    struct Finding: Equatable, Sendable {
        let startSample: Int64
        /// End sample for a span; `nil` for a point finding. Carried for the
        /// export summary and potential future idioms — the WFDB projection
        /// currently records only the onset (extent lives in `text`).
        let endSample: Int64?
        let text: String
    }

    /// Outcome of an export, surfaced to the UI (and its accessibility hooks).
    struct Result: Equatable, Sendable {
        let url: URL
        let annotator: String
        let findingCount: Int
    }

    // MARK: - Amber filter

    /// Collects the amber (exportable) set from the two persisted disposition
    /// stores. Confirming a candidate region AUTHORS the analyst's finding, so
    /// confirmed regions are amber; so are annotations the analyst confirmed
    /// through the id-keyed store. Dismissed and unreviewed items are excluded.
    ///
    /// `authoredExtra` is a seam for drag-to-author findings once that gesture
    /// persists its own `Annotation`s — callers can inject them; the filter
    /// itself never fabricates findings.
    static func amberFindings(
        annotations: [Annotation],
        annotationDispositions: [UUID: AnnotationDisposition],
        confirmedRegions: [RegionDisposition],
        authoredExtra: [Finding] = []
    ) -> [Finding] {
        var findings: [Finding] = []

        // Confirmed VT/VF candidate regions (analyst-authored by confirming).
        for region in confirmedRegions where region.state == .confirmed {
            findings.append(Finding(
                startSample: region.startSample,
                endSample: region.endSample,
                text: region.note ?? region.confirmedKind.exportLabel
            ))
        }

        // Annotations that are amber: either the analyst confirmed them through
        // the id-keyed store, OR the analyst authored them directly (drag-to-
        // author range findings carry `analystAuthoredSource` and need no
        // disposition). A confirmed disposition's note wins as the text.
        for annotation in annotations {
            let disposition = annotationDispositions[annotation.id]
            let confirmedText = disposition?.state == .confirmed
                ? exportLabel(for: annotation, disposition: disposition)
                : nil
            let authored = annotation.source == Annotation.analystAuthoredSource
            guard let text = confirmedText ?? (authored ? annotation.displayLabel : nil) else { continue }
            findings.append(Finding(
                startSample: annotation.sampleIndex,
                endSample: annotation.endSampleIndex,
                text: text
            ))
        }

        findings.append(contentsOf: authoredExtra)
        return findings.sorted { $0.startSample < $1.startSample }
    }

    /// The text a confirmed annotation carries into the annotator file.
    ///
    /// Precedence, most-specific first (#331):
    ///   1. the analyst's own `note` — they typed a sentence about THIS finding
    ///   2. `confirmedCategory` — they said what the finding IS, possibly
    ///      disagreeing with the producer's label; that disagreement is the
    ///      single most important thing to carry downstream
    ///   3. `confirmedKind` — the VT/VF narrowing, when it says something
    ///      ("unclassified" does not)
    ///   4. the annotation's own `displayLabel` — nobody added anything, so
    ///      the producer's word stands
    ///
    /// Note beats category deliberately: prose is strictly more specific than
    /// a one-word class, and an analyst who typed a note meant it to be read.
    static func exportLabel(
        for annotation: Annotation,
        disposition: AnnotationDisposition?
    ) -> String {
        if let note = disposition?.note { return note }
        if let category = disposition?.confirmedCategory { return category }
        // `exportLabel` hangs off the Optional (below), which is also what
        // keeps "kind absent" and "kind unclassified" landing on the same
        // neutral wording. Both are excluded here so precedence falls through
        // to the producer's own label instead.
        let kind = disposition?.confirmedKind
        if kind != nil, kind != .unclassified { return kind.exportLabel }
        return annotation.displayLabel
    }

    // MARK: - Finding → annotation mapping

    /// Flattens amber findings to WFDB NOTE events — one comment at each
    /// finding's onset, aux = the analyst's text. See the file header for why
    /// the span is not written as a rhythm onset/offset pair.
    static func events(from findings: [Finding]) -> [WFDBAnnotationWriter.Event] {
        findings.map {
            WFDBAnnotationWriter.Event(sampleIndex: $0.startSample, aux: $0.text)
        }
    }

    // MARK: - Pipeline

    /// Filters to amber, maps to NOTE events, and writes the annotator file.
    /// Throws `WFDBAnnotationWriter.WriteError` on a reserved annotator or an
    /// unconfirmed clobber.
    @discardableResult
    static func export(
        annotations: [Annotation],
        annotationDispositions: [UUID: AnnotationDisposition],
        confirmedRegions: [RegionDisposition],
        authoredExtra: [Finding] = [],
        recordName: String,
        annotator: String = WFDBAnnotationWriter.defaultAnnotator,
        in directory: URL,
        overwrite: Bool = false
    ) throws -> Result {
        let findings = amberFindings(
            annotations: annotations,
            annotationDispositions: annotationDispositions,
            confirmedRegions: confirmedRegions,
            authoredExtra: authoredExtra
        )
        let url = try WFDBAnnotationWriter.write(
            events(from: findings),
            recordName: recordName,
            annotator: annotator,
            in: directory,
            overwrite: overwrite
        )
        return Result(url: url, annotator: annotator.lowercased(), findingCount: findings.count)
    }

    /// Filters to amber, maps to NOTE events, and writes to an explicit
    /// destination `fileURL` (chosen by the user through a save panel).
    @discardableResult
    static func export(
        annotations: [Annotation],
        annotationDispositions: [UUID: AnnotationDisposition],
        confirmedRegions: [RegionDisposition],
        authoredExtra: [Finding] = [],
        to fileURL: URL
    ) throws -> Result {
        let findings = amberFindings(
            annotations: annotations,
            annotationDispositions: annotationDispositions,
            confirmedRegions: confirmedRegions,
            authoredExtra: authoredExtra
        )
        let url = try WFDBAnnotationWriter.write(events(from: findings), to: fileURL)
        return Result(url: url, annotator: url.pathExtension.lowercased(), findingCount: findings.count)
    }
}

private extension Optional where Wrapped == AnnotationDisposition.ConfirmedKind {
    /// Analyst-voice descriptor for an exported confirmed region. The kind is
    /// the analyst's own classification chosen at confirmation, so "VT"/"VF"
    /// carry their word; an unspecified kind falls back to a neutral factual
    /// descriptor rather than any app-asserted diagnosis.
    var exportLabel: String {
        switch self {
        case .vt:            return "VT"
        case .vf:            return "VF"
        case .unclassified:  return "confirmed finding"
        case .none:          return "confirmed finding"
        }
    }
}
