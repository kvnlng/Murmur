//
//  LeadPlacementSheet.swift
//  MurmurCore
//
//  #358 — the analyst declares what a recorded channel's NAME physically
//  meant: "MLII on this folder is limb lead II", "…but on this record it was
//  a front chest patch". A declaration is provenance attached to a name. It
//  is disclosure only: nothing in this file (or reachable from it) feeds a
//  calculation, a lead resolution, or a preset match — the jurisdiction rule
//  in `LeadPlacementMap.swift` §Jurisdiction applies verbatim here.
//
//  ## Plan ruling 3 — no suggestions
//
//  The field NEVER pre-fills a conventional reading of the channel's name,
//  and this file ships no table of lead names. The only thing that pre-fills
//  it is a declaration the analyst already made. A suggestion would be the
//  app asserting what a name means, which is precisely the assertion this
//  sheet exists to take FROM the analyst.
//
//  ## Scope
//
//  Two scopes, one field. Folder-wide is the baseline; "this record only"
//  writes an override that wins over it. Opening the sheet on a record that
//  has no override shows the FOLDER text (there is one declaration in view
//  at a time, the one that currently applies) — saving it under "this record
//  only" is how a per-record exception gets made from the baseline's wording.
//  A shell with no record id (a preview) offers folder scope alone.
//

import SwiftUI

/// The sheet's pure logic — what the field starts as, and what Save/Delete
/// do to a map. Split out of the `View` so the rules are pinned by unit
/// tests against a fresh `LeadPlacementMapContext()` rather than by an XCUI
/// run (and so no test ever needs `.shared`).
/// `@MainActor` because `LeadPlacementMapContext` is: every method here takes
/// the live map, and the sheet, the header and the tests all touch it from the
/// main actor already.
@MainActor
struct LeadPlacementSheetModel: Equatable {
    /// Which keying a save lands on. `.record` is only offered when
    /// `recordID != nil`; with a nil id the model REFUSES rather than
    /// quietly writing the folder-wide baseline, which is a different
    /// (and much broader) assertion than the one the analyst chose.
    enum Scope: Hashable, CaseIterable {
        case folder
        case record
    }

    /// The channel name as recorded — normalisation for lookup/storage is
    /// `LeadPlacementMapContext`'s business, so this is the display string,
    /// verbatim.
    let recordedName: String
    /// The navigator's record id (root-relative `.hea` path), the SAME id
    /// space `CarriedSessionStore`, `SessionFlagStore` and the cohort export
    /// key by. `nil` where the shell has no record id.
    let recordID: String?

    /// Whether the "this record only" scope can be offered at all.
    var canScopeToRecord: Bool { recordID != nil }

    /// The scope the sheet opens on: the record's own override when it has
    /// one, otherwise the folder-wide baseline (which is also where a first
    /// declaration lands — the folder is the general case).
    func initialScope(in map: LeadPlacementMapContext) -> Scope {
        guard let recordID,
              map.declaration(forRecordedName: recordedName, recordID: recordID)?.isOverride == true
        else { return .folder }
        return .record
    }

    /// What the field starts as: the declaration that CURRENTLY applies to
    /// this name on this record (override first, then folder baseline), or
    /// empty. Never a suggestion — plan ruling 3.
    func initialText(in map: LeadPlacementMapContext) -> String {
        map.declaration(forRecordedName: recordedName, recordID: recordID)?
            .declaration.placement ?? ""
    }

    /// The declaration standing at `scope` right now, if any — what the
    /// reviewer/date line reports and what Delete would withdraw. Scoped
    /// exactly: a folder baseline is NOT reported as the record's own.
    func existingDeclaration(
        in map: LeadPlacementMapContext,
        scope: Scope
    ) -> LeadPlacementDeclaration? {
        switch scope {
        case .folder:
            return map.declaration(forRecordedName: recordedName, recordID: nil)?.declaration
        case .record:
            guard let recordID,
                  let hit = map.declaration(forRecordedName: recordedName, recordID: recordID),
                  hit.isOverride
            else { return nil }
            return hit.declaration
        }
    }

    /// Write the analyst's assertion at `scope`. A whitespace-only string is
    /// a withdrawal, not a declaration of nothing — `declare` already routes
    /// it to `deleteDeclaration`, so the sheet needs no separate rule.
    func save(_ placement: String, scope: Scope, in map: LeadPlacementMapContext) {
        switch scope {
        case .folder:
            map.declare(recordedName: recordedName, placement: placement, recordID: nil)
        case .record:
            guard let recordID else { return }
            map.declare(recordedName: recordedName, placement: placement, recordID: recordID)
        }
    }

    /// Withdraw the declaration at `scope`. Deleting a record override leaves
    /// the folder baseline standing — that is the point of the two scopes.
    func delete(scope: Scope, in map: LeadPlacementMapContext) {
        switch scope {
        case .folder:
            map.deleteDeclaration(recordedName: recordedName, recordID: nil)
        case .record:
            guard let recordID else { return }
            map.deleteDeclaration(recordedName: recordedName, recordID: recordID)
        }
    }
}

struct LeadPlacementSheet: View {
    /// The channel being declared about. Held as a name, not a `Channel`:
    /// the map keys by recorded name, and an empty channel is as declarable
    /// as a populated one (declaring is a statement about the folder's
    /// wiring, not about samples).
    let recordedName: String
    let recordID: String?
    /// The live map. Injected rather than reached for, so previews and any
    /// future view-level test can pass their own instance — `.shared` is the
    /// caller's (BedsideView's) choice, exactly as with every other #358
    /// read site.
    let map: LeadPlacementMapContext
    var onDismiss: () -> Void

    @State private var placement: String = ""
    @State private var scope: LeadPlacementSheetModel.Scope = .folder

    private var model: LeadPlacementSheetModel {
        LeadPlacementSheetModel(recordedName: recordedName, recordID: recordID)
    }

    private var existing: LeadPlacementDeclaration? {
        model.existingDeclaration(in: map, scope: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Declare placement — \(recordedName)")
                .font(.headline)
            Text("What this channel's name means physically — where the electrodes "
                 + "actually were. Recorded as your assertion, with your name and "
                 + "today's date, and disclosed beside the lead. It changes no "
                 + "measurement.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.canScopeToRecord {
                Picker("Applies to", selection: $scope) {
                    Text("Everywhere in this folder").tag(LeadPlacementSheetModel.Scope.folder)
                    Text("This record only").tag(LeadPlacementSheetModel.Scope.record)
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("lead-placement-scope")
            }

            // Plan ruling 3: the prompt describes the FIELD, it does not
            // suggest a reading of the channel's name.
            TextField("Placement", text: $placement, prompt: Text("Where these electrodes were"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("lead-placement-field")

            if let existing {
                Text("Declared by \(existing.reviewer), "
                     + "\(AnalysisLeadHeaderLine.dateString(existing.declaredAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lead-placement-provenance")
            } else {
                Text("Not declared at this scope yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                if existing != nil {
                    Button("Delete", role: .destructive) {
                        model.delete(scope: scope, in: map)
                        onDismiss()
                    }
                    .accessibilityIdentifier("lead-placement-delete")
                }
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("lead-placement-cancel")
                Button("Declare") {
                    model.save(placement, scope: scope, in: map)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("lead-placement-save")
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            scope = model.initialScope(in: map)
            placement = model.initialText(in: map)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lead-placement-sheet")
    }
}
