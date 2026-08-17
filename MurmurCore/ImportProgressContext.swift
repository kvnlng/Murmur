//
//  ImportProgressContext.swift
//  MurmurCore
//
//  Shared observable state carrying folder-import progress to the info bar
//  (#263, 12a Region 5). Same App-writes / MurmurCore-reads pattern as
//  `CurrentRecordingContext` and `VariabilityMetricsContext`: ContentView
//  owns the import pipeline and writes; the bedside's info bar reads.
//
//  Why a context rather than threading state down: the strip is GLOBAL.
//  12a calls it "the only chrome that changes state between empty and
//  loaded" — one strip for the whole window, not one per record pane — and
//  the import pipeline and the info bar live on opposite sides of the
//  ContentView/BedsideView boundary.
//
//  Imports are lazy and sequential (one sidebar click, one import), so at
//  most one record is in flight; `completedRecords of totalRecords` counts
//  the folder plan around it.
//

import Foundation
import Observation

@MainActor
@Observable
public final class ImportProgressContext {

    public static let shared = ImportProgressContext()

    /// The record currently importing, or nil when no import is in flight —
    /// which is the strip's mounted/unmounted state.
    public private(set) var recordName: String?
    /// 0…1 for the in-flight record. Clamped on write.
    public private(set) var fractionComplete: Double = 0
    /// Records of the folder plan already imported.
    public private(set) var completedRecords: Int = 0
    /// Records in the folder plan.
    public private(set) var totalRecords: Int = 0

    public var isActive: Bool { recordName != nil }

    public init() {}

    public func update(
        recordName: String,
        fractionComplete: Double,
        completedRecords: Int,
        totalRecords: Int
    ) {
        self.recordName = recordName
        self.fractionComplete = min(1, max(0, fractionComplete))
        self.completedRecords = completedRecords
        self.totalRecords = totalRecords
    }

    public func clear() {
        recordName = nil
        fractionComplete = 0
        completedRecords = 0
        totalRecords = 0
    }

    /// The strip's whole sentence — `synth-02 · 3 of 12 records · 41%` —
    /// composed here so it is testable, per the "a sentence nobody can test
    /// is how a control comes to lie" rule. Nil when no import is in flight.
    public var summary: String? {
        guard let recordName else { return nil }
        let pct = Int((fractionComplete * 100).rounded())
        let noun = totalRecords == 1 ? "record" : "records"
        return "\(recordName) · \(completedRecords) of \(totalRecords) \(noun) · \(pct)%"
    }
}
