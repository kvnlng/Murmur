//
//  TempScratchSweeper.swift
//  MurmurCore
//
//  Launch-time sweep of the per-operation scratch the app writes under the
//  container tmp and never deletes afterwards:
//
//      csv-import-<UUID>/      CSV → WFDB working dir (presentParsedCSV)
//      mur-session-<UUID>/     extracted .mur package (openMurPackage)
//      ui-test-<UUID>.mur/.csv UI-test launch fixtures
//      murmur-ui-test-open/    synthetic folder-open fixtures (one child/launch)
//
//  None of these can be deleted when the operation finishes: the csv-import
//  and mur-session directories back the viewing session that follows (channel
//  binaries are read lazily from them for as long as the record is open), and
//  the UI-test fixtures outlive the app because XCUI terminates it with no
//  teardown hook. So — like SyntheticRecording.sweepStaleFixtures, which
//  exists for the same reason — leftovers are reaped at the NEXT launch,
//  before this process has opened any session of its own (~650 MB of them had
//  accumulated before this sweep existed).
//
//  The age cutoff is not redundant with "at launch": parallel XCUI test runs
//  launch several app instances against the same container tmp, and an
//  instance that is just starting must not reap a sibling's live scratch.
//  Anything younger than an hour is spared, which covers every concurrent
//  instance; anything older can only be litter from a dead process.
//

import Foundation

public enum TempScratchSweeper {

    /// Entry-name prefixes this sweep owns. Exact-name matches count too
    /// (`murmur-ui-test-open` is a fixed-name parent whose modification date
    /// moves whenever a launch adds a child, so a stale date means no child
    /// was created in the past hour and the whole tree is dead).
    public static let scratchPrefixes = [
        "csv-import-",
        "mur-session-",
        "ui-test-",
        "murmur-ui-test-open",
    ]

    /// Best-effort removal of scratch entries left behind by earlier
    /// launches. Call once at app launch; entries created after launch are
    /// inherently younger than the cutoff, so running this off-main can
    /// never race a session the analyst has just opened.
    public static func sweepAtLaunch(
        in parent: URL = FileManager.default.temporaryDirectory,
        olderThan cutoff: Date = Date(timeIntervalSinceNow: -3600)
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            guard scratchPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
