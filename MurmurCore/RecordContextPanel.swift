//
//  RecordContextPanel.swift
//  Murmur
//
//  Scrollable context strip that sits alongside the bedside summary header,
//  occupying the full remaining width. Renders two pieces of waveform-level
//  context:
//
//    1. `.hea` `#` comment lines (immutable — they belong to the WFDB record).
//       MIT-BIH puts patient demographics + meds here.
//    2. Analyst-editable Markdown notes from `<bundle>/notes.md`.
//
//  Whether the body is editable is governed by the app-wide `isEditing` flag
//  controlled from the bedside toolbar — the same flag will gate annotation
//  edits when those are implemented. The panel never owns that state itself,
//  it just reads it.
//
//  Persistence is bundle-local. Edits write to `<bundle>/notes.md` with a
//  debounced save; a transition from editing → locked flushes immediately.
//

import SwiftUI

struct RecordContextPanel: View {
    let headerComments: [String]
    let notesURL: URL?
    let isEditing: Bool

    @State private var notesText: String = ""
    @State private var hasLoadedNotes: Bool = false
    @State private var saveTask: Task<Void, Never>?
    @State private var saveError: String?

    /// Tall enough to show 6-8 lines without growing; the analyst gets a real
    /// vertical scroll affordance for longer histories.
    private static let panelHeight: CGFloat = 96
    private static let saveDebounceNS: UInt64 = 600_000_000   // 0.6 s

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    if !headerComments.isEmpty {
                        headerCommentsBlock
                        if hasNotes || isEditing {
                            Divider()
                        }
                    }
                    if isEditing {
                        notesEditor
                    } else {
                        notesRender
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .task { await loadNotesIfNeeded() }
        .onChange(of: isEditing) { wasEditing, nowEditing in
            // Lock flips on (true → false): force any pending save right now
            // so the analyst's keystrokes are durable the moment they lock.
            if wasEditing && !nowEditing { flushSaveImmediately() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Context")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if isEditing {
                Text("• editing")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    // MARK: - Body — header comments

    private var headerCommentsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(headerComments.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Body — notes

    @ViewBuilder
    private var notesRender: some View {
        if notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("No analyst notes yet. Unlock the toolbar lock to add some.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if let attributed = renderMarkdown(notesText) {
            Text(attributed)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Text(notesText)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var notesEditor: some View {
        TextEditor(text: $notesText)
            .font(.caption.monospaced())
            .scrollContentBackground(.hidden)
            .frame(minHeight: 60)
            .onChange(of: notesText) { _, newValue in scheduleSave(newValue) }
            .accessibilityIdentifier("context-notes-editor")
    }

    private var hasNotes: Bool {
        !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - I/O

    private func loadNotesIfNeeded() async {
        guard !hasLoadedNotes else { return }
        hasLoadedNotes = true
        guard let url = notesURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        await MainActor.run { notesText = text }
    }

    /// Debounced auto-save while the analyst types.
    private func scheduleSave(_ text: String) {
        saveTask?.cancel()
        guard let url = notesURL else { return }
        saveTask = Task { [text] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNS)
            if Task.isCancelled { return }
            await persist(text: text, to: url)
        }
    }

    private func flushSaveImmediately() {
        saveTask?.cancel()
        guard let url = notesURL else { return }
        Task { await persist(text: notesText, to: url) }
    }

    private func persist(text: String, to url: URL) async {
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            await MainActor.run { saveError = nil }
        } catch {
            let message = error.localizedDescription
            await MainActor.run { saveError = "Save failed: \(message)" }
        }
    }

    // MARK: - Markdown

    /// Best-effort inline Markdown render. Falls back to plain text if the
    /// parser can't make sense of the input.
    private func renderMarkdown(_ source: String) -> AttributedString? {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return try? AttributedString(markdown: source, options: options)
    }
}
