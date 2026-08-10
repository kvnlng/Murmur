//
//  UITestSupport.swift
//  Murmur
//
//  Centralised launch-argument hooks for the MurmurUITests target.
//  Wrapped in `#if DEBUG` so production App Store builds get none of this
//  code — the hooks exist purely to side-step XCUI macOS quirks that bit
//  the canvas polish pass (XCUICoordinate.hover() doesn't fire AppKit
//  NSTrackingArea events; pinch-zoom is awkward to synthesise) and to
//  make accessibility-restricted nested SwiftUI Texts reachable from
//  the test runner.
//
//  Supported arguments (all opt-in, all gated behind DEBUG):
//
//    --ui-test-sample
//        Already-existing flag handled by ContentView. Loads the
//        synthetic multi-frequency fixture on launch so the bedside
//        view renders without the welcome-screen detour.
//
//    --ui-test-initial-duration=<seconds>
//        Overrides BedsideView.initialDurationSeconds. With a value
//        smaller than the recording length, the viewport starts
//        zoomed in so a drag-pan actually has somewhere to move to —
//        the default 10 s window encompasses the whole 10 s synthetic
//        fixture, so drag would otherwise clamp at sample 0 and the
//        test would assert no visible change.
//
//    --ui-test-standard-open
//        Opts a UI test into X50's open-state Standard-View snap (25 mm/s ·
//        10 mm/mV at t=0). OFF by default under XCUI — the snapped width
//        depends on the runner's physical display size, so leaving it off
//        keeps every bare `--ui-test-sample` test's open geometry stable.
//        A normal (non-test) launch always snaps; this flag just lets the
//        dedicated X50 wire-up test verify it.
//
//    --ui-test-hover-at=<x>,<y>
//        Injects a single hover update at the given canvas-local
//        point right after first paint. Bypasses NSTrackingArea
//        synthesis entirely — the test runner just asks the app to
//        pretend the cursor's there, and the existing hover-update
//        closure runs as if HoverTrackingView had fired.
//
//    --ui-test-seed-recent
//        Materialises a synthetic WFDB folder into a unique temp
//        directory and seeds it as a recents-store entry, without
//        auto-loading. Lets a UI test land on the welcome screen
//        with one clickable recents row so the row-click → bookmark
//        resolve → import → bedside path runs end-to-end. Wipes the
//        existing recents list first so each run starts deterministic.
//
//    --ui-test-open-folder
//        Materialises a synthetic WFDB folder and calls `openFolder(_:)`
//        directly — bypasses the system `NSOpenPanel`. Covers the
//        welcome Open button, toolbar Open button, and drop-delegate
//        paths (all three terminate in `openFolder`).
//
//    --ui-test-attach-findings
//        Writes a synthetic attach sidecar with a distinctive
//        `category: "ATTACH"` finding, then routes it through
//        `BedsideView.handleAttachFindings` on appear — bypasses the
//        `attach-findings` file picker.
//
//    --ui-test-pan-by=<dx>
//        On bedside appear, calls `viewport.setStart(startSample + dx)`
//        — the same mutation `DragGesture.onChanged` calls. XCUI can't
//        synthesise `NSEvent.mouseDragged`, so this is the bypass.
//
//    --ui-test-pan-burst=<count>
//        On bedside appear, sleeps 500 ms (so MTKView's display link
//        suspends and the renderer goes truly cold), then fires `count`
//        viewport mutations spaced ~16 ms apart — the cadence of a
//        real 60 Hz drag's onChanged stream. Each tick advances startSample
//        by `panBurstTickDeltaSamples` (50 by default). Pairs with the
//        signpost-based perf tests: the first captured tick is cold, the
//        rest are warm, so the difference between cold-only single-pan
//        and burst-average latency exposes the cold-start premium.
//
//    --ui-test-zoom-to=<seconds>
//        On bedside appear, calls `viewport.setWidth(seconds * sampleRate,
//        anchorFraction: 0.5)` — the same mutation
//        `MagnifyGesture.onChanged` calls. XCUI has no multi-touch
//        synthesis, so this is the bypass.
//
//    --ui-test-record-urls
//        Switches `URLLauncher.open` from "call `NSWorkspace.open`" to
//        "record the URL on `lastLaunchedURL`". A hidden accessibility
//        element echoes the URL onto label `ui-test-last-launched-url`,
//        letting XCUI assert the URL each Help menu item / link targets
//        without launching a browser.
//
//    --ui-test-collapse-findings-groups
//        Restores the SHIPPING collapsed state of the review queue's
//        deviation-ranked group rows.
//
//        X65 (2026-08-04) INVERTED this: under a UI test, groups now
//        render EXPANDED by default, so a test needing
//        `finding-row-<cat>` exemplars no longer has to ask. The old
//        opt-in `--ui-test-expand-all-findings-groups` is GONE; twelve
//        tests each had to remember it, and forgetting produced a bare
//        "element does not exist" that named nothing.
//
//        Pass this flag only when collapse itself is what you are
//        exercising. Note what that means: under XCUI the app's real
//        default is no longer observable, so such a test asserts a state
//        it asked for rather than the shipping default. Kevin took that
//        trade knowingly — do not quietly reverse it, and do not add a
//        third mode. Only affects the initial expandedGroups set; the
//        analyst's toggle behaviour is unchanged.
//
//    --ui-test-overlay-leads=<name>,<name>,…
//        Opens the focus stage with these leads overlaid, first one
//        primary (X64). Exists because the gesture that builds an
//        overlay is a ⌘-CLICK, and XCUI on macOS has no modifier-click:
//        without this the entire overlay render path — stacked canvases,
//        edge labels, legend, chip swatches — would be reachable only by
//        hand. Names are matched against the record's ECG channels;
//        unknown names are dropped, and an empty result leaves the
//        default single-lead focus alone.
//
//        It seeds the SAME `LeadSelection` the chip bar builds, so what
//        the test exercises is the rendering, not a parallel code path.
//        The ⌘-click itself is not covered here.
//
//    --ui-test-window=<width>x<height>
//        Sizes the main window explicitly at launch (WindowSizing applies
//        it; the production minimums are relaxed for the run). Exists so a
//        test can reproduce Xcode Cloud's short VM display (1024×768)
//        deterministically on any machine — the class of failure it guards
//        is "bottom-of-window control not hittable on CI, green locally".
//

#if DEBUG
import Foundation
import CoreGraphics

enum UITestSupport {

    /// Returns the value parsed from `--<flag>=<value>` in
    /// `ProcessInfo.processInfo.arguments`, or nil if the flag is absent
    /// or the value isn't parseable as the requested type.
    static func value(forFlag flag: String) -> String? {
        let prefix = "--\(flag)="
        for arg in ProcessInfo.processInfo.arguments where arg.hasPrefix(prefix) {
            return String(arg.dropFirst(prefix.count))
        }
        return nil
    }

    /// If `--ui-test-initial-duration=N` is set, returns N seconds.
    /// BedsideView falls back to its own `initialDurationSeconds`
    /// constant when this returns nil.
    static var initialDurationSeconds: Double? {
        guard let raw = value(forFlag: "ui-test-initial-duration"),
              let n = Double(raw), n > 0 else { return nil }
        return n
    }

    /// Lead names from `--ui-test-overlay-leads=I,V1`, in order, first
    /// primary. Empty when the flag is absent.
    static var overlayLeadNames: [String] {
        guard let raw = value(forFlag: "ui-test-overlay-leads") else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// True when the process was launched with ANY `--ui-test-*` argument —
    /// i.e. it's an XCUI run, not a normal DEBUG launch from Xcode. Used to
    /// suppress display-size-dependent open-state behaviour (X50's Standard-View
    /// snap) that would otherwise make every bare-`--ui-test-sample` test's
    /// initial viewport width vary by the runner's physical screen.
    static var isRunningUITest: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-test") }
    }

    /// If `--ui-test-inject-qtc-lane=<qtcMs>` is set, returns the QTc value (ms)
    /// to seed. It (a) grants ECG Metrics in `PurchaseStore.init` so the paid
    /// QTc trend lane renders, and (b) has `BedsideView` inject a deterministic
    /// fiducial store whose every beat carries this exact QTc, so the lane's
    /// computed bin median is KNOWN. The X52 §5 wire-up test then asserts the
    /// lane's RENDERED value equals this — catching a units/binding slip between
    /// the validated computer and the screen that a green unit suite would miss.
    /// The `IntervalMarkingsOrchestrator` skips its recompute under this flag so
    /// real delineation doesn't overwrite the injected store.
    static var injectQTcLaneValue: Double? {
        guard let raw = value(forFlag: "ui-test-inject-qtc-lane"),
              let n = Double(raw), n > 0 else { return nil }
        return n
    }

    /// True when `--ui-test-standard-open` is passed. Opts a UI test INTO the
    /// X50 open-state Standard-View snap (off by default under XCUI so existing
    /// tests keep their legacy open geometry). The dedicated X50 wire-up test
    /// uses this to assert the readout reads standard immediately on open.
    static var standardOpenEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-standard-open")
    }

    /// If `--ui-test-hover-at=X,Y` is set, returns the point in canvas
    /// coordinates. The canvas's hover-update closure is invoked with
    /// this point after the first layout, exactly as if `HoverTrackingView`
    /// had received a mouseEntered NSEvent at that location.
    static var hoverPoint: CGPoint? {
        guard let raw = value(forFlag: "ui-test-hover-at") else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }

    /// If `--ui-test-pan-by=N` is set, returns N samples. BedsideView
    /// applies this on first appear by calling `viewport.setStart(start + N)` —
    /// the same mutation the drag-pan gesture's `onChanged` runs. Lets us
    /// validate the pan → viewport-state path without synthesising a
    /// `DragGesture` event stream that XCUI on macOS can't produce.
    static var panBySamples: Int64? {
        guard let raw = value(forFlag: "ui-test-pan-by"),
              let n = Int64(raw) else { return nil }
        return n
    }

    /// If `--ui-test-pan-burst=N` is set, returns the tick count. BedsideView
    /// fires N viewport mutations after an idle prelude — the cold-start
    /// of the first tick + the warm cost of the next N-1 lets the perf
    /// test decompose hesitation into "wake from idle" vs "steady-state
    /// per-tick" cost.
    static var panBurstTickCount: Int? {
        guard let raw = value(forFlag: "ui-test-pan-burst"),
              let n = Int(raw), n > 0 else { return nil }
        return n
    }

    /// Per-tick startSample advance for `--ui-test-pan-burst`. Kept small
    /// enough that `count * delta` lands well below 1000 — macOS's
    /// accessibility post-processor injects thousands separators into 4+
    /// digit numbers, which would break the test's label predicate.
    static let panBurstTickDeltaSamples: Int64 = 40

    /// Idle prelude before the first burst tick. 500 ms is comfortably
    /// longer than MTKView's display-link auto-suspend window when
    /// `isPaused=true`, so the first tick measures a genuine cold-start.
    static let panBurstIdleNanoseconds: UInt64 = 500_000_000

    /// Inter-tick sleep. ~16 ms approximates the cadence of a real drag's
    /// onChanged events at 60 Hz; on ProMotion it's a slight over-sleep,
    /// which still keeps the display link spinning between ticks.
    static let panBurstTickIntervalNanoseconds: UInt64 = 16_000_000

    /// If `--ui-test-zoom-to=N` is set, returns N seconds. BedsideView
    /// applies this on first appear by calling `viewport.setWidth(seconds *
    /// sampleRate, anchorFraction: 0.5)` — the same mutation the pinch-zoom
    /// gesture runs. Lets us validate the zoom → viewport-width path
    /// without synthesising a `MagnifyGesture` event stream that XCUI on
    /// macOS can't produce.
    static var zoomToSeconds: Double? {
        guard let raw = value(forFlag: "ui-test-zoom-to"),
              let n = Double(raw), n > 0 else { return nil }
        return n
    }

    /// True when `--ui-test-vtvf-candidates` is passed. BedsideView injects
    /// a fixed set of synthetic candidates into `VTVFScanContext` on appear —
    /// the same state a committed scan produces — so the candidate group, the
    /// scan toolbar affordance, and the region-keyed disposition wire-up are
    /// exercisable without running Core ML in the test process. Deliberately
    /// does NOT grant the PurchaseStore entitlement (that races the async
    /// currentEntitlements refresh); the scan orchestrator makes the affordance
    /// available under this same flag instead.
    static var injectVTVFCandidates: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-vtvf-candidates")
    }

    /// True when `--ui-test-first-run-ruo` is passed: force the first-run
    /// RUO notice to present regardless of any stored acknowledgement (XCUI
    /// runs share the app container's defaults, so an acknowledgement from
    /// an earlier run must not make the notice test flaky). Every OTHER
    /// UI-test launch suppresses the notice — see
    /// `RUOFirstRunNotice.shouldPresent`.
    static var forceFirstRunRUO: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-first-run-ruo")
    }

    /// True when `--ui-test-crash-loss-notice` is passed: force the X86
    /// one-time crash-loss disclosure to present on the first carrying
    /// switch, regardless of any stored acknowledgement — the same
    /// shared-defaults reasoning as `forceFirstRunRUO`. Every other UI-test
    /// launch suppresses it; see `CrashLossNotice.shouldPresent`.
    static var forceCrashLossNotice: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-crash-loss-notice")
    }

    /// X99 (#164): `--ui-test-sample-rich[=seconds]` loads the ECGSYN-style
    /// rich fixture (realistic P-QRS-T, spectral R–R variability, known truth)
    /// instead of the 10 s demo; 180 s default keeps it test-budget friendly.
    static var richSampleDurationSeconds: Double? {
        if let raw = value(forFlag: "ui-test-sample-rich"), let secs = Double(raw), secs > 0 { return min(3600, secs) }
        return ProcessInfo.processInfo.arguments.contains("--ui-test-sample-rich") ? 180 : nil
    }

    /// True when `--ui-test-arrhythmia-candidates` is passed. Same bypass as
    /// `injectVTVFCandidates`, for the arrhythmia scan (A2): BedsideView
    /// publishes a fixed candidate set into `ArrhythmiaScanContext` so the
    /// queue group and the region-keyed disposition wire-up are exercisable
    /// without running the detectors; the App-side orchestrator skips its
    /// recompute under this flag so it can't overwrite the injection.
    static var injectArrhythmiaCandidates: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-arrhythmia-candidates")
    }

    /// True when `--ui-test-no-entitlements` is passed. `PurchaseStore` then
    /// starts with an empty owned-set and neither walks `currentEntitlements`
    /// nor listens for transaction updates, so "the free viewer never exposes
    /// a paid affordance" XCUI assertions are hermetic against StoreKit-test
    /// transactions a developer may have persisted on the machine (e.g. via
    /// the DEBUG grant toggle's real-purchase sibling).
    static var forceNoEntitlements: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-no-entitlements")
    }

    /// True when `--ui-test-export-wfdb` is passed. BedsideView confirms a
    /// synthetic candidate region and runs the WFDB export end-to-end (amber
    /// filter → writer → `<base>.mur` beside the fixture), then publishes the
    /// result on the `ui-test-wfdb-export` accessibility leaf. Bypasses the
    /// export confirmation dialog and the toolbar click so XCUI can assert the
    /// exported count + annotator suffix — the plumbing snapshot/unit tests
    /// can't reach.
    static var exportWFDBFindings: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-export-wfdb")
    }

    /// True when `--ui-test-seed-confirmed-region` is passed. BedsideView
    /// confirms a synthetic candidate region on appear but does NOT export —
    /// so `amberFindingCount > 0` enables the export toolbar button and an XCUI
    /// test can drive the REAL button → confirm alert → write path (the path
    /// the `--ui-test-export-wfdb` bypass deliberately skips). This is what
    /// reproduces a crash IN the export affordance itself.
    static var seedConfirmedRegion: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-seed-confirmed-region")
    }

    /// True when `--ui-test-author-range` is passed. BedsideView invokes the
    /// drag-to-author handler directly with a fixed time range (a real
    /// DragGesture isn't XCUI-drivable on macOS, same as pan/zoom), creating +
    /// persisting a range finding, and publishes the authored-finding count on
    /// the `ui-test-authored-count` leaf. Exercises the author→persist→render
    /// plumbing end-to-end without the gesture.
    static var authorRange: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-author-range")
    }

    /// True when `--ui-test-collapse-findings-groups` is passed. Restores the
    /// SHIPPING collapsed default for a test that is specifically exercising
    /// collapse — see `shouldExpandFindingsGroups`.
    static var collapseFindingsGroups: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-collapse-findings-groups")
    }

    /// Whether the review-queue rail should initialise with every group
    /// expanded, so exemplar rows (`finding-row-<category>`) are addressable
    /// without first clicking a disclosure chevron.
    ///
    /// X65: **expanded is the default under UI test, collapsed elsewhere.**
    /// This inverts the previous opt-in `--ui-test-expand-all-findings-groups`,
    /// which twelve tests each had to remember. Forgetting it was invisible in
    /// the worst way — the row was in no tree, so the failure read "element
    /// does not exist" with nothing pointing at the cause.
    ///
    /// **The cost, stated plainly:** the app's real collapsed default is no
    /// longer what a UI test sees, so no XCUI test can observe it. The two
    /// tests that exercise collapse now pass
    /// `--ui-test-collapse-findings-groups` and are asserting a state they
    /// asked for rather than the shipping default. Kevin took this trade
    /// knowingly on 2026-08-04; do not quietly reverse it, and do not add a
    /// third mode.
    static var shouldExpandFindingsGroups: Bool {
        isRunningUITest && !collapseFindingsGroups
    }

    /// If `--ui-test-seed-beat-annotations=N` is set, returns N. The
    /// synthetic fixture generator adds N evenly-spaced normal-beat
    /// ("N") point annotations across the whole recording so waveform
    /// LOD tests have enough beats-in-window to cross tier thresholds.
    /// Without seeding, the default fixture ships only 3 findings
    /// (2 VT + 1 VF) and beatsInWindow stays at 0-1 for any viewport
    /// — the tier selector never leaves Inspect.
    static var seedBeatAnnotationsCount: Int? {
        guard let raw = value(forFlag: "ui-test-seed-beat-annotations"),
              let n = Int(raw), n > 0 else { return nil }
        return n
    }

    /// If `--ui-test-seed-atr-normals=N` is set, returns N. Like the beat
    /// seed above, but the annotations carry a `wfdb.atr.*` source, so they
    /// pass `Recording.normalBeatSampleIndices()`'s provenance filter and
    /// feed the variability-metrics pipeline (X95's tests need a fixture the
    /// strip can actually measure). A separate flag rather than a source
    /// change on the existing seed: the review-queue and LOD tests count on
    /// `ui-test-seed` findings NOT reading as atr-coded normals, which the
    /// FindingsPanel would collapse.
    static var seedATRNormalBeatsCount: Int? {
        guard let raw = value(forFlag: "ui-test-seed-atr-normals"),
              let n = Int(raw), n > 0 else { return nil }
        return n
    }

    /// True when `--ui-test-grant-studio` is passed. Grants the Studio
    /// entitlement in `PurchaseStore.init` and skips the entitlement walk —
    /// the counterpart of `--ui-test-no-entitlements`, for driving REAL paid
    /// computations (not injections) against a staged record. Added for
    /// X76's pixel pass, where the rolling LF/HF series had to be computed
    /// for real on a multi-hour record without dragging the QTc injection's
    /// synthetic fiducial store into the picture.
    static var grantStudio: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-grant-studio")
    }

    /// True when `--ui-test-inject-lfhf-lane` is passed (X76). It (a) grants
    /// Studio in `PurchaseStore.init` (the X52 §5 pattern — a StoreKit-test
    /// machine can't clobber the grant on the async refresh), (b) has
    /// `BedsideView` seed `RollingLFHFContext` with a deterministic series
    /// whose every window reads exactly 1.50, and (c) has
    /// `RollingLFHFOrchestrator` skip its recompute so the real computation
    /// doesn't overwrite the injection. The wire-up test asserts the lane's
    /// RENDERED value equals the injected one — catching a binding slip
    /// between the context and the screen that a green unit suite would miss.
    static var injectLFHFLane: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-inject-lfhf-lane")
    }

    /// If `--ui-test-seed-notes=N` is set, returns N. BedsideView seeds N
    /// anchored notes at deterministic, evenly-spaced positions on appear
    /// (X72), so the drawn surfaces notes feed — the record band's note-tick
    /// layer, the drawer list, the info-bar count — render without XCUI
    /// having to drive the create flow first. The creation flow itself keeps
    /// its own unseeded test.
    static var seedNotesCount: Int? {
        guard let raw = value(forFlag: "ui-test-seed-notes"),
              let n = Int(raw), n > 0 else { return nil }
        return n
    }

    /// Filled by `ContentView` when `--ui-test-attach-findings` is set.
    /// `BedsideView` checks this on appear and, if non-nil, routes the URL
    /// through its `handleAttachFindings` path — the same one the toolbar
    /// "Attach findings…" button reaches. Bypasses the system fileImporter
    /// modal.
    static var attachFindingsURL: URL?

    /// Materialises a synthetic attach-sidecar JSON in a temp file. The
    /// JSON carries one distinctive finding (`category: "ATTACH"`) so the
    /// test can wait for `finding-row-ATTACH` to appear in the panel.
    static func makeAttachFindingsFixture() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-ui-test-attach", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let json = """
            {
              "schemaVersion": 1,
              "source": "ui-test-attach",
              "findings": [
                {
                  "kind": "point",
                  "startSample": 2200,
                  "category": "ATTACH",
                  "label": "ATTACH",
                  "confidence": 0.5,
                  "note": "Synthetic finding injected via --ui-test-attach-findings"
                }
              ]
            }
            """
            try json.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
#endif
