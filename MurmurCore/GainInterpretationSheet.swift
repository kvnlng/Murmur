//
//  GainInterpretationSheet.swift
//  MurmurCore
//
//  X16 (#19) — the analyst's per-channel gain reinterpretation. Stored
//  samples are physical mV as the source header's gain converted them; when
//  that header gain was wrong, every amplitude is off by a constant factor.
//  This sheet records the analyst's correction — true mV = stored × factor —
//  as a bundle-manifest fact, WITHOUT rewriting a byte of sample data.
//
//  Entry is either the factor directly or the true counts/mV (against the
//  header's claimed value, shown for audit); the two fields are views of the
//  same assertion and stay in sync.
//

import SwiftUI

struct GainInterpretationSheet: View {
    let channel: Channel
    var onApply: (Double?) -> Void
    var onCancel: () -> Void

    @State private var factorText: String = ""

    private var parsedFactor: Double? {
        guard let value = Double(factorText.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The counts/mV the analyst's factor implies: stored values were
    /// counts ÷ headerGain, so reading them as true mV at factor f means the
    /// converter SHOULD have divided by headerGain ÷ f.
    private var impliedCountsPerUnit: Double? {
        guard let header = channel.headerGainCountsPerUnit,
              let factor = parsedFactor else { return nil }
        return header / factor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interpret gain — \(channel.name)")
                .font(.headline)
            Text("True mV = stored × factor. Sample data is never rewritten; "
                 + "the factor is recorded in the recording bundle with the header's "
                 + "claimed gain as provenance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("Factor")
                TextField("1.0", text: $factorText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .accessibilityIdentifier("gain-sheet-factor")
                Text("×").foregroundStyle(.secondary)
            }
            .font(.callout)

            if let header = channel.headerGainCountsPerUnit {
                Text(String(format: "Header said %g counts/%@%@",
                            header,
                            channel.unit.isEmpty ? "mV" : channel.unit,
                            impliedCountsPerUnit.map {
                                String(format: " · your factor implies %g", $0)
                            } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("gain-sheet-header-gain")
            } else {
                Text("Header gain unknown (imported before it was recorded).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                if channel.appliedGainFactor != 1 {
                    Button("Clear correction") { onApply(nil) }
                        .accessibilityIdentifier("gain-sheet-clear")
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("gain-sheet-cancel")
                Button("Apply") {
                    if let factor = parsedFactor { onApply(factor) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsedFactor == nil)
                .accessibilityIdentifier("gain-sheet-apply")
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            if let factor = channel.analystGainFactor {
                factorText = String(format: "%g", factor)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gain-interpretation-sheet")
    }
}
