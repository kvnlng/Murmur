//
//  BundleAnnotationsFile.swift
//  Murmur
//
//  Read/write the bundle-side `annotations.json` sidecar that lives inside
//  each imported recording directory. This file is the source of truth for
//  a recording's findings once the bundle exists — it survives across
//  launches and gets updated by the "Attach findings…" toolbar action so
//  re-running the producer doesn't require a full re-import of the .dat
//  samples.
//
//  Wire format:
//      {
//        "schemaVersion": 1,
//        "annotations": [ ...resolved Annotation values... ]
//      }
//
//  The schema version is independent of `Recording.currentVersion` so the
//  manifest and the annotations sidecar can evolve on different cadences.
//

import Foundation

struct BundleAnnotationsFile: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let annotations: [Annotation]

    static let currentSchemaVersion = 1
    static let filename = "annotations.json"

    static func read(from bundleDirectory: URL) -> [Annotation]? {
        let url = bundleDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? JSONDecoder().decode(BundleAnnotationsFile.self, from: data) else {
            return nil
        }
        guard payload.schemaVersion == BundleAnnotationsFile.currentSchemaVersion else {
            return nil
        }
        return payload.annotations
    }

    static func write(_ annotations: [Annotation], to bundleDirectory: URL) throws {
        let payload = BundleAnnotationsFile(
            schemaVersion: BundleAnnotationsFile.currentSchemaVersion,
            annotations: annotations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let url = bundleDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
    }
}
