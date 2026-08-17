//
//  IntervalSpanTests.swift
//  MurmurTests
//
//  PR / QRS / QT as spans, and the deviation the overhang shows (#227).
//
//  The rules worth pinning are refusals: a span must NOT appear where the app
//  is deliberately declining to state a number. X53 withholds a QT that is
//  physically implausible and X58 withholds one whose T-offset the delineator
//  flagged — in both cases the endpoints still exist, so geometry alone would
//  happily draw a span for a measurement the beat card is refusing to make.
//

import Testing
@testable import MurmurCore

@Suite("Interval spans (#227)")
struct IntervalSpanTests {

    private func fiducial(_ kind: MarkingsFiducialKind, _ sample: Int64) -> MarkingsFiducial {
        MarkingsFiducial(kind: kind, sampleIndex: sample, confidence: 0.9)
    }

    /// A beat with every endpoint and every duration published.
    private func completeBeat(
        prMs: Double? = 160,
        qrsMs: Double? = 90,
        qtMs: Double? = 400
    ) -> MarkingsBeat {
        MarkingsBeat(
            rPeakSampleIndex: 1_000,
            rPeakConfidence: 0.95,
            pOnset: fiducial(.pOnset, 900),
            pOffset: fiducial(.pOffset, 950),
            qrsOnset: fiducial(.qrsOnset, 980),
            qrsOffset: fiducial(.qrsOffset, 1_003),
            tOnset: fiducial(.tOnset, 1_060),
            tOffset: fiducial(.tOffset, 1_080),
            prMs: prMs,
            qrsMs: qrsMs,
            qtMs: qtMs,
            qtcMs: 410,
            precedingRRMs: 1_000)
    }

    private func template(
        pr: Double? = 140,
        qrs: Double? = 88,
        qt: Double? = 390
    ) -> MarkingsTemplate {
        MarkingsTemplate(
            sampleCount: 40,
            medianPRMs: pr, iqrPRMs: 10,
            medianQRSMs: qrs, iqrQRSMs: 6,
            medianQTMs: qt, iqrQTMs: 20,
            qtcFormulaName: "Bazett",
            medianQTcMs: 400, iqrQTcMs: 18)
    }

    @Test("All three spans, in nested drawing order")
    func threeSpansInOrder() {
        let spans = IntervalSpans.spans(for: completeBeat(), template: template())
        #expect(spans.map(\.kind) == [.pr, .qrs, .qt])
    }

    /// The spans have to bound what their names mean, or the trace is lying
    /// about which measurement it is showing.
    @Test("Each span runs between the endpoints its name refers to")
    func spansBoundTheRightEndpoints() {
        let beat = completeBeat()
        let spans = IntervalSpans.spans(for: beat, template: template())
        let byKind = Dictionary(uniqueKeysWithValues: spans.map { ($0.kind, $0) })

        // PR: P onset → QRS onset.
        #expect(byKind[.pr]?.startSample == 900)
        #expect(byKind[.pr]?.endSample == 980)
        // QRS: its own onset → offset.
        #expect(byKind[.qrs]?.startSample == 980)
        #expect(byKind[.qrs]?.endSample == 1_003)
        // QT: QRS onset → T offset. Shares PR's far edge as its near one,
        // which is why the rows stack instead of sharing a line.
        #expect(byKind[.qt]?.startSample == 980)
        #expect(byKind[.qt]?.endSample == 1_080)
    }

    /// The whole point of the feature: the number the card states and the
    /// overhang the trace draws are the same quantity.
    @Test("Deviation is this beat against this patient's normal")
    func deviationIsAgainstTheTemplate() throws {
        let spans = IntervalSpans.spans(
            for: completeBeat(prMs: 163.4), template: template(pr: 140))
        let deviation = try #require(spans.first { $0.kind == .pr }?.deviationMs)
        // Tolerance, not ==: 163.4 − 140 is 23.400000000000006 in binary.
        #expect(abs(deviation - 23.4) < 1e-9)
    }

    @Test("No template median means no deviation and no ghost")
    func withoutATemplateThereIsNothingToCompare() {
        let spans = IntervalSpans.spans(for: completeBeat(), template: nil)
        #expect(spans.count == 3)
        for span in spans {
            #expect(span.deviationMs == nil)
            #expect(span.ghostEndSample(sampleRate: 250) == nil)
        }
    }

    /// A template can carry some medians and withhold others — X53 and X58 both
    /// exclude beats from the QT statistics specifically.
    @Test("A partially withheld template only ghosts what it knows")
    func partialTemplateGhostsOnlyWhatItHas() {
        let spans = IntervalSpans.spans(
            for: completeBeat(), template: template(qt: nil))
        let byKind = Dictionary(uniqueKeysWithValues: spans.map { ($0.kind, $0) })
        #expect(byKind[.pr]?.deviationMs != nil)
        #expect(byKind[.qt]?.deviationMs == nil)
        #expect(byKind[.qt]?.ghostEndSample(sampleRate: 250) == nil)
    }

    /// The refusal that matters. Endpoints exist, but the beat published no
    /// duration — X53 (physically implausible QT) and X58 (unreliable
    /// T-offset) both land here. Drawing a span would put a mark on the trace
    /// for a number the card is deliberately declining to state.
    @Test("A withheld measurement draws no span, even with both endpoints present")
    func withheldMeasurementsDrawNothing() {
        let spans = IntervalSpans.spans(for: completeBeat(qtMs: nil), template: template())
        #expect(!spans.contains { $0.kind == .qt },
                "QT endpoints exist but the measurement was withheld — no span")
        #expect(spans.map(\.kind) == [.pr, .qrs])
    }

    /// A record whose delineator found no P wave at all: no PR to draw, and the
    /// other two unaffected.
    @Test("Missing endpoints drop only their own span")
    func missingEndpointsDropOnlyTheirSpan() {
        let beat = MarkingsBeat(
            rPeakSampleIndex: 1_000,
            rPeakConfidence: 0.95,
            pOnset: nil,
            pOffset: nil,
            qrsOnset: fiducial(.qrsOnset, 980),
            qrsOffset: fiducial(.qrsOffset, 1_003),
            tOnset: fiducial(.tOnset, 1_060),
            tOffset: fiducial(.tOffset, 1_080),
            prMs: nil,
            qrsMs: 90,
            qtMs: 400,
            qtcMs: 410,
            precedingRRMs: 1_000)
        #expect(IntervalSpans.spans(for: beat, template: template()).map(\.kind) == [.qrs, .qt])
    }

    /// The ghost runs from the SAME start as the solid span, out to the
    /// template's duration — that is what makes the overhang readable as the
    /// deviation rather than as two unrelated bars.
    @Test("The ghost shares the span's start and takes the template's length")
    func ghostSharesStartAndTakesTemplateLength() {
        let spans = IntervalSpans.spans(
            for: completeBeat(qrsMs: 100), template: template(qrs: 88))
        let qrs = spans.first { $0.kind == .qrs }
        // 88 ms at 250 Hz = 22 samples past the 980 start. Precomputed —
        // an arithmetic rhs (980 + 22) inside #expect miscompared on this
        // toolchain even with both sides expanding to 1002; a plain literal
        // follows the pattern every passing sibling uses.
        #expect(qrs?.ghostEndSample(sampleRate: 250) == 1_002)
        // Longer than normal, so the solid span overhangs the ghost — which is
        // the +12 ms, seen.
        #expect((qrs?.deviationMs ?? 0) > 0)
        #expect((qrs?.endSample ?? 0) > (qrs?.ghostEndSample(sampleRate: 250) ?? .max))
    }

    @Test("Unusable sample rates produce no ghost rather than a bar at the origin",
          arguments: [0.0, -250.0])
    func degenerateSampleRateProducesNoGhost(rate: Double) {
        let spans = IntervalSpans.spans(for: completeBeat(), template: template())
        for span in spans {
            #expect(span.ghostEndSample(sampleRate: rate) == nil)
        }
    }

    /// Colour comes from the letter palette rather than a second scheme, so an
    /// analyst who has learned blue-is-P reads the PR span without relearning.
    @Test("Spans borrow the letter palette rather than introducing a second one")
    func spansReuseTheLetterVocabulary() {
        #expect(IntervalSpan.Kind.pr.paletteLayer == .p)
        #expect(IntervalSpan.Kind.qrs.paletteLayer == .qrs)
        #expect(IntervalSpan.Kind.qt.paletteLayer == .t)
    }

    /// The card and the trace must name the same object identically.
    @Test("Labels match the beat card's own")
    func labelsMatchTheCard() {
        #expect(IntervalSpan.Kind.pr.label == "PR")
        #expect(IntervalSpan.Kind.qrs.label == "QRS")
        #expect(IntervalSpan.Kind.qt.label == "QT")
    }
}
