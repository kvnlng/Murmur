//
//  CSVImportDialog.swift
//  MurmurCore
//
//  The import dialog for a header-LESS CSV — the RUO metadata surface per
//  project_csv_import_spec.md. The asserted rate / units / leads are a CLAIM,
//  not hidden state: the analyst inspects + corrects them here BEFORE commit,
//  and a refusal states its single reason. `num_channels` is authoritative from
//  the file's detected column count, so it's shown, not typed.
//
//  The draft emits the same key/value shape a `#` header block would, so both
//  metadata sources validate through one path (CSVImport.metadata(fromKeyValues:)).
//

import SwiftUI

struct CSVImportDialog: View {
    let fileName: String
    /// Total columns detected (index + signals).
    let columnCount: Int
    /// Non-nil when a previous attempt refused — shown so the analyst can fix
    /// the metadata rather than starting over.
    let refusalMessage: String?
    let onImport: (CSVImport.Draft) -> Void
    let onCancel: () -> Void

    @State private var draft: CSVImport.Draft

    init(
        fileName: String,
        columnCount: Int,
        refusalMessage: String?,
        onImport: @escaping (CSVImport.Draft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.fileName = fileName
        self.columnCount = columnCount
        self.refusalMessage = refusalMessage
        self.onImport = onImport
        self.onCancel = onCancel
        var seed = CSVImport.Draft()
        let signalCount = max(0, columnCount - 1)
        seed.leadNamesCSV = (1...max(1, signalCount)).map { "ch\($0)" }.joined(separator: ", ")
        _draft = State(initialValue: seed)
    }

    private var signalCount: Int { max(0, columnCount - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import CSV — \(fileName)")
                .font(.headline)
                .padding([.top, .horizontal])
            Text("\(columnCount) columns detected: 1 index + \(signalCount) signal\(signalCount == 1 ? "" : "s"). These values are your assertion about the signal — check them before importing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding([.horizontal, .top], 8)
                .padding(.horizontal)

            Form {
                Section("Timing") {
                    Picker("Index column", selection: $draft.indexKind) {
                        Text("Sample number").tag(CSVImport.IndexKind.sampleNumber)
                        Text("Time (seconds)").tag(CSVImport.IndexKind.timeSeconds)
                    }
                    TextField("Sample rate (Hz)", text: $draft.sampleRateHz)
                        .help(draft.indexKind == .sampleNumber
                              ? "Required — a sample-number index carries no rate."
                              : "Optional — cross-checked against the time column's step.")
                }
                Section("Leads") {
                    TextField("Lead names (comma-separated)", text: $draft.leadNamesCSV)
                        .help("One name per signal column (I, II, V1…, or ch1…). Must be \(signalCount).")
                }
                Section("Amplitude") {
                    Picker("Encoding", selection: $draft.isPhysical) {
                        Text("ADC counts").tag(false)
                        Text("Physical").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Unit", text: $draft.physicalUnit)
                    if !draft.isPhysical {
                        TextField("ADC resolution (bits)", text: $draft.adcResolutionBits)
                        TextField("ADC gain (0 = unspecified)", text: $draft.adcGain)
                        TextField("ADC baseline", text: $draft.adcBaseline)
                    }
                }
                Section("Missing values") {
                    Picker("Sentinel", selection: $draft.sentinel) {
                        Text("None").tag(CSVImport.Draft.SentinelChoice.none)
                        Text("Empty cell").tag(CSVImport.Draft.SentinelChoice.emptyCell)
                        Text("NaN").tag(CSVImport.Draft.SentinelChoice.nan)
                        Text("Integer").tag(CSVImport.Draft.SentinelChoice.integer)
                    }
                    if draft.sentinel == .integer {
                        TextField("Sentinel integer", text: $draft.sentinelInteger)
                    }
                }
            }
            .formStyle(.grouped)

            if let refusalMessage {
                Text(refusalMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .accessibilityIdentifier("csv-import-refusal")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { onImport(draft) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("csv-import-confirm")
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .accessibilityIdentifier("csv-import-dialog")
    }
}
