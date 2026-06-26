//
//  RecentFoldersStore.swift
//  Murmur
//
//  Remembers the last few folders the user has opened so the welcome
//  screen can offer one-tap re-entry. Each entry stores a security-scoped
//  bookmark — sandboxed Murmur can only re-open folders by resolving
//  bookmarks captured the first time the user picked them, not by saving
//  raw paths.
//
//  Storage lives in `UserDefaults` under a single versioned key so the
//  format can evolve without colliding with older entries.
//

import Foundation

/// One row in the recent-folders list. `id` and `addedAt` are local; the
/// bookmark is what actually gets the sandbox to hand the folder back.
struct RecentFolder: Codable, Identifiable, Equatable {
    let id: UUID
    let displayName: String
    /// Best-effort path captured at record-time. Used for display, dedup
    /// against re-picking the same folder, and as a "last seen at" hint
    /// when the bookmark resolves to a moved location.
    let resolvedPath: String
    let bookmarkData: Data
    let addedAt: Date
}

@Observable
final class RecentFoldersStore {
    private(set) var entries: [RecentFolder] = []

    /// Versioned key — bump if the `RecentFolder` shape ever changes
    /// incompatibly.
    private let defaultsKey = "MurmurRecentFolders.v1"
    /// Pre-rename key. Read once on first launch to carry recents forward.
    private let legacyDefaultsKey = "PlottingRecentFolders.v1"
    private let maxEntries = 10
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyDefaultsIfNeeded()
        self.entries = loadFromDefaults()
    }

    private func migrateLegacyDefaultsIfNeeded() {
        guard defaults.data(forKey: defaultsKey) == nil,
              let legacy = defaults.data(forKey: legacyDefaultsKey) else { return }
        defaults.set(legacy, forKey: defaultsKey)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    // MARK: - Mutations

    /// Record (or move-to-top) a folder the user just opened. No-op if a
    /// security-scoped bookmark can't be captured for it.
    func record(folder: URL) {
        guard let bookmark = makeBookmark(for: folder) else { return }
        let entry = RecentFolder(
            id: UUID(),
            displayName: folder.lastPathComponent,
            resolvedPath: folder.path,
            bookmarkData: bookmark,
            addedAt: .now
        )
        var next = entries.filter { $0.resolvedPath != entry.resolvedPath }
        next.insert(entry, at: 0)
        if next.count > maxEntries {
            next = Array(next.prefix(maxEntries))
        }
        entries = next
        persist()
    }

    func remove(_ entry: RecentFolder) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    // MARK: - Resolution

    /// Resolve an entry's bookmark to a current `URL`. Returns `nil` when
    /// the bookmark is irrecoverable — caller should drop the entry from
    /// the store in that case.
    func resolve(_ entry: RecentFolder) -> URL? {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: entry.bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            return nil
        }
        // Stale bookmarks usually still resolve — refresh in the background
        // so subsequent opens stay healthy. Failures here are non-fatal.
        if isStale, let refreshed = makeBookmark(for: url) {
            let refreshedEntry = RecentFolder(
                id: entry.id,
                displayName: url.lastPathComponent,
                resolvedPath: url.path,
                bookmarkData: refreshed,
                addedAt: entry.addedAt
            )
            entries = entries.map { $0.id == entry.id ? refreshedEntry : $0 }
            persist()
        }
        return url
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func loadFromDefaults() -> [RecentFolder] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([RecentFolder].self, from: data)) ?? []
    }

    private func makeBookmark(for url: URL) -> Data? {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
