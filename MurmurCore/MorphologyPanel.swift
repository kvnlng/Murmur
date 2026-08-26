//
//  MorphologyPanel.swift
//  MurmurCore
//
//  X112 (#188) — the Morphology section's editor column in the Context
//  drawer: one card per cluster (median-complex thumbnail, burden, QRS
//  width, annotator codes), each carrying Endorse-as-baseline /
//  Withdraw-endorsement behind the same Editing + Studio latch as every
//  authoring surface. RUO: neutral ink, geometric names, no severity, no
//  recommendation of which cluster to pick — the algorithm clusters, the
//  human classifies.
//
//  An endorsement that no longer matches any recomputed cluster renders as
//  an orphan row (withdraw stays available) — surfaced, never silently
//  dropped.
//

import SwiftUI

struct MorphologyPanel: View {
    let summary: MorphologySummary
    @Binding var endorsements: [MorphologyEndorsement]
    let isEditing: Bool

    /// Live purchase observation so a mid-session purchase flips the latch
    /// without relaunch (FindingsPanel pattern).
    @State private var purchaseStore = PurchaseStore.shared

    private var canAuthor: Bool { isEditing && purchaseStore.hasStudio }

    /// #381: the attachment verdicts come published from the App's
    /// orchestrator (paid distance) — this panel only sorts them.
    @State private var morphologyContext = MorphologyContext.shared

    /// Endorsement indices keyed by the card they re-attach to; the
    /// leftovers are orphans. While the verdicts for the current
    /// (summary, endorsements) pair are still resolving, nothing is
    /// attached and nothing is tagged orphan — a transient blank beats a
    /// wrong verdict.
    private var attachments: (byCard: [Int: [Int]], orphans: [Int]) {
        guard let verdicts = morphologyContext.attachments else { return ([:], []) }
        var byCard: [Int: [Int]] = [:]
        var orphans: [Int] = []
        for (index, endorsement) in endorsements.enumerated() {
            switch verdicts[endorsement] {
            case .some(.some(let card)): byCard[card, default: []].append(index)
            case .some(.none): orphans.append(index)
            case .none: break   // not resolved yet — no verdict to render
            }
        }
        return (byCard, orphans)
    }

    var body: some View {
        let attached = attachments
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.cards) { card in
                        clusterCard(card, endorsementIndices: attached.byCard[card.id] ?? [])
                    }
                    ForEach(attached.orphans, id: \.self) { index in
                        orphanRow(endorsementIndex: index)
                    }
                    if let remainder = summary.remainderCaption {
                        Text(remainder)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityIdentifier("morphology-remainder")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            Divider()
            Text(summary.provenance)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("morphology-provenance")
            Text("The algorithm clusters; the analyst classifies. Endorsements save with the session (⌘S).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("morphology-panel")
    }

    // MARK: - Cluster card

    private func clusterCard(_ card: MorphologyClusterCard, endorsementIndices: [Int]) -> some View {
        let isEndorsed = !endorsementIndices.isEmpty
        return HStack(alignment: .top, spacing: 8) {
            thumbnail(card.representative)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.title).font(.caption.weight(.semibold))
                    Text(card.burden).font(.caption2).foregroundStyle(.secondary)
                }
                if let qrs = card.qrsWidth {
                    Text(qrs).font(.caption2).foregroundStyle(.secondary)
                }
                if let codes = card.annotatorCodes {
                    Text(codes).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                if isEndorsed, let date = endorsementIndices
                    .compactMap({ endorsements.indices.contains($0) ? endorsements[$0].endorsedAt : nil })
                    .min() {
                    Text("Endorsed as baseline · \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            endorsementButton(card: card, endorsementIndices: endorsementIndices)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("morphology-cluster-row-\(card.id)")
        // XCUI-readable state leaf — an .accessibilityValue on a
        // children:.contain container does not read reliably (FindingsPanel
        // precedent).
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityIdentifier("morphology-cluster-state-\(card.id)")
                .accessibilityLabel(isEndorsed ? "endorsed" : "not endorsed")
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func endorsementButton(card: MorphologyClusterCard, endorsementIndices: [Int]) -> some View {
        if endorsementIndices.isEmpty {
            Button("Endorse as baseline") {
                endorsements.append(MorphologyEndorsement(
                    representative: card.representative, endorsedAt: Date()))
            }
            .font(.caption2)
            .disabled(!canAuthor)
            .help(canAuthor
                  ? "Endorse this cluster as a patient baseline — recorded with date, saved with the session"
                  : "Unlock Editing (and Pro) to endorse a baseline")
            .accessibilityIdentifier("morphology-endorse-\(card.id)")
        } else {
            Button("Withdraw endorsement") {
                removeEndorsements(at: endorsementIndices)
            }
            .font(.caption2)
            .disabled(!canAuthor)
            .help(canAuthor
                  ? "Withdraw this baseline endorsement — reverts to the unadjudicated annotator-normal template"
                  : "Unlock Editing (and Pro) to withdraw an endorsement")
            .accessibilityIdentifier("morphology-withdraw-\(card.id)")
        }
    }

    private func orphanRow(endorsementIndex index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Endorsed baseline no longer matches any cluster in this record"
                 + " (endorsed \(endorsements[index].endorsedAt.formatted(date: .abbreviated, time: .omitted)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Withdraw") {
                removeEndorsements(at: [index])
            }
            .font(.caption2)
            .disabled(!canAuthor)
            .help(canAuthor
                  ? "Withdraw the orphaned endorsement"
                  : "Unlock Editing (and Pro) to withdraw an endorsement")
            .accessibilityIdentifier("morphology-orphan-withdraw-\(index)")
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("morphology-orphan-row-\(index)")
    }

    private func removeEndorsements(at indices: [Int]) {
        for index in indices.sorted(by: >) where endorsements.indices.contains(index) {
            endorsements.remove(at: index)
        }
    }

    // MARK: - Thumbnail

    /// The cluster's median complex as a small polyline. Geometry only —
    /// normalized amplitude, no grid, no calipers: this is a shape the
    /// analyst compares against other shapes, not a measurement surface.
    private func thumbnail(_ representative: [Float]) -> some View {
        Canvas { context, size in
            guard representative.count > 1,
                  let minValue = representative.min(),
                  let maxValue = representative.max(),
                  maxValue > minValue else { return }
            let span = CGFloat(maxValue - minValue)
            var path = Path()
            for (i, value) in representative.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(representative.count - 1)
                let y = size.height * (1 - (CGFloat(value) - CGFloat(minValue)) / span)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.secondary), lineWidth: 1)
        }
        .frame(width: 52, height: 30)
        .accessibilityHidden(true)
    }
}
