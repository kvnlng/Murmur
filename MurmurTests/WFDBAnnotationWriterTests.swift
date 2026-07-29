//
//  WFDBAnnotationWriterTests.swift
//  MurmurTests
//
//  Byte-exact golden tests for the WFDB annotation writer. The goldens are the
//  literal output of `wfdb-python` v4.3.1 `wrann` for the same inputs (captured
//  and hex-dumped during the export design pass). Byte-for-byte equality is the
//  strongest possible round-trip guarantee: if our bytes ARE the reference
//  implementation's bytes, `rdann` reads them back identically. A live
//  read-back through wfdb-python is also run out-of-band during development;
//  these goldens pin the format in CI without a Python dependency.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("WFDB annotation writer — byte-exact vs wfdb-python")
struct WFDBAnnotationWriterTests {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    @Test("NOTE with even-length aux matches wfdb-python")
    func evenAux() {
        let out = WFDBAnnotationWriter.encode([.init(sampleIndex: 100, aux: "AB")])
        #expect(hex(out) == "64 58 02 fc 41 42 00 00")
    }

    @Test("NOTE with odd-length aux gets a single pad byte")
    func oddAux() {
        let out = WFDBAnnotationWriter.encode([.init(sampleIndex: 100, aux: "ABC")])
        #expect(hex(out) == "64 58 03 fc 41 42 43 00 00 00")
    }

    @Test("Sample beyond the 10-bit delta emits a SKIP frame")
    func skipFrameForLargeDelta() {
        let out = WFDBAnnotationWriter.encode([.init(sampleIndex: 5000, aux: "X")])
        #expect(hex(out) == "00 ec 00 00 88 13 00 58 01 fc 58 00 00 00")
    }

    @Test("Two spaced annotations accumulate deltas, second needs SKIP")
    func twoSpacedAnnotations() {
        let out = WFDBAnnotationWriter.encode([
            .init(sampleIndex: 100, aux: "P"),
            .init(sampleIndex: 1500, aux: "Q"),
        ])
        #expect(hex(out) == "64 58 01 fc 50 00 00 ec 00 00 78 05 00 58 01 fc 51 00 00 00")
    }

    @Test("Rhythm code with empty aux emits no AUX frame")
    func emptyAuxEmitsNoAuxFrame() {
        let out = WFDBAnnotationWriter.encode([.init(sampleIndex: 100, code: 28, aux: "")])
        #expect(hex(out) == "64 70 00 00")
    }

    @Test("Encoder round-trips through Murmur's own reader")
    func roundTripsThroughReader() {
        let events = [
            WFDBAnnotationWriter.Event(sampleIndex: 250, aux: "confirmed VT 1.0-16.0s"),
            WFDBAnnotationWriter.Event(sampleIndex: 4000, aux: "PVC couplet"),
        ]
        let decoded = WFDBAnnotationParser.parse(data: WFDBAnnotationWriter.encode(events))
        #expect(decoded.map(\.sampleIndex) == [250, 4000])
        #expect(decoded.allSatisfy { $0.label == "\"" })   // NOTE symbol
    }

    @Test("Unsorted input is serialised in ascending sample order")
    func sortsInput() {
        let out = WFDBAnnotationWriter.encode([
            .init(sampleIndex: 1500, aux: "Q"),
            .init(sampleIndex: 100, aux: "P"),
        ])
        #expect(hex(out) == "64 58 01 fc 50 00 00 ec 00 00 78 05 00 58 01 fc 51 00 00 00")
    }

    // MARK: - AUX capture on read-back (C2)

    @Test("Reader captures the AUX payload verbatim on read-back")
    func readerCapturesAux() {
        let events = [
            WFDBAnnotationWriter.Event(sampleIndex: 250, aux: "confirmed VT 1.0-16.0s"),
            WFDBAnnotationWriter.Event(sampleIndex: 4000, aux: "PVC couplet"),
        ]
        let decoded = WFDBAnnotationParser.parse(data: WFDBAnnotationWriter.encode(events))
        #expect(decoded.map(\.aux) == ["confirmed VT 1.0-16.0s", "PVC couplet"])
    }

    @Test("`+` rhythm-marker AUX decodes to a verbatim note, minus the leading (")
    func rhythmMarkerAuxBecomesNote() {
        // Hand-built .atr stream: a `+` (code 28) at sample 10, then an AUX
        // frame carrying "(AFIB" (5 bytes, padded to 6), then EOF.
        var bytes: [UInt8] = []
        func word(_ w: UInt16) {
            bytes.append(UInt8(w & 0xff))
            bytes.append(UInt8(w >> 8))
        }
        word((28 << 10) | 10)
        let payload = Array("(AFIB".utf8)
        word((63 << 10) | UInt16(payload.count))
        bytes.append(contentsOf: payload)
        bytes.append(0)          // pad to even length
        word(0)                  // EOF

        let decoded = WFDBAnnotationParser.parse(data: Data(bytes))
        #expect(decoded.count == 1)
        #expect(decoded.first?.label == "+")
        #expect(decoded.first?.aux == "(AFIB")

        // Import strips only the syntactic leading `(`; the rest is verbatim.
        let ann = Annotation(fromWFDB: decoded[0])
        #expect(ann.category == "+")
        #expect(ann.note == "AFIB")
    }
}
