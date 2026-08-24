//
//  ArrhythmiaScanCacheKey.swift
//  Murmur (app target)
//
//  Pure derived-cache key builder for the arrhythmia scan (A2, #357).
//  Split out of ArrhythmiaScanOrchestrator as a standalone, dependency-free
//  static so it's testable from MurmurTests via the symlink pattern
//  (QRSProminenceLeadScorer.swift) — the orchestrator itself can't be
//  symlinked in, since its body references app-only context types
//  (CurrentRecordingContext, ArrhythmiaScanContext, PurchaseStore, …) that
//  are invisible outside the app target without `@testable import Murmur`,
//  which MurmurTests never does.
//

import Foundation

enum ArrhythmiaScanCacheKey {
    /// The bundle-cache `parametersKey` for the arrhythmia scan. Carries
    /// the analysis lead's name (#357) so a designation change can never
    /// re-serve results computed on the old lead — the key simply misses
    /// and the scan recomputes.
    static func make(
        lowBpm: Double,
        highBpm: Double,
        minDurationSeconds: Double,
        minRunBeats: Int,
        analysisLeadName: String
    ) -> String {
        "low=\(lowBpm);high=\(highBpm);"
            + "minDur=\(minDurationSeconds);minRun=\(minRunBeats);"
            + "lead=\(analysisLeadName)"
    }
}
