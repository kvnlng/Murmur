//
//  MurmurCoreTests.swift
//  MurmurCoreTests
//
//  Out-of-module tests against the MurmurCore public surface. This
//  target deliberately uses `import MurmurCore` (NOT `@testable`),
//  so anything it touches has to be `public` — which makes this
//  file the load-bearing contract test for the Phase B2 public-API
//  audit. If a paid extension framework (`MurmurAnnotation`,
//  `MurmurSilver`, `MurmurInference`) can't reach a symbol from
//  here, it can't reach it from its own bundle either.
//
//  The xcodeproj target `MurmurTests` retains `@testable import`
//  and exhaustively covers MurmurCore's internals. This file is
//  the contract test — does the *external* surface let you
//  construct an Annotation, conform to FindingProducer, register
//  against the ProducerRegistry, and gate behind PurchaseStore?
//

import Foundation
import Testing
import MurmurCore

// MARK: - Annotation

@Suite("Annotation — construction and behavior")
struct AnnotationTests {

    @Test("Constructs with minimal required params; sensible defaults")
    func minimalConstruction() {
        let a = Annotation(
            kind: .point,
            sampleIndex: 100,
            category: "PVC",
            source: "test"
        )
        #expect(a.kind == .point)
        #expect(a.sampleIndex == 100)
        #expect(a.endSampleIndex == nil)
        #expect(a.unixMillisStart == nil)
        #expect(a.unixMillisEnd == nil)
        #expect(a.category == "PVC")
        #expect(a.label == nil)
        #expect(a.confidence == nil)
        #expect(a.severity == .info)
        #expect(a.source == "test")
        #expect(a.note == nil)
        #expect(a.lead == nil)
        #expect(a.evidenceContextSeconds == nil)
    }

    @Test("Constructs with all params populated")
    func fullConstruction() {
        let id = UUID()
        let a = Annotation(
            id: id,
            kind: .range,
            sampleIndex: 500,
            endSampleIndex: 1500,
            unixMillisStart: 1_000_000,
            unixMillisEnd: 2_000_000,
            category: "AFib",
            label: "Atrial fib",
            confidence: 0.87,
            severity: .warning,
            source: "murmur.silver",
            note: "ectopic burst",
            lead: "II",
            evidenceContextSeconds: 30
        )
        #expect(a.id == id)
        #expect(a.kind == .range)
        #expect(a.endSampleIndex == 1500)
        #expect(a.unixMillisStart == 1_000_000)
        #expect(a.unixMillisEnd == 2_000_000)
        #expect(a.label == "Atrial fib")
        #expect(a.confidence == 0.87)
        #expect(a.severity == .warning)
        #expect(a.note == "ectopic burst")
        #expect(a.lead == "II")
        #expect(a.evidenceContextSeconds == 30)
    }

    @Test("Codable roundtrip preserves every field")
    func codableRoundtrip() throws {
        let original = Annotation(
            kind: .range,
            sampleIndex: 12_345,
            endSampleIndex: 23_456,
            unixMillisStart: 100,
            unixMillisEnd: 200,
            category: "VT",
            label: "VT run",
            confidence: 0.91,
            severity: .critical,
            source: "murmur.vtdetect",
            note: "n",
            lead: "MLII",
            evidenceContextSeconds: 10
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(decoded == original)
    }

    @Test("displayLabel falls back to category when label is nil")
    func displayLabelFallback() {
        let a = Annotation(kind: .point, sampleIndex: 0, category: "PVC", source: "t")
        #expect(a.displayLabel == "PVC")
    }

    @Test("displayLabel returns label when present")
    func displayLabelPresent() {
        let a = Annotation(kind: .point, sampleIndex: 0, category: "PVC", label: "Premature", source: "t")
        #expect(a.displayLabel == "Premature")
    }

    @Test("renderEndSample equals sampleIndex for point findings")
    func renderEndSamplePoint() {
        let a = Annotation(kind: .point, sampleIndex: 250, category: "x", source: "t")
        #expect(a.renderEndSample == 250)
    }

    @Test("renderEndSample uses endSampleIndex for range findings")
    func renderEndSampleRange() {
        let a = Annotation(
            kind: .range,
            sampleIndex: 100,
            endSampleIndex: 500,
            category: "x",
            source: "t"
        )
        #expect(a.renderEndSample == 500)
    }

    @Test("matchesChannel: lead-less annotation matches any channel")
    func matchesChannelLeadless() {
        let a = Annotation(kind: .point, sampleIndex: 0, category: "x", source: "t")
        #expect(a.matchesChannel("II") == true)
        #expect(a.matchesChannel("V1") == true)
    }

    @Test("matchesChannel: empty/whitespace lead is treated as lead-less")
    func matchesChannelEmptyLead() {
        let a = Annotation(kind: .point, sampleIndex: 0, category: "x", source: "t", lead: "   ")
        #expect(a.matchesChannel("II") == true)
    }

    @Test("matchesChannel: exact name match")
    func matchesChannelExact() {
        let a = Annotation(kind: .point, sampleIndex: 0, category: "x", source: "t", lead: "II")
        #expect(a.matchesChannel("II") == true)
    }

    @Test("matchesChannel: case + whitespace insensitive")
    func matchesChannelNormalized() {
        let a = Annotation(kind: .point, sampleIndex: 0, category: "x", source: "t", lead: " ii ")
        #expect(a.matchesChannel("II") == true)
    }

    @Test("matchesChannel: non-matching lead does not match")
    func matchesChannelMismatch() {
        let a = Annotation(kind: .point, sampleIndex: 0, category: "x", source: "t", lead: "II")
        #expect(a.matchesChannel("V1") == false)
    }
}

@Suite("Annotation.Severity — ordering and conformances")
struct SeverityTests {

    @Test("rank is monotonic info < notice < warning < critical")
    func rankMonotonic() {
        #expect(Annotation.Severity.info.rank == 0)
        #expect(Annotation.Severity.notice.rank == 1)
        #expect(Annotation.Severity.warning.rank == 2)
        #expect(Annotation.Severity.critical.rank == 3)
    }

    @Test("Comparable conformance matches rank order")
    func comparable() {
        #expect(Annotation.Severity.info < .notice)
        #expect(Annotation.Severity.notice < .warning)
        #expect(Annotation.Severity.warning < .critical)
        #expect(!(Annotation.Severity.critical < .warning))
    }

    @Test("CaseIterable returns all four cases")
    func allCases() {
        #expect(Annotation.Severity.allCases.count == 4)
        #expect(Set(Annotation.Severity.allCases) == [.info, .notice, .warning, .critical])
    }

    @Test("Codable roundtrip preserves case")
    func codableRoundtrip() throws {
        for severity in Annotation.Severity.allCases {
            let data = try JSONEncoder().encode(severity)
            let decoded = try JSONDecoder().decode(Annotation.Severity.self, from: data)
            #expect(decoded == severity)
        }
    }
}

@Suite("Annotation.Kind — values and conformances")
struct KindTests {

    @Test("Raw values are stable")
    func rawValues() {
        #expect(Annotation.Kind.point.rawValue == "point")
        #expect(Annotation.Kind.range.rawValue == "range")
    }

    @Test("Decodable from rawValue strings")
    func decodes() throws {
        let pointData = "\"point\"".data(using: .utf8)!
        let rangeData = "\"range\"".data(using: .utf8)!
        #expect(try JSONDecoder().decode(Annotation.Kind.self, from: pointData) == .point)
        #expect(try JSONDecoder().decode(Annotation.Kind.self, from: rangeData) == .range)
    }
}

// MARK: - Channel + PyramidLevel

@Suite("Channel — construction and computed properties")
struct ChannelTests {

    private func makeChannel(sampleRate: Double = 250, sampleCount: Int64 = 250_000) -> Channel {
        Channel(
            name: "II",
            unit: "mV",
            sampleRate: sampleRate,
            startTimeUnixMS: 1_000_000,
            sampleCount: sampleCount,
            storageFileName: "II.bin"
        )
    }

    @Test("Constructs with default empty pyramid")
    func basicConstruction() {
        let c = makeChannel()
        #expect(c.name == "II")
        #expect(c.unit == "mV")
        #expect(c.sampleRate == 250)
        #expect(c.sampleCount == 250_000)
        #expect(c.pyramid.isEmpty)
    }

    @Test("Constructs with custom id + pyramid")
    func fullConstruction() {
        let id = UUID()
        let level = PyramidLevel(binSamples: 10, binCount: 25_000, storageFileName: "II.p1.bin")
        let c = Channel(
            id: id,
            name: "V1",
            unit: "mV",
            sampleRate: 360,
            startTimeUnixMS: 0,
            sampleCount: 360_000,
            storageFileName: "V1.bin",
            pyramid: [level]
        )
        #expect(c.id == id)
        #expect(c.pyramid.count == 1)
        #expect(c.pyramid.first?.binSamples == 10)
    }

    @Test("startDate is derived from startTimeUnixMS")
    func startDate() {
        let c = makeChannel()
        #expect(c.startDate.timeIntervalSince1970 == 1000) // 1_000_000 ms = 1000 s
    }

    @Test("durationSeconds = sampleCount / sampleRate")
    func durationSeconds() {
        let c = makeChannel(sampleRate: 250, sampleCount: 250_000)
        #expect(c.durationSeconds == 1000)
    }

    @Test("sampleIndex(for:) maps absolute unix-ms to sample index")
    func sampleIndexFor() {
        let c = makeChannel()
        // Channel starts at unixMS = 1_000_000, sampleRate = 250
        // At unixMS = 1_000_400 (400 ms later), sample index = 400 * 0.250 = 100
        #expect(c.sampleIndex(for: 1_000_400) == 100)
        #expect(c.sampleIndex(for: 1_000_000) == 0)
    }

    @Test("isTrendChannel is true for sub-5-Hz channels")
    func isTrendChannelLowRate() {
        #expect(makeChannel(sampleRate: 1).isTrendChannel == true)
        #expect(makeChannel(sampleRate: 4.999).isTrendChannel == true)
    }

    @Test("isTrendChannel is false for >=5 Hz channels")
    func isTrendChannelHighRate() {
        #expect(makeChannel(sampleRate: 5).isTrendChannel == false)
        #expect(makeChannel(sampleRate: 250).isTrendChannel == false)
    }

    @Test("Codable roundtrip preserves all fields")
    func codableRoundtrip() throws {
        let level = PyramidLevel(binSamples: 100, binCount: 2500, storageFileName: "x.bin")
        let original = Channel(
            name: "II",
            unit: "mV",
            sampleRate: 250,
            startTimeUnixMS: 1_000_000,
            sampleCount: 250_000,
            storageFileName: "II.bin",
            pyramid: [level]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Channel.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("PyramidLevel — construction and Codable")
struct PyramidLevelTests {

    @Test("Constructs with provided fields")
    func construction() {
        let level = PyramidLevel(binSamples: 10, binCount: 1000, storageFileName: "p.bin")
        #expect(level.binSamples == 10)
        #expect(level.binCount == 1000)
        #expect(level.storageFileName == "p.bin")
    }

    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        let original = PyramidLevel(binSamples: 100, binCount: 250, storageFileName: "y.bin")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PyramidLevel.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Recording

@Suite("Recording — construction and legacy-decoder paths")
struct RecordingTests {

    private func makeRecording(annotations: [Annotation] = []) -> Recording {
        let channel = Channel(
            name: "II",
            unit: "mV",
            sampleRate: 250,
            startTimeUnixMS: 0,
            sampleCount: 1000,
            storageFileName: "II.bin"
        )
        return Recording(
            version: Recording.currentVersion,
            id: UUID(),
            device: "TestDevice",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "rec.hea",
            channels: [channel],
            annotations: annotations,
            headerComments: ["# Test"],
            notesFileName: "notes.md"
        )
    }

    @Test("currentVersion is exposed")
    func currentVersion() {
        #expect(Recording.currentVersion == 1)
    }

    @Test("Constructs with defaults for optional fields")
    func minimalConstruction() {
        let r = Recording(
            version: 1,
            id: UUID(),
            device: "X",
            createdAt: Date(timeIntervalSince1970: 0),
            sourceFileName: "x.hea",
            channels: []
        )
        #expect(r.annotations.isEmpty)
        #expect(r.headerComments.isEmpty)
        #expect(r.notesFileName == nil)
    }

    @Test("Codable roundtrip preserves all fields")
    func codableRoundtrip() throws {
        let original = makeRecording(annotations: [
            Annotation(kind: .point, sampleIndex: 100, category: "PVC", source: "t")
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Recording.self, from: data)
        #expect(decoded == original)
    }

    @Test("Legacy manifest without annotations key decodes with empty array")
    func legacyDecodeNoAnnotationsKey() throws {
        let json = """
        {
          "version": 1,
          "id": "00000000-0000-0000-0000-000000000001",
          "device": "Legacy",
          "createdAt": -978307200,
          "sourceFileName": "rec.hea",
          "channels": []
        }
        """
        let decoded = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        #expect(decoded.annotations.isEmpty)
        #expect(decoded.headerComments.isEmpty)
        #expect(decoded.notesFileName == nil)
    }

    @Test("Legacy manifest with [WFDBAnnotation] decodes via the adapter path")
    func legacyDecodeWFDBAnnotations() throws {
        // WFDBAnnotation JSON shape: { sampleIndex, code, label }
        // Recording's custom init(from:) detects this and adapts each to a
        // point Annotation tagged source="wfdb.atr".
        let json = """
        {
          "version": 1,
          "id": "00000000-0000-0000-0000-000000000002",
          "device": "Legacy",
          "createdAt": 0,
          "sourceFileName": "rec.hea",
          "channels": [],
          "annotations": [
            {"sampleIndex": 100, "code": 1, "label": "N"},
            {"sampleIndex": 200, "code": 5, "label": "V"}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(Recording.self, from: Data(json.utf8))
        #expect(decoded.annotations.count == 2)
        #expect(decoded.annotations[0].kind == .point)
        #expect(decoded.annotations[0].sampleIndex == 100)
        #expect(decoded.annotations[0].category == "N")
        #expect(decoded.annotations[0].source == "wfdb.atr")
        #expect(decoded.annotations[1].category == "V")
    }
}

// MARK: - ProgressUpdate

@Suite("ProgressUpdate — clamping and equality")
struct ProgressUpdateTests {

    @Test("In-range fractions pass through unchanged")
    func inRange() {
        let p = ProgressUpdate(fractionComplete: 0.42, stage: "scanning")
        #expect(p.fractionComplete == 0.42)
        #expect(p.stage == "scanning")
    }

    @Test("Negative fractions clamp to zero")
    func clampLow() {
        #expect(ProgressUpdate(fractionComplete: -0.5, stage: "x").fractionComplete == 0)
    }

    @Test("Fractions above 1 clamp to one")
    func clampHigh() {
        #expect(ProgressUpdate(fractionComplete: 1.5, stage: "x").fractionComplete == 1)
    }

    @Test("Boundary values pass through exactly")
    func boundaries() {
        #expect(ProgressUpdate(fractionComplete: 0, stage: "x").fractionComplete == 0)
        #expect(ProgressUpdate(fractionComplete: 1, stage: "x").fractionComplete == 1)
    }

    @Test("Equatable matches both fraction and stage")
    func equatable() {
        let a = ProgressUpdate(fractionComplete: 0.5, stage: "x")
        let b = ProgressUpdate(fractionComplete: 0.5, stage: "x")
        let c = ProgressUpdate(fractionComplete: 0.5, stage: "y")
        let d = ProgressUpdate(fractionComplete: 0.6, stage: "x")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }
}

// MARK: - ProducerRegistry

@Suite("ProducerRegistry — registration roundtrips")
struct ProducerRegistryTests {

    @Test("register then lookup returns the same producer instance")
    func registerLookup() async {
        let registry = ProducerRegistry()
        let producer = TestProducer(id: "test.alpha", displayName: "Alpha")
        await registry.register(producer)
        let found = await registry.producer(id: "test.alpha")
        #expect(found?.id == "test.alpha")
    }

    @Test("Unknown id returns nil")
    func unknownIDReturnsNil() async {
        let registry = ProducerRegistry()
        let found = await registry.producer(id: "missing")
        #expect(found == nil)
    }

    @Test("unregister removes a registered producer")
    func unregister() async {
        let registry = ProducerRegistry()
        await registry.register(TestProducer(id: "test.beta", displayName: "Beta"))
        await registry.unregister(id: "test.beta")
        let found = await registry.producer(id: "test.beta")
        #expect(found == nil)
    }

    @Test("unregister is a no-op for unknown ids")
    func unregisterNoop() async {
        let registry = ProducerRegistry()
        await registry.unregister(id: "not.there")
        let all = await registry.all()
        #expect(all.isEmpty)
    }

    @Test("Re-registering with the same id clobbers the prior registration")
    func reregisterClobbers() async {
        let registry = ProducerRegistry()
        await registry.register(TestProducer(id: "test.x", displayName: "First"))
        await registry.register(TestProducer(id: "test.x", displayName: "Second"))
        let found = await registry.producer(id: "test.x")
        #expect(found?.displayName == "Second")
    }

    @Test("all() returns producers sorted by id")
    func allSorted() async {
        let registry = ProducerRegistry()
        await registry.register(TestProducer(id: "z", displayName: "Z"))
        await registry.register(TestProducer(id: "a", displayName: "A"))
        await registry.register(TestProducer(id: "m", displayName: "M"))
        let all = await registry.all()
        #expect(all.map { $0.id } == ["a", "m", "z"])
    }

    @Test("Independent registries don't share state")
    func independentInstances() async {
        let r1 = ProducerRegistry()
        let r2 = ProducerRegistry()
        await r1.register(TestProducer(id: "only.in.r1", displayName: "X"))
        let inR2 = await r2.producer(id: "only.in.r1")
        #expect(inR2 == nil)
    }
}

// MARK: - External FindingProducer conformance

@Suite("FindingProducer — external conformance and stream consumption")
struct ExternalProducerTests {

    @Test("External producer can be constructed and run")
    func externalConformerRuns() async throws {
        let producer = TestProducer(id: "test.runs", displayName: "Run")
        let recording = makeFakeRecording()

        var events: [String] = []
        for try await event in producer.analyze(recording) {
            switch event {
            case .progress: events.append("progress")
            case .findings: events.append("findings")
            case .warning:  events.append("warning")
            }
        }
        // TestProducer emits one progress, one findings (single annotation), and finishes.
        #expect(events == ["progress", "findings"])
    }

    @Test("Stream completes by exhaustion when there's nothing more to emit")
    func streamCompletes() async throws {
        let producer = TestProducer(id: "test.completes", displayName: "C")
        var iter = producer.analyze(makeFakeRecording()).makeAsyncIterator()
        while try await iter.next() != nil {
            // drain
        }
        let after = try await iter.next()
        #expect(after == nil)
    }

    @Test("Cancellation tears down the stream")
    func cancellationTearsDown() async throws {
        let producer = SlowTestProducer()
        let task = Task<Int, Error> {
            var count = 0
            for try await event in producer.analyze(makeFakeRecording()) {
                if case .progress = event { count += 1 }
            }
            return count
        }
        // Give the task a moment to enter the stream, then cancel.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        // The producer's stream should either complete normally or throw
        // CancellationError; both are acceptable teardown paths.
        do {
            _ = try await task.value
        } catch is CancellationError {
            // expected
        }
    }

    @Test("Warning events surface to the consumer without ending the stream")
    func warningEvents() async throws {
        let producer = WarningTestProducer()
        var sawWarning = false
        var sawFindings = false
        for try await event in producer.analyze(makeFakeRecording()) {
            switch event {
            case .warning: sawWarning = true
            case .findings: sawFindings = true
            case .progress: break
            }
        }
        #expect(sawWarning)
        #expect(sawFindings)
    }

    @Test("Empty .findings yield is allowed and means a clean-scanned window")
    func emptyFindingsAllowed() async throws {
        let producer = EmptyFindingsTestProducer()
        var emptyCount = 0
        for try await event in producer.analyze(makeFakeRecording()) {
            if case .findings(let arr) = event, arr.isEmpty {
                emptyCount += 1
            }
        }
        #expect(emptyCount == 1)
    }
}

// MARK: - PurchaseStore

@Suite("PurchaseStore — entitlement gating and producer routing")
@MainActor
struct PurchaseStoreTests {

    @Test("ProductID raw values are stable")
    func productIDRawValues() {
        #expect(PurchaseStore.ProductID.annotationAuthoring.rawValue == "com.kevinlong.murmur.annotationauthoring")
        #expect(PurchaseStore.ProductID.silverMetrics.rawValue == "com.kevinlong.murmur.silvermetrics")
        #expect(PurchaseStore.ProductID.vtDetection.rawValue == "com.kevinlong.murmur.vtdetection")
    }

    @Test("ProductID is CaseIterable across all three IAPs")
    func productIDCaseIterable() {
        #expect(PurchaseStore.ProductID.allCases.count == 3)
    }

    @Test("requiredProduct returns nil for unrecognized (free) producer ids")
    func requiredProductFree() {
        #expect(PurchaseStore.requiredProduct(forProducerID: "murmur.synthetic") == nil)
        #expect(PurchaseStore.requiredProduct(forProducerID: "random.thing") == nil)
    }

    @Test("requiredProduct maps the three known paid producers")
    func requiredProductPaid() {
        #expect(PurchaseStore.requiredProduct(forProducerID: "murmur.annotation") == .annotationAuthoring)
        #expect(PurchaseStore.requiredProduct(forProducerID: "murmur.silver") == .silverMetrics)
        #expect(PurchaseStore.requiredProduct(forProducerID: "murmur.vtdetect") == .vtDetection)
    }

    @Test("Fresh store owns nothing")
    func freshStoreEmpty() {
        let store = PurchaseStore()
        #expect(store.ownedProductIDs.isEmpty)
        for id in PurchaseStore.ProductID.allCases {
            #expect(store.owns(id) == false)
        }
    }

    @Test("canRun is always true for free producers regardless of ownership")
    func canRunFreeProducer() {
        let store = PurchaseStore()
        #expect(store.canRun(producerID: "murmur.synthetic") == true)
        #expect(store.canRun(producerID: "anything.else") == true)
    }

    @Test("canRun is false for paid producers when entitlement absent")
    func canRunPaidLocked() {
        let store = PurchaseStore()
        #expect(store.canRun(producerID: "murmur.silver") == false)
        #expect(store.canRun(producerID: "murmur.annotation") == false)
        #expect(store.canRun(producerID: "murmur.vtdetect") == false)
    }

    #if DEBUG
    @Test("canRun flips to true once the gating entitlement is set")
    func canRunPaidUnlocked() {
        let store = PurchaseStore()
        store._setOwnedForTesting([.silverMetrics])
        #expect(store.canRun(producerID: "murmur.silver") == true)
        #expect(store.canRun(producerID: "murmur.annotation") == false)
        #expect(store.canRun(producerID: "murmur.vtdetect") == false)
        #expect(store.owns(.silverMetrics) == true)
        #expect(store.owns(.annotationAuthoring) == false)
    }

    @Test("Multiple entitlements set independently")
    func multipleEntitlements() {
        let store = PurchaseStore()
        store._setOwnedForTesting([.silverMetrics, .vtDetection])
        #expect(store.canRun(producerID: "murmur.silver") == true)
        #expect(store.canRun(producerID: "murmur.vtdetect") == true)
        #expect(store.canRun(producerID: "murmur.annotation") == false)
    }
    #endif

    @Test("purchase throws productNotLoaded when the product hasn't been fetched")
    func purchaseThrowsWhenProductMissing() async {
        // Fresh store; products dict stays empty because the test
        // bundle has no StoreKit configuration to load against.
        // Asking to purchase any product should refuse cleanly with
        // productNotLoaded rather than crashing or hanging.
        let store = PurchaseStore()
        do {
            _ = try await store.purchase(.silverMetrics)
            Issue.record("Expected purchase to throw productNotLoaded")
        } catch let error as PurchaseStore.PurchaseError {
            if case .productNotLoaded = error {
                // Expected path.
            } else {
                Issue.record("Wrong PurchaseError case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Test fixtures

/// A minimal external `FindingProducer` conformance. The fact that this
/// compiles is itself a contract test — it proves the public surface is
/// sufficient for an out-of-module type to conform.
private struct TestProducer: FindingProducer {
    let id: String
    let displayName: String

    func analyze(_ recording: Recording) -> AsyncThrowingStream<ProducerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(ProgressUpdate(fractionComplete: 0.5, stage: "scanning")))
            continuation.yield(.findings([
                Annotation(
                    kind: .point,
                    sampleIndex: 0,
                    category: "Test",
                    source: id
                )
            ]))
            continuation.finish()
        }
    }
}

/// A producer that emits a warning between progress and findings to
/// verify the host can surface non-fatal warnings without ending the
/// run.
private struct WarningTestProducer: FindingProducer {
    let id = "test.warning"
    let displayName = "Warning"

    func analyze(_ recording: Recording) -> AsyncThrowingStream<ProducerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(ProgressUpdate(fractionComplete: 0.25, stage: "start")))
            continuation.yield(.warning(message: "noisy window", underlying: nil))
            continuation.yield(.findings([
                Annotation(kind: .point, sampleIndex: 100, category: "x", source: "test.warning")
            ]))
            continuation.finish()
        }
    }
}

/// A producer that emits an empty `.findings` event — meaningful because
/// it signals "this window was scanned and produced nothing" rather than
/// "nothing has happened yet."
private struct EmptyFindingsTestProducer: FindingProducer {
    let id = "test.empty"
    let displayName = "Empty"

    func analyze(_ recording: Recording) -> AsyncThrowingStream<ProducerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.findings([]))
            continuation.finish()
        }
    }
}

/// A producer that takes long enough between yields that Task cancellation
/// has time to fire mid-stream.
private struct SlowTestProducer: FindingProducer {
    let id = "test.slow"
    let displayName = "Slow"

    func analyze(_ recording: Recording) -> AsyncThrowingStream<ProducerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for index in 0..<100 {
                    do { try Task.checkCancellation() } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    continuation.yield(.progress(ProgressUpdate(
                        fractionComplete: Double(index) / 100,
                        stage: "step \(index)"
                    )))
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Convenience: a one-channel Recording suitable for feeding any
/// `FindingProducer.analyze` that doesn't actually read samples.
private func makeFakeRecording() -> Recording {
    let channel = Channel(
        name: "II",
        unit: "mV",
        sampleRate: 250,
        startTimeUnixMS: 0,
        sampleCount: 2500,
        storageFileName: "II.bin"
    )
    return Recording(
        version: Recording.currentVersion,
        id: UUID(),
        device: "TestRig",
        createdAt: Date(timeIntervalSince1970: 0),
        sourceFileName: "rec.hea",
        channels: [channel]
    )
}
