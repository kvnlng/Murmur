//
//  LeadPresetManagerSheet.swift
//  MurmurCore
//
//  Rename and delete saved lead presets (#332).
//
//  Only the analyst's own sets appear. Built-ins are compiled in and cannot be
//  renamed or removed, so listing them here — greyed out, refusing every
//  action offered beside them — would be a list that is mostly inert.
//

import SwiftUI

struct LeadPresetManagerSheet: View {
    let store: LeadPresetStore
    let onClose: () -> Void

    /// The preset being renamed, and the text mid-edit. Committed on blur or
    /// return, so there is no per-row Save button to forget to press.
    @State private var editingID: LeadPreset.ID?
    @State private var editingName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Lead Presets")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if store.userPresets.isEmpty {
                // Reachable by deleting the last one while the sheet is open.
                Text("No saved presets. Stage the leads you want, then "
                     + "“Save current selection as preset…”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                List {
                    ForEach(store.allPresets.filter { !$0.isBuiltIn }) { preset in
                        row(for: preset)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 160)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { commitEdit(); onClose() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("lead-preset-manage-done")
            }
            .padding(16)
        }
        .frame(width: 380)
    }

    private func row(for preset: LeadPreset) -> some View {
        HStack(spacing: 8) {
            if editingID == preset.id {
                TextField("Name", text: $editingName, onCommit: commitEdit)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("lead-preset-rename-field")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.body.weight(.medium))
                    // The leads, verbatim and in order — the order IS the
                    // preset (first is primary), so it is shown rather than
                    // sorted for tidiness.
                    Text(preset.leads.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Rename") {
                    commitEdit()
                    editingID = preset.id
                    editingName = preset.name
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("lead-preset-rename-\(preset.id.uuidString)")
                Button("Delete", role: .destructive) {
                    if editingID == preset.id { editingID = nil }
                    store.remove(preset.id)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("lead-preset-delete-\(preset.id.uuidString)")
            }
        }
        .padding(.vertical, 2)
    }

    private func commitEdit() {
        guard let editingID else { return }
        store.rename(editingID, to: editingName)
        self.editingID = nil
    }
}
