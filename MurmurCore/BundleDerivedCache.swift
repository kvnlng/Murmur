//
//  BundleDerivedCache.swift
//  MurmurCore
//
//  Derived-result cache inside a recording bundle: one version-stamped blob
//  per producer at `<bundle>/cache/<producer>.blob`.
//
//  This is the durable big sibling of the in-memory report cache in
//  VariabilityMetricsOrchestrator, built on the same X14-C discipline
//  (`MurSessionCache`): a blob decodes ONLY when its stamp matches, and any
//  mismatch or corruption is a miss — recompute — never a stale render.
//  Combined with source-fingerprinted bundle reuse (SourceFingerprint),
//  this is what makes a record's SECOND open cheap: the first open pays the
//  orchestrator computes once (~25 s optimized on a 25-hour record) and
//  every open after that reads blobs.
//
//  The stamp's `version` is the app's version+build, not a hand-bumped
//  per-producer constant, on purpose: the producing algorithms live in the
//  Murmur-Extensions packages and land here through exact-pin bumps, so
//  every algorithm change is an app-build change. Keying on the build makes
//  forgetting to bump impossible; the cost — caches invalidate on every app
//  update, including UI-only ones — is one recompute per record per update.
//  For measurements that feed clinical review, over-invalidation is the
//  right side to err on.
//
//  Payloads are Codable and JSON-encoded, then LZFSE-compressed behind a
//  magic prefix. JSON keeps the payload format debuggable and Release
//  decode was measured fast enough (~710 ms for the 47 MB markings blob);
//  what JSON is NOT is small — the ~100k-beat markings array is ~47 MB of
//  highly repetitive text, carried verbatim into every .mur save. LZFSE
//  shrinks that at a decompress cost far below the JSON parse it feeds.
//  The prefix, not the stamp, carries the format: a payload without it is
//  legacy raw JSON and still decodes — blobs written by older builds
//  (including ones restored out of existing .mur saves) need no migration,
//  they just get compressed on their next rewrite.
//

import Foundation
import OSLog

public enum BundleDerivedCache {

    /// Same persisted category as the compute signposts, so one log read
    /// tells the whole story: which components hit, which missed and WHY,
    /// and what the blob decode cost. Exists because the first field read
    /// of the cache required filesystem archaeology (blob mtimes) to prove
    /// the hits happened — the durations alone were dominated by
    /// main-actor wait and looked like misses.
    private static let log = Logger(
        subsystem: "com.kevinlong.murmur", category: "compute"
    )

    static let cacheSubdirectory = "cache"

    /// The version every stamp carries — see header for why this is the app
    /// build rather than per-producer constants.
    public static let appVersionStamp: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(build)"
    }()

    /// Read a producer's cached payload from a bundle. Nil on absence, stamp
    /// mismatch (version or parameters), or any decode failure — all of
    /// which mean "recompute", never an error.
    public static func load<T: Decodable>(
        _ type: T.Type,
        producer: String,
        parametersKey: String,
        from bundleDirectory: URL
    ) -> T? {
        let started = DispatchTime.now().uptimeNanoseconds
        let url = blobURL(producer: producer, in: bundleDirectory)
        guard let blob = try? Data(contentsOf: url) else {
            log.notice("Cache MISS (no blob) — \(producer, privacy: .public)")
            return nil
        }
        let stamp = CacheStamp(
            producer: producer, version: appVersionStamp, parametersKey: parametersKey
        )
        guard let payload = MurSessionCache.decode(blob, expected: stamp) else {
            // The stored stamp is inside the blob; naming both sides makes a
            // version or parameter drift diagnosable from the log alone.
            log.notice("Cache MISS (stamp) — \(producer, privacy: .public) expected \(appVersionStamp, privacy: .public) / \(parametersKey, privacy: .public)")
            return nil
        }
        guard let json = decompressed(payload),
              let value = try? JSONDecoder().decode(T.self, from: json) else {
            log.error("Cache MISS (payload decode) — \(producer, privacy: .public), \(payload.count, privacy: .public) bytes")
            return nil
        }
        let ms = (DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        log.notice("Cache HIT — \(producer, privacy: .public) in \(ms, privacy: .public) ms (\(blob.count, privacy: .public) bytes)")
        return value
    }

    /// Persist a producer's payload into a bundle. Failures are silent — a
    /// bundle that can't hold a cache (read-only, vanished mid-session)
    /// costs a recompute next open, nothing more.
    public static func store<T: Encodable>(
        _ value: T,
        producer: String,
        parametersKey: String,
        in bundleDirectory: URL
    ) {
        let dir = bundleDirectory.appendingPathComponent(cacheSubdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = CacheStamp(
            producer: producer, version: appVersionStamp, parametersKey: parametersKey
        )
        guard let payload = try? JSONEncoder().encode(value),
              let blob = try? MurSessionCache.encode(stamp: stamp, payload: compressed(payload)) else { return }
        try? blob.write(to: blobURL(producer: producer, in: bundleDirectory), options: .atomic)
    }

    // MARK: - Payload compression

    /// Marks a payload as LZFSE-compressed. JSON can never begin with these
    /// bytes (a payload starts with `{` or `[`), so ABSENCE of the prefix is
    /// the legacy format — see header.
    private static let compressionMagic = Data("MRZ1".utf8)

    /// LZFSE-compress an encoded payload, magic-prefixed. Falls back to the
    /// raw bytes when compression fails or wouldn't pay — the load side keys
    /// on the prefix, so either form round-trips.
    private static func compressed(_ payload: Data) -> Data {
        guard let squeezed = try? (payload as NSData).compressed(using: .lzfse) as Data,
              squeezed.count + compressionMagic.count < payload.count else { return payload }
        return compressionMagic + squeezed
    }

    /// Undo `compressed(_:)`. Raw (un-prefixed) payloads pass through; a
    /// prefixed payload that fails to decompress is nil — corruption, which
    /// the caller treats as a miss like every other decode failure.
    private static func decompressed(_ payload: Data) -> Data? {
        guard payload.starts(with: compressionMagic) else { return payload }
        let body = Data(payload.dropFirst(compressionMagic.count))
        return try? (body as NSData).decompressed(using: .lzfse) as Data
    }

    private static func blobURL(producer: String, in bundleDirectory: URL) -> URL {
        bundleDirectory
            .appendingPathComponent(cacheSubdirectory, isDirectory: true)
            .appendingPathComponent("\(producer).blob")
    }
}
