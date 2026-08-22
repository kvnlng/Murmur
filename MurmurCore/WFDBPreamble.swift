//
//  WFDBPreamble.swift
//  Murmur
//
//  Validation for the preamble a WFDB signal file may carry ahead of sample 0
//  (#327).
//
//  THE OFFSET IS AUTHORITATIVE. Per `header(5)` the format field's `+N` is
//  "the offset in bytes from the beginning of the signal file to sample 0
//  (i.e. the length of the preamble)", and the spec says nothing whatever
//  about the preamble's contents. So the declared offset is honored
//  unconditionally and is never inferred from the bytes.
//
//  What this file adds is a SEPARATE, additional check. When the preamble is
//  recognizably a MATLAB Level 4 header, that header makes verifiable claims
//  about the bytes that follow it, and those claims can be compared against
//  the `.hea`. Every assertion below is derived from a published definition —
//  nothing is pattern-matched:
//
//    • WFDB header(5)  — https://physionet.org/physiotools/wag/header-5.htm
//      format field `<format>[x<spf>[:<skew>]][+<offset>]`; offset as above.
//    • WFDB signal(5)  — https://physionet.org/physiotools/wag/signal-5.htm
//      format 16: "Each sample is represented by a 16-bit two's complement
//      amplitude stored least significant byte first"; multiplexed files store
//      "samples from two or more signals … alternately" (sample-major frames).
//    • MathWorks, *MAT-File Format*, appendix "Level 4 MAT-File Format" —
//      five 32-bit integers `type, mrows, ncols, imagf, namlen`, then `namlen`
//      bytes of null-terminated variable name, then `mrows × ncols` real
//      elements in column-major order (imaginary part following if `imagf`).
//      `type` is the decimal MOPT code: M (thousands) byte order — 0 IEEE
//      little-endian, 1 IEEE big-endian, 2 VAX D, 3 VAX G, 4 Cray; O
//      (hundreds) always 0; P (tens) precision — 0 double, 1 single, 2 int32,
//      3 int16, 4 uint16, 5 uint8; T (units) matrix type — 0 full numeric,
//      1 text, 2 sparse.
//
//  Why the shape check matters most: column-major with rows = signals means
//  the byte stream is sample-major frames, which is exactly signal(5)'s
//  multiplexed layout. The TRANSPOSED case stores bytes signal-major, and a
//  format-16 decode of it reads plausible-looking garbage with no error at
//  all — the one silent-corruption mode the offset alone cannot prevent.
//

import Foundation

enum WFDBPreamble {

    /// A decoded MATLAB Level 4 header. Field names follow the appendix.
    struct MATLevel4Header: Equatable, Sendable {
        let byteOrder: Int          // M
        let precision: Int          // P
        let matrixType: Int         // T
        let rows: Int               // mrows
        let cols: Int               // ncols
        let isComplex: Bool         // imagf != 0
        let nameLength: Int         // namlen, includes the trailing NUL

        /// Total header length the MAT layout implies: five Int32 fields plus
        /// the null-terminated name.
        var headerBytes: Int { 20 + nameLength }

        var byteOrderName: String {
            switch byteOrder {
            case 0:  return "little-endian"
            case 1:  return "big-endian"
            case 2:  return "VAX D-float"
            case 3:  return "VAX G-float"
            case 4:  return "Cray"
            default: return "order \(byteOrder)"
            }
        }

        var precisionName: String {
            switch precision {
            case 0:  return "double"
            case 1:  return "single"
            case 2:  return "int32"
            case 3:  return "int16"
            case 4:  return "uint16"
            case 5:  return "uint8"
            default: return "precision \(precision)"
            }
        }

        var matrixKindName: String {
            if isComplex { return "complex" }
            switch matrixType {
            case 1:  return "text"
            case 2:  return "sparse"
            default: return "full numeric"
            }
        }
    }

    /// Recognition gate. Returns a header only when the first 20 bytes decode
    /// to a MOPT code whose every digit is in range — the deterministic test
    /// from the appendix. Anything else is an arbitrary preamble about which
    /// no claim is made.
    ///
    /// Requires `offset >= 20`: a shorter preamble cannot hold a Level 4
    /// header, so it is never inspected.
    ///
    /// Note: scipy's "mopt < 0 || mopt > 5000 implies a byte-swapped file"
    /// branch is deliberately NOT replicated. A big-endian Level 4 file is
    /// rejected by `validate` rather than transparently swapped, because
    /// format 16 is defined as least-significant-byte-first.
    static func matLevel4Header(in data: Data, declaredOffset: Int) -> MATLevel4Header? {
        guard declaredOffset >= 20, data.count >= 20 else { return nil }

        var fields = [Int32](repeating: 0, count: 5)
        data.withUnsafeBytes { raw in
            for idx in 0..<5 {
                fields[idx] = Int32(
                    littleEndian: raw.loadUnaligned(fromByteOffset: idx * 4, as: Int32.self)
                )
            }
        }

        let type = Int(fields[0])
        guard type >= 0 else { return nil }
        let m = type / 1000
        let o = (type / 100) % 10
        let p = (type / 10) % 10
        let t = type % 10
        guard (0...4).contains(m), o == 0, (0...5).contains(p), (0...2).contains(t) else {
            return nil
        }

        // A negative dimension or name length is not a Level 4 header.
        guard fields[1] >= 0, fields[2] >= 0, fields[4] >= 0 else { return nil }

        return MATLevel4Header(
            byteOrder: m,
            precision: p,
            matrixType: t,
            rows: Int(fields[1]),
            cols: Int(fields[2]),
            isComplex: fields[3] != 0,
            nameLength: Int(fields[4])
        )
    }

    /// Compares a recognized Level 4 header's claims against the `.hea`.
    /// Throws the first disagreement; returns silently when they agree.
    ///
    /// `wfdbFormat` selects the required precision. Only format 16 has a
    /// defined mapping today (int16); other formats skip that one assertion
    /// rather than guess.
    static func validate(
        _ header: MATLevel4Header,
        declaredOffset: Int,
        wfdbFormat: Int,
        signalCount: Int,
        sampleCount: Int
    ) throws {
        // 1 — the preamble length the MAT layout implies must equal the `.hea`'s.
        guard header.headerBytes == declaredOffset else {
            throw WFDBDecodeError.preambleLengthMismatch(
                declaredOffset: declaredOffset,
                matHeaderBytes: header.headerBytes,
                nameLength: header.nameLength
            )
        }

        // 2 — signal(5): format 16 is least-significant-byte-first.
        guard header.byteOrder == 0 else {
            throw WFDBDecodeError.preambleByteOrder(
                matOrder: header.byteOrderName,
                format: wfdbFormat
            )
        }

        // 3 — precision must match what the WFDB format stores.
        if wfdbFormat == 16, header.precision != 3 {
            throw WFDBDecodeError.preamblePrecision(
                matPrecision: header.precisionName,
                format: wfdbFormat
            )
        }

        // 4 — a full real numeric matrix, not text / sparse / complex.
        guard header.matrixType == 0, !header.isComplex else {
            throw WFDBDecodeError.preambleMatrixKind(matKind: header.matrixKindName)
        }

        // 5 — shape. Column-major with rows = signals IS signal(5)'s
        // multiplexed frame layout; the transposed case is byte-order-wrong in
        // a way nothing downstream would catch, so it is named explicitly.
        guard header.rows == signalCount, header.cols == sampleCount else {
            if header.rows == sampleCount && header.cols == signalCount {
                throw WFDBDecodeError.preambleShapeTransposed(
                    rows: header.rows, cols: header.cols,
                    signals: signalCount, samples: sampleCount
                )
            }
            throw WFDBDecodeError.preambleShapeMismatch(
                rows: header.rows, cols: header.cols,
                signals: signalCount, samples: sampleCount
            )
        }
    }

    /// Convenience: recognize-then-validate. A preamble that fails the gate is
    /// silently accepted (the offset alone carries it).
    static func validateIfRecognized(
        in data: Data,
        declaredOffset: Int,
        wfdbFormat: Int,
        signalCount: Int,
        sampleCount: Int
    ) throws {
        guard let header = matLevel4Header(in: data, declaredOffset: declaredOffset) else {
            return
        }
        try validate(
            header,
            declaredOffset: declaredOffset,
            wfdbFormat: wfdbFormat,
            signalCount: signalCount,
            sampleCount: sampleCount
        )
    }
}
