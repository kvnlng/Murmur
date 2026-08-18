//
//  AnnotationDerivations.swift
//  MurmurCore
//
//  The render-path annotation arrays for one bedside view, derived ONCE per
//  input change instead of on every access.
//
//  Why this exists (#17): `BedsideView` derived these through computed
//  properties — `(recording.annotations + attached).map {...}` then chained
//  filters — evaluated on the MAIN actor on every access, with roughly eight
//  render-path accesses per body evaluation. At nsrdb scale (100,216
//  annotations) each access measured 5.8–12.4 ms Release-optimized, and every
//  access minted fresh array identities, so downstream views could never
//  short-circuit — each body evaluation re-rendered every heavy child. During
//  a record mount, with eight orchestrators publishing into @Observable
//  contexts, that compounded into ~5 s of blocked main actor: the convoy
//  whose fingerprint (multiple compute intervals ending within 1 ms of each
//  other) showed up in the #13 field verification.
//
//  The derivation is pure and runs off-main; the view holds the result in
//  @State and rebuilds it via `.task(id:)` keyed on the inputs. Stable array
//  identities between rebuilds are the other half of the fix: unchanged
//  arrays compare pointer-equal, so SwiftUI's change detection can finally
//  say "nothing changed here".
//
//  Persistence and export paths deliberately do NOT read this — they
//  recompute fresh from the sources (rare, and a stale write is a worse bug
//  than a slow one). This struct is for what the SCREEN shows.
//

import Foundation

public struct AnnotationDerivations: Equatable, Sendable {

    /// Union of the recording's annotations and session-attached ones, with
    /// the rename overlay applied — the render-path equivalent of the
    /// authoring paths' fresh computation.
    public let all: [Annotation]

    /// `all` through the analyst's finding filter. Drives the overview map
    /// and finding navigation.
    public let filtered: [Annotation]

    /// `filtered` per channel name — lead-tagged findings on their channel,
    /// lead-less findings on every channel. Built in one pass over the
    /// channel list so the per-channel ForEach reads a dictionary instead of
    /// re-filtering 100k elements per channel per body evaluation.
    public let byChannel: [String: [Annotation]]

    public init() {
        all = []
        filtered = []
        byChannel = [:]
    }

    init(all: [Annotation], filtered: [Annotation], byChannel: [String: [Annotation]]) {
        self.all = all
        self.filtered = filtered
        self.byChannel = byChannel
    }

    /// Pure build — same semantics, in order, as BedsideView's
    /// `allAnnotations` → `filteredAnnotations` → `annotationsForChannel`.
    public static func build(
        recordingAnnotations: [Annotation],
        attached: [Annotation],
        renamedLabels: [UUID: String],
        filter: FindingFilter,
        channelNames: [String]
    ) -> AnnotationDerivations {
        let all = (recordingAnnotations + attached).map { annotation in
            guard let newLabel = renamedLabels[annotation.id] else { return annotation }
            return annotation.withLabel(newLabel)
        }
        let filtered = all.filter(filter.matches)
        var byChannel: [String: [Annotation]] = [:]
        byChannel.reserveCapacity(channelNames.count)
        for name in channelNames {
            byChannel[name] = filtered.filter { $0.matchesChannel(name) }
        }
        return AnnotationDerivations(all: all, filtered: filtered, byChannel: byChannel)
    }
}
