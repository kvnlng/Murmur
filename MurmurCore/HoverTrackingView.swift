//
//  HoverTrackingView.swift
//  Murmur
//
//  AppKit-backed mouse hover tracking that survives a SwiftUI overlay above
//  an NSViewRepresentable (the MTKView in WaveformCanvas).
//
//  Why not `.onContinuousHover`?
//  SwiftUI's `.onContinuousHover` installs an NSTrackingArea on the
//  SwiftUI-managed NSView. When the underlying view hierarchy contains an
//  NSViewRepresentable (the MTKView), the tracking area either collides
//  with the representable's responder chain or is silently dropped — the
//  hover handler fires inconsistently or not at all.
//
//  The workaround is a transparent NSView with its own NSTrackingArea that
//  overrides `hitTest(_:)` to return nil, so clicks/drags fall straight
//  through to the gesture recognizers attached to the parent SwiftUI view.
//  The tracking area continues to receive mouse-moved events for free.
//

import AppKit
import SwiftUI

/// SwiftUI-friendly mouse hover tracker. Drop it into a ZStack overlay
/// over the view you want to track; the trailing closure fires with the
/// current pointer location (in SwiftUI top-left coordinates) on
/// mouseEntered/mouseMoved, and `nil` on mouseExited.
struct HoverTrackingView: NSViewRepresentable {
    var onUpdate: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackerNSView {
        let view = TrackerNSView()
        view.onUpdate = onUpdate
        return view
    }

    func updateNSView(_ nsView: TrackerNSView, context: Context) {
        nsView.onUpdate = onUpdate
    }
}

final class TrackerNSView: NSView {
    var onUpdate: ((CGPoint?) -> Void)?
    private var trackingArea: NSTrackingArea?

    /// Flip the coordinate system so the points reported to SwiftUI match
    /// its top-left origin convention out of the box (no manual y-flip).
    override var isFlipped: Bool { true }

    /// Pass every click straight through. SwiftUI's gesture recognizers
    /// then see the event on the view below us in the ZStack (the canvas
    /// + the parent ZStack's contentShape).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        report(event)
    }

    override func mouseMoved(with event: NSEvent) {
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        onUpdate?(nil)
    }

    private func report(_ event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        onUpdate?(pt)
    }
}
