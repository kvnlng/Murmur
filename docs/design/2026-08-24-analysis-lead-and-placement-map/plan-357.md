# Analysis Lead (#357) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The analysis lead is designated directly or defaulted by R-peak quality, disclosed everywhere, and never chosen or gated by a lead's name.

**Architecture:** MurmurCore gains an `AnalysisLeadScorer` registry (FindingProducer pattern), an `analysis_lead.json` bundle sidecar stamped once at import, and a `Recording.analysisLead(inBundle:)` resolution (designation → stored default → first-in-file) with a provenance enum feeding one disclosure vocabulary. The App target registers a MurmurMetrics-backed scorer gated on the Pro entitlement. All calculation consumers read the resolution; QT becomes a single-lead read and the X108 name gate is deleted.

**Tech Stack:** Swift / SwiftUI, Swift Testing (`#expect`), macOS 26. No Murmur-Extensions changes (`QRSDetector.qrsProminence` is already public).

**Spec:** `docs/design/2026-08-24-analysis-lead-and-placement-map/README.md` (Part 1). The plan argues from the spec; read both.

## Global Constraints

- Tests run via the workaround, NOT `xcodebuild test` (it hangs on this Mac after CodeSign):
  ```
  xcodebuild build-for-testing -scheme Murmur -destination 'platform=macOS' -derivedDataPath <dd>
  ln -sfn <dd>/Build/Products/Debug/MurmurCore.framework <dd>/Build/Products/Debug/PackageFrameworks/MurmurCore.framework
  xcrun xctest <dd>/Build/Products/Debug/MurmurTests.xctest
  ```
  Package tests: `swift test` from the repo root.
- Release build must succeed before any push: `xcodebuild build -scheme Murmur -configuration Release -destination 'platform=macOS'`. UITestSupport and test hooks are DEBUG-only; an unguarded reference passes Debug and fails only at archive.
- swift-testing gotcha: `#expect(a == b + 1)` can miscompare — bind the arithmetic to a `let` first and compare plain values.
- Suites live in `MurmurTests/` (app-hosted, imports MurmurCore `@testable`, MurmurMetrics importable — see `DetectorInvariantTests`). Match existing style: `@Suite("…") struct`, `#expect`, fixtures via `WFDBRecordWriter`/`SyntheticECG`.
- Every push gets a written-up PR; merge only with the full gate green (unit suites + Release build). One branch for this arc: `feat/357-analysis-lead`, PR per task group is fine, or one PR for the arc — executor's call, but never leave pushed commits without a PR.
- Comment style: comments state constraints code can't show, in the repo's voice (see any recent MurmurCore file). Issue references like `(#357)` are conventional.
- The docs site is Jekyll; `docs/design/` is excluded. Product docs edited here: `docs/annotation-schema.md`, `docs/what-murmur-asserts.md`.

---

### Task 1: Core model — scorer registry, sidecar file, resolution

**Files:**
- Create: `MurmurCore/AnalysisLead.swift`
- Test: `MurmurTests/AnalysisLeadTests.swift` (new file)

**Interfaces:**
- Consumes: `Recording`/`Channel` (`MurmurCore/Recording.swift`), `BinaryRecordingFile.readSamples` (pattern at `Recording.conventionalQTLeads`), `SourceFingerprint`'s read/write shape (`MurmurCore/SourceFingerprint.swift`).
- Produces (later tasks rely on these exact names):
  - `protocol AnalysisLeadScorer: Sendable` with `func scoreLeads(_ leads: [(name: String, samples: [Float])], sampleRate: Double) -> [String: Double]?`
  - `final class AnalysisLeadScoring` — `static let shared`, `func register(_:)`, `func currentScorer() -> (any AnalysisLeadScorer)?`, `func clearForTesting()`
  - `struct AnalysisLeadFile: Codable` — `static let bundleFileName = "analysis_lead.json"`, `var defaultChoice: DefaultChoice?`, `var designation: Designation?`, `static func read(from:) -> AnalysisLeadFile?`, `func write(to:) throws`
  - `enum AnalysisLeadProvenance: Equatable, Sendable` — `.designated(reviewer: String, date: Date)`, `.rPeakScore(score: Double, perLead: [String: Double])`, `.firstInFile`
  - `struct AnalysisLeadResolution` — `channel: Recording.Channel`, `provenance: AnalysisLeadProvenance`, `staleDesignation: String?`
  - `Recording.analysisLead(inBundle directory: URL) -> AnalysisLeadResolution?`
  - `Recording.samples(of channel: Channel, inDirectory: URL) -> [Float]?`

- [ ] **Step 1: Write the failing tests**

```swift
//
//  AnalysisLeadTests.swift
//  MurmurTests
//
//  #357: the analysis-lead resolution contract. A calculation may never
//  be gated on a lead's NAME — resolution is designation → stored
//  default → first-in-file, and every branch carries its provenance.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("Analysis lead — sidecar and resolution")
struct AnalysisLeadTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-lead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Two-ECG-channel recording; channel binaries are not needed for
    /// resolution tests (only for scoring, which Task 2 covers).
    private func makeRecording() -> Recording {
        Recording(
            id: UUID(),
            name: "rec",
            startTimeUnixMS: 0,
            channels: [
                Recording.Channel(id: UUID(), name: "MLII", sampleRate: 360,
                                  sampleCount: 3600, storageFileName: "channel_MLII.bin"),
                Recording.Channel(id: UUID(), name: "V5", sampleRate: 360,
                                  sampleCount: 3600, storageFileName: "channel_V5.bin"),
            ]
        )
    }

    @Test("Sidecar round-trips; absent file reads nil, never a throw")
    func sidecarRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AnalysisLeadFile.read(from: dir) == nil)

        let file = AnalysisLeadFile(
            defaultChoice: .init(channelName: "V5", reason: .rPeakScore,
                                 perLeadScores: ["MLII": 3.2, "V5": 6.1],
                                 scoredAt: Date(timeIntervalSince1970: 100),
                                 scorerVersion: 1),
            designation: nil
        )
        try file.write(to: dir)
        #expect(AnalysisLeadFile.read(from: dir) == file)
    }

    @Test("No sidecar resolves first-in-file with that provenance")
    func noSidecarIsFirstInFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "MLII")
        #expect(resolution?.provenance == .firstInFile)
        #expect(resolution?.staleDesignation == nil)
    }

    @Test("Stored default wins over first-in-file, with score provenance")
    func storedDefaultWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AnalysisLeadFile(
            defaultChoice: .init(channelName: "V5", reason: .rPeakScore,
                                 perLeadScores: ["MLII": 3.2, "V5": 6.1],
                                 scoredAt: .now, scorerVersion: 1),
            designation: nil
        ).write(to: dir)
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "V5")
        #expect(resolution?.provenance == .rPeakScore(score: 6.1, perLead: ["MLII": 3.2, "V5": 6.1]))
    }

    @Test("Designation wins over the stored default")
    func designationWins() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 200)
        try AnalysisLeadFile(
            defaultChoice: .init(channelName: "V5", reason: .rPeakScore,
                                 perLeadScores: [:], scoredAt: .now, scorerVersion: 1),
            designation: .init(channelName: "MLII", reviewer: "kevin", designatedAt: date)
        ).write(to: dir)
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "MLII")
        #expect(resolution?.provenance == .designated(reviewer: "kevin", date: date))
    }

    @Test("A designation naming a missing channel is disclosed and ignored")
    func staleDesignationFallsThrough() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AnalysisLeadFile(
            defaultChoice: .init(channelName: "V5", reason: .rPeakScore,
                                 perLeadScores: [:], scoredAt: .now, scorerVersion: 1),
            designation: .init(channelName: "V9", reviewer: "kevin", designatedAt: .now)
        ).write(to: dir)
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "V5")
        #expect(resolution?.staleDesignation == "V9")
    }

    @Test("A stored default naming a missing channel falls to first-in-file")
    func staleDefaultFallsThrough() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AnalysisLeadFile(
            defaultChoice: .init(channelName: "GONE", reason: .rPeakScore,
                                 perLeadScores: [:], scoredAt: .now, scorerVersion: 1),
            designation: nil
        ).write(to: dir)
        let resolution = makeRecording().analysisLead(inBundle: dir)
        #expect(resolution?.channel.name == "MLII")
        #expect(resolution?.provenance == .firstInFile)
    }

    @Test("Duplicate names resolve to the first match (X96's rule)")
    func duplicateNamesFirstMatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var recording = makeRecording()
        recording = Recording(
            id: recording.id, name: recording.name,
            startTimeUnixMS: recording.startTimeUnixMS,
            channels: recording.channels + [
                Recording.Channel(id: UUID(), name: "MLII", sampleRate: 360,
                                  sampleCount: 100, storageFileName: "channel_MLII_2.bin")
            ]
        )
        try AnalysisLeadFile(
            defaultChoice: nil,
            designation: .init(channelName: "MLII", reviewer: "kevin", designatedAt: .now)
        ).write(to: dir)
        let resolution = recording.analysisLead(inBundle: dir)
        #expect(resolution?.channel.sampleCount == 3600)   // the first MLII
    }

    @Test("Registry registers, serves, and clears a scorer")
    func registryLifecycle() {
        struct Fake: AnalysisLeadScorer {
            func scoreLeads(_ leads: [(name: String, samples: [Float])],
                            sampleRate: Double) -> [String: Double]? { [:] }
        }
        let registry = AnalysisLeadScoring()
        #expect(registry.currentScorer() == nil)
        registry.register(Fake())
        #expect(registry.currentScorer() != nil)
        registry.clearForTesting()
        #expect(registry.currentScorer() == nil)
    }
}
```

Note: adapt the `Recording`/`Channel` initializers to the real
memberwise signatures in `MurmurCore/Recording.swift` (they carry more
fields — units, gain; fill with obvious defaults). Do not change
`Recording` itself for the tests' convenience.

- [ ] **Step 2: Run the tests to verify they fail**

Run the Global Constraints test workaround. Expected: compile failures — `AnalysisLeadFile` etc. undefined.

- [ ] **Step 3: Implement `MurmurCore/AnalysisLead.swift`**

```swift
//
//  AnalysisLead.swift
//  MurmurCore
//
//  #357 — which channel the calculations run on, and why.
//
//  The rule (docs/design/2026-08-24-analysis-lead-and-placement-map,
//  docs/what-murmur-asserts.md): a calculation may never be gated on a
//  lead's NAME. The analysis lead is resolved designation → stored
//  default → first-in-file, every branch carries its provenance for the
//  disclosure line, and the name plays no part in the choice.
//
//  The default is stamped ONCE at import (RecordingStore) and never
//  recomputed — a record's analysis lead must not change under an
//  analyst mid-review. Scoring is provided by whatever registered an
//  AnalysisLeadScorer (the App registers a MurmurMetrics-backed one,
//  entitlement-gated); with none registered the default records
//  firstInFile explicitly — the absence of scoring is a stored fact,
//  never an inference.
//

import Foundation

// MARK: - Scorer registry

/// Scores leads for analysis-lead defaulting. Dumb by contract: scores
/// in, no channel choice out — choosing (and disclosing) stays in core
/// so free and paid builds share one resolution path.
public protocol AnalysisLeadScorer: Sendable {
    /// Per-lead-name scores, higher = better R-peak support. Return nil
    /// to decline (unentitled, degenerate input) — the caller then
    /// records firstInFile.
    func scoreLeads(
        _ leads: [(name: String, samples: [Float])],
        sampleRate: Double
    ) -> [String: Double]?
}

/// Process-wide slot for the one registered scorer. A class with a lock
/// rather than an actor so the synchronous import path can consult it
/// without an await. Tests construct their own instance.
public final class AnalysisLeadScoring: @unchecked Sendable {
    public static let shared = AnalysisLeadScoring()

    private let lock = NSLock()
    private var scorer: (any AnalysisLeadScorer)?

    public init() {}

    public func register(_ scorer: any AnalysisLeadScorer) {
        lock.lock(); defer { lock.unlock() }
        self.scorer = scorer
    }

    public func currentScorer() -> (any AnalysisLeadScorer)? {
        lock.lock(); defer { lock.unlock() }
        return scorer
    }

    public func clearForTesting() {
        lock.lock(); defer { lock.unlock() }
        scorer = nil
    }
}

// MARK: - Bundle sidecar

/// `analysis_lead.json` — beside `source_fingerprint.json`, same rule:
/// assertions live in the bundle, never the producer's folder. Channels
/// are referenced by NAME (names survive re-import of unchanged source;
/// channel IDs do not); duplicates resolve to the first match, X96's rule.
public struct AnalysisLeadFile: Codable, Equatable, Sendable {

    public enum DefaultReason: String, Codable, Sendable {
        case rPeakScore
        case firstInFile
    }

    /// The import-time default. Written once when the bundle is cut;
    /// nothing ever rewrites it (scope decision 2: never backfill).
    public struct DefaultChoice: Codable, Equatable, Sendable {
        public var channelName: String
        public var reason: DefaultReason
        public var perLeadScores: [String: Double]?
        public var scoredAt: Date
        public var scorerVersion: Int

        public init(channelName: String, reason: DefaultReason,
                    perLeadScores: [String: Double]?, scoredAt: Date, scorerVersion: Int) {
            self.channelName = channelName
            self.reason = reason
            self.perLeadScores = perLeadScores
            self.scoredAt = scoredAt
            self.scorerVersion = scorerVersion
        }
    }

    /// The analyst's assertion. Reviewer per the DispositionStore
    /// convention (macOS user name, best-effort).
    public struct Designation: Codable, Equatable, Sendable {
        public var channelName: String
        public var reviewer: String
        public var designatedAt: Date

        public init(channelName: String, reviewer: String, designatedAt: Date) {
            self.channelName = channelName
            self.reviewer = reviewer
            self.designatedAt = designatedAt
        }
    }

    public var defaultChoice: DefaultChoice?
    public var designation: Designation?

    enum CodingKeys: String, CodingKey {
        case defaultChoice = "default"
        case designation
    }

    public init(defaultChoice: DefaultChoice?, designation: Designation?) {
        self.defaultChoice = defaultChoice
        self.designation = designation
    }

    public static let bundleFileName = "analysis_lead.json"

    /// Nil on absence or decode failure — malformed means "no stored
    /// choice", never an error; resolution falls through honestly.
    public static func read(from bundleDirectory: URL) -> AnalysisLeadFile? {
        let url = bundleDirectory.appendingPathComponent(bundleFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AnalysisLeadFile.self, from: data)
    }

    public func write(to bundleDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = bundleDirectory.appendingPathComponent(Self.bundleFileName)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Resolution

/// Why this channel is the analysis lead — the disclosure line and the
/// export columns render from this, one vocabulary everywhere.
public enum AnalysisLeadProvenance: Equatable, Sendable {
    case designated(reviewer: String, date: Date)
    case rPeakScore(score: Double, perLead: [String: Double])
    case firstInFile
}

public struct AnalysisLeadResolution: Equatable, Sendable {
    public let channel: Recording.Channel
    public let provenance: AnalysisLeadProvenance
    /// A designation that named a channel not in this recording — the
    /// header disclosure reports it ("designated lead V9 not in this
    /// record — using default"); resolution fell through.
    public let staleDesignation: String?
}

extension Recording {

    /// The channel calculations run on. Resolution order: designation →
    /// stored default → first-in-file; a stored name that no longer
    /// resolves is skipped (and, for designations, disclosed). Nil only
    /// when the recording has no ECG channel at all.
    public func analysisLead(inBundle directory: URL) -> AnalysisLeadResolution? {
        let ecg = channels.filter { !$0.isTrendChannel }
        guard !ecg.isEmpty else { return nil }
        // First match by name — X96's duplicate rule.
        func channel(named name: String) -> Channel? {
            ecg.first { $0.name == name }
        }

        let file = AnalysisLeadFile.read(from: directory)
        var stale: String?

        if let designation = file?.designation {
            if let channel = channel(named: designation.channelName) {
                return AnalysisLeadResolution(
                    channel: channel,
                    provenance: .designated(reviewer: designation.reviewer,
                                            date: designation.designatedAt),
                    staleDesignation: nil
                )
            }
            stale = designation.channelName
        }

        if let choice = file?.defaultChoice, choice.reason == .rPeakScore,
           let channel = channel(named: choice.channelName) {
            let scores = choice.perLeadScores ?? [:]
            return AnalysisLeadResolution(
                channel: channel,
                provenance: .rPeakScore(score: scores[choice.channelName] ?? 0,
                                        perLead: scores),
                staleDesignation: stale
            )
        }

        guard let first = primaryECGChannel else { return nil }
        return AnalysisLeadResolution(
            channel: first, provenance: .firstInFile, staleDesignation: stale
        )
    }

    /// One channel's full sample buffer — the per-channel read the
    /// analysis-lead consumers use (same BinaryRecordingFile call the
    /// deleted conventionalQTLeads made).
    public func samples(of channel: Channel, inDirectory directory: URL) -> [Float]? {
        let url = directory.appendingPathComponent(channel.storageFileName)
        return try? BinaryRecordingFile.readSamples(url: url, range: 0..<channel.sampleCount)
    }
}
```

Adapt `Recording.Channel` spelling to the real nesting (the tests and
this file must agree with `Recording.swift` — `Channel` may be
top-level `Channel`, not `Recording.Channel`; use whatever
`Recording.swift` declares).

- [ ] **Step 4: Run the tests to verify they pass**

Full MurmurTests via the workaround. Expected: all new tests PASS, no existing test broken.

- [ ] **Step 5: Commit**

```bash
git add MurmurCore/AnalysisLead.swift MurmurTests/AnalysisLeadTests.swift
git commit -m "Analysis lead: scorer registry, bundle sidecar, resolution (#357)"
```

---

### Task 2: Import-time scoring stamp in RecordingStore

**Files:**
- Modify: `MurmurCore/RecordingStore.swift` (inside `importWFDB`, where the fingerprint is stamped)
- Test: `MurmurTests/AnalysisLeadTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `AnalysisLeadScoring.shared`, `AnalysisLeadFile`; `Recording.ecgLeadSamples(inDirectory:)`.
- Produces: every fresh import writes `analysis_lead.json` with a `defaultChoice`; reused bundles (#341) keep theirs untouched.

- [ ] **Step 1: Write the failing tests** (extend `AnalysisLeadTests.swift`; reuse the `writeSource`/`makeStore` fixture shapes from `SourceFingerprintTests.swift` — copy them in, do not share test code across files)

```swift
@Suite("Analysis lead — import-time default")
@MainActor
struct AnalysisLeadImportTests {

    // makeStore() and writeSource(in:) copied from SourceFingerprintTests
    // (two-channel variant: leadNames ["ECG1", "ECG2"], two channelSamples
    // arrays — ECG1 low-amplitude flatline-ish, ECG2 a clear repeating spike).

    struct RiggedScorer: AnalysisLeadScorer {
        let scores: [String: Double]?
        func scoreLeads(_ leads: [(name: String, samples: [Float])],
                        sampleRate: Double) -> [String: Double]? { scores }
    }

    @Test("A fresh import with a scorer stamps the highest-scoring lead")
    func importStampsScoredDefault() async throws {
        AnalysisLeadScoring.shared.register(
            RiggedScorer(scores: ["ECG1": 1.0, "ECG2": 9.0]))
        defer { AnalysisLeadScoring.shared.clearForTesting() }
        // import via store.importWFDB, then:
        // let file = AnalysisLeadFile.read(from: summary.directory)
        // #expect(file?.defaultChoice?.channelName == "ECG2")
        // #expect(file?.defaultChoice?.reason == .rPeakScore)
        // #expect(file?.defaultChoice?.perLeadScores?["ECG2"] == 9.0)
    }

    @Test("No scorer registered stamps firstInFile explicitly")
    func importStampsFirstInFileWithoutScorer() async throws {
        AnalysisLeadScoring.shared.clearForTesting()
        // import, then:
        // #expect(file?.defaultChoice?.reason == .firstInFile)
        // #expect(file?.defaultChoice?.channelName == "ECG1")
        // #expect(file?.defaultChoice?.perLeadScores == nil)
    }

    @Test("A scorer that declines (nil) stamps firstInFile")
    func decliningScorerStampsFirstInFile() async throws {
        AnalysisLeadScoring.shared.register(RiggedScorer(scores: nil))
        defer { AnalysisLeadScoring.shared.clearForTesting() }
        // #expect(file?.defaultChoice?.reason == .firstInFile)
    }

    @Test("Equal scores tie-break to file order, recorded as a score choice")
    func equalScoresTieBreakToFileOrder() async throws {
        AnalysisLeadScoring.shared.register(
            RiggedScorer(scores: ["ECG1": 5.0, "ECG2": 5.0]))
        defer { AnalysisLeadScoring.shared.clearForTesting() }
        // #expect(file?.defaultChoice?.channelName == "ECG1")
    }

    @Test("Bundle reuse keeps the original stamp — never re-scored (#341 composition)")
    func reuseKeepsOriginalStamp() async throws {
        AnalysisLeadScoring.shared.register(
            RiggedScorer(scores: ["ECG1": 1.0, "ECG2": 9.0]))
        // first import → ECG2. Re-register a scorer preferring ECG1,
        // import the same unchanged source again:
        // #expect(second.directory == first.directory)
        // #expect(AnalysisLeadFile.read(from: second.directory)?
        //     .defaultChoice?.channelName == "ECG2")
        AnalysisLeadScoring.shared.clearForTesting()
    }
}
```

Fill the commented skeletons with real code following
`SourceFingerprintTests.RecordingStoreReuseTests` verbatim patterns
(temp source dir, `store.importWFDB(folderURL:heaFilename:)`, defer
cleanup). The rigged scorer keys must match the fixture's lead names.

- [ ] **Step 2: Run to verify the new tests fail** (import writes no sidecar yet).

- [ ] **Step 3: Implement.** In `RecordingStore.importWFDB`, immediately after the fingerprint stamp (`try? fingerprint.write(to: summary.directory)` and its index entry — keep those first):

```swift
// #357: stamp the analysis-lead default, ONCE, while the bundle is
// fresh — the same "assertions ride the bundle" moment as the
// fingerprint. Never rewritten (a record's analysis lead must not
// change under an analyst mid-review; scope decision 2), and reuse
// serves the original stamp. No scorer, or a scorer that declines
// (unentitled), records firstInFile EXPLICITLY — the absence of
// scoring is a stored fact, not an inference.
Self.stampAnalysisLeadDefault(for: summary.recording, in: summary.directory)
```

and the helper (nonisolated static, beside `reusableSummary`):

```swift
private nonisolated static func stampAnalysisLeadDefault(
    for recording: Recording, in directory: URL
) {
    guard AnalysisLeadFile.read(from: directory)?.defaultChoice == nil else { return }
    let ecg = recording.channels.filter { !$0.isTrendChannel && $0.sampleCount > 0 }
    guard let first = ecg.first else { return }

    var choice = AnalysisLeadFile.DefaultChoice(
        channelName: first.name, reason: .firstInFile,
        perLeadScores: nil, scoredAt: Date(), scorerVersion: 1
    )

    if let scorer = AnalysisLeadScoring.shared.currentScorer() {
        let leads: [(name: String, samples: [Float])] = ecg.compactMap { channel in
            recording.samples(of: channel, inDirectory: directory)
                .map { (channel.name, $0) }
        }
        if leads.count == ecg.count,
           let scores = scorer.scoreLeads(leads, sampleRate: first.sampleRate),
           let best = ecg.max(by: { (scores[$0.name] ?? 0) < (scores[$1.name] ?? 0) }) {
            // max(by:) keeps the FIRST of equals in file order — the
            // tie-break the disclosure names. (Verify: Swift's max(by:)
            // returns the last of equal elements; if so, iterate
            // manually so file order wins. The test pins it.)
            choice = .init(channelName: best.name, reason: .rPeakScore,
                           perLeadScores: scores, scoredAt: Date(), scorerVersion: 1)
        }
    }

    let existing = AnalysisLeadFile.read(from: directory)
    try? AnalysisLeadFile(defaultChoice: choice,
                          designation: existing?.designation).write(to: directory)
}
```

Heed the inline caveat: `max(by:)` with `<` returns a LATER maximal
element on ties — write an explicit loop (`var best; for c in ecg where
(scores[c.name] ?? 0) > bestScore { … }`) so equal scores keep file
order, and let `equalScoresTieBreakToFileOrder` prove it.

- [ ] **Step 4: Run the full suite** — new tests pass, `SourceFingerprintTests` untouched.

- [ ] **Step 5: Commit**

```bash
git add MurmurCore/RecordingStore.swift MurmurTests/AnalysisLeadTests.swift
git commit -m "Import stamps the analysis-lead default once, scored or firstInFile (#357)"
```

---

### Task 3: App-side scorer registration (MurmurMetrics, entitlement-gated)

**Files:**
- Create: `Murmur/QRSProminenceLeadScorer.swift`
- Modify: `Murmur/MurmurApp.swift` (the `bootstrapBaselineProducers` Task in `init`)
- Test: `MurmurTests/AnalysisLeadTests.swift` (extend — MurmurTests links MurmurMetrics; see `DetectorInvariantTests`)

**Interfaces:**
- Consumes: `QRSDetector.qrsProminence(samples:sampleRate:)` (public, MurmurMetrics), Task 1's protocol, `PurchaseStore.shared.ownedProductIDs`.
- Produces: `struct QRSProminenceLeadScorer: AnalysisLeadScorer` with `init(entitled: @escaping @Sendable () -> Bool)` — registered at app launch.

- [ ] **Step 1: Write the failing test.** The scorer struct is testable without the app running because entitlement is injected:

```swift
import MurmurMetrics   // at top of AnalysisLeadTests.swift

@Suite("Analysis lead — QRS prominence scorer")
struct QRSProminenceLeadScorerTests {

    /// Deterministic noisy vs clean pair: clean = repeating sharp spike
    /// train (a crude QRS), noisy = seeded LCG white noise. No
    /// SystemRandomNumberGenerator — the test must not flake.
    private func makeLeads() -> [(name: String, samples: [Float])] {
        let n = 360 * 30
        var clean = [Float](repeating: 0, count: n)
        for beat in stride(from: 0, to: n, by: 360) { // 60 bpm at 360 Hz
            clean[beat] = 1.0
            if beat + 1 < n { clean[beat + 1] = -0.4 }
        }
        var state: UInt64 = 0x5DEECE66D
        var noisy = [Float](repeating: 0, count: n)
        for i in 0..<n {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            noisy[i] = Float(Int64(bitPattern: state) % 1000) / 1000.0
        }
        return [("NOISY", noisy), ("CLEAN", clean)]
    }

    @Test("Entitled: the clean lead outscores the noisy one")
    func cleanOutscoresNoisy() {
        let scorer = QRSProminenceLeadScorer(entitled: { true })
        let scores = scorer.scoreLeads(makeLeads(), sampleRate: 360)
        let clean = scores?["CLEAN"] ?? 0
        let noisy = scores?["NOISY"] ?? 0
        #expect(clean > noisy)
    }

    @Test("Unentitled: the scorer declines (firstInFile downstream)")
    func unentitledDeclines() {
        let scorer = QRSProminenceLeadScorer(entitled: { false })
        #expect(scorer.scoreLeads(makeLeads(), sampleRate: 360) == nil)
    }
}
```

NOTE: `QRSProminenceLeadScorer` lives in the **Murmur app target**;
MurmurTests is app-hosted, so the type is visible without an import.
If it is not (compile error), move the struct to a small file compiled
into both targets is NOT the fix — instead mark it `public` in the app
target and import the app module `@testable import Murmur`. Check how
`DetectorInvariantTests` reaches app types first and copy that.

- [ ] **Step 2: Run — fails** (type undefined).

- [ ] **Step 3: Implement `Murmur/QRSProminenceLeadScorer.swift`:**

```swift
//
//  QRSProminenceLeadScorer.swift
//  Murmur
//
//  #357 — the paid scorer behind the analysis-lead default. Lives in
//  the App target because MurmurCore must not import MurmurMetrics;
//  core defines the AnalysisLeadScorer slot, this fills it. Entitlement
//  is injected so the gate is testable; declining (nil) makes the
//  import stamp firstInFile — the free default, disclosed as such.
//

import Foundation
import MurmurCore
import MurmurMetrics

struct QRSProminenceLeadScorer: AnalysisLeadScorer {
    let entitled: @Sendable () -> Bool

    init(entitled: @escaping @Sendable () -> Bool) {
        self.entitled = entitled
    }

    func scoreLeads(
        _ leads: [(name: String, samples: [Float])],
        sampleRate: Double
    ) -> [String: Double]? {
        guard entitled(), sampleRate > 0, !leads.isEmpty else { return nil }
        var scores: [String: Double] = [:]
        for lead in leads where scores[lead.name] == nil {
            // First-of-duplicates only — the resolution's X96 rule; a
            // second same-named lead must not overwrite the score the
            // chooser will attribute to the first.
            scores[lead.name] = QRSDetector.qrsProminence(
                samples: lead.samples, sampleRate: sampleRate)
        }
        return scores
    }
}
```

Registration in `MurmurApp.swift`, inside the existing bootstrap Task
(next to `await bootstrapBaselineProducers()`):

```swift
// #357: the analysis-lead scorer — MurmurMetrics' QRS prominence,
// gated on the Studio entitlement at SCORE time (import time), so a
// free import records firstInFile and a Pro import records the score.
AnalysisLeadScoring.shared.register(
    QRSProminenceLeadScorer(entitled: {
        PurchaseStore.shared.ownedProductIDs.contains(.studio)
    })
)
```

Adapt the entitlement expression to `PurchaseStore`'s real API — if
`ownedProductIDs` is main-actor-isolated, capture it the way
`VTVFScanOrchestrator` reads its gate (copy that call site's pattern);
the closure runs on the import's detached task.

- [ ] **Step 4: Run the full suite; also build Release** (App-target change — the archive trap from Global Constraints).

- [ ] **Step 5: Commit**

```bash
git add Murmur/QRSProminenceLeadScorer.swift Murmur/MurmurApp.swift MurmurTests/AnalysisLeadTests.swift
git commit -m "Register the QRS-prominence analysis-lead scorer, entitlement-gated (#357)"
```

---

### Task 4: ArrhythmiaScanOrchestrator on the analysis lead

**Files:**
- Modify: `Murmur/ArrhythmiaScanOrchestrator.swift` (~lines 85–160)
- Test: `MurmurTests/ArrhythmiaPreflightTests.swift` or a new focused suite — whichever already exercises the orchestrator's caption; extend it.

**Interfaces:**
- Consumes: `recording.analysisLead(inBundle: directory)`, `recording.samples(of:inDirectory:)`.
- Produces: the scan runs on exactly the analysis lead; the derived-cache key carries the lead name; candidate lead attribution names the analysis lead.

- [ ] **Step 1: Read the whole orchestrator run function first** (it was excerpted in recon; the executor reads it all).

- [ ] **Step 2: Write the failing test.** The observable contract: the cache `parametersKey` must include the lead. Extract the key construction into a testable static:

```swift
@Test("The scan cache key carries the analysis lead — designating invalidates")
func scanCacheKeyCarriesLead() {
    let a = ArrhythmiaScanOrchestrator.cacheParametersKey(
        lowBpm: 40, highBpm: 120, minDurationSeconds: 10,
        minRunBeats: 5, analysisLeadName: "MLII")
    let b = ArrhythmiaScanOrchestrator.cacheParametersKey(
        lowBpm: 40, highBpm: 120, minDurationSeconds: 10,
        minRunBeats: 5, analysisLeadName: "V5")
    #expect(a != b)
}
```

(Requires `@testable import Murmur` or the app-hosted visibility from Task 3 — same mechanism.)

- [ ] **Step 3: Implement.** In the run function:

```swift
// #357: the scan runs on THE ANALYSIS LEAD, not on a per-run
// strongest-QRS pick over all leads — one designated channel for
// every calculation, disclosed once. Passing a single lead keeps
// ArrhythmiaScanService's API unchanged (its internal pick trivially
// selects the only lead given), and the A3 quality preflight runs on
// the same lead, as before.
guard let resolution = recording.analysisLead(inBundle: directory),
      let leadSamples = recording.samples(of: resolution.channel, inDirectory: directory)
else {
    await MainActor.run { scanContext.clearCandidates() }
    return
}
let leads = [leadSamples]
let sampleRate = resolution.channel.sampleRate
let analysisLeadName = resolution.channel.name
```

- Replace the old `leadNames`/`namesAligned` block: attribution is now
  always `analysisLeadName` (one lead, always aligned) — delete the
  mismatch path and its comment.
- Extend `parametersKey` via the new static
  `cacheParametersKey(lowBpm:highBpm:minDurationSeconds:minRunBeats:analysisLeadName:)`
  which appends `";lead=\(analysisLeadName)"`. A designation change
  therefore misses the cache and recomputes — stale results computed on
  the old lead are unreachable.
- `result.quality.leadUsed` is an index into the passed array (always
  0 now); wherever it fed a lead-name display, use `analysisLeadName`.

- [ ] **Step 4: Run the full suite.**

- [ ] **Step 5: Commit**

```bash
git add Murmur/ArrhythmiaScanOrchestrator.swift MurmurTests
git commit -m "Arrhythmia scan runs on the analysis lead; cache key carries it (#357)"
```

---

### Task 5: MorphologyOrchestrator + VTVFScanView on the analysis lead

**Files:**
- Modify: `Murmur/MorphologyOrchestrator.swift` (~lines 47, 84), `Murmur/VTVFScanView.swift` (~lines 84–85, 277), and its constructing orchestrator `Murmur/VTVFScanOrchestrator.swift` if the resolution is passed in.
- Test: extend the suites that cover these paths (`MorphologyModesTests` / `VTVFCandidateStoreTests` neighborhoods) with the same rigged-sidecar approach: write an `AnalysisLeadFile` designating the second channel into the test bundle, run the path, assert the second channel's data/name is used.

**Interfaces:**
- Consumes: Task 1's resolution + samples helpers.
- Produces: both features read the designated channel; their captions/labels name it.

- [ ] **Step 1: Write failing tests** — for each surface, the pattern:

```swift
// bundle with channels [A (distinctive samples), B (different samples)];
// designation → B. Run the orchestrator entry the existing tests use.
// Assert the published context/caption carries B's name, and (where the
// test can see samples) B's data.
```

Copy the fixture mechanics from whichever existing test in the target
suite already builds a bundle and runs the path — do not invent a new
fixture style.

- [ ] **Step 2: Implement.**
- `MorphologyOrchestrator` line ~47: `recording.primaryECGChannel` → resolution channel; line ~84 fallback `recording.primaryECGSamples(inDirectory:)` → `recording.samples(of: resolution.channel, inDirectory: directory)`.
- `VTVFScanView` lines 84–85: take the resolved channel (rate + name) from the resolution its constructor now receives (resolve in the orchestrator/caller where `directory` is in hand); line 277: `recording.samples(of: resolvedChannel, inDirectory: directory)`.
- If either path has a `BundleDerivedCache` key, append `;lead=<name>` exactly as Task 4 did.

- [ ] **Step 3: Run the full suite.** **Step 4: Commit**

```bash
git commit -am "Morphology and VT/VF read the analysis lead (#357)"
```

---

### Task 6: QT on the analysis lead — the methods change

**Files:**
- Modify: `Murmur/IntervalMarkingsOrchestrator.swift` (~lines 80–140), `MurmurCore/Recording.swift` (delete `conventionalQTChannels` + `conventionalQTLeads(inDirectory:)`), `MurmurCore/BeatCalipers.swift` (~line 278, the X25 lead disclosure)
- Delete/rewrite: `MurmurTests/ConventionalQTLeadTests.swift`
- Test: rewrite as `MurmurTests/AnalysisLeadQTTests.swift`

**Interfaces:**
- Consumes: the resolution; `MultiLeadQT.perLeadBeats`/`compose` (unchanged, fed one lead).
- Produces: QT measured on the analysis lead; disclosure string exactly `measured on <name> — not a conventional QT lead (II/V5)` when the name doesn't read as II/V5 (case/whitespace-insensitive equality, NO prefix stripping).

- [ ] **Step 1: Read `ConventionalQTLeadTests.swift` fully** — every behavior it pins either transfers (rewritten against the new contract) or dies with the name gate; list which in the commit message.

- [ ] **Step 2: Write the failing tests:**

```swift
@Suite("QT on the analysis lead (#357)")
struct AnalysisLeadQTTests {

    @Test("The conventional-name disclosure fires exactly on non-II/V5 names")
    func disclosureNameRule() {
        #expect(QTLeadDisclosure.annotation(forLeadNamed: "II") == nil)
        #expect(QTLeadDisclosure.annotation(forLeadNamed: " ii ") == nil)
        #expect(QTLeadDisclosure.annotation(forLeadNamed: "V5") == nil)
        // NO prefix stripping — the ML normaliser is gone. MLII honestly
        // discloses until a #358 declaration quiets the sentence.
        #expect(QTLeadDisclosure.annotation(forLeadNamed: "MLII")
            == "measured on MLII — not a conventional QT lead (II/V5)")
        #expect(QTLeadDisclosure.annotation(forLeadNamed: "V4")
            == "measured on V4 — not a conventional QT lead (II/V5)")
    }
}
```

- [ ] **Step 3: Implement.**
- New `QTLeadDisclosure` (small enum in `MurmurCore/AnalysisLead.swift`):

```swift
/// #357 §1.5 — the one permitted direction for lead names: disclosure.
/// "Reads as II/V5" is exact equality after uppercasing and stripping
/// whitespace; NO prefix stripping (the X108 ML normaliser is gone —
/// on MIT-BIH this honestly fires until the analyst declares MLII → II,
/// #358). The comparison never chooses a lead; it only writes a sentence.
public enum QTLeadDisclosure {
    public static func annotation(forLeadNamed name: String) -> String? {
        let normalized = name.uppercased().filter { !$0.isWhitespace }
        guard normalized != "II", normalized != "V5" else { return nil }
        return "measured on \(name.trimmingCharacters(in: .whitespaces)) — not a conventional QT lead (II/V5)"
    }
}
```

- `IntervalMarkingsOrchestrator`: replace the `conventionalLeads` /
  `legacySamples` block with the resolution + single-lead read;
  `leadName` = the analysis lead's name; delete the
  `qtWithheldReason = "QT: Conventional leads (II, V5) absent."` branch
  (QT always has a lead now — the abstention gates that remain are
  X109's, untouched); feed `MultiLeadQT.perLeadBeats` the one lead and
  `compose` its per-beat single-element arrays; attach
  `QTLeadDisclosure.annotation(forLeadNamed:)` to the context's
  citation/caption the way the multi-lead method note was attached
  (read how the citation string is built and extend it, don't invent a
  second channel for the sentence).
- Delete `conventionalQTChannels` and `conventionalQTLeads(inDirectory:)`
  from `Recording.swift`.
- `BeatCalipers.swift` ~278 (X25): the measured-lead line now renders
  from the resolution's name + provenance (Task 7 adds the full header
  line; here just keep the existing line compiling on the new source of
  the lead name).

- [ ] **Step 4: Run the full suite** — expect fallout in suites that
  referenced the deleted API; fix each by rewriting against the new
  contract, never by re-adding a name gate.

- [ ] **Step 5: Commit** — the message MUST state the methods change:

```bash
git commit -am "QT measures on the analysis lead — II+V5 composite retired (#357)

Methods change: the X108 conventional-lead composite (per-beat median
across II and V5) is replaced by a single-lead read on the designated
analysis lead; citations change wording, and records where II and V5
disagreed change numbers. Name checks survive only as disclosure."
```

---

### Task 7: Designation UI, header disclosure, re-run wiring

**Files:**
- Modify: `MurmurCore/ChannelPanel.swift` (the `.contextMenu` at ~line 641), `MurmurCore/BedsideView.swift` (thread the hooks; header line), `MurmurCore/BeatCalipers.swift` (~line 278 X25 line), `MurmurCore/CurrentRecordingContext.swift` (revision stamp), the orchestrators from Tasks 4–6 (`.task(id:)` gains the stamp)
- Test: `MurmurTests/AnalysisLeadTests.swift` (header text rendering; designation write path)

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces:
  - `CurrentRecordingContext.analysisLeadRevision: Int` — bumped after every designation write; orchestrator `.task(id:)` values include it so a designation re-runs every calculation.
  - `AnalysisLeadHeaderLine.text(for resolution: AnalysisLeadResolution, excludedSummary: String?) -> String` — pure, testable.
  - Context-menu entries: `Use as analysis lead` / `Revert to default (<name> — <reason phrase>)`.

- [ ] **Step 1: Write the failing header-line tests:**

```swift
@Suite("Analysis lead — header disclosure line")
struct AnalysisLeadHeaderLineTests {
    // Build resolutions directly (channel from any fixture recording).

    @Test("Designated") func designated() {
        // "analysis lead: V4 — designated by kevin, 2026-08-24"
        // (date via DateFormatter yyyy-MM-dd, en_US_POSIX, UTC)
    }
    @Test("Scored") func scored() {
        // "analysis lead: MLII — strongest R peaks"
        // with a per-lead excluded summary appended when provided:
        // "analysis lead: MLII — strongest R peaks (V5: 18% of beats excluded)"
    }
    @Test("First in file") func firstInFile() {
        // "analysis lead: MLII — first in file"
    }
    @Test("Stale designation is reported") func stale() {
        // resolution.staleDesignation = "V9" →
        // "designated lead V9 not in this record — using default" is
        // PREPENDED as its own sentence/segment.
    }
}
```

Write exact expected strings in the tests (they are the spec's §1.6
strings); the implementation renders them, not vice versa.

- [ ] **Step 2: Implement.**
- `AnalysisLeadHeaderLine` (pure, in `AnalysisLead.swift`): renders the
  four cases above. The `excludedSummary` parameter is supplied by the
  caller from the per-lead delineator exclusion counts where available
  (BeatCalipers' territory) — nil renders the score phrase alone.
- `BeatCalipers.swift` X25 line: replace/extend the measured-lead
  disclosure with `AnalysisLeadHeaderLine.text(...)` output.
- Designation write (in `BedsideView` or a small
  `AnalysisLeadDesignator` helper in core): read sidecar → set/clear
  `designation` (reviewer `ProcessInfo.processInfo.userName`, date now)
  → write → bump `CurrentRecordingContext.shared.analysisLeadRevision`.
  Revert deletes the `designation` section, keeps `defaultChoice`.
- `ChannelPanel` context menu, after the existing entries + `Divider()`:

```swift
// #357: designation is a per-lead assertion, so it lives on the
// lead's own right-click, beside the other authoring actions.
if let designation = analysisLeadHooks {
    Divider()
    if designation.isAnalysisLead {
        Button("Revert to default (\(designation.defaultLabel))") {
            designation.revertToDefault()
        }
        .accessibilityIdentifier("bedside-context-revert-analysis-lead")
    } else {
        Button("Use as analysis lead") { designation.designate() }
            .accessibilityIdentifier("bedside-context-designate-analysis-lead")
    }
}
```

  threaded from `BedsideView` exactly like `noteAuthoring` (a small
  hooks struct with `isAnalysisLead`, `defaultLabel`, `designate`,
  `revertToDefault`). Free tier gets the same menu — designation is an
  assertion, not a paid computation.
- Orchestrators (Tasks 4–6 files): add `analysisLeadRevision` to the
  `.task(id:)` tuple/whatever mechanism each uses to re-run on record
  change — copy each one's existing trigger shape.

- [ ] **Step 3: Run the full suite. Step 4: Release build (app-target UI changed). Step 5: Commit**

```bash
git commit -am "Designation context menu, header disclosure, re-run wiring (#357)"
```

Report honestly: the menu/header render paths are UI — XCUI cannot run
on this machine, so visual verification is the header-line unit tests
plus a manual `run the app` check; say so in the PR.

---

### Task 8: Review table, report, session package, schema docs

**Files:**
- Modify: `MurmurCore/ReviewTableBuilder.swift` (~line 75 context), `MurmurCore/MurSessionPackage.swift` (`analystSidecars` list, ~line 43), the Markdown report builder (find via `grep -rn "Markdown report\|reportBuilder" MurmurCore/`), `docs/annotation-schema.md`
- Test: `MurmurTests/ReviewTableTests.swift` (extend), `MurmurTests/MurSessionPackageTests.swift` (extend)

**Interfaces:**
- Consumes: resolution + provenance.
- Produces: per-record columns `analysis_lead` and `analysis_lead_reason` with values `r-peak score 0.91` / `analyst override — kevin` / `first in file`; the sidecar travels in `.mur`.

- [ ] **Step 1: Failing tests.**
- ReviewTable: build a source with a designated bundle and an undesignated one; assert both columns for both rows (exact strings above; score formatted to two decimals).
- Session: import → designate → save `.mur` → reopen into a fresh store → `AnalysisLeadFile.read` from the restored bundle shows the designation. Copy the round-trip mechanics from the existing package tests.

- [ ] **Step 2: Implement.**
- `ReviewTableBuilder`: resolve per record (it has recording + bundle directory in its `Source.imported`); never-imported rows leave the columns empty (they already contribute nothing — #330's rule).
- Reason strings from provenance:

```swift
// One vocabulary, shared with the header line — put this on
// AnalysisLeadProvenance in AnalysisLead.swift:
public var exportReason: String {
    switch self {
    case .designated(let reviewer, _): return "analyst override — \(reviewer)"
    case .rPeakScore(let score, _):    return String(format: "r-peak score %.2f", score)
    case .firstInFile:                 return "first in file"
    }
}
```

- `MurSessionPackage.analystSidecars`: add `(AnalysisLeadFile.bundleFileName, "dispositions")` — or a more honest subdir name if the tuple supports one; read the surrounding comment and follow it.
- `docs/annotation-schema.md`: document the two columns (name, values, provenance vocabulary, "empty = record never imported").

- [ ] **Step 3: Run the full suite. Step 4: Commit**

```bash
git commit -am "Analysis lead + reason in review table, report and .mur; schema documented (#357)"
```

---

### Task 9: End-to-end acceptance + the no-name-gate guard + boundary docs

**Files:**
- Test: `MurmurTests/AnalysisLeadTests.swift` (extend)
- Modify: `docs/what-murmur-asserts.md`

- [ ] **Step 1: End-to-end acceptance test** (the spec's §1.7 first bullet, with the REAL scorer):

```swift
@Test("Noisy ch0 / clean ch1 defaults to ch1 with score provenance, end-to-end")
@MainActor
func noisyFirstChannelDefaultsToClean() async throws {
    AnalysisLeadScoring.shared.register(QRSProminenceLeadScorer(entitled: { true }))
    defer { AnalysisLeadScoring.shared.clearForTesting() }
    // WFDBRecordWriter fixture: channel 0 = the LCG noise from Task 3's
    // test (scaled to Int32), channel 1 = the clean spike train.
    // Import via a temp RecordingStore. Then:
    // let resolution = summary.recording.analysisLead(inBundle: summary.directory)
    // #expect(resolution?.channel.name == "CLEAN")
    // if case .rPeakScore = resolution!.provenance {} else { Issue.record("expected score provenance") }
}
```

- [ ] **Step 2: The no-name-gate guard.** A source-level test (the repo
  precedent is code-shape tests like `LayoutFitSupport`'s): read the
  orchestrator + core calculation sources at test time and assert the
  banned shapes are absent:

```swift
@Test("No calculation path selects a channel by name or channels.first (#357)")
func noNameGatesInCalculationPaths() throws {
    // Files: ArrhythmiaScanOrchestrator, MorphologyOrchestrator,
    // IntervalMarkingsOrchestrator, VTVFScanView (app target sources,
    // read from the repo — resolve the path from #filePath).
    let banned = ["conventionalQTChannels", "primaryECGSamples(",
                  "channels.first", "hasPrefix(\"ML\")"]
    for file in calculationSources {
        let text = try String(contentsOf: file, encoding: .utf8)
        for pattern in banned {
            #expect(!text.contains(pattern),
                    "\(file.lastPathComponent) contains banned shape \(pattern)")
        }
    }
}
```

  (`primaryECGChannel` itself survives in display paths —
  `RecordListEntry`, `MurSessionPackage` — which is why the guard walks
  only the four calculation files. If `#filePath`-relative source
  reading proves brittle in the xctest workaround, scope the guard to
  what it can reach and say so in the PR — do not silently drop it.)

- [ ] **Step 3: `docs/what-murmur-asserts.md`** — add the one sentence
  (place it with the existing selection/assertion rules):

> Murmur never chooses, and never gates, a calculation by a lead's
> name; the analysis lead is designated by the analyst or defaulted by
> measured R-peak quality, and lead names appear only in disclosures.

- [ ] **Step 4: Full gate.** Both suites green via the workaround +
  `swift test`; Release build; then push, PR with write-up (include the
  §1.5 methods change and the XCUI-unverified UI caveat), merge per the
  standing flow; close #357 with a resolution comment naming the PR(s).

```bash
git commit -am "Acceptance: quality default end-to-end; no-name-gate guard; boundary doc (#357)"
```

---

## Self-review checklist (run after drafting, before executing)

- Spec §1.1–§1.7 each map to a task: 1.1→T1, 1.2→T1/T3, 1.3→T1/T2, 1.4→T4/T5/T6/T8, 1.5→T6, 1.6→T7/T8/T9, 1.7→T1–T9 tests. RecordListEntry deliberately untouched (display), per spec §1.4.
- Names used across tasks: `AnalysisLeadScoring.shared`, `AnalysisLeadFile.bundleFileName`, `analysisLead(inBundle:)`, `samples(of:inDirectory:)`, `QRSProminenceLeadScorer(entitled:)`, `analysisLeadRevision`, `exportReason` — consistent as written.
- Known adaptation points are called out inline (Channel initializer shape, PurchaseStore isolation, max(by:) tie order, app-type test visibility, report-builder location). These are executor checks, not open design questions.
