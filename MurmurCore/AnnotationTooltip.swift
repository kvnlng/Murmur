//
//  AnnotationTooltip.swift
//  Murmur
//
//  Floating panel rendered next to the cursor when hovering over a finding
//  on the waveform canvas. Shows the producer's note, confidence, source,
//  and a category-colored severity dot — the full context the analyst would
//  otherwise have to scroll the findings panel to see.
//
//  Lives in its own file (extracted from BedsideView) so the bedside view
//  stays under the file-length lint limit.
//

import SwiftUI

struct AnnotationTooltip: View {
    let annotation: Annotation
    let sampleRate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(CategoryPalette.swiftUIColor(for: annotation.category))
                    .frame(width: 8, height: 8)
                Text(annotation.displayLabel)
                    .font(.caption.weight(.semibold))
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(annotation.severity.rawValue.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(timeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let conf = annotation.confidence {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(String(format: "conf %.0f%%", conf * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(annotation.source)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let note = annotation.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
        )
    }

    private var timeLabel: String {
        guard sampleRate > 0 else { return "—" }
        let startSec = Double(annotation.sampleIndex) / sampleRate
        if let endSample = annotation.endSampleIndex, annotation.kind == .range {
            let endSec = Double(endSample) / sampleRate
            return String(format: "%.2f s – %.2f s", startSec, endSec)
        }
        return String(format: "@ %.2f s", startSec)
    }
}
