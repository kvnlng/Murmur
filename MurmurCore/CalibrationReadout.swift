//
//  CalibrationReadout.swift
//  MurmurCore
//
//  The persistent calibration readout (X40 phase 1). Always visible, never
//  hover-dependent (X33's lesson) — it is the piece that delivers the
//  "feeling of understanding" of what you are looking at, in clinical units.
//  Neutral ink, factual coordinates, no amber, no severity: it states
//  coordinates, it never interprets, so it adds no RUO surface. Renders beside
//  the viewport indicator (X33) rather than inventing a second location.
//
//  Takes a pre-computed `CalibrationReading` so it stays trivially
//  snapshot-testable; the geometry → clinical-units math lives in
//  `CalibrationReading.make`.
//

import SwiftUI

struct CalibrationReadout: View {
    let reading: CalibrationReading

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "ruler")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(reading.text)
                .font(.caption.monospacedDigit().weight(.semibold))
                // Neutral ink even when non-standard — the readout reports a
                // coordinate, it never flags a problem (no amber / severity).
                .foregroundStyle(.secondary)
                // Wrap rather than truncate: "· non-standard" must stay legible
                // in the narrow inspector column, not clip to "· non-stand…".
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calibration-readout")
        .accessibilityLabel("Calibration \(reading.text)")
    }
}
