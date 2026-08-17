//
//  BeatPinTests.swift
//  MurmurTests
//
//  The beat card has to survive the pointer leaving the trace (#225).
//
//  It did not. `dockedBeatCard` renders only while a beat is focused, and the
//  only thing that focused one was canvas hover — which `ChannelPanel`
//  cleared on mouse-exit. Moving the pointer toward the card in order to read
//  it was therefore exactly the gesture that closed it, and since X71 removed
//  the placeholder the card did not blank, it vanished and the column
//  reflowed. Every measurement on it was legible only in peripheral vision.
//
//  The state's own doc comment had described the fix for as long as the bug
//  existed — "the one the calipers panel is PINNED on, or the one under the
//  cursor when nothing is pinned" — against a property nothing implemented.
//

import Foundation
import Testing
@testable import MurmurCore

@MainActor
@Suite("Beat pinning (#225)")
struct BeatPinTests {

    private func context() -> IntervalMarkingsContext {
        let ctx = IntervalMarkingsContext()
        ctx.set(beats: [beat(1000), beat(2000), beat(3000)], sampleRate: 250, template: nil)
        return ctx
    }

    private func beat(_ rPeak: Int64) -> MarkingsBeat {
        MarkingsBeat(rPeakSampleIndex: rPeak, rPeakConfidence: 1.0)
    }

    @Test("Hover alone does not survive the pointer leaving")
    func hoverIsTransient() {
        // Unchanged behaviour, pinned as the baseline the rest is measured
        // against: an unpinned hover MUST clear, or the app would claim the
        // analyst is looking somewhere they are not.
        let ctx = context()
        ctx.focus(beatSampleIndex: 2000)
        #expect(ctx.focusedBeatSampleIndex == 2000)
        ctx.focus(beatSampleIndex: nil)
        #expect(ctx.focusedBeatSampleIndex == nil, "Nothing pinned, so mouse-exit leaves nothing focused")
    }

    @Test("A pinned beat survives the pointer leaving the trace")
    func pinSurvivesMouseExit() {
        // The bug, in one assertion.
        let ctx = context()
        ctx.focus(beatSampleIndex: 2000)
        ctx.togglePin(beatSampleIndex: 2000)
        ctx.focus(beatSampleIndex: nil)
        #expect(ctx.focusedBeatSampleIndex == 2000,
                "The card closed as the analyst moved toward it — the whole of #225")
    }

    @Test("Hover previews over the pin, and the pin comes back")
    func hoverPreviewsThenRestores() {
        // Why hover wins over the pin rather than the pin freezing the
        // surfaces: pin ?? hover would make a pinned beat un-leaveable and
        // kill the compare-this-against-that workflow the pin is for. This
        // order gives both — preview any beat, then get yours back.
        let ctx = context()
        ctx.togglePin(beatSampleIndex: 1000)
        ctx.focus(beatSampleIndex: 3000)
        #expect(ctx.focusedBeatSampleIndex == 3000, "Hover should preview a different beat")
        ctx.focus(beatSampleIndex: nil)
        #expect(ctx.focusedBeatSampleIndex == 1000, "Leaving the trace returns to the pinned beat")
    }

    @Test("Clicking the pinned beat again releases it")
    func pinTogglesOff() {
        let ctx = context()
        ctx.togglePin(beatSampleIndex: 2000)
        ctx.togglePin(beatSampleIndex: 2000)
        #expect(ctx.pinnedBeatSampleIndex == nil)
    }

    @Test("Clicking a different beat moves the pin rather than adding one")
    func pinMoves() {
        let ctx = context()
        ctx.togglePin(beatSampleIndex: 2000)
        ctx.togglePin(beatSampleIndex: 3000)
        #expect(ctx.pinnedBeatSampleIndex == 3000)
    }

    @Test("A jump pins its target")
    func jumpPins() {
        // The deviation shortcuts (`]` / `[`) and interval-trend bin clicks
        // arrive here. In every case the analyst asked for that specific beat
        // — and the card carrying it must not be erased by the next
        // mouse-exit, frequently before it had been read.
        //
        // This test used to name J/K, which never called this at all: they
        // are the FINDING jumps. Asserting the property against the context
        // API while assuming the wiring is how #279 survived — the UI test
        // `testADeviationJumpSurvivesThePointerLeavingTheTrace` covers the
        // wiring this cannot see.
        let ctx = context()
        ctx.pin(beatSampleIndex: 3000)
        #expect(ctx.focusedBeatSampleIndex == 3000)
        ctx.focus(beatSampleIndex: nil)
        #expect(ctx.focusedBeatSampleIndex == 3000, "A jumped-to beat must not evaporate on mouse-exit")
    }

    @Test("A jump outranks the hover it lands on top of")
    func jumpClearsAStaleHover() {
        // The viewport moves to the target, so a stationary pointer now sits
        // over a different part of the signal while the old hover is still
        // recorded. Since focus reads `hovered ?? pinned`, leaving it would
        // let a stale hover outrank the beat just asked for.
        let ctx = context()
        ctx.focus(beatSampleIndex: 1000)
        ctx.pin(beatSampleIndex: 3000)
        #expect(ctx.focusedBeatSampleIndex == 3000,
                "The beat the analyst asked for lost to the beat the pointer had been over")
    }

    @Test("A pin belongs to the record it was placed in")
    func clearReleasesThePin() {
        // Carried across a record change, the card would report a sample
        // index the new recording knows nothing about.
        let ctx = context()
        ctx.togglePin(beatSampleIndex: 2000)
        ctx.clear()
        #expect(ctx.pinnedBeatSampleIndex == nil)
        #expect(ctx.focusedBeatSampleIndex == nil)
    }
}
