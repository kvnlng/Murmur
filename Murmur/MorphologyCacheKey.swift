//
//  MorphologyCacheKey.swift
//  Murmur (app target)
//
//  Pure derived-cache key builder for the morphology panel (X112, #357).
//  Split out of MorphologyOrchestrator as a standalone, dependency-free
//  static so it's testable from MurmurTests via the symlink pattern
//  (QRSProminenceLeadScorer.swift, ArrhythmiaScanCacheKey.swift) — the
//  orchestrator itself can't be symlinked in, since its body references
//  app-only context types (CurrentRecordingContext, MorphologyContext,
//  PurchaseStore, …) that are invisible outside the app target without
//  `@testable import Murmur`, which MurmurTests never does.
//

import Foundation

enum MorphologyCacheKey {
    /// The bundle-cache `parametersKey` for the morphology summary. No
    /// analyst dial feeds the compute, but the lead it ran over can change
    /// (morphology reads the analysis lead unconditionally, #357) — the key
    /// carries that lead's name so a designation change can never re-serve
    /// a summary computed on the old lead.
    static func make(analysisLeadName: String) -> String {
        "lead=\(analysisLeadName)"
    }
}
