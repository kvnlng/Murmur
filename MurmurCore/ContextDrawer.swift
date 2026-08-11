//
//  ContextDrawer.swift
//  MurmurCore
//
//  The expanded Context region (X72) — the two-column drawer of design 8a/9a:
//  a list of everything the record says about itself, and an editor for the
//  row the analyst has selected.
//
//  The list carries THREE kinds of row, and they persist on three different
//  schedules the drawer states rather than hides (DECISIONS §4):
//
//    - the `.hea` comment block — immutable, belongs to the WFDB record;
//    - `notes.md` — the record-level document, autosaved bundle-local with a
//      0.6 s debounce, flushed the moment Editing re-locks (exactly the old
//      `RecordContextPanel` behaviour, rehomed);
//    - anchored notes — SESSION work product in `MurSessionState`, written by
//      File ▸ Save Session and never autosaved. The wireframe's "Saved · 2 s
//      ago · 0.6 s debounce" footer is FALSE for these rows and is replaced
//      by an unsaved-state indicator pointing at ⌘S.
//
//  Editability is governed by the app-wide Editing latch, same as every other
//  analyst edit; the drawer never owns that state.
//

import SwiftUI

/// Which row of the drawer's list is open in the editor column.
enum ContextDrawerSelection: Hashable {
    case hea
    case document
    case morphology
    case note(UUID)
}

struct ContextDrawer: View {
    /// `.hea` `#` comment lines — immutable record property.
    let headerComments: [String]
    /// `<bundle>/notes.md`, or nil when the record reserves no notes file.
    let notesURL: URL?
    @Binding var notes: [AnchoredNote]
    @Binding var selection: ContextDrawerSelection?
    let isEditing: Bool
    /// Bound to BedsideView's `@FocusState` so the bedside key commands
    /// disable themselves while the analyst is typing here (X22).
    var editorFocus: FocusState<Bool>.Binding
    /// Anchor coordinates speak primary-channel samples; these convert them
    /// to the analyst's chosen time base (X28 — never a synthesised clock).
    let sampleRate: Double
    let hasAbsoluteStartTime: Bool
    let startUnixMillis: Int64?
    /// The current viewport, for `New note` and `Re-anchor to current window`.
    let currentWindow: ClosedRange<Int64>
    /// The focused lead, recorded as provenance on a new anchor.
    let currentLeadName: String?
    /// The anchored notes as of the last session save/restore — the unsaved
    /// indicator compares against this. `nil` reads as an empty baseline.
    let savedNotes: [AnchoredNote]?
    /// X112 — the computed morphology clusters, or nil when there is nothing
    /// to show (no entitlement, no annotated beats). The row and editor
    /// mount only when present.
    let morphologySummary: MorphologySummary?
    /// X112 — the analyst's endorsements: session work product owned by
    /// BedsideView, same lifecycle as `notes`.
    @Binding var morphologyEndorsements: [MorphologyEndorsement]
    var onJump: (AnchoredNote) -> Void

    @State private var searchText = ""
    @State private var sortByEdited = false
    // notes.md document state — ported from RecordContextPanel (X72 retired
    // that view; this column is its successor, same identifiers, same I/O).
    @State private var documentText: String = ""
    @State private var hasLoadedDocument = false
    @State private var documentSaveTask: Task<Void, Never>?
    @State private var documentSaveError: String?

    private static let bodyHeight: CGFloat = 214
    private static let listWidth: CGFloat = 288
    private static let documentSaveDebounceNS: UInt64 = 600_000_000   // 0.6 s

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controlsRow
            HStack(alignment: .top, spacing: 10) {
                listColumn
                editorColumn
            }
            .frame(height: Self.bodyHeight)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
        .task { await loadDocumentIfNeeded() }
        .onChange(of: isEditing) { wasEditing, nowEditing in
            // Lock flips on: flush the document save immediately so the
            // analyst's keystrokes are durable the moment they lock. Anchored
            // notes have no equivalent — they are not autosaved at all.
            if wasEditing && !nowEditing { flushDocumentSave() }
        }
    }

    // MARK: - Header controls

    /// Stepper + New note. The disclosure lives on the collapsed bar above;
    /// the Editing latch lives in the toolbar — not duplicated here, one
    /// control per state.
    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button {
                step(by: -1)
            } label: { Image(systemName: "chevron.left") }
                .disabled(notes.isEmpty)
                .accessibilityIdentifier("notes-drawer-previous")
            Button {
                step(by: 1)
            } label: { Image(systemName: "chevron.right") }
                .disabled(notes.isEmpty)
                .accessibilityIdentifier("notes-drawer-next")
            Text(stepperReadout)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notes-drawer-stepper-readout")

            Spacer(minLength: 8)

            Button {
                createNote()
            } label: {
                Label("New note at \(windowLabel(currentWindow))", systemImage: "plus")
                    .font(.caption)
            }
            .disabled(!isEditing)
            .help(isEditing
                  ? "Anchor a note to the current window"
                  : "Unlock Editing to add notes")
            .accessibilityIdentifier("notes-drawer-new-note")

            // X84: the location-less kind — record-level, no anchor. Both
            // kinds are creatable here AND from the trace's right-click menu.
            Button {
                createRecordNote()
            } label: {
                Label("Record note", systemImage: "doc.badge.plus")
                    .font(.caption)
            }
            .disabled(!isEditing)
            .help(isEditing
                  ? "Add a record-level note — about the whole recording, no anchor"
                  : "Unlock Editing to add notes")
            .accessibilityIdentifier("notes-drawer-new-record-note")
        }
        .buttonStyle(.borderless)
    }

    private var stepperReadout: String {
        guard !sortedNotes.isEmpty else { return "no notes" }
        guard case .note(let id)? = selection,
              let index = sortedNotes.firstIndex(where: { $0.id == id }) else {
            return "\(sortedNotes.count) note\(sortedNotes.count == 1 ? "" : "s")"
        }
        return "\(index + 1) of \(sortedNotes.count)"
    }

    private func step(by delta: Int) {
        guard let next = Self.stepped(notes: sortedNotes, selection: selection, by: delta) else { return }
        selection = .note(next.id)
        onJump(next)
    }

    /// The stepping rule, shared with BedsideView's ⌥J/⌥K commands (which
    /// cannot call into this view instance). Anchor order, wrapping; with no
    /// current note selected, forward starts at the first note and backward
    /// at the last.
    static func stepped(
        notes ordered: [AnchoredNote],
        selection: ContextDrawerSelection?,
        by delta: Int
    ) -> AnchoredNote? {
        guard !ordered.isEmpty else { return nil }
        var index = delta < 0 ? ordered.count - 1 : 0
        if case .note(let id)? = selection,
           let current = ordered.firstIndex(where: { $0.id == id }) {
            index = (current + delta + ordered.count) % ordered.count
        }
        return ordered[index]
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("Search notes", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .accessibilityIdentifier("notes-drawer-search")
                Menu(sortByEdited ? "Edited" : "Time") {
                    Button("Time") { sortByEdited = false }
                    Button("Edited") { sortByEdited = true }
                }
                .font(.caption2)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("notes-drawer-sort")
            }
            .padding(6)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if !headerComments.isEmpty {
                        fixedRow(
                            selection: .hea,
                            icon: "pin.fill",
                            title: ".hea comments",
                            badge: "read-only",
                            preview: headerComments.joined(separator: " · "),
                            identifier: "note-row-hea"
                        )
                    }
                    if notesURL != nil {
                        fixedRow(
                            selection: .document,
                            icon: "doc.text",
                            title: "notes.md",
                            badge: "record document",
                            preview: firstLine(of: documentText) ?? "No analyst notes yet.",
                            identifier: "note-row-document"
                        )
                    }
                    if let morphology = morphologySummary {
                        fixedRow(
                            selection: .morphology,
                            icon: "waveform.path.ecg",
                            title: "Morphology",
                            badge: "\(morphology.cards.count) cluster\(morphology.cards.count == 1 ? "" : "s")",
                            preview: morphologyPreview(morphology),
                            identifier: "note-row-morphology"
                        )
                    }
                    ForEach(Array(filteredNotes.enumerated()), id: \.element.id) { index, note in
                        noteRow(note, index: index)
                    }
                }
            }
            Divider()
            Text("Selecting a row moves the trace to its anchor.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(6)
        }
        .frame(width: Self.listWidth)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-drawer-list")
    }

    private func fixedRow(
        selection target: ContextDrawerSelection,
        icon: String,
        title: String,
        badge: String,
        preview: String,
        identifier: String
    ) -> some View {
        Button {
            selection = target
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.caption.weight(.semibold))
                        Text(badge).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(preview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selection == target ? Color.accentColor.opacity(0.15) : .clear)
        .accessibilityIdentifier(identifier)
    }

    private func noteRow(_ note: AnchoredNote, index: Int) -> some View {
        Button {
            selection = .note(note.id)
            // X84: a record-level note has no anchor — selecting it edits
            // it, and the trace stays where the analyst left it.
            if !note.isLocationless { onJump(note) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The anchored kind carries the accent dot the bands echo;
                // the record-level kind carries a hollow one — same column,
                // visibly not a location.
                Circle()
                    .fill(note.isLocationless ? Color.clear : Color.accentColor)
                    .stroke(Color.accentColor, lineWidth: note.isLocationless ? 1 : 0)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(note.isLocationless ? "Record note" : timeLabel(note.startSample))
                            .font(.caption.weight(.semibold).monospacedDigit())
                        Spacer(minLength: 4)
                        Text(note.isLocationless ? "no anchor" : durationLabel(note))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(firstLine(of: note.text) ?? "Empty note")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selection == .note(note.id) ? Color.accentColor.opacity(0.15) : .clear)
        // Positional, not UUID-based (X98). The UUID id forced tests to find
        // anchored rows with a BEGINSWITH predicate — and XCUI serves plain
        // identifier matches cheaply but pays a full-app snapshot (~20 s in
        // this app) for EVERY evaluation of an opaque predicate, which made
        // one drawer test spend 139 of 163 s in a single query. A stable
        // "first anchored row" address costs nothing to look up; rows are in
        // list order, so `note-row-anchored-0` is the top row after sort.
        .accessibilityIdentifier("note-row-anchored-\(index)")
    }

    private var filteredNotes: [AnchoredNote] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sortedNotes }
        return sortedNotes.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// X112 — what the collapsed Morphology row says: adjudication state
    /// first, because that is the fact the drawer exists to surface.
    private func morphologyPreview(_ morphology: MorphologySummary) -> String {
        let endorsed = morphologyEndorsements.count
        if endorsed == 0 {
            return "unadjudicated — no baseline endorsed"
        }
        return "\(endorsed) baseline\(endorsed == 1 ? "" : "s") endorsed"
    }

    private var sortedNotes: [AnchoredNote] {
        sortByEdited
            ? notes.sorted { $0.modifiedAt > $1.modifiedAt }
            : notes.sorted { $0.startSample < $1.startSample }
    }

    // MARK: - Editor column

    @ViewBuilder
    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch selection {
            case .hea:
                heaEditor
            case .morphology:
                if let morphology = morphologySummary {
                    MorphologyPanel(
                        summary: morphology,
                        endorsements: $morphologyEndorsements,
                        isEditing: isEditing)
                } else {
                    // The summary vanished under the selection (record swap).
                    placeholder("Select a row to read or edit it.")
                }
            case .note(let id):
                if let index = notes.firstIndex(where: { $0.id == id }) {
                    noteEditor(index: index)
                } else {
                    // Selection outlived its note (deleted elsewhere).
                    placeholder("Select a row to read or edit it.")
                }
            case .document, nil:
                if notesURL != nil {
                    documentEditor
                } else {
                    placeholder("Select a row to read or edit it.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-drawer-editor")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The .hea block — read-only, and the footer says whose fault that is.
    private var heaEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(headerComments.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary.opacity(0.85))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            Divider()
            Text("Read-only — these lines belong to the WFDB record header.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // notes.md — the record-level document, exactly the old RecordContextPanel
    // behaviour: debounced bundle-local autosave, flush on re-lock.
    private var documentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing {
                TextEditor(text: $documentText)
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .focused(editorFocus)
                    .onChange(of: documentText) { _, newValue in
                        scheduleDocumentSave(newValue)
                    }
                    .accessibilityIdentifier("context-notes-editor")
            } else {
                ScrollView {
                    renderedMarkdown(
                        documentText,
                        empty: "No analyst notes yet. Unlock the toolbar lock to add some."
                    )
                    .padding(8)
                }
            }
            Divider()
            HStack(spacing: 6) {
                if let documentSaveError {
                    Text(documentSaveError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else {
                    Text("Autosaved · 0.6 s debounce to notes.md in the record bundle · flushed when Editing re-locks.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func noteEditor(index: Int) -> some View {
        let note = notes[index]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(windowLabel(note.startSample...max(note.startSample, note.endSample)))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .accessibilityIdentifier("note-anchor-chip")
                Text(anchorCaption(note))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Jump to anchor") { onJump(note) }
                    .font(.caption)
                    .accessibilityIdentifier("note-jump")
                Button("Re-anchor to current window") {
                    notes[index].startSample = currentWindow.lowerBound
                    notes[index].endSample = currentWindow.upperBound
                    notes[index].leadName = currentLeadName
                    notes[index].modifiedAt = Date()
                }
                .font(.caption)
                .disabled(!isEditing)
                .accessibilityIdentifier("note-reanchor")
            }
            .buttonStyle(.borderless)

            if isEditing {
                TextEditor(text: Binding(
                    get: { notes[index].text },
                    set: { newValue in
                        notes[index].text = newValue
                        notes[index].modifiedAt = Date()
                    }
                ))
                .font(.caption)
                .scrollContentBackground(.hidden)
                .focused(editorFocus)
                .accessibilityIdentifier("anchored-note-editor")
            } else {
                ScrollView {
                    renderedMarkdown(note.text, empty: "Empty note. Unlock Editing to write it.")
                        .padding(8)
                }
            }

            Divider()
            HStack(spacing: 8) {
                // DECISIONS §4: the wireframe's "Saved · 2 s ago · 0.6 s
                // debounce" is FALSE here — anchored notes are session work
                // product and only ⌘S makes them durable.
                Text(anchoredSaveStatus)
                    .font(.caption2)
                    .foregroundStyle(hasUnsavedNotes ? Color.orange : Color.secondary.opacity(0.8))
                    .accessibilityIdentifier("note-save-status")
                Spacer(minLength: 8)
                Toggle("Include in exported report", isOn: Binding(
                    get: { notes[index].includeInReport ?? false },
                    set: { notes[index].includeInReport = $0 }
                ))
                .font(.caption2)
                .toggleStyle(.checkbox)
                .disabled(!isEditing)
                .accessibilityIdentifier("note-include-toggle")
                Button("Delete note", role: .destructive) {
                    let id = note.id
                    notes.removeAll { $0.id == id }
                    selection = nil
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .disabled(!isEditing)
                .accessibilityIdentifier("note-delete")
            }
        }
    }

    private var hasUnsavedNotes: Bool {
        notes != (savedNotes ?? [])
    }

    private var anchoredSaveStatus: String {
        hasUnsavedNotes
            ? "Not saved yet — anchored notes save with the session: File ▸ Save Session (⌘S)."
            : "Saved with the session. Anchored notes are not autosaved."
    }

    private func anchorCaption(_ note: AnchoredNote) -> String {
        // X84: the location-less kind states its scope instead of inventing
        // a zero-length range at sample 0.
        if note.isLocationless { return "record-level — no anchor" }
        let span = durationLabel(note)
        if let lead = note.leadName {
            return "anchored to a \(span) range in lead \(lead)"
        }
        return "anchored to a \(span) range"
    }

    // MARK: - New note

    private func createNote() {
        let now = Date()
        let note = AnchoredNote(
            startSample: currentWindow.lowerBound,
            endSample: currentWindow.upperBound,
            leadName: currentLeadName,
            createdAt: now,
            modifiedAt: now
        )
        notes.append(note)
        selection = .note(note.id)
    }

    /// X84 — the location-less kind. No anchor, no lead provenance: the note
    /// is about the RECORD, and stamping the currently-focused lead on it
    /// would claim a scope it doesn't have.
    private func createRecordNote() {
        let now = Date()
        let note = AnchoredNote(
            startSample: 0,
            endSample: 0,
            createdAt: now,
            modifiedAt: now,
            isRecordLevel: true
        )
        notes.append(note)
        selection = .note(note.id)
    }

    // MARK: - Time labels

    private func timeLabel(_ sample: Int64) -> String {
        guard sampleRate > 0 else { return "—" }
        let mode = TimeDisplayContext.shared.effectiveMode(hasAbsoluteStart: hasAbsoluteStartTime)
        return ViewportTimeFormat.coordinate(
            Double(sample) / sampleRate, mode: mode, startUnixMillis: startUnixMillis
        )
    }

    private func windowLabel(_ range: ClosedRange<Int64>) -> String {
        "\(timeLabel(range.lowerBound))–\(timeLabel(range.upperBound))"
    }

    private func durationLabel(_ note: AnchoredNote) -> String {
        guard sampleRate > 0 else { return "—" }
        let seconds = Double(max(0, note.endSample - note.startSample)) / sampleRate
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        return String(format: "%.1f h", seconds / 3600)
    }

    private func firstLine(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.components(separatedBy: .newlines).first
    }

    // MARK: - Markdown render (shared by document + note read views)

    @ViewBuilder
    private func renderedMarkdown(_ source: String, empty: String) -> some View {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(empty)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let attributed = try? AttributedString(
            markdown: source,
            options: {
                var options = AttributedString.MarkdownParsingOptions()
                options.interpretedSyntax = .inlineOnlyPreservingWhitespace
                return options
            }()
        ) {
            Text(attributed)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Text(source)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - notes.md I/O (ported from RecordContextPanel)

    private func loadDocumentIfNeeded() async {
        guard !hasLoadedDocument else { return }
        hasLoadedDocument = true
        guard let url = notesURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        await MainActor.run { documentText = text }
    }

    private func scheduleDocumentSave(_ text: String) {
        documentSaveTask?.cancel()
        guard let url = notesURL else { return }
        documentSaveTask = Task { [text] in
            try? await Task.sleep(nanoseconds: Self.documentSaveDebounceNS)
            if Task.isCancelled { return }
            await persistDocument(text: text, to: url)
        }
    }

    private func flushDocumentSave() {
        documentSaveTask?.cancel()
        guard let url = notesURL else { return }
        Task { await persistDocument(text: documentText, to: url) }
    }

    private func persistDocument(text: String, to url: URL) async {
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            await MainActor.run { documentSaveError = nil }
        } catch {
            let message = error.localizedDescription
            await MainActor.run { documentSaveError = "Save failed: \(message)" }
        }
    }
}
