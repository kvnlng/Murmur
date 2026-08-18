//
//  RecordingBundleSweeper.swift
//  MurmurCore
//
//  Launch-time sweep of recording bundles that can never be opened again.
//
//  Every import before source-fingerprint reuse existed created a fresh
//  bundle under Application Support / Murmur / recordings — repeated opens
//  of the same PhysioNet record piled up hundreds of byte-identical
//  bundles (938 bundles / 16 GB measured before the sweep). Reuse
//  (SourceFingerprint, #311) stopped the pile-up going forward but left
//  the pile: a bundle WITHOUT a fingerprint can never be matched by any
//  future import — `reusableSummary` compares fingerprints, and absence
//  never matches — so those bundles are dead weight the moment they were
//  superseded. Bundles WITH a fingerprint are the reuse cache itself and
//  are kept: deleting one trades disk for a multi-minute re-import, and
//  the population is bounded at one per distinct source record.
//
//  TempScratchSweeper's mold, for the same reasons it has them: swept at
//  launch (the one moment this process provably has no session open), off
//  the main actor, with an age cutoff so a parallel instance's import that
//  is IN FLIGHT — its bundle exists but its fingerprint stamp only lands
//  after the import succeeds — is never reaped mid-write. The residual
//  window (a pre-fingerprint app version holding a bundle open for over an
//  hour while this version launches beside it) is accepted the same way
//  TempScratchSweeper accepts it: bundles are pure derived data, and the
//  cost of the miss is a re-import, not data loss.
//

import Foundation
import OSLog

public enum RecordingBundleSweeper {
    /// Same persisted category as the compute log, so the sweep's effect
    /// shows up in the log that measures what the bundles cost.
    private static let log = Logger(
        subsystem: "com.kevinlong.murmur", category: "compute"
    )

    /// Sweep the default bundles root. Call once at app launch, off-main.
    public static func sweepAtLaunch() {
        sweepUnreusableBundles(in: RecordingStore.defaultRootURL())
    }

    /// Remove every direct child of `root` that is provably an unreusable
    /// recording bundle: a directory carrying a manifest (`recording.json`
    /// — anything else is not ours and is never touched), carrying NO
    /// readable source fingerprint (so no future import can match it), and
    /// older than `cutoff` (so an in-flight parallel import is spared).
    /// Returns the number removed; failures are silent per-entry — a bundle
    /// that won't delete costs disk, nothing more.
    @discardableResult
    static func sweepUnreusableBundles(
        in root: URL,
        olderThan cutoff: Date = Date(timeIntervalSinceNow: -3600),
        fileManager: FileManager = .default
    ) -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        var removed = 0
        for url in entries {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let manifest = url.appendingPathComponent("recording.json")
            guard fileManager.fileExists(atPath: manifest.path) else { continue }
            // A malformed fingerprint reads as nil, which `reusableSummary`
            // also treats as "never reuse" — so it is equally unreusable
            // and equally sweepable.
            guard SourceFingerprint.read(from: url) == nil else { continue }
            guard let modified = values?.contentModificationDate,
                  modified < cutoff else { continue }
            guard (try? fileManager.removeItem(at: url)) != nil else { continue }
            removed += 1
        }
        if removed > 0 {
            log.notice("Swept \(removed, privacy: .public) unreusable recording bundle(s)")
        }
        return removed
    }
}
