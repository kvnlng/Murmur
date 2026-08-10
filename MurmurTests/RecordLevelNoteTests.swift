//
//  RecordLevelNoteTests.swift
//  MurmurTests
//
//  X84 — the location-less note kind: decode compatibility for sessions
//  saved before the field existed, and the surfaces that must NOT invent an
//  anchor for a note that refuses to have one.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("Record-level notes (X84)")
struct RecordLevelNoteTests {

    @Test("Notes saved before the kind split decode as location-marked")
    func preX84NoteDecodesAsAnchored() throws {
        // Field-for-field what a pre-X84 session.json carried — no
        // isRecordLevel key at all.
        let json = """
        {"id":"6F1E9C4A-2B3D-4E5F-8A9B-0C1D2E3F4A5B",
         "startSample":1250,"endSample":3750,
         "leadName":"II","text":"short run here",
         "createdAt":700000000,"modifiedAt":700000000}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let note = try decoder.decode(AnchoredNote.self, from: json)
        #expect(note.isRecordLevel == nil)
        #expect(!note.isLocationless)
        #expect(note.startSample == 1250)
    }

    @Test("The record-level kind round-trips through Codable")
    func recordLevelRoundTrips() throws {
        let note = AnchoredNote(
            startSample: 0, endSample: 0,
            text: "whole-record impression",
            createdAt: Date(timeIntervalSince1970: 700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 700_000_000),
            isRecordLevel: true
        )
        let data = try JSONEncoder().encode(note)
        let back = try JSONDecoder().decode(AnchoredNote.self, from: data)
        #expect(back.isLocationless)
        #expect(back == note)
    }

    @Test("The report states the record-level scope instead of a fabricated 0:00 anchor")
    func reportRendersRecordNoteWithoutTimes() {
        let now = Date(timeIntervalSince1970: 700_000_000)
        let channel = Channel(
            id: UUID(),
            name: "II",
            unit: "mV",
            sampleRate: 250,
            startTimeUnixMS: 0,
            sampleCount: 2500,
            storageFileName: "ii.bin",
            pyramid: []
        )
        let recording = Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "test-device",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "synth.hea",
            channels: [channel],
            annotations: []
        )
        let anchored = AnchoredNote(
            startSample: 250, endSample: 500, leadName: "II",
            text: "anchored text", createdAt: now, modifiedAt: now,
            includeInReport: true
        )
        let recordLevel = AnchoredNote(
            startSample: 0, endSample: 0,
            text: "record-level text", createdAt: now, modifiedAt: now,
            includeInReport: true, isRecordLevel: true
        )
        let report = MarkdownReport.generate(
            recording: recording,
            annotations: [],
            dispositions: [:],
            tally: .init(confirmed: 0, dismissed: 0, unreviewed: 0),
            notes: [anchored, recordLevel],
            now: now
        )
        #expect(report.contains("- **Record note**"))
        #expect(report.contains("record-level text"))
        // The anchored note still renders its range, so the branch did not
        // flatten both kinds into the label-only form.
        #expect(report.contains("lead II"))
    }
}
