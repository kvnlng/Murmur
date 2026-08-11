//
//  GainInterpretationTests.swift
//  MurmurTests
//
//  X16 (#19) — the analyst's per-channel gain reinterpretation: manifest
//  persistence (true mV = stored × factor, sample data untouched), the
//  guarded factor accessor, the stored-space grid conversion, and the
//  calibration readout's provenance suffix.
//

import Foundation
@testable import MurmurCore
import Testing

@Suite("Gain factor model (X16)")
struct GainFactorModelTests {

    private func channel(factor: Double?) -> Channel {
        Channel(name: "II", unit: "mV", sampleRate: 250, startTimeUnixMS: 0,
                sampleCount: 1000, storageFileName: "channel_ii.bin",
                analystGainFactor: factor, headerGainCountsPerUnit: 200)
    }

    @Test("appliedGainFactor: nil and invalid values read as no correction")
    func appliedFactorGuards() {
        #expect(channel(factor: nil).appliedGainFactor == 1)
        #expect(channel(factor: 2).appliedGainFactor == 2)
        #expect(channel(factor: 0).appliedGainFactor == 1)
        #expect(channel(factor: -3).appliedGainFactor == 1)
        #expect(channel(factor: .infinity).appliedGainFactor == 1)
        #expect(channel(factor: .nan).appliedGainFactor == 1)
    }

    @Test("A pre-X16 manifest decodes with no factor and no header gain")
    func decodesAbsentFields() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"II","unit":"mV","sampleRate":250,
         "startTimeUnixMS":0,"sampleCount":1000,
         "storageFileName":"channel_ii.bin","pyramid":[]}
        """
        let decoded = try JSONDecoder().decode(Channel.self, from: Data(json.utf8))
        #expect(decoded.analystGainFactor == nil)
        #expect(decoded.headerGainCountsPerUnit == nil)
        #expect(decoded.appliedGainFactor == 1)
    }

    @Test("replacingChannel swaps by id and keeps the recording's other facts")
    func replacingChannel() {
        let original = channel(factor: nil)
        let other = Channel(name: "V5", unit: "mV", sampleRate: 250,
                            startTimeUnixMS: 0, sampleCount: 1000,
                            storageFileName: "channel_v5.bin")
        let recording = Recording(
            version: 1, id: UUID(), device: "test", createdAt: .distantPast,
            sourceFileName: "rec.hea", channels: [original, other],
            hasAbsoluteStartTime: true)
        var corrected = original
        corrected.analystGainFactor = 2
        let mutated = recording.replacingChannel(corrected)
        #expect(mutated.channels[0].analystGainFactor == 2)
        #expect(mutated.channels[1].analystGainFactor == nil)
        #expect(mutated.hasAbsoluteStartTime,
                "The copy must not drop the X32 flag — that is the manifest-fidelity bug class")
    }
}

@Suite("Gain factor persistence (X16)")
struct GainPersistenceTests {

    private func makeBundle() throws -> (URL, Recording) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x16-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recording = Recording(
            version: 1, id: UUID(), device: "test", createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "rec.hea",
            channels: [Channel(name: "II", unit: "mV", sampleRate: 250,
                               startTimeUnixMS: 0, sampleCount: 100,
                               storageFileName: "channel_ii.bin",
                               headerGainCountsPerUnit: 200)],
            hasAbsoluteStartTime: true)
        return (dir, recording)
    }

    @Test("The factor round-trips through writeManifest → loadManifest")
    @MainActor
    func factorRoundTrips() throws {
        let (dir, recording) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        var corrected = recording.channels[0]
        corrected.analystGainFactor = 2.5
        try RecordingStore.shared.writeManifest(
            recording.replacingChannel(corrected), at: dir)
        let loaded = try RecordingStore.shared.loadManifest(at: dir)
        #expect(loaded.channels[0].analystGainFactor == 2.5)
        #expect(loaded.channels[0].headerGainCountsPerUnit == 200)
    }

    @Test("The sidecar-rebuild load path keeps the factor AND the X32 flag")
    @MainActor
    func sidecarLoadKeepsChannelFacts() throws {
        let (dir, recording) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: dir) }
        var corrected = recording.channels[0]
        corrected.analystGainFactor = 3
        try RecordingStore.shared.writeManifest(
            recording.replacingChannel(corrected), at: dir)
        // A sidecar forces loadManifest's Recording rebuild — the path that
        // used to drop hasAbsoluteStartTime.
        try BundleAnnotationsFile.write(
            [Annotation(kind: .point, sampleIndex: 10, category: "N",
                        label: "N", source: "wfdb.atr.test")],
            to: dir)
        let loaded = try RecordingStore.shared.loadManifest(at: dir)
        #expect(loaded.channels[0].analystGainFactor == 3)
        #expect(loaded.hasAbsoluteStartTime,
                "The sidecar rebuild silently dropped the X32 flag before X16's fix")
    }
}

@Suite("Stored-space grid conversion (X16)")
struct GridLadderGainTests {

    private func ladder() -> GridLadder {
        GridLadder.compute(windowSeconds: 5, windowMillivolts: 2,
                           plotWidthPoints: 800, plotHeightPoints: 400)
    }

    @Test("Amplitude spacings divide by the factor; time families are untouched")
    func amplitudeScaled() {
        let scaled = ladder().amplitudeSpacingScaled(dividedBy: 2)
        for (original, converted) in zip(ladder().tiers, scaled.tiers) {
            if original.family == .redAmplitude {
                #expect(converted.spacing == original.spacing / 2)
            } else {
                #expect(converted.spacing == original.spacing)
            }
            #expect(converted.onScreenPoints == original.onScreenPoints,
                    "On-screen geometry is a fact of the TRUE window — the ramp must not re-run")
            #expect(converted.alpha == original.alpha)
        }
    }

    @Test("Factor 1 and invalid factors are identity")
    func identity() {
        #expect(ladder().amplitudeSpacingScaled(dividedBy: 1) == ladder())
        #expect(ladder().amplitudeSpacingScaled(dividedBy: 0) == ladder())
        #expect(ladder().amplitudeSpacingScaled(dividedBy: -2) == ladder())
    }
}

@Suite("Calibration readout gain annotation (X16)")
struct CalibrationGainAnnotationTests {

    @Test("The correction travels with the mm/mV claim")
    func annotated() {
        let reading = CalibrationReading.make(
            windowSeconds: 10, canvasWidthPoints: 720, canvasHeightPoints: 288,
            visibleMillivoltSpan: 10,
            millimetersPerPoint: 25.0 / 72.0,
            gainAnnotation: "gain ×2 — analyst")
        #expect(reading.text == "25 mm/s · 10 mm/mV · gain ×2 — analyst")
        #expect(reading.isStandard, "The paper is still standard — it maps TRUE mV")
    }

    @Test("The points fallback carries the annotation too")
    func annotatedFallback() {
        let reading = CalibrationReading.make(
            windowSeconds: 10, canvasWidthPoints: 720, canvasHeightPoints: 288,
            visibleMillivoltSpan: 10,
            millimetersPerPoint: nil,
            gainAnnotation: "gain ×2 — analyst")
        #expect(reading.text.hasSuffix("display size unavailable · gain ×2 — analyst"))
    }

    @Test("No annotation, no suffix — the pre-X16 strings stand verbatim")
    func unannotated() {
        let reading = CalibrationReading.make(
            windowSeconds: 10, canvasWidthPoints: 720, canvasHeightPoints: 288,
            visibleMillivoltSpan: 10,
            millimetersPerPoint: 25.0 / 72.0)
        #expect(reading.text == "25 mm/s · 10 mm/mV")
    }
}
