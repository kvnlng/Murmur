//
//  FiducialLetterTag.swift
//  MurmurCore
//
//  The P / QRS / T letter tag, one component for every surface that shows one
//  (#249).
//
//  The feedback asked for two things that are easy to state and easy to let
//  drift: the same colour for a letter everywhere, and a bedside tag larger
//  than the queue's. Both are properties of a RELATIONSHIP between surfaces, so
//  neither survives being implemented twice. This is the single component; the
//  only thing a caller chooses is the size, and the two sizes live together in
//  `FiducialPalette` where a test can compare them.
//
//  Confidence is deliberately not a parameter. On the trace it is real
//  information — a boundary the delineator was unsure of is what a fiducial
//  edit pass goes looking for — but a queue row represents an analyst-placed
//  span, which has no algorithmic confidence to report. A shared component
//  that took an optional confidence would invite a caller to pass one where the
//  concept does not apply.
//

import SwiftUI

public struct FiducialLetterTag: View {
    private let layer: MarkingsFiducialLayer
    private let pointSize: CGFloat
    private let weight: Font.Weight

    public init(
        layer: MarkingsFiducialLayer,
        pointSize: CGFloat,
        weight: Font.Weight = .semibold
    ) {
        self.layer = layer
        self.pointSize = pointSize
        self.weight = weight
    }

    public var body: some View {
        Text(FiducialPalette.letter(for: layer))
            .font(.system(size: pointSize, weight: weight, design: .rounded))
            .foregroundStyle(FiducialPalette.color(for: layer))
            .fixedSize()
            // Spelled out rather than left to the Text, so VoiceOver says the
            // wave rather than a bare letter — "QRS" read aloud out of context
            // is three consonants.
            .accessibilityLabel("\(layer.displayName) wave")
    }
}
