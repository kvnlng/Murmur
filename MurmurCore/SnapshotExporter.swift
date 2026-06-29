//
//  SnapshotExporter.swift
//  MurmurCore
//
//  PNG snapshot of the current bedside view — chart, axes, finding
//  overlays, all SwiftUI chrome — captured via
//  `NSView.cacheDisplay(in:to:)`. That API renders the view hierarchy
//  offscreen including Metal-backed CALayers, which is what we need so
//  the exported image actually shows the trace and not a hollow rect
//  where the MTKView lives. SwiftUI's `ImageRenderer` doesn't descend
//  into Metal layers reliably, so we go through AppKit instead.
//
//  The filename helper is split out so it's testable as a pure function;
//  the capture function itself depends on a live NSWindow.
//

import Foundation

#if canImport(AppKit)
import AppKit
#endif

enum SnapshotExporter {

    /// Builds the suggested save-panel filename from the recording's
    /// source name and a UTC `yyyy-MM-dd-HHmm` timestamp. Pure helper
    /// so tests pin output deterministically; the in-app path passes
    /// `Date()` at click time.
    static func suggestedFilename(for recording: Recording, at date: Date) -> String {
        let base = (recording.sourceFileName as NSString).deletingPathExtension
        let stem = base.isEmpty ? "recording" : base
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(stem)-snapshot-\(formatter.string(from: date)).png"
    }

    #if canImport(AppKit)

    /// Renders `view`'s pixel content as a PNG. Returns nil when the
    /// view can't be cached (e.g., zero-sized bounds, no graphics
    /// context). The caller writes the result to disk via `Data.write`.
    @MainActor
    static func renderPNG(of view: NSView) -> Data? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Convenience: capture the application's key window's content
    /// view (the bedside hierarchy when invoked from the toolbar) and
    /// encode it as PNG. Returns nil when there's no key window or
    /// the capture fails.
    @MainActor
    static func renderKeyWindowPNG() -> Data? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else { return nil }
        return renderPNG(of: contentView)
    }

    #endif
}
