//
//  CorpusScanContext.swift
//  MurmurCore
//
//  Shared observable state carrying corpus-scan progress to the launch
//  shell (#329). Same App-writes / MurmurCore-reads pattern as
//  `ImportProgressContext`, and for the same reason: `ContentView` owns the
//  scan and the launch shell's empty-state line is where it has to show.
//
//  Why a scan needs progress at all: before #329 the picker read ONE
//  directory and returned in milliseconds. Honouring a `RECORDS` index means
//  parsing every header in the corpus — 45,152 of them for PhysioNet's
//  `ecg-arrhythmia` — off the main actor, over seconds. A window that sits
//  still for that long reads as a hang, and the analyst has no way to tell
//  the difference between "working" and "the folder was wrong".
//
//  The count is deliberately the only number: a scan cannot know its total
//  until it has walked the tree, so a percentage would be invented.
//

import Foundation
import Observation

@MainActor
@Observable
public final class CorpusScanContext {
    public static let shared = CorpusScanContext()

    /// Folder being scanned, or nil when no scan is in flight — which is
    /// this context's whole mounted/unmounted state.
    public private(set) var folderName: String?
    /// Records found so far. Updated in batches by the scanner, not per file.
    public private(set) var recordsFound: Int = 0

    public var isActive: Bool { folderName != nil }

    public init() {}

    public func begin(folderName: String) {
        self.folderName = folderName
        self.recordsFound = 0
    }

    /// Ignored when no scan is in flight, so a late callback from a scan the
    /// analyst already superseded cannot resurrect the status line.
    public func update(recordsFound: Int) {
        guard folderName != nil else { return }
        self.recordsFound = max(0, recordsFound)
    }

    public func clear() {
        folderName = nil
        recordsFound = 0
    }

    /// The line the launch shell renders — `Scanning ecg-arrhythmia… 4,500
    /// records`. Composed here so it is testable rather than assembled inline
    /// in a view, per the "a sentence nobody can test is how a control comes
    /// to lie" rule. Nil when no scan is in flight.
    public var summary: String? {
        guard let folderName else { return nil }
        guard recordsFound > 0 else { return "Scanning \(folderName)…" }
        let count = Self.formatter.string(from: NSNumber(value: recordsFound))
            ?? String(recordsFound)
        return "Scanning \(folderName)… \(count) \(recordsFound == 1 ? "record" : "records")"
    }

    /// Grouped thousands: at corpus scale a bare `45152` is harder to read at
    /// a glance than `45,152`, and this line exists to be glanced at.
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
