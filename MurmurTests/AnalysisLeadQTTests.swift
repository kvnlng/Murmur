//
//  AnalysisLeadQTTests.swift
//  MurmurTests
//
//  #357 §1.5 — QT measures on the ANALYSIS LEAD, and a lead's NAME
//  survives in one direction only: disclosure. Replaces
//  ConventionalQTLeadTests (X108's name-gated selection). What that suite
//  pinned about CHOOSING a lead by name dies with the gate — the II-before-V5
//  order, the Mason–Likar prefix normaliser, "a non-conventional lead is
//  never selected". What it pinned about reading a name HONESTLY transfers
//  here, inverted: a name that doesn't read as II/V5 is measured on anyway
//  and disclosed, and the comparison still refuses to over-match (III is not
//  II, V50 is not V5).
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("QT on the analysis lead (#357)")
struct AnalysisLeadQTTests {
    // Task 7: these assert through `citedLeadName` — the one production
    // spelling of the clause. The standalone "measured on …" sentence had no
    // caller (the §1.6 header line states the analysis lead's PROVENANCE,
    // not the QT convention), so it is gone; the rule it encoded is
    // unchanged and pinned here on the surviving entry point.
    @Test("The conventional-name disclosure fires exactly on non-II/V5 names")
    func disclosureNameRule() {
        #expect(QTLeadDisclosure.citedLeadName(for: "II") == "II")
        #expect(QTLeadDisclosure.citedLeadName(for: " ii ") == "ii")
        #expect(QTLeadDisclosure.citedLeadName(for: "V5") == "V5")
        // NO prefix stripping — the ML normaliser is gone. MLII honestly
        // discloses until a #358 declaration quiets the sentence.
        #expect(QTLeadDisclosure.citedLeadName(for: "MLII")
            == "MLII — not a conventional QT lead (II/V5)")
        #expect(QTLeadDisclosure.citedLeadName(for: "V4")
            == "V4 — not a conventional QT lead (II/V5)")
    }

    @Test("Equality, never prefix or substring — III is not II, V50 is not V5")
    func disclosureNeverOverMatches() {
        // The X108 normaliser's over-match guard, transferred: the same
        // near-miss names it refused to SELECT must now be disclosed, since
        // the analysis lead is measured on whatever it is.
        #expect(QTLeadDisclosure.citedLeadName(for: "III")
            == "III — not a conventional QT lead (II/V5)")
        #expect(QTLeadDisclosure.citedLeadName(for: "MLIII")
            == "MLIII — not a conventional QT lead (II/V5)")
        #expect(QTLeadDisclosure.citedLeadName(for: "V50")
            == "V50 — not a conventional QT lead (II/V5)")
        #expect(QTLeadDisclosure.citedLeadName(for: "MCL1")
            == "MCL1 — not a conventional QT lead (II/V5)")
    }

    @Test("The citation's lead slot carries the as-recorded name, plus the clause")
    func citedLeadNameCarriesTheDisclosure() {
        // Built at render time by the QT-bearing surfaces (the QTc repro
        // caption, the inspector's provenance footer) from the stored lead
        // NAME — one clause, so those surfaces can never word it differently.
        #expect(QTLeadDisclosure.citedLeadName(for: "V5") == "V5")
        #expect(QTLeadDisclosure.citedLeadName(for: " ii ") == "ii")
        #expect(QTLeadDisclosure.citedLeadName(for: "MLII")
            == "MLII — not a conventional QT lead (II/V5)")
        #expect(QTLeadDisclosure.citedLeadName(for: "V4")
            == "V4 — not a conventional QT lead (II/V5)")
    }

    @Test("A record with no II/V5 is measured on its analysis lead — and says so")
    @MainActor
    func renamedLeadRecordIsMeasuredAndDisclosed() throws {
        // The X109 fixture (lead II written as telemetry-style MCL1), read
        // against the new contract: where X108 found no conventional lead
        // and X109 withheld QT, #357 resolves an analysis lead, measures on
        // it, and discloses the name. Nothing abstains for want of a name.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-qt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let heaURL = try SyntheticRecording.makeRichRecord(
            into: workDir,
            parameters: .init(durationSeconds: 20),
            leadRenames: ["II": "MCL1"])
        let outputDir = workDir.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let summary = try WFDBImporter.importRecord(heaURL: heaURL, outputDirectory: outputDir)
        let recording = try RecordingStore.shared.loadManifest(at: summary.directory)

        let resolution = try #require(recording.analysisLead(inBundle: summary.directory),
                                      "A populated ECG channel always resolves a lead")
        #expect(recording.channels.contains { $0.name == "MCL1" },
                "The renamed lead itself must survive with its signal")
        #expect(QTLeadDisclosure.citedLeadName(for: resolution.channel.name)
                != resolution.channel.name,
                "No lead on this record reads as II/V5 — the QT read must disclose")
        let samples = recording.samples(of: resolution.channel, inDirectory: summary.directory)
        #expect(samples?.isEmpty == false,
                "The resolved lead is the one the pipeline reads — it must carry signal")
    }

    // MARK: - #358: declared-placement clause interaction

    private var declaredAt: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 24
        components.hour = 0
        components.minute = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    @Test("Declared II suppresses the not-conventional QT clause; the measurement text cites the declaration")
    func declaredConventionalSuppressesClause() {
        let declII = LeadPlacementDeclaration(
            placement: "II", reviewer: "kevin", declaredAt: declaredAt)
        let cited = QTLeadDisclosure.citedLeadName(for: "MLII", declaredPlacement: declII)
        #expect(cited.contains("(declared: II"))
        #expect(!cited.contains("not a conventional QT lead"))
        #expect(cited == "MLII (declared: II, by kevin, 2026-08-24)")
    }

    @Test("A declared non-conventional placement keeps the clause")
    func declaredUnconventionalKeepsClause() {
        let declFrontPatch = LeadPlacementDeclaration(
            placement: "front patch", reviewer: "kevin", declaredAt: declaredAt)
        let cited = QTLeadDisclosure.citedLeadName(for: "MLII", declaredPlacement: declFrontPatch)
        #expect(cited.contains("not a conventional QT lead (II/V5)"))
        #expect(cited.contains("(declared: front patch"))
    }

    @Test("Free text 'V5, back patch' does not read as V5 — clause stays")
    func freeTextDoesNotMatchConventional() {
        let declFreeText = LeadPlacementDeclaration(
            placement: "V5, back patch", reviewer: "kevin", declaredAt: declaredAt)
        let cited = QTLeadDisclosure.citedLeadName(for: "MLII", declaredPlacement: declFreeText)
        #expect(cited.contains("not a conventional QT lead (II/V5)"))
        #expect(cited.contains("(declared: V5, back patch"))
    }

    @Test("A record override reads its own override wording in the clause interaction")
    func declaredOverrideSuppressesClause() {
        let declII = LeadPlacementDeclaration(
            placement: "II", reviewer: "kevin", declaredAt: declaredAt)
        let cited = QTLeadDisclosure.citedLeadName(
            for: "MLII", declaredPlacement: declII, isOverride: true)
        #expect(cited == "MLII (declared: II — record override, by kevin, 2026-08-24)")
    }

    @Test("No declaration: clause byte-identical to #357 behaviour")
    func nilDeclarationUnchanged() {
        #expect(QTLeadDisclosure.citedLeadName(for: "MLII")
            == "MLII — not a conventional QT lead (II/V5)")
        #expect(QTLeadDisclosure.citedLeadName(for: "MLII", declaredPlacement: nil)
            == "MLII — not a conventional QT lead (II/V5)")
        #expect(QTLeadDisclosure.citedLeadName(for: "II") == "II")
        #expect(QTLeadDisclosure.citedLeadName(for: "II", declaredPlacement: nil) == "II")
    }
}
