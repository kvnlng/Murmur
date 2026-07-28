//
//  CSVImport.swift
//  MurmurCore
//
//  CSV → WFDB import, per project_csv_import_spec.md. CSV has no standard, so
//  this accepts exactly ONE hard form and refuses everything else with a single
//  precise reason. It does NOT sniff dialects. It DOES accept legitimate device
//  variation (multi-lead, device header block, physical OR ADC amplitude) as
//  long as the file is structurally coherent and internally consistent.
//
//  Guiding rule: support legitimate machine complexity, refuse tampering. The
//  parser enforces STRUCTURE + INTERNAL CONSISTENCY (which catches hand-editing);
//  the asserted metadata (rate/units/leads) is the RUO surface that guards the
//  scientific claim — not this parser.
//
//  This file is X15-A: parse + validate → `Parsed` (integer channel samples +
//  marked-missing indices + resolved rate + the gain used) or a `.refusal` with
//  its single reason. Conversion to a WFDB record is X15-B; the dialog + open
//  path is X15-C. Metadata is HYBRID: an in-file `# key: value` header block if
//  present (must be complete), else caller-supplied dialog metadata.
//
//  Scope note (X15-A): amplitude metadata is applied as ONE shared encoding
//  across channels (the common device case). Per-channel unit/gain arrays are a
//  declared extension point, not yet parsed.
//

import Foundation

public enum CSVImport {

    // MARK: - Metadata

    public enum IndexKind: String, Sendable, Equatable {
        case timeSeconds = "time_seconds"
        case sampleNumber = "sample_number"
    }

    public enum Amplitude: Sendable, Equatable {
        /// Physical values in `unit`; digitised to WFDB integers with a gain.
        case physical(unit: String)
        /// Integer ADC counts already in the record's native encoding.
        case adcCounts(resolutionBits: Int, gain: Double, baseline: Int, unit: String)
    }

    public enum Sentinel: Sendable, Equatable {
        case emptyCell
        case nan
        case integer(Int)
    }

    /// The asserted metadata — identical keys whether from the header block or
    /// the dialog. This is a CLAIM about the signal, surfaced for correction; the
    /// parser validates structure against it, not its scientific truth.
    public struct Metadata: Sendable, Equatable {
        public var indexKind: IndexKind
        public var sampleRateHz: Double?
        public var numChannels: Int
        public var leadNames: [String]
        public var amplitude: Amplitude
        public var sentinel: Sentinel?
        public var startDatetimeISO: String?

        public init(
            indexKind: IndexKind,
            sampleRateHz: Double? = nil,
            numChannels: Int,
            leadNames: [String],
            amplitude: Amplitude,
            sentinel: Sentinel? = nil,
            startDatetimeISO: String? = nil
        ) {
            self.indexKind = indexKind
            self.sampleRateHz = sampleRateHz
            self.numChannels = numChannels
            self.leadNames = leadNames
            self.amplitude = amplitude
            self.sentinel = sentinel
            self.startDatetimeISO = startDatetimeISO
        }
    }

    // MARK: - Result

    public struct Parsed: Sendable, Equatable {
        public let metadata: Metadata
        /// Per-channel integer samples ready for a WFDB `.dat` (X15-B).
        public let channelSamples: [[Int32]]
        /// Per-channel sample indices that were the declared sentinel (WFDB
        /// invalid-sample on write).
        public let missingByChannel: [[Int]]
        /// Resolved sampling rate (from the index step or metadata, cross-checked).
        public let sampleRateHz: Double
        /// ADC gain actually used (proposed power-of-ten for `physical`, or the
        /// declared `adc_gain`). Written to the WFDB header in X15-B.
        public let gain: Double
        /// Where metadata came from — surfaced by the dialog.
        public let metadataFromHeaderBlock: Bool
    }

    /// One refusal reason. Carries a human sentence and, where meaningful, the
    /// offending 1-based line and/or column. The importer's only two outcomes
    /// are a `Parsed` or one of these.
    public struct Refusal: Error, Equatable, Sendable {
        public let reason: Reason
        public let line: Int?
        public let column: Int?

        public enum Reason: String, Sendable, Equatable {
            case notUTF8
            case mixedLineEndings
            case quotedField
            case whitespaceInCell
            case raggedRow
            case emptyFile
            case malformedHeaderBlock
            case incompleteMetadata
            case columnCountMismatch
            case indexNotNumeric
            case indexNotIncreasing
            case indexStepNotUniform
            case sampleNumberStepNotOne
            case rateContradiction
            case missingSampleRate
            case signalNotNumeric
            case adcValueOutOfRange
            case embeddedUnitOrSeparator
            case nonConformantCell
            case losslessGainOverflowsBitDepth
        }

        public var message: String {
            let base: String
            switch reason {
            case .notUTF8: base = "The file isn't valid UTF-8."
            case .mixedLineEndings: base = "Line endings are mixed; use LF or CRLF consistently."
            case .quotedField: base = "Quoted fields aren't allowed; all data cells must be bare numbers."
            case .whitespaceInCell: base = "A cell contains a tab or internal whitespace."
            case .raggedRow: base = "A row has a different column count than the others."
            case .emptyFile: base = "The file has no data rows."
            case .malformedHeaderBlock: base = "The '#' metadata header block is malformed or mislocated."
            case .incompleteMetadata: base = "Required metadata is missing (no complete header block and none supplied)."
            case .columnCountMismatch: base = "The signal-column count doesn't match num_channels."
            case .indexNotNumeric: base = "The index column has a non-numeric value."
            case .indexNotIncreasing: base = "The index column isn't strictly increasing."
            case .indexStepNotUniform: base = "The index column's step isn't uniform."
            case .sampleNumberStepNotOne: base = "A sample_number index must step by exactly 1."
            case .rateContradiction: base = "The index-implied rate contradicts sample_rate_hz."
            case .missingSampleRate: base = "sample_rate_hz is required for a sample_number index."
            case .signalNotNumeric: base = "A signal cell isn't a valid number."
            case .adcValueOutOfRange: base = "An adc_counts value is outside the declared bit range."
            case .embeddedUnitOrSeparator: base = "A cell has an embedded unit, comma-decimal, or thousands separator."
            case .nonConformantCell: base = "A cell is neither a valid sample nor the declared sentinel."
            case .losslessGainOverflowsBitDepth: base = "The values need more precision than the declared bit depth allows."
            }
            switch (line, column) {
            case let (l?, c?): return "\(base) (line \(l), column \(c))"
            case let (l?, nil): return "\(base) (line \(l))"
            default: return base
            }
        }
    }

    // MARK: - Entry point

    /// Parse `data` into a `Parsed` or throw a `Refusal`. `dialogMetadata` is
    /// used only when the file has no header block; a header block present but
    /// incomplete refuses (presence asserts completeness) rather than falling
    /// back to the dialog.
    public static func parse(data: Data, dialogMetadata: Metadata? = nil) throws -> Parsed {
        let text = try decodeUTF8(data)
        let lines = try normalizedLines(text)

        // Split leading contiguous `# ...` header block from the data rows.
        var headerLines: [String] = []
        var dataLines: [String] = []
        var sawData = false
        for (idx, line) in lines.enumerated() {
            if line.hasPrefix("#") {
                if sawData { throw Refusal(reason: .malformedHeaderBlock, line: idx + 1, column: nil) }
                headerLines.append(line)
            } else {
                sawData = true
                dataLines.append(line)
            }
        }
        guard !dataLines.isEmpty else { throw Refusal(reason: .emptyFile, line: nil, column: nil) }

        let metadata: Metadata
        let fromHeader: Bool
        if !headerLines.isEmpty {
            metadata = try parseHeaderBlock(headerLines)
            fromHeader = true
        } else if let dialogMetadata {
            metadata = dialogMetadata
            fromHeader = false
        } else {
            throw Refusal(reason: .incompleteMetadata, line: nil, column: nil)
        }

        return try parseData(dataLines, metadata: metadata, fromHeader: fromHeader)
    }

    // MARK: - UTF-8 + line endings

    private static func decodeUTF8(_ data: Data) throws -> String {
        var bytes = data
        // Strip a leading UTF-8 BOM if present.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw Refusal(reason: .notUTF8, line: nil, column: nil)
        }
        return text
    }

    /// Splits into lines, enforcing a single consistent LF or CRLF convention
    /// (no bare CR, no mix). A single trailing newline is optional.
    private static func normalizedLines(_ text: String) throws -> [String] {
        var working = text
        if working.contains("\r\n") {
            let placeholder = "\u{1}"
            let stripped = working.replacingOccurrences(of: "\r\n", with: placeholder)
            if stripped.contains("\n") || stripped.contains("\r") {
                throw Refusal(reason: .mixedLineEndings, line: nil, column: nil)
            }
            working = stripped.replacingOccurrences(of: placeholder, with: "\n")
        } else if working.contains("\r") {
            throw Refusal(reason: .mixedLineEndings, line: nil, column: nil)
        }
        var lines = working.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // optional trailing newline
        return lines
    }

    // MARK: - Header block

    private static func parseHeaderBlock(_ headerLines: [String]) throws -> Metadata {
        var kv: [String: String] = [:]
        for (idx, raw) in headerLines.enumerated() {
            // `# key: value`
            let body = raw.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let colon = body.firstIndex(of: ":") else {
                throw Refusal(reason: .malformedHeaderBlock, line: idx + 1, column: nil)
            }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces)
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw Refusal(reason: .malformedHeaderBlock, line: idx + 1, column: nil) }
            kv[key] = value
        }
        return try metadata(fromKeyValues: kv)
    }

    /// Builds + validates `Metadata` from a key/value map (shared by the header
    /// block; the dialog builds `Metadata` directly). Missing/!parseable required
    /// keys refuse as `.incompleteMetadata`.
    static func metadata(fromKeyValues kv: [String: String]) throws -> Metadata {
        func incomplete() -> Refusal { Refusal(reason: .incompleteMetadata, line: nil, column: nil) }

        guard let indexKindRaw = kv["index_kind"], let indexKind = IndexKind(rawValue: indexKindRaw),
              let numChannelsRaw = kv["num_channels"], let numChannels = Int(numChannelsRaw), numChannels > 0,
              let leadRaw = kv["lead_names"],
              let encodingRaw = kv["amplitude_encoding"]
        else { throw incomplete() }

        let leadNames = leadRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard leadNames.count == numChannels, leadNames.allSatisfy({ !$0.isEmpty }) else { throw incomplete() }

        let sampleRate = kv["sample_rate_hz"].flatMap(Double.init)

        let amplitude: Amplitude
        switch encodingRaw {
        case "physical":
            guard let unit = kv["physical_unit"], !unit.isEmpty else { throw incomplete() }
            amplitude = .physical(unit: unit)
        case "adc_counts":
            let bits = kv["adc_resolution_bits"].flatMap(Int.init) ?? 16
            let gain = kv["adc_gain"].flatMap(Double.init) ?? 0
            let baseline = kv["adc_baseline"].flatMap(Int.init) ?? 0
            let unit = kv["physical_unit"] ?? "mV"
            amplitude = .adcCounts(resolutionBits: bits, gain: gain, baseline: baseline, unit: unit)
        default:
            throw incomplete()
        }

        if indexKind == .sampleNumber, sampleRate == nil {
            throw Refusal(reason: .missingSampleRate, line: nil, column: nil)
        }

        let sentinel = try kv["sentinel"].map(parseSentinelDecl)

        return Metadata(
            indexKind: indexKind,
            sampleRateHz: sampleRate,
            numChannels: numChannels,
            leadNames: leadNames,
            amplitude: amplitude,
            sentinel: sentinel,
            startDatetimeISO: kv["start_datetime"]
        )
    }

    private static func parseSentinelDecl(_ raw: String) throws -> Sentinel {
        let token = raw.trimmingCharacters(in: .whitespaces)
        if token.isEmpty { return .emptyCell }
        if token.caseInsensitiveCompare("NaN") == .orderedSame { return .nan }
        if let i = Int(token) { return .integer(i) }
        throw Refusal(reason: .malformedHeaderBlock, line: nil, column: nil)
    }

    // MARK: - Data rows

    private static func parseData(_ dataLines: [String], metadata: Metadata, fromHeader: Bool) throws -> Parsed {
        let expectedColumns = metadata.numChannels + 1
        // Header block occupies lines above; data line N is at file line
        // (headerCount + N). We report data-relative lines +1-based here; the
        // caller can offset by the header size if it wants absolute lines.
        var indexValues: [Double] = []
        var raw: [[String]] = []
        raw.reserveCapacity(dataLines.count)

        // Column count is taken from the first data row: rows disagreeing with
        // each other are RAGGED; rows that agree but don't match num_channels
        // are a COLUMN-COUNT MISMATCH — two distinct refusals.
        var actualColumns: Int?
        for (i, line) in dataLines.enumerated() {
            let lineNo = i + 1
            if line.contains("\"") { throw Refusal(reason: .quotedField, line: lineNo, column: nil) }
            let cells = line.components(separatedBy: ",")
            if let expected = actualColumns {
                guard cells.count == expected else {
                    throw Refusal(reason: .raggedRow, line: lineNo, column: nil)
                }
            } else {
                actualColumns = cells.count
            }
            var trimmed: [String] = []
            trimmed.reserveCapacity(cells.count)
            for (c, cell) in cells.enumerated() {
                // Trim ASCII spaces only; any other whitespace inside → refuse.
                let spaceTrimmed = cell.trimmingCharacters(in: CharacterSet(charactersIn: " "))
                if spaceTrimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                    throw Refusal(reason: .whitespaceInCell, line: lineNo, column: c + 1)
                }
                trimmed.append(spaceTrimmed)
            }
            raw.append(trimmed)
        }
        guard actualColumns == expectedColumns else {
            throw Refusal(reason: .columnCountMismatch, line: 1, column: nil)
        }

        // First data row must parse as numbers (no textual column-name row).
        // Index column.
        for (i, row) in raw.enumerated() {
            guard let v = parseFinite(row[0]) else {
                throw Refusal(reason: .indexNotNumeric, line: i + 1, column: 1)
            }
            indexValues.append(v)
        }
        let resolvedRate = try validateIndex(indexValues, metadata: metadata)

        // Signal columns.
        var channels = [[Int32]](repeating: [], count: metadata.numChannels)
        var missing = [[Int]](repeating: [], count: metadata.numChannels)
        for ch in 0..<metadata.numChannels { channels[ch].reserveCapacity(raw.count) }

        let gain = try resolveGain(raw: raw, metadata: metadata)

        for (i, row) in raw.enumerated() {
            for ch in 0..<metadata.numChannels {
                let cell = row[ch + 1]
                if isSentinel(cell, metadata.sentinel) {
                    missing[ch].append(i)
                    channels[ch].append(Int32.min)   // placeholder; WFDB invalid on write (X15-B)
                    continue
                }
                let value = try sampleValue(cell, metadata: metadata, gain: gain, line: i + 1, column: ch + 2)
                channels[ch].append(value)
            }
        }

        return Parsed(
            metadata: metadata,
            channelSamples: channels,
            missingByChannel: missing,
            sampleRateHz: resolvedRate,
            gain: gain,
            metadataFromHeaderBlock: fromHeader
        )
    }

    // MARK: - Index validation

    private static func validateIndex(_ values: [Double], metadata: Metadata) throws -> Double {
        guard values.count >= 2 else {
            // A single row — rate must come from metadata.
            if let r = metadata.sampleRateHz { return r }
            throw Refusal(reason: .missingSampleRate, line: nil, column: nil)
        }
        let step = values[1] - values[0]
        guard step > 0 else { throw Refusal(reason: .indexNotIncreasing, line: 2, column: 1) }

        switch metadata.indexKind {
        case .sampleNumber:
            for i in 1..<values.count {
                let d = values[i] - values[i - 1]
                if d <= 0 { throw Refusal(reason: .indexNotIncreasing, line: i + 1, column: 1) }
                if abs(d - 1) > 1e-9 { throw Refusal(reason: .sampleNumberStepNotOne, line: i + 1, column: 1) }
            }
            guard let rate = metadata.sampleRateHz else {
                throw Refusal(reason: .missingSampleRate, line: nil, column: nil)
            }
            return rate
        case .timeSeconds:
            for i in 1..<values.count {
                let d = values[i] - values[i - 1]
                if d <= 0 { throw Refusal(reason: .indexNotIncreasing, line: i + 1, column: 1) }
                if abs(d - step) > 1e-6 * max(abs(step), 1e-12) {
                    throw Refusal(reason: .indexStepNotUniform, line: i + 1, column: 1)
                }
            }
            let impliedRate = 1.0 / step
            if let declared = metadata.sampleRateHz,
               abs(declared - impliedRate) > 1e-6 * max(declared, 1) {
                throw Refusal(reason: .rateContradiction, line: nil, column: nil)
            }
            return impliedRate
        }
    }

    // MARK: - Sample values + gain

    /// Smallest power-of-ten gain making every `physical` value a lossless
    /// integer within the (implicit 16-bit) range; for `adc_counts` the declared
    /// gain (or 0 = unspecified) is returned unchanged.
    private static func resolveGain(raw: [[String]], metadata: Metadata) throws -> Double {
        switch metadata.amplitude {
        case .adcCounts(_, let gain, _, _):
            return gain
        case .physical:
            let maxCode = Int(Int16.max)   // 16-bit signed target
            for k in 0...8 {
                let g = pow(10.0, Double(k))
                var ok = true
                var overflow = false
                for row in raw {
                    for ch in 1..<row.count {
                        let cell = row[ch]
                        if isSentinel(cell, metadata.sentinel) { continue }
                        guard let v = parseFinite(cell) else { continue }  // caught later
                        let scaled = v * g
                        if abs(scaled - scaled.rounded()) > 1e-6 * max(1, abs(scaled)) { ok = false; break }
                        if abs(scaled.rounded()) > Double(maxCode) { overflow = true }
                    }
                    if !ok { break }
                }
                if ok {
                    if overflow { throw Refusal(reason: .losslessGainOverflowsBitDepth, line: nil, column: nil) }
                    return g
                }
            }
            throw Refusal(reason: .losslessGainOverflowsBitDepth, line: nil, column: nil)
        }
    }

    private static func sampleValue(_ cell: String, metadata: Metadata, gain: Double, line: Int, column: Int) throws -> Int32 {
        switch metadata.amplitude {
        case .adcCounts(let bits, _, _, _):
            // Must be a bare integer, no decimal point / exponent / unit.
            guard isIntegerToken(cell) else {
                if parseFinite(cell) != nil {
                    throw Refusal(reason: .signalNotNumeric, line: line, column: column)  // float in an int column
                }
                throw Refusal(reason: .nonConformantCell, line: line, column: column)
            }
            guard let i = Int(cell) else { throw Refusal(reason: .signalNotNumeric, line: line, column: column) }
            let limit = 1 << (bits - 1)
            guard i >= -limit && i <= limit - 1 else {
                throw Refusal(reason: .adcValueOutOfRange, line: line, column: column)
            }
            return Int32(i)
        case .physical:
            if hasEmbeddedUnitOrSeparator(cell) {
                throw Refusal(reason: .embeddedUnitOrSeparator, line: line, column: column)
            }
            guard let v = parseFinite(cell) else {
                throw Refusal(reason: .nonConformantCell, line: line, column: column)
            }
            return Int32((v * gain).rounded())
        }
    }

    // MARK: - Token helpers

    private static func isSentinel(_ cell: String, _ sentinel: Sentinel?) -> Bool {
        guard let sentinel else { return false }
        switch sentinel {
        case .emptyCell: return cell.isEmpty
        case .nan: return cell.caseInsensitiveCompare("NaN") == .orderedSame
        case .integer(let s): return Int(cell) == s
        }
    }

    /// A finite decimal number: optional sign, digits, optional `.frac`,
    /// optional `e`/`E` exponent. Rejects inf/nan tokens and anything else.
    private static func parseFinite(_ token: String) -> Double? {
        guard !token.isEmpty else { return nil }
        guard let v = Double(token), v.isFinite else { return nil }
        // `Double.init` accepts "inf"/"nan"/hex floats; require plain decimal chars.
        let allowed = CharacterSet(charactersIn: "0123456789+-.eE")
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return v
    }

    private static func isIntegerToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var s = Substring(token)
        if s.first == "+" || s.first == "-" { s = s.dropFirst() }
        return !s.isEmpty && s.allSatisfy(\.isNumber)
    }

    private static func hasEmbeddedUnitOrSeparator(_ token: String) -> Bool {
        // A letter that isn't part of an exponent, or a stray separator. The
        // valid-number check catches most; this gives the specific reason for
        // the "1.2 mV" / "1,024" fingerprints of hand-editing.
        for ch in token where ch.isLetter && ch != "e" && ch != "E" { return true }
        return false
    }
}
