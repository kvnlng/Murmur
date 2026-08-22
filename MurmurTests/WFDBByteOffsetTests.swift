//
//  WFDBByteOffsetTests.swift
//  MurmurTests
//
//  #327 — the WFDB signal-line format field carries an optional `+offset`
//  ("the offset in bytes from the beginning of the signal file to sample 0,
//  i.e. the length of the preamble" — header(5)). Murmur discarded it, so
//  every PhysioNet/CinC 2020-2021 record — which stores samples as MATLAB
//  Level 4 `.mat` files behind a 24-byte prefix and declares `16+24` —
//  decoded one frame off, silently.
//
//  Two things are under test here:
//    1. The offset itself is parsed and honored. This is unconditional: the
//       spec says nothing about what a preamble contains, so the declared
//       offset is authoritative and never inferred.
//    2. WHEN the preamble is recognizably a MATLAB Level 4 header, it makes
//       verifiable claims about the bytes that follow, and those claims are
//       checked against the `.hea`. Recognition is a deterministic MOPT-range
//       gate, not a heuristic. Every fixture below is written byte-for-byte
//       from the published layout rather than captured from a dataset.
//

import Foundation
import Testing
@testable import MurmurCore

@Suite("WFDB byte offset (#327) — header parsing")
struct WFDBByteOffsetHeaderTests {

    @Test("`16+24` parses as format 16 with a 24-byte preamble")
    func parsesByteOffset() throws {
        let hea = """
        JS00001 1 500 5000
        JS00001.mat 16+24 1000/mV 16 0 -254 21756 0 I
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].format == 16)
        #expect(header.signals[0].byteOffset == 24)
    }

    @Test("A format field with no `+` yields a zero offset")
    func defaultsByteOffsetToZero() throws {
        let hea = """
        mitdb100 1 360 650000
        mitdb100.dat 16 200(mV)/0 16 0 0 0 0 MLII
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].byteOffset == 0)
    }

    @Test("`16x250+24` keeps samples-per-frame AND the offset")
    func parsesOffsetAlongsideSamplesPerFrame() throws {
        let hea = """
        multi 1 1 100
        multi.dat 16x250+24 200(mV)/0 16 0 0 0 0 ECG
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].format == 16)
        #expect(header.signals[0].samplesPerFrame == 250)
        #expect(header.signals[0].byteOffset == 24)
    }

    @Test("`16x4:10+24` parses the offset past a skew suffix")
    func parsesOffsetPastSkew() throws {
        let hea = """
        skewed 1 250 100
        skewed.dat 16x4:10+24 200(mV)/0 16 0 0 0 0 II
        """
        let header = try WFDBHeaderParser.parse(text: hea)
        #expect(header.signals[0].samplesPerFrame == 4)
        #expect(header.signals[0].byteOffset == 24)
    }
}

// MARK: - Decoding past the preamble

@Suite("WFDB byte offset (#327) — decoding")
struct WFDBByteOffsetDecodeTests {

    /// Two signals, three samples, frame-interleaved — the same ADC values
    /// used by the existing multi-signal format-16 test.
    private static let adcValues: [Int16] = [200, 400, 100, -100, 0, 0]

    private static func sampleBody() -> Data {
        var d = Data(count: adcValues.count * 2)
        d.withUnsafeMutableBytes { buf in
            let base = buf.baseAddress!.assumingMemoryBound(to: Int16.self)
            for (idx, val) in adcValues.enumerated() { base[idx] = val.littleEndian }
        }
        return d
    }

    private func signal(offset: Int, gain: Double = 200) -> WFDBSignal {
        WFDBSignal(
            filename: "test.dat", format: 16, gain: gain, unit: "mV",
            baseline: 0, adcResolution: 16, adcZero: 0, label: "II",
            byteOffset: offset
        )
    }

    @Test("An arbitrary 24-byte preamble is skipped: decode matches the un-prefixed file")
    func offsetSkipsArbitraryPreamble() throws {
        let body = Self.sampleBody()

        let plain = try WFDBSampleDecoder.decode(
            data: body,
            signals: [signal(offset: 0), signal(offset: 0)],
            declaredSampleCount: 3
        )

        // 24 bytes that are NOT a MAT header (first word out of MOPT range),
        // so no preamble assertions apply — the offset alone must carry it.
        var prefixed = Data(repeating: 0xFF, count: 24)
        prefixed.append(body)
        let offsetDecoded = try WFDBSampleDecoder.decode(
            data: prefixed,
            signals: [signal(offset: 24), signal(offset: 24)],
            declaredSampleCount: 3
        )

        #expect(offsetDecoded == plain)
    }

    @Test("Truncation is measured from after the preamble, not from byte 0")
    func truncationCheckUsesPostOffsetLength() {
        // Body holds exactly 3 frames; the preamble pushes total length up so a
        // byte-0 length check would wrongly pass a 4-frame declaration.
        var prefixed = Data(repeating: 0xFF, count: 24)
        prefixed.append(Self.sampleBody())

        #expect(throws: WFDBDecodeError.self) {
            _ = try WFDBSampleDecoder.decode(
                data: prefixed,
                signals: [signal(offset: 24), signal(offset: 24)],
                declaredSampleCount: 4
            )
        }
    }

    @Test("The Challenge layout's 24-byte preamble is byte-for-byte what we expect")
    func challengePreambleIsByteExact() {
        // PhysioNet ecg-arrhythmia 1.0.0, WFDBRecords/01/010/JS00001.mat — the
        // first 24 bytes of every record in the CinC 2020/2021 corpora.
        // Verified against the file on disk: type 30 (M0 O0 P3 T0), 12 signals
        // x 5000 samples, real, variable "val" (namlen 4) => 20 + 4 = the `+24`
        // the .hea declares.
        let expected: [UInt8] = [
            0x1e, 0x00, 0x00, 0x00,   // type  = 30
            0x0c, 0x00, 0x00, 0x00,   // mrows = 12   (signals)
            0x88, 0x13, 0x00, 0x00,   // ncols = 5000 (samples)
            0x00, 0x00, 0x00, 0x00,   // imagf = 0
            0x04, 0x00, 0x00, 0x00,   // namlen = 4
            0x76, 0x61, 0x6c, 0x00,   // "val\0"
        ]
        let built = MATLevel4Fixture.file(
            .init(type: 30, mrows: 12, ncols: 5000, imagf: 0, name: "val"), body: Data()
        )
        #expect(Array(built) == expected)

        let header = WFDBPreamble.matLevel4Header(in: built, declaredOffset: 24)
        #expect(header?.headerBytes == 24)
        #expect(header?.rows == 12)
        #expect(header?.cols == 5000)
        #expect(header?.precision == 3)
        #expect(header?.byteOrder == 0)
    }

    @Test("A real MATLAB Level 4 preamble decodes to the right samples")
    func matlabV4PreambleDecodes() throws {
        // 2 signals x 3 samples, int16 LE, full real numeric, variable "val".
        let file = MATLevel4Fixture.file(
            .init(type: 30, mrows: 2, ncols: 3, imagf: 0, name: "val"), body: Self.sampleBody()
        )
        #expect(file.count == 36)      // 24-byte header + 6 int16 samples

        let decoded = try WFDBSampleDecoder.decode(
            data: file,
            signals: [signal(offset: 24), signal(offset: 24)],
            declaredSampleCount: 3
        )
        #expect(decoded[0][0] == Float(1.0))
        #expect(decoded[1][0] == Float(2.0))
        #expect(decoded[0][1] == Float(0.5))
        #expect(decoded[1][1] == Float(-0.5))
    }
}

// MARK: - Preamble validation (referenced, not heuristic)

@Suite("WFDB byte offset (#327) — MATLAB Level 4 preamble validation")
struct WFDBPreambleValidationTests {

    private static func sampleBody(_ values: [Int16]) -> Data {
        var d = Data(count: values.count * 2)
        d.withUnsafeMutableBytes { buf in
            let base = buf.baseAddress!.assumingMemoryBound(to: Int16.self)
            for (idx, val) in values.enumerated() { base[idx] = val.littleEndian }
        }
        return d
    }

    private func signal(offset: Int) -> WFDBSignal {
        WFDBSignal(
            filename: "t.mat", format: 16, gain: 200, unit: "mV",
            baseline: 0, adcResolution: 16, adcZero: 0, label: "II",
            byteOffset: offset
        )
    }

    private static let body = sampleBody([200, 400, 100, -100, 0, 0])

    @Test("Rejects a transposed matrix — samples x signals stores bytes signal-major")
    func rejectsTransposedMatrix() {
        // Declared 2 signals x 3 samples, but the matrix says 3 rows x 2 cols.
        let file = MATLevel4Fixture.file(
            .init(type: 30, mrows: 3, ncols: 2, imagf: 0, name: "val"), body: Self.body
        )
        #expect(throws: WFDBDecodeError.self) {
            _ = try WFDBSampleDecoder.decode(
                data: file, signals: [signal(offset: 24), signal(offset: 24)],
                declaredSampleCount: 3
            )
        }
    }

    @Test("Rejects a non-int16 precision (P = 0, double)")
    func rejectsNonInt16Precision() {
        // MOPT 0 => M0 O0 P0 (double) T0.
        let file = MATLevel4Fixture.file(
            .init(type: 0, mrows: 2, ncols: 3, imagf: 0, name: "val"), body: Self.body
        )
        #expect(throws: WFDBDecodeError.self) {
            _ = try WFDBSampleDecoder.decode(
                data: file, signals: [signal(offset: 24), signal(offset: 24)],
                declaredSampleCount: 3
            )
        }
    }

    @Test("Rejects big-endian MAT data — format 16 is least-significant-byte-first")
    func rejectsBigEndianMatrix() {
        // MOPT 1030 => M1 (big-endian) O0 P3 T0.
        let file = MATLevel4Fixture.file(
            .init(type: 1030, mrows: 2, ncols: 3, imagf: 0, name: "val"), body: Self.body
        )
        #expect(throws: WFDBDecodeError.self) {
            _ = try WFDBSampleDecoder.decode(
                data: file, signals: [signal(offset: 24), signal(offset: 24)],
                declaredSampleCount: 3
            )
        }
    }

    @Test("Rejects a preamble length that disagrees with 20 + namlen")
    func rejectsNamlenMismatch() {
        // Variable named "data" => namlen 5 => header is 25 bytes, not 24.
        let file = MATLevel4Fixture.file(
            .init(type: 30, mrows: 2, ncols: 3, imagf: 0, name: "data"), body: Self.body
        )
        #expect(throws: WFDBDecodeError.self) {
            _ = try WFDBSampleDecoder.decode(
                data: file, signals: [signal(offset: 24), signal(offset: 24)],
                declaredSampleCount: 3
            )
        }
    }

    @Test("Rejects a complex matrix — WFDB needs a full real numeric matrix")
    func rejectsComplexMatrix() {
        let file = MATLevel4Fixture.file(
            .init(type: 30, mrows: 2, ncols: 3, imagf: 1, name: "val"), body: Self.body
        )
        #expect(throws: WFDBDecodeError.self) {
            _ = try WFDBSampleDecoder.decode(
                data: file, signals: [signal(offset: 24), signal(offset: 24)],
                declaredSampleCount: 3
            )
        }
    }

    @Test("A preamble outside the MOPT range makes no claims and is simply skipped")
    func ignoresNonMATPreamble() throws {
        var file = Data(repeating: 0xFF, count: 24)   // first word is not a valid MOPT
        file.append(Self.body)
        let decoded = try WFDBSampleDecoder.decode(
            data: file, signals: [signal(offset: 24), signal(offset: 24)],
            declaredSampleCount: 3
        )
        #expect(decoded[0][0] == Float(1.0))
    }

    @Test("An offset shorter than a MAT header is never inspected")
    func ignoresOffsetTooShortToBeAMATHeader() throws {
        var file = Data(repeating: 0x00, count: 8)
        file.append(Self.body)
        let decoded = try WFDBSampleDecoder.decode(
            data: file, signals: [signal(offset: 8), signal(offset: 8)],
            declaredSampleCount: 3
        )
        #expect(decoded[0][0] == Float(1.0))
    }
}

// MARK: - Fixture builder

/// Builds a MATLAB Level 4 file byte-for-byte from the published layout:
/// five 32-bit integers (`type, mrows, ncols, imagf, namlen`), then `namlen`
/// bytes of null-terminated variable name, then `mrows * ncols` real elements
/// in column-major order.
///
/// `type` is the decimal MOPT code: M (thousands) byte order, O (hundreds)
/// always 0, P (tens) precision — 3 is int16, T (units) matrix type — 0 is
/// full numeric.
enum MATLevel4Fixture {

    /// The five Int32 header fields, with the Challenge layout as the default:
    /// `type` 30 (M0 O0 P3 T0 — little-endian int16, full numeric), real, and
    /// a variable named "val" (namlen 4, so the header is 20 + 4 = 24 bytes).
    struct Spec {
        var type: Int32 = 30
        var mrows: Int32
        var ncols: Int32
        var imagf: Int32 = 0
        var name: String = "val"
    }

    static func file(_ spec: Spec, body: Data) -> Data {
        var d = Data()
        let nameBytes = Array(spec.name.utf8) + [0]
        let fields = [spec.type, spec.mrows, spec.ncols, spec.imagf, Int32(nameBytes.count)]
        for field in fields {
            withUnsafeBytes(of: field.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: nameBytes)
        d.append(body)
        return d
    }
}
