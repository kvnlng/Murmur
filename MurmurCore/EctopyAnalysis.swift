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

        /// Factual, non-verdict descriptor. Never "NSVT" / "salvo".
        var kindLabel: String {
            switch length {
            case 2:  return "couplet"
            case 3:  return "triplet"
            default: return "run of \(length)"
            }
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
                runs.append(.init(startSampleIndex: beats[i].sampleIndex, length: length))
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
