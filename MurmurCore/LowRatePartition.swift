//
//  LowRatePartition.swift
//  Murmur
//
//  Splits the low-rate (`isTrendChannel == true`) subset of a recording's
//  channels into intent-based buckets so the bedside view can render each
//  kind in its own strip (vital trends, alarms, quality ratios, and the
//  ventilation-state probability pair).
//
//  Matching is name-based and reflects what the Medallion feature store
//  emits today; producers that want explicit control can name their
//  channels to opt in or out (e.g. naming a channel `notes_status` would
//  flag it as an alarm because of the `_status` suffix).
//

import Foundation

struct LowRatePartition {
    let trends: [Channel]
    let alarms: [Channel]
    let quality: [Channel]
    let spontaneous: Channel?
    let assistControl: Channel?

    init(channels: [Channel]) {
        var trends: [Channel] = []
        var alarms: [Channel] = []
        var quality: [Channel] = []
        var spontaneous: Channel? = nil
        var assist: Channel? = nil

        for channel in channels {
            let name = channel.name
            if name == "prob_state_spontaneous" {
                spontaneous = channel
            } else if name == "prob_state_assist_control" {
                assist = channel
            } else if Self.looksLikeAlarmFlag(name) {
                alarms.append(channel)
            } else if Self.looksLikeQualityRatio(name) {
                quality.append(channel)
            } else {
                trends.append(channel)
            }
        }

        self.trends = trends
        self.alarms = alarms
        self.quality = quality
        self.spontaneous = spontaneous
        self.assistControl = assist
    }

    /// Conservative — matches the Medallion-emitted alarm/status flags and
    /// any future channel whose name carries the same suffix.
    private static func looksLikeAlarmFlag(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("_alarm")
            || lower.hasSuffix("_status")
            || lower.hasSuffix("_silenced")
    }

    /// Quality / artifact-ratio channels — anything ending in `_ratio`
    /// or whose name contains `artifact_ratio`. The Medallion paper's
    /// canonical example is `ecg_artifact_ratio`.
    private static func looksLikeQualityRatio(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("_ratio") || lower.contains("artifact_ratio")
    }
}
