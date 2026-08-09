//
//  RUOFirstRunNotice.swift
//  MurmurCore
//
//  The one-time, first-launch research-use-only disclosure (X4b).
//
//  Relationship to the two-RUO-surface rule: that rule governs PER-OUTPUT
//  RUO badges — the chrome painted next to model/detector output — and it
//  still admits exactly two (the findings-queue candidate-group badge and
//  the VT/VF scan-dialog badge). This notice is deliberately NOT an output
//  badge: it speaks once, about the APP's posture (what the app is and is
//  not), before any output exists, and never again. Keeping the two kinds
//  distinct is what lets both stay credible — badges stay scarce at the
//  point of output, and the app-level disclosure doesn't multiply.
//
//  The wording is facts, not verdicts, in the same register as the rest
//  of the app: what Murmur presents, what it is not, what that means for
//  its output. No scare framing, no legalese wall — one screen, one
//  acknowledgement.
//

import SwiftUI

public enum RUOFirstRunNotice {
    /// UserDefaults key for the acknowledgement. A plain bool: the notice
    /// states the app's standing posture, not a versioned agreement — if
    /// the posture itself ever changes, that's a new key, not a re-prompt.
    public static let acknowledgedDefaultsKey = "hasAcknowledgedRUONotice"

    public static let title = "Research use only"

    /// The disclosure body, one fact per paragraph.
    public static let paragraphs: [String] = [
        "Murmur presents measurements, detector output, and annotations from ECG recordings for research and review.",
        "It is not a medical device. Nothing it displays is a diagnosis, and its output must not be used for clinical decision-making.",
        "Where the app shows algorithm or model output, it is labelled RUO and framed as a candidate for your review — never a conclusion.",
    ]

    public static let acknowledgeLabel = "I understand"

    /// Whether the notice should present at launch. Pure so the gate is
    /// testable:
    ///  - `forcedByTest` (the `--ui-test-first-run-ruo` bypass) always
    ///    presents, regardless of stored state — XCUI runs share the app
    ///    container's defaults, so a stored acknowledgement from an earlier
    ///    run must not make the test flaky.
    ///  - Any OTHER UI-test run suppresses it: every existing test would
    ///    otherwise meet a modal it never asked for.
    ///  - Normal launches present it exactly until acknowledged.
    public static func shouldPresent(
        hasAcknowledged: Bool,
        isUITestRun: Bool,
        forcedByTest: Bool
    ) -> Bool {
        if forcedByTest { return true }
        if isUITestRun { return false }
        return !hasAcknowledged
    }
}

/// The sheet content. The acknowledge button is the only way out — the
/// notice is one click, once, so an escape-dismissal that silently
/// re-queues it for next launch would just be a worse version of itself.
public struct RUOFirstRunView: View {
    let onAcknowledge: () -> Void

    public init(onAcknowledge: @escaping () -> Void) {
        self.onAcknowledge = onAcknowledge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(RUOFirstRunNotice.title)
                    .font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(RUOFirstRunNotice.paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(RUOFirstRunNotice.acknowledgeLabel, action: onAcknowledge)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ruo-first-run-acknowledge")
            }
        }
        .padding(24)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ruo-first-run-notice")
    }
}
