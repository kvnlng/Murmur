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
