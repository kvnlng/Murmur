//
//  LowRatePartition.swift
//  Murmur
//
//  Picks out the low-rate (`isTrendChannel == true`) channels the bedside
//  view actually renders: the heart-rate trend, and the quality / artifact
//  ratios.
//
//  Matching is name-based and reflects what the Medallion feature store
//  emits today; producers that want explicit control can name their channels
//  to opt in (e.g. `heart_rate_bpm` lands in `heartRate`).
//
//  X66 narrowed this. It used to bucket four kinds — vital trends, alarm
//  flags, quality ratios, and the ventilation-state probability pair — one
//  strip each. The main-window redesign keeps a single HR lane and the
//  quality lane, so alarms, the state pair, and the non-HR vitals (SpO₂,
//  etCO₂, tidal volume…) are no longer rendered anywhere. They still IMPORT
//  — `WFDBImporter` reads every signal and `isTrendChannel` still classifies
//  them — they simply have no lane. That asymmetry is deliberate: dropping
//  them from the importer would lose data a producer supplied, while
//  dropping them from the view is the design decision (see
//  `Planning/design/design_handoff_murmur_main_window/DECISIONS.md` §2).
//

import Foundation

struct LowRatePartition {
    /// The record's heart-rate trend, if it carries one. The HR lane renders
    /// only when this is non-nil — the design's "trend channel only" caption
    /// is literal, and HR is never derived from beats here.
    let heartRate: Channel?

    /// Continuous quality / artifact-ratio channels.
    let quality: [Channel]

    init(channels: [Channel]) {
        var heartRate: Channel?
        var quality: [Channel] = []

        for channel in channels {
            if heartRate == nil, Self.looksLikeHeartRate(channel.name) {
                heartRate = channel
            } else if Self.looksLikeQualityRatio(channel.name) {
                quality.append(channel)
            }
        }

        self.heartRate = heartRate
        self.quality = quality
    }

    /// Conservative — matches `HR_bpm` (what the synthetic fixture and the
    /// Medallion tables emit) and the spelled-out form, without swallowing
    /// other rates. Deliberately NOT unit-based: a respiratory rate is also
    /// reported in "bpm", and labelling breaths as heart rate would be a
    /// clinical misstatement, not a cosmetic one.
    private static func looksLikeHeartRate(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "hr" || lower.hasPrefix("hr_") || lower.contains("heart_rate")
    }

    /// Quality / artifact-ratio channels — anything ending in `_ratio`
    /// or whose name contains `artifact_ratio`. The Medallion paper's
    /// canonical example is `ecg_artifact_ratio`.
    private static func looksLikeQualityRatio(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("_ratio") || lower.contains("artifact_ratio")
    }
}
