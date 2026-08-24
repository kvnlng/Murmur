//
//  ConfirmedCategoryTests.swift
//  MurmurTests
//
//  #331 — `AnnotationDisposition.confirmedCategory`, the field that lets an
//  analyst say what a finding IS rather than only that they looked at it.
//
//  Before this, "confirmed" carried one optional narrowing: a closed VT/VF
//  enum built for the arrhythmia scan. On a record whose producer emits AFib,
//  PVC, or a SNOMED code, an analyst who DISAGREED with a label had nowhere to
//  put the disagreement — and disagreeing with a label is the whole point of
//  review. These tests pin the three things that follow from adding it: the
//  field normalises like every other free-text field, agreement and
//  disagreement stay distinguishable downstream, and the sidecar still loads
//  when written by a build that never heard of the field.
//

@testable import MurmurCore
import Foundation
import Testing

@Suite("Confirmed category (#331) — the model")
struct ConfirmedCategoryModelTests {
    private func annotation(category: String = "AFib") -> Annotation {
        Annotation(
            id: UUID(), kind: .point, sampleIndex: 0,
            category: category, source: "physionet-dx"
        )
    }

    private func disposition(
        id: UUID = UUID(),
        state: AnnotationDisposition.State = .confirmed,
        kind: AnnotationDisposition.ConfirmedKind? = nil,
        category: String? = nil,
        note: String? = nil
    ) -> AnnotationDisposition {
        AnnotationDisposition(
            annotationID: id, state: state, confirmedKind: kind,
            confirmedCategory: category, note: note,
            reviewedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    @Test("A whitespace-only category normalises to absent")
    func blankCategoryBecomesNil() {
        #expect(disposition(category: "   \n ").confirmedCategory == nil)
        #expect(disposition(category: "").confirmedCategory == nil)
    }

    @Test("A category keeps its own text, trimmed at the edges")
    func categoryIsTrimmedNotAltered() {
        #expect(disposition(category: "  AFib  ").confirmedCategory == "AFib")
        // Free-form means free-form: a SNOMED code is as valid as a word, and
        // internal punctuation is the producer's business, not Murmur's.
        #expect(disposition(category: "164889003").confirmedCategory == "164889003")
        #expect(disposition(category: "PVC, multifocal").confirmedCategory == "PVC, multifocal")
    }

    @Test("Confirming as the annotation's own category is agreement, not an override")
    func agreementIsNotAnOverride() {
        let ann = annotation(category: "AFib")
        #expect(disposition(category: "AFib").overridesCategory(of: ann) == false)
    }

    @Test("Confirming as a different category is an override")
    func disagreementIsAnOverride() {
        let ann = annotation(category: "AFib")
        #expect(disposition(category: "AFlutter").overridesCategory(of: ann))
    }

    @Test("No category at all is not an override")
    func absentCategoryIsNotAnOverride() {
        #expect(disposition(category: nil).overridesCategory(of: annotation()) == false)
    }

    @Test("A sidecar written before #331 still decodes, with no category")
    func decodesPre331Sidecar() throws {
        // Verbatim shape of a v1 record from a build that had no such key.
        let json = """
        {"schemaVersion":1,"dispositions":[{
          "annotationID":"00000000-0000-0000-0000-000000000001",
          "state":"confirmed","confirmedKind":"vt",
          "reviewedAt":"2025-06-15T15:06:40Z","reviewedBy":"kevin"
        }]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(DispositionFile.self, from: Data(json.utf8))

        #expect(file.schemaVersion == DispositionFile.currentSchemaVersion)
        #expect(file.dispositions.count == 1)
        #expect(file.dispositions[0].confirmedCategory == nil)
        #expect(file.dispositions[0].confirmedKind == .vt)
    }

    @Test("A category survives an encode/decode round trip")
    func roundTripsThroughJSON() throws {
        let original = disposition(category: "AFlutter", note: "sawtooth in II")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(
            AnnotationDisposition.self, from: encoder.encode(original)
        )
        #expect(restored == original)
        #expect(restored.confirmedCategory == "AFlutter")
    }

    @Test("The store writes the category the analyst named")
    func storePersistsCategory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        DispositionStore(bundleDirectory: dir, defaultReviewerName: "kevin")
            .confirm(id, kind: nil, category: "AFlutter")

        // Reload from disk rather than reading the in-memory dictionary — the
        // point of the field is that it survives to whoever reads the sidecar.
        let reloaded = DispositionStore(bundleDirectory: dir, defaultReviewerName: "kevin")
        #expect(reloaded.record(for: id)?.confirmedCategory == "AFlutter")
        #expect(reloaded.record(for: id)?.state == .confirmed)
    }
}

@Suite("Confirmed category (#331) — what it carries downstream")
struct ConfirmedCategoryExportTests {
    private func annotation(
        id: UUID = UUID(), category: String = "AFib", label: String? = nil
    ) -> Annotation {
        Annotation(
            id: id, kind: .point, sampleIndex: 0, category: category,
            label: label, source: "physionet-dx"
        )
    }

    private func disposition(
        id: UUID,
        kind: AnnotationDisposition.ConfirmedKind? = nil,
        category: String? = nil,
        note: String? = nil
    ) -> AnnotationDisposition {
        AnnotationDisposition(
            annotationID: id, state: .confirmed, confirmedKind: kind,
            confirmedCategory: category, note: note,
            reviewedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    // MARK: - WFDB annotator text

    @Test("A note outranks everything — the analyst wrote a sentence about this one")
    func noteWinsExportLabel() {
        let ann = annotation(category: "AFib")
        let text = WFDBAnnotationExport.exportLabel(
            for: ann,
            disposition: disposition(id: ann.id, kind: .vt, category: "AFlutter", note: "sawtooth")
        )
        #expect(text == "sawtooth")
    }

    @Test("With no note, the analyst's category outranks the VT/VF kind")
    func categoryOutranksKind() {
        let ann = annotation(category: "AFib")
        let text = WFDBAnnotationExport.exportLabel(
            for: ann, disposition: disposition(id: ann.id, kind: .vt, category: "AFlutter")
        )
        #expect(text == "AFlutter")
    }

    @Test("With neither, a meaningful kind still carries its word")
    func kindCarriesWhenItSaysSomething() {
        let ann = annotation(category: "AFib")
        #expect(
            WFDBAnnotationExport.exportLabel(for: ann, disposition: disposition(id: ann.id, kind: .vf))
            == "VF"
        )
    }

    @Test("An unclassified kind says nothing, so the producer's own label stands")
    func unclassifiedFallsThroughToTheLabel() {
        let ann = annotation(category: "AFib", label: "AFib (lead II)")
        #expect(
            WFDBAnnotationExport.exportLabel(
                for: ann, disposition: disposition(id: ann.id, kind: .unclassified)
            ) == "AFib (lead II)"
        )
    }

    @Test("A bare confirm exports the label the finding arrived with")
    func bareConfirmUsesDisplayLabel() {
        let ann = annotation(category: "AFib")
        #expect(WFDBAnnotationExport.exportLabel(for: ann, disposition: disposition(id: ann.id)) == "AFib")
    }

    @Test("The override reaches the annotator file, not just the sidecar")
    func overrideReachesAmberFindings() {
        let ann = annotation(category: "AFib")
        let findings = WFDBAnnotationExport.amberFindings(
            annotations: [ann],
            annotationDispositions: [ann.id: disposition(id: ann.id, category: "AFlutter")],
            confirmedRegions: []
        )
        #expect(findings.count == 1)
        #expect(findings.first?.text == "AFlutter")
    }

    // MARK: - Markdown report

    @Test("The report distinguishes agreeing with a label from overriding it")
    func reportWordsOverrideAndAgreementDifferently() {
        let ann = annotation(category: "AFib")
        let agreed = MarkdownReport.formatDisposition(
            disposition(id: ann.id, category: "AFib"), annotation: ann
        )
        let overrode = MarkdownReport.formatDisposition(
            disposition(id: ann.id, category: "AFlutter"), annotation: ann
        )
        #expect(agreed == "confirmed")
        #expect(overrode == "confirmed (as AFlutter)")
    }

    @Test("Without the annotation to compare against, the report never claims an override")
    func reportNeedsTheAnnotationToClaimAnOverride() {
        let id = UUID()
        #expect(
            MarkdownReport.formatDisposition(disposition(id: id, category: "AFlutter"))
            == "confirmed"
        )
        #expect(
            MarkdownReport.formatDisposition(disposition(id: id, kind: .vt)) == "confirmed (VT)"
        )
    }

    // MARK: - Review table

    @Test("The review table carries the category in its own column")
    func reviewTableEmitsConfirmedCategory() {
        let ann = annotation(category: "AFib")
        let recording = Recording(
            version: 2, id: UUID(), device: "A",
            createdAt: Date(timeIntervalSince1970: 0), sourceFileName: "A.hea",
            channels: [Channel(
                id: UUID(), name: "II", unit: "mV", sampleRate: 500,
                startTimeUnixMS: 0, sampleCount: 5000,
                storageFileName: "ch.bin", pyramid: []
            )],
            annotations: [ann],
            headerComments: []
        )
        let result = ReviewTableBuilder.build(
            sources: [.init(
                recordPath: "a.hea",
                imported: .init(
                    recording: recording,
                    dispositions: [ann.id: disposition(id: ann.id, category: "AFlutter")],
                    headerComments: [],
                    bundleDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                )
            )],
            flaggedIDs: []
        )

        let lines = result.csv.split(separator: "\n")
        let header = lines[0].split(separator: ",").map(String.init)
        let fields = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields.count == header.count)
        #expect(header.firstIndex(of: "confirmed_category").map { fields[$0] } == "AFlutter")
        // The producer's own word is still in the row — the export records the
        // disagreement, it does not overwrite the claim that was disagreed with.
        #expect(header.firstIndex(of: "category").map { fields[$0] } == "AFib")
    }
}
