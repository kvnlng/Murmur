//
//  DisplayMetrics.swift
//  MurmurCore
//
//  Physical-size of the display, for the calibration instrument (X40 /
//  project_calibration_instrument_spec.md). A "mm/mV" or "mm/s" figure is a
//  claim about PHYSICAL size on glass — it may only be printed when the
//  display's physical dimensions are trustworthy. External displays frequently
//  report zero or nonsense physical sizes; asserting a physical calibration we
//  can't substantiate is the same error class as the fabricated recording
//  start time (X32). So the conversion returns nil when the reported size is
//  missing/zero/implausible, and the readout falls back to points-per-mV with
//  NO mm figure.
//

import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

enum DisplayMetrics {
    /// Millimetres per point, or nil when the physical size is untrustworthy.
    /// Pure so it's unit-testable without a real display — the degenerate
    /// guard (the X32-class honesty rule) is the important part to test.
    /// - Parameters:
    ///   - physicalWidthMM: display width in millimetres (`CGDisplayScreenSize`).
    ///   - pointWidth: display width in points (`NSScreen.frame.width`).
    static func millimetersPerPoint(physicalWidthMM: Double, pointWidth: Double) -> Double? {
        // Reject missing/zero and implausible sizes — a real display is wider
        // than a couple of centimetres and narrower than a couple of metres.
        // Values outside that band are the "reports nonsense" case.
        guard physicalWidthMM > 20, physicalWidthMM < 2000, pointWidth > 0 else {
            return nil
        }
        let mmPerPoint = physicalWidthMM / pointWidth
        guard mmPerPoint.isFinite, mmPerPoint > 0 else { return nil }
        return mmPerPoint
    }

    #if canImport(AppKit)
    /// Millimetres per point for the screen showing `view`, or the main screen.
    /// nil when the physical size can't be trusted — callers then print
    /// points-per-mV instead of a mm figure.
    @MainActor
    static func millimetersPerPoint(for view: NSView? = nil) -> Double? {
        guard let screen = view?.window?.screen ?? NSScreen.main else { return nil }
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let physical = CGDisplayScreenSize(displayID)   // millimetres
        return millimetersPerPoint(
            physicalWidthMM: Double(physical.width),
            pointWidth: Double(screen.frame.width)
        )
    }
    #endif
}
