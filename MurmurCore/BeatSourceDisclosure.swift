//
//  BeatSourceDisclosure.swift
//  MurmurCore
//
//  Why the beat-derived surfaces are absent (#206).
//
//  Variability Metrics, the Trend stack's beat lanes, and Morphology all read
//  annotator-coded beats out of the WFDB `.atr`. Murmur has no beat detector,
//  so on a record whose annotations are rhythm-only — every record in vfdb,
//  and afdb-style records whose beats live in a sibling file — those surfaces
//  had no input and each one silently unmounted. Header and all: not
//  empty-with-a-caption, absent.
//
//  Each gate was individually reasonable. X95's silence rule in particular was
//  written for a case where "there is nothing to sell the analyst and nothing
//  they can dial to change the answer", which assumed the emptiness would be
//  self-evident. On a 35-minute record with a full review queue and a rhythm
//  panel reading `Rhythms N · VFL`, it is the opposite of self-evident — the
//  record is plainly working, so half the measurement surfaces vanishing reads
//  as a broken import rather than as a property of the data.
//
//  So: state the absence, and name the missing INPUT rather than the missing
//  output. "No beats" is a fact about the record the analyst can act on;
//  "metrics unavailable" is a fact about the app that they cannot. Where a
//  sibling beat file is sitting right there unread, saying its name is the
//  difference between a dead end and a next step.
//
//  Same honesty pattern as the QT lead-absence line and the
//  `unadjudicated — annotator-coded` caption: this costs no new pipeline and
//  makes no measurement. It turns a silent hole into a stated fact.
//

import SwiftUI

/// Why a record carries no annotator-coded beats.
public enum BeatSourceAbsence: Equatable, Sendable {
    /// The `.atr` is present and populated, but every annotation in it is a
    /// rhythm change or other non-beat event. The confusing case: the review
    /// queue is full, so nothing else on screen suggests a missing input.
    case rhythmAnnotationsOnly(rhythmCount: Int)
    /// No WFDB annotations at all — the trace is the whole record.
    case noAnnotations
}

/// One line where the beat-derived surfaces would have been.
///
/// Deliberately not styled as an error. Nothing has gone wrong: this is a
/// property of the record, and the analyst who opened a vfdb record to see
/// what the detector saw is not looking at a failure.
public struct BeatSourceDisclosure: View {

    let absence: BeatSourceAbsence
    /// A beat file sitting beside the record that Murmur does not read, e.g.
    /// `418.qrs`. Named when present because for afdb-style records this is
    /// the entire answer — the beats exist, in a file the importer ignores.
    let siblingBeatFileName: String?

    public init(absence: BeatSourceAbsence, siblingBeatFileName: String? = nil) {
        self.absence = absence
        self.siblingBeatFileName = siblingBeatFileName
    }

    /// A WFDB beat file sitting beside the record that the importer does not
    /// read — `.qrs` (reference) or `.wqrs` (the `wqrs` detector's output).
    ///
    /// afdb is the case that matters: its `.atr` is rhythm-only exactly like
    /// vfdb's, but its beats are right there in a sibling file. Naming it
    /// turns "this record has no beats" into "this record's beats are in a
    /// file Murmur doesn't open", which is a different sentence for whoever
    /// decides what the importer reads next.
    ///
    /// Existence only — nothing here parses the file or promises it would
    /// work if read.
    public static func siblingBeatFileName(
        forRecordNamed name: String,
        in directory: URL
    ) -> String? {
        ["qrs", "wqrs"]
            .map { "\(name).\($0)" }
            .first { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("No annotator-coded beats in this record")
                    .font(.subheadline.weight(.semibold))
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let siblingBeatFileName {
                Text("Beats may be in \(siblingBeatFileName), beside the record — Murmur reads beats only from the .atr.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("beat-source-sibling-file")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("beat-source-disclosure")
    }

    /// Names the surfaces by the label the analyst sees them under, so the
    /// line answers the question they actually have — "where did Variability
    /// Metrics go" — rather than describing a pipeline they cannot see.
    private var explanation: String {
        let missing = "Variability Metrics, the Trend stack's beat lanes, and Morphology need them."
        switch absence {
        case .rhythmAnnotationsOnly(let rhythmCount):
            let markers = "\(rhythmCount) rhythm marker\(rhythmCount == 1 ? "" : "s")"
            return "The .atr carries \(markers) and no beats. \(missing)"
        case .noAnnotations:
            return "This record has no WFDB annotations. \(missing)"
        }
    }
}
