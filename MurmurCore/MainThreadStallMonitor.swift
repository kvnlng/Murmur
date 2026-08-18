//
//  MainThreadStallMonitor.swift
//  MurmurCore
//
//  The publish-side complement to ComputeSignpost.
//
//  Why this exists: the compute log answered "which component does the work
//  and for how long", and after the orchestrators moved off the main actor a
//  warm open still FEELS clunky — input is accepted but the view doesn't
//  update for seconds at a time. That symptom lives in a place the compute
//  intervals can't see: the main run loop, where each context publish's
//  SwiftUI fallout (body re-evaluation, queue regrouping, canvas drawing)
//  runs synchronously. A compute interval that ends with a publish measures
//  time-to-publish; nothing measures the turn the publish then triggers.
//
//  This monitor draws that boundary: it times every main-run-loop turn
//  (wake → back to sleep) and persists any that exceed the shared slow
//  threshold. Correlating "Main stall — N ms" lines against the adjacent
//  "Slow compute" publishes in the same log names which publish's render
//  fallout the analyst actually felt.
//
//  Measurement only, same charter as ComputeSignpost: it changes no
//  concurrency posture and no render scope — those decisions follow the
//  numbers.
//

import Foundation
import os.log
import os.signpost

/// Logs every main-run-loop turn that exceeds
/// `ComputeMeasurement.slowThresholdSeconds` — the same "a person felt this"
/// bar the compute log uses, so the two line up on one axis.
public enum MainThreadStallMonitor {
    private static let diagnostics = Logger(
        subsystem: "com.kevinlong.murmur",
        category: "compute"
    )

    /// Mutable state for the observer handler. A class, not a captured
    /// `var` — the CF handler block outlives `install`'s frame.
    private final class TurnClock {
        var turnStartUptimeNanoseconds: UInt64 = 0
    }

    /// Install on the main run loop. Idempotence is the caller's problem —
    /// the app installs once at launch.
    @MainActor
    public static func install() {
        let clock = TurnClock()
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities.rawValue, true, 0
        ) { _, activity in
            switch activity {
            case .afterWaiting:
                clock.turnStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            case .beforeWaiting:
                reportTurn(startedAt: clock.turnStartUptimeNanoseconds)
                clock.turnStartUptimeNanoseconds = 0
            default:
                break
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Persist one completed turn if it was slow. `ComputeMeasurement`
    /// carries the threshold policy so this stays in lockstep with the
    /// compute log's bar.
    private static func reportTurn(startedAt startUptimeNanoseconds: UInt64) {
        guard startUptimeNanoseconds != 0 else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startUptimeNanoseconds
        let measurement = ComputeMeasurement(
            name: "MainThreadStall",
            durationSeconds: Double(elapsed) / 1_000_000_000
        )
        guard measurement.isSlow else { return }
        os_signpost(
            .event, log: computeSignpostLog, name: "MainThreadStall",
            "%{public}ld ms", measurement.durationMilliseconds
        )
        diagnostics.notice(
            "Main stall — \(measurement.durationMilliseconds, privacy: .public) ms"
        )
    }
}
