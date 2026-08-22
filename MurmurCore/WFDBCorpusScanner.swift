//
//  WFDBCorpusScanner.swift
//  MurmurCore
//
//  Builds a corpus's record list from the folder the analyst picked (#329).
//
//  The picker used to do one non-recursive `contentsOfDirectory` for `.hea`
//  files. That is the shape of a MIT-BIH database directory and it is NOT the
//  shape of a large PhysioNet corpus: WFDB's own convention is a `RECORDS`
//  index at the root naming either record names or subdirectories, each of
//  those carrying its own `RECORDS`. `ecg-arrhythmia/1.0.0` is 45,152 records
//  across 452 leaf folders, so picking its root reported "No WFDB records
//  found" — the corpus most likely to be worth reviewing was the one Murmur
//  could not open.
//
//  This honours the index when there is one and behaves exactly as before
//  when there isn't. The index is the corpus author's own statement of what
//  the corpus contains, which is why it is read rather than second-guessed by
//  a blind recursive walk: a `.hea` sitting in the tree that `RECORDS` does
//  not list was excluded on purpose.
//
//  Pure over a root URL and free of UI: the caller runs it off the main actor
//  (45k header parses is seconds of work) and owns the security scope.
//
//  Reference: WFDB Applications Guide, "Database directories and the RECORDS
//  file" — https://physionet.org/physiotools/wag/wag.htm
//

import Foundation

enum WFDBCorpusScanner {
    /// What a scan found, plus what it could not use. Nothing is dropped
    /// silently: an index entry with no `.hea` beside it and a path the scan
    /// refused to follow are both reported to the analyst.
    struct Result: Sendable {
        let entries: [WFDBRecordEntry]
        /// Root-relative paths the index named but that produced no record —
        /// the `.hea` is missing, or it is there and does not parse.
        ///
        /// Paths, not a bare count: PhysioNet's own ecg-arrhythmia 1.0.0 ships
        /// two headers (`01/019/JS01052`, `23/236/JS23074`) whose record line
        /// and first signal line were merged by a lost newline, so they
        /// declare 12 signals and carry 11. "2 records were skipped" leaves an
        /// analyst with 45,150 rows and no way to find the two — which is a
        /// report that technically told the truth and practically didn't.
        let skipped: [String]
        /// Root-relative paths the scan declined: outside the picked folder,
        /// deeper than `maxDepth`, or an index file it could not read.
        let unreadable: [String]

        /// Banner text for a completed open, or nil when everything resolved
        /// and the record count already speaks for itself.
        var shortfallSummary: String? {
            var parts: [String] = []
            if !skipped.isEmpty {
                let noun = skipped.count == 1 ? "entry" : "entries"
                var part = "\(skipped.count) index \(noun) had no readable .hea"
                // Named while there are few enough to read. Past that the list
                // is the corpus's problem, not a banner's.
                if skipped.count <= WFDBCorpusScanner.namedSkipLimit {
                    part += " (\(skipped.joined(separator: ", ")))"
                }
                parts.append(part)
            }
            if !unreadable.isEmpty {
                let noun = unreadable.count == 1 ? "path was" : "paths were"
                parts.append("\(unreadable.count) \(noun) not followed")
            }
            guard !parts.isEmpty else { return nil }
            return "Opened \(entries.count) \(entries.count == 1 ? "record" : "records"); "
                + parts.joined(separator: ", ") + "."
        }
    }

    /// The name WFDB gives its index file. Case-sensitive, as the spec is.
    static let indexFileName = "RECORDS"

    /// How many skipped paths the banner will name before falling back to a
    /// bare count.
    private static let namedSkipLimit = 3

    /// Scans `root`, honouring `RECORDS` indexes recursively.
    ///
    /// `maxDepth` is a guard against a pathological or circular tree, not a
    /// statement about real corpora — `ecg-arrhythmia` nests three levels.
    /// `onProgress` is called with a running entry count so a caller can show
    /// motion during a long scan; it is called on the scanning thread.
    static func scan(
        root: URL,
        maxDepth: Int = 6,
        onProgress: ((Int) -> Void)? = nil
    ) throws -> Result {
        var accumulator = Accumulator()
        let context = WalkContext(
            // Resolved once, up front: every child path is checked against this
            // so the scan cannot walk out of the folder the analyst granted.
            boundary: root.resolvingSymlinksInPath().standardizedFileURL.path,
            maxDepth: maxDepth,
            onProgress: onProgress
        )
        try walk(directory: root, relativePrefix: "", depth: 0, context: context, into: &accumulator)
        accumulator.entries.sort { $0.filename < $1.filename }
        return Result(
            entries: accumulator.entries,
            skipped: accumulator.skipped,
            unreadable: accumulator.unreadable
        )
    }

    // MARK: - Walk

    private struct Accumulator {
        var entries: [WFDBRecordEntry] = []
        var skipped: [String] = []
        var unreadable: [String] = []
        /// Entry count at the last progress callback, so the caller is nudged
        /// every `progressStride` records rather than 45,152 times.
        var lastReported = 0
    }

    private static let progressStride = 500

    /// The parts of a scan that never change as it descends, so the recursion
    /// carries only what actually varies: where it is and how deep.
    private struct WalkContext {
        let boundary: String
        let maxDepth: Int
        let onProgress: ((Int) -> Void)?
    }

    private static func walk(
        directory: URL,
        relativePrefix: String,
        depth: Int,
        context: WalkContext,
        into accumulator: inout Accumulator
    ) throws {
        let indexURL = directory.appendingPathComponent(indexFileName)

        guard isReadableFile(indexURL) else {
            // No index here: this is a plain WFDB directory, scanned exactly
            // the way the pre-#329 picker scanned the one folder it looked at.
            try scanFlat(
                directory: directory,
                relativePrefix: relativePrefix,
                context: context,
                into: &accumulator
            )
            return
        }

        guard let text = try? String(contentsOf: indexURL, encoding: .utf8) else {
            // An index we cannot read is reported, not treated as "no index" —
            // falling through to a flat scan would quietly return a fraction
            // of the corpus and look like success.
            accumulator.unreadable.append(relativePrefix + indexFileName)
            return
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Blank lines and `#` comments appear in published indexes.
            if line.isEmpty || line.hasPrefix("#") { continue }

            let isDirectoryLine = line.hasSuffix("/")
            let name = isDirectoryLine ? String(line.dropLast()) : line
            if name.isEmpty { continue }

            guard let child = resolve(name, under: directory, boundary: context.boundary) else {
                // Absolute path, `..` escape, or a symlink pointing out of the
                // picked folder. The app is sandboxed: a security-scoped grant
                // covers the picked tree and nothing else, so following one of
                // these would fail at read time anyway — better to say so.
                accumulator.unreadable.append(relativePrefix + line)
                continue
            }

            if isDirectoryLine || isDirectory(child) {
                guard depth < context.maxDepth else {
                    accumulator.unreadable.append(relativePrefix + line)
                    continue
                }
                try walk(
                    directory: child,
                    relativePrefix: relativePrefix + name + "/",
                    depth: depth + 1,
                    context: context,
                    into: &accumulator
                )
                continue
            }

            // A record NAME, not a filename — WFDB indexes omit the extension.
            let heaURL = directory.appendingPathComponent(name + ".hea")
            guard let header = try? WFDBHeaderParser.parse(url: heaURL) else {
                accumulator.skipped.append(relativePrefix + name + ".hea")
                continue
            }
            append(
                WFDBRecordEntry(filename: relativePrefix + name + ".hea", header: header),
                to: &accumulator,
                onProgress: context.onProgress
            )
        }
    }

    /// The pre-#329 behaviour, unchanged: every `.hea` in one directory.
    private static func scanFlat(
        directory: URL,
        relativePrefix: String,
        context: WalkContext,
        into accumulator: inout Accumulator
    ) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "hea" {
            guard let header = try? WFDBHeaderParser.parse(url: url) else { continue }
            append(
                WFDBRecordEntry(filename: relativePrefix + url.lastPathComponent, header: header),
                to: &accumulator,
                onProgress: context.onProgress
            )
        }
    }

    private static func append(
        _ entry: WFDBRecordEntry,
        to accumulator: inout Accumulator,
        onProgress: ((Int) -> Void)?
    ) {
        accumulator.entries.append(entry)
        if accumulator.entries.count - accumulator.lastReported >= progressStride {
            accumulator.lastReported = accumulator.entries.count
            onProgress?(accumulator.entries.count)
        }
    }

    // MARK: - Containment

    /// Resolves an index entry against its directory, or nil when the result
    /// would leave the picked folder. Rejects absolute paths and `..` before
    /// touching the filesystem, then re-checks after symlink resolution — a
    /// name with neither can still be a symlink pointing anywhere.
    private static func resolve(_ name: String, under directory: URL, boundary: String) -> URL? {
        if name.hasPrefix("/") || name.hasPrefix("~") { return nil }
        if name.components(separatedBy: "/").contains("..") { return nil }
        let candidate = directory.appendingPathComponent(name)
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == boundary || resolved.hasPrefix(boundary + "/") else { return nil }
        return candidate
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    private static func isReadableFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }
}
