//
//  EctopyAnalysis.swift
//  MurmurCore
//
//  Structural analysis of ventricular ectopy over the annotation stream:
//  burden (ectopic beats as a fraction of total beats) and consecutive-run
//  grouping (isolated / couplet / triplet / run-of-N). Same class of purely
//  structural summary as AnnotationClustering / AnnotationSummary — it counts
//  what the annotator already marked and states coordinates, and it NEVER
//  composes a clinical verdict: a run of three is "3 consecutive ventricular
//  beats at 4:12", never "NSVT". No threshold, no severity axis, neutral
//  everywhere. (C7 / X29)
//
//  Pure function: no rendering, no environment access. The counting is over
//  the annotator's own labels, so it stays inside the free viewer's
//  read-only remit (no arithmetic on physiological measurements — this is
//  arithmetic on the label stream, like the existing summary chips).
//
//  Boundary ruling (#385): KEEP in MurmurCore, including the one step the
//  paragraph above anticipates as a judgment call — converting a run's
//  median RR to bpm for its caption. That conversion states the run's own
//  coordinates in the unit an analyst reads (caption-tier display
//  arithmetic, same class as BeatHeartRateSeries); it feeds no analysis
//  and composes no verdict.
//

import Foundation

struct EctopyRunSummary: Equatable {
    /// Ventricular-ectopic beats (V / PVC), counted across the recording.
    let ectopicBeatCount: Int
    /// Total beat annotations — the burden denominator. Non-beat markers
    /// (rhythm `+`, noise `~`, artifact `|`, comment `"`) are excluded.
    let totalBeatCount: Int
    /// Ectopic beats as a fraction of total beats (0…1); zero when no beats.
    let burdenFraction: Double
    /// Isolated ectopic beats (a length-1 run, i.e. a single V between
    /// non-ectopic beats).
    let isolatedCount: Int
    /// Consecutive-ectopic runs of length ≥ 2, in time order.
    let runs: [Run]

    struct Run: Equatable, Identifiable {
        /// Start sample index doubles as a stable identity (runs can't share
        /// a start).
        var id: Int64 { startSampleIndex }
        let startSampleIndex: Int64
        let length: Int
        /// Median R–R interval WITHIN the run, in samples (a run of N beats
        /// bounds N−1 intervals). X110 (§1.5): a "run of 4" could be
        /// NSVT-range or AIVR-range — the count alone doesn't say, so the
        /// run's own rate travels with it. Median, not mean: robust to one
        /// aberrant interval, same policy as every other rate on screen.
        let medianRRSamples: Int64

        /// Factual, non-verdict descriptor. Never "NSVT" / "salvo".
        var kindLabel: String {
            switch length {
            case 2:  return "couplet"
            case 3:  return "triplet"
            default: return "run of \(length)"
            }
        }

        /// The run's own rate (bpm) from its median internal R–R. Nil when
        /// the sample rate is unknown — no rate is better than a wrong one.
        func rateBpm(sampleRate: Double) -> Double? {
            guard sampleRate > 0, medianRRSamples > 0 else { return nil }
            return 60.0 * sampleRate / Double(medianRRSamples)
        }
    }

    var burdenPercent: Double { burdenFraction * 100 }
    var hasEctopy: Bool { ectopicBeatCount > 0 }
    var coupletCount: Int { runs.filter { $0.length == 2 }.count }
    var tripletCount: Int { runs.filter { $0.length == 3 }.count }
    var longRunCount: Int { runs.filter { $0.length >= 4 }.count }

    static let empty = EctopyRunSummary(
        ectopicBeatCount: 0, totalBeatCount: 0, burdenFraction: 0,
        isolatedCount: 0, runs: []
    )
}

extension EctopyRunSummary {
    /// X110 (§1.5): the run clauses for the burden line, each carrying its
    /// class's rate — "1 couplet · 150 bpm", "3 triplets · 132–161 bpm" —
    /// and runs of ≥ 4 (the NSVT-vs-AIVR ambiguity the review names) listed
    /// INDIVIDUALLY with their own rates while few, collapsing to a
    /// count + range only past four. Facts beside counts, never a verdict.
    func runClauses(sampleRate: Double) -> [String] {
        var clauses: [String] = []
        if let clause = Self.classClause(
            runs.filter { $0.length == 2 }, singular: "couplet",
            plural: "couplets", sampleRate: sampleRate) {
            clauses.append(clause)
        }
        if let clause = Self.classClause(
            runs.filter { $0.length == 3 }, singular: "triplet",
            plural: "triplets", sampleRate: sampleRate) {
            clauses.append(clause)
        }
        let long = runs.filter { $0.length >= 4 }
        if long.count > 4 {
            if let clause = Self.classClause(
                long, singular: "run of ≥4", plural: "runs of ≥4",
                sampleRate: sampleRate) {
                clauses.append(clause)
            }
        } else {
            for run in long {
                clauses.append(run.rateBpm(sampleRate: sampleRate)
                    .map { String(format: "%@ · %.0f bpm", run.kindLabel, $0) }
                    ?? run.kindLabel)
            }
        }
        return clauses
    }

    private static func classClause(
        _ classRuns: [Run], singular: String, plural: String, sampleRate: Double
    ) -> String? {
        guard !classRuns.isEmpty else { return nil }
        let count = classRuns.count
        var clause = count == 1 ? "1 \(singular)" : "\(count) \(plural)"
        let rates = classRuns.compactMap { $0.rateBpm(sampleRate: sampleRate) }
        if let lo = rates.min(), let hi = rates.max() {
            clause += lo.rounded() == hi.rounded()
                ? String(format: " · %.0f bpm", lo)
                : String(format: " · %.0f–%.0f bpm", lo, hi)
        }
        return clause
    }
}

enum EctopyAnalyzer {

    /// MIT-BIH beat-annotation symbols — the burden denominator. Case-sensitive
    /// per the WFDB standard (`a` aberrated-atrial and `A` atrial-premature are
    /// both beats; `s` ST-change is NOT a beat while `S` supraventricular is).
    /// Producer word-aliases (PVC / APC) are accepted alongside the symbols.
    static let beatSymbols: Set<String> = [
        "N", "L", "R", "B", "A", "a", "J", "S", "V",
        "r", "F", "e", "j", "n", "E", "/", "f", "Q", "?",
        "PVC", "APC"
    ]

    /// Ventricular-ectopic beats. Escape (`E`) is deliberately excluded — it's
    /// a late beat, not ectopy (see the annotation-code fidelity work). Fusion
    /// (`F`) is intermediate by construction and also excluded from burden.
    static let ventricularEctopicSymbols: Set<String> = ["V", "PVC"]

    static func summarize(_ annotations: [Annotation]) -> EctopyRunSummary {
        let beats = annotations
            .filter { beatSymbols.contains($0.category.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.sampleIndex < $1.sampleIndex }
        guard !beats.isEmpty else { return .empty }

        func isEctopic(_ ann: Annotation) -> Bool {
            ventricularEctopicSymbols.contains(ann.category.trimmingCharacters(in: .whitespaces))
        }

        var ectopic = 0
        var isolated = 0
        var runs: [EctopyRunSummary.Run] = []

        var i = 0
        while i < beats.count {
            guard isEctopic(beats[i]) else { i += 1; continue }
            // Maximal run of consecutive ectopic beats (non-beat markers were
            // already filtered out, so interspersed `+`/`~` don't split a run).
            var j = i
            while j < beats.count, isEctopic(beats[j]) { j += 1 }
            let length = j - i
            ectopic += length
            if length == 1 {
                isolated += 1
            } else {
                let intervals = (i + 1..<j)
                    .map { beats[$0].sampleIndex - beats[$0 - 1].sampleIndex }
                    .sorted()
                let mid = intervals.count / 2
                let median = intervals.count % 2 == 1
                    ? intervals[mid]
                    : (intervals[mid - 1] + intervals[mid]) / 2
                runs.append(.init(startSampleIndex: beats[i].sampleIndex,
                                  length: length,
                                  medianRRSamples: median))
            }
            i = j
        }

        return EctopyRunSummary(
            ectopicBeatCount: ectopic,
            totalBeatCount: beats.count,
            burdenFraction: Double(ectopic) / Double(beats.count),
            isolatedCount: isolated,
            runs: runs
        )
    }
}
