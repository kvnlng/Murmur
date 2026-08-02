//
//  SessionDocumentCoordinator.swift
//  MurmurCore
//
//  Bridges a "please open this .mur" request from a Scene-level menu command
//  (which can't reach ContentView's private state) to ContentView, which owns
//  the presentation. The File → Open Session… command sets `openRequestURL`;
//  ContentView observes it, loads the package, and clears it. Finder
//  double-clicks arrive separately via `.onOpenURL` and route through the same
//  ContentView loader, so this coordinator only carries the menu path.
//

import Foundation
import Observation

@MainActor
@Observable
public final class SessionDocumentCoordinator {
    public static let shared = SessionDocumentCoordinator()

    /// Set by the Open Session… command; ContentView consumes it (loads the
    /// package, presents it) and resets it to nil.
    public var openRequestURL: URL?

    /// Set by the File ▸ Open Recent menu (X22). Carries the entry rather than a
    /// resolved URL so ContentView runs its own `reopen` — resolving the
    /// security-scoped bookmark and reading the folder in one synchronous call,
    /// which a resolved URL routed through `openRequestURL` (consumed async)
    /// could not keep scoped.
    public var reopenRecentRequest: RecentFolder?

    public init() {}

    public func requestOpen(_ url: URL) { openRequestURL = url }

    public func requestReopenRecent(_ entry: RecentFolder) { reopenRecentRequest = entry }
}
