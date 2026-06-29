//
//  CitationBuilder.swift
//  MurmurCore
//
//  Generates citation strings (BibTeX, RIS) for the free Murmur Studio
//  viewer. The in-app "Copy citation" Help-menu items call into this
//  module and write the result to NSPasteboard.
//
//  Pure functions, no I/O, no environment access — caller decides which
//  format to emit and whether a DOI is yet known. Once the Zenodo
//  integration mints DOIs at release time, the caller fills in the
//  `doi` argument; until then a `TBD` placeholder ships so the entry is
//  copy-pasteable and obviously needs the value replaced.
//
//  Scope is currently the free viewer only. Citation routing for the
//  paid IAPs (Silver, VT) is deferred until those frameworks ship —
//  see ROADMAP.md "Citation infrastructure → Routing".
//

import Foundation

/// Citation output formats we support.
enum CitationFormat: String, CaseIterable, Sendable {
    /// BibTeX `@software{...}` entry. Default for the in-app Copy
    /// citation action.
    case bibtex
    /// RIS reference-format. Some reference managers (EndNote, Zotero
    /// pre-CSL) prefer this over BibTeX.
    case ris
}

enum CitationBuilder {

    /// Default placeholder used in place of a real DOI when the
    /// Zenodo integration hasn't been wired yet. Obvious enough that
    /// researchers will notice they need to fill it in.
    static let pendingDOIPlaceholder = "10.5281/zenodo.XXXXXXX"

    /// Builds a citation entry for the Murmur Studio viewer.
    ///
    /// - Parameters:
    ///   - format: BibTeX or RIS.
    ///   - version: software version string, e.g. `"1.0.0"`.
    ///   - doi: Zenodo DOI; nil substitutes the placeholder.
    ///   - year: publication year; defaults to current year (UTC) when nil.
    static func formatViewer(
        format: CitationFormat,
        version: String = "1.0.0",
        doi: String? = nil,
        year: Int? = nil
    ) -> String {
        let resolvedDOI = doi ?? pendingDOIPlaceholder
        let resolvedYear = year ?? currentYearUTC()
        switch format {
        case .bibtex:
            return bibtex(version: version, doi: resolvedDOI, year: resolvedYear)
        case .ris:
            return ris(version: version, doi: resolvedDOI, year: resolvedYear)
        }
    }

    // MARK: - Format-specific renderers

    private static func bibtex(version: String, doi: String, year: Int) -> String {
        """
        @software{murmur_studio,
          author       = {Long, Kevin},
          title        = {{Murmur Studio: A native macOS viewer for
                           PhysioNet WFDB recordings}},
          year         = {\(year)},
          publisher    = {Zenodo},
          version      = {\(version)},
          doi          = {\(doi)},
          url          = {https://github.com/kvnlng/Murmur}
        }
        """
    }

    private static func ris(version: String, doi: String, year: Int) -> String {
        """
        TY  - COMP
        AU  - Long, Kevin
        TI  - Murmur Studio: A native macOS viewer for PhysioNet WFDB recordings
        PY  - \(year)
        PB  - Zenodo
        ET  - \(version)
        DO  - \(doi)
        UR  - https://github.com/kvnlng/Murmur
        ER  -
        """
    }

    // MARK: - Helpers

    private static func currentYearUTC() -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.component(.year, from: Date())
    }
}

// MARK: - Public app-target bridge

#if canImport(AppKit)
import AppKit

/// Builds the viewer citation in `format` and writes it to the system
/// pasteboard. Public so `MurmurApp`'s Help menu can call into it
/// across the module boundary without needing direct access to the
/// internal CitationBuilder / CitationFormat types.
///
/// Returns the string that was written, so callers can show a brief
/// confirmation or log it. The pasteboard write replaces previous
/// contents (standard NSPasteboard semantics).
@MainActor
@discardableResult
public func copyViewerCitationToPasteboard(asBibTeX: Bool) -> String {
    let format: CitationFormat = asBibTeX ? .bibtex : .ris
    let text = CitationBuilder.formatViewer(format: format)
    let pasteboard = NSPasteboard.general
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString(text, forType: .string)
    return text
}
#endif
