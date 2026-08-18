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
//  Payloads are Codable and JSON-encoded. JSON is not the fastest choice
//  for the largest payload (the ~100k-beat markings array), but every cache
//  read runs inside its orchestrator's ComputeSignpost interval, so if
//  decode cost ever rivals recompute cost it will be visible in the same
//  log that motivated this file.
//

import Foundation

public enum BundleDerivedCache {

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
        let url = blobURL(producer: producer, in: bundleDirectory)
        guard let blob = try? Data(contentsOf: url) else { return nil }
        let stamp = CacheStamp(
            producer: producer, version: appVersionStamp, parametersKey: parametersKey
        )
        guard let payload = MurSessionCache.decode(blob, expected: stamp) else { return nil }
        return try? JSONDecoder().decode(T.self, from: payload)
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
              let blob = try? MurSessionCache.encode(stamp: stamp, payload: payload) else { return }
        try? blob.write(to: blobURL(producer: producer, in: bundleDirectory), options: .atomic)
    }

    private static func blobURL(producer: String, in bundleDirectory: URL) -> URL {
        bundleDirectory
            .appendingPathComponent(cacheSubdirectory, isDirectory: true)
            .appendingPathComponent("\(producer).blob")
    }
}
