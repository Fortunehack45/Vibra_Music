import XCTest
@testable import Automix

/// The per-deck gain and filter curves Playback renders a plan with.
final class TransitionAutomationTests: XCTestCase {

    func testGainsAreEqualPowerForEveryStyle() {
        for style in TransitionStyle.allCases {
            let automation = TransitionAutomation(style: style, bassSwap: true, filterSweep: 1, vocalOverlap: 0.5)
            for frame in automation.frames(count: 21) {
                XCTAssertEqual(frame.incomingGain * frame.incomingGain + frame.outgoingGain * frame.outgoingGain, 1, accuracy: 1e-12)
            }
            XCTAssertEqual(automation.frame(at: 0).outgoingGain, 1)
            XCTAssertEqual(automation.frame(at: 1).incomingGain, 1)
        }
    }

    func testProgressIsClamped() {
        let automation = TransitionAutomation(style: .equalPower)
        XCTAssertEqual(automation.frame(at: -3).progress, 0)
        XCTAssertEqual(automation.frame(at: 7).progress, 1)
        XCTAssertEqual(automation.frame(at: .nan).progress, 0)
        XCTAssertEqual(automation.frames(count: 5).map(\.progress), [0, 0.25, 0.5, 0.75, 1])
    }

    func testGaplessAndUncollidedPlainFadesNeverFilter() {
        for automation in [
            TransitionAutomation(style: .gapless, bassSwap: true, filterSweep: 1, vocalOverlap: 1),
            TransitionAutomation(style: .equalPower),
            TransitionAutomation(style: .djBlend, bassSwap: false),
            TransitionAutomation(style: .djFilter, filterSweep: 0),
        ] {
            XCTAssertFalse(automation.filtersAtAll)
            for frame in automation.frames(count: 11) {
                XCTAssertTrue(frame.outgoingFilter.isOpen)
                XCTAssertTrue(frame.incomingFilter.isOpen)
            }
        }
    }

    func testFilterRideClosesTheOutgoingTrackAndOpensTheIncomingOne() {
        let automation = TransitionAutomation(style: .djFilter, filterSweep: 1)
        let frames = automation.frames(count: 101)

        XCTAssertEqual(frames.first!.outgoingFilter.lowPassHz, TransitionAutomation.filterEntryHz, accuracy: 1e-6)
        XCTAssertEqual(frames.last!.outgoingFilter.lowPassHz, TransitionAutomation.filterFloorHz, accuracy: 1e-6)
        for (earlier, later) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(later.outgoingFilter.lowPassHz, earlier.outgoingFilter.lowPassHz + 1e-9)
            XCTAssertLessThanOrEqual(later.incomingFilter.highPassHz, earlier.incomingFilter.highPassHz + 1e-9)
        }
        // Front-loaded: the outgoing top is mostly gone a fifth of the way in (2.6 kHz).
        XCTAssertEqual(automation.frame(at: 0.2).outgoingFilter.lowPassHz, 2_600, accuracy: 150)
        XCTAssertEqual(automation.frame(at: 0.5).outgoingFilter.lowPassHz, 1_000, accuracy: 100)
        // The incoming track enters high-passed at 1.2 kHz and is whole by 60% of the fade.
        XCTAssertEqual(frames.first!.incomingFilter.highPassHz, 1_200, accuracy: 1e-6)
        XCTAssertTrue(automation.frame(at: 0.6).incomingFilter.isOpen)
    }

    func testAPartialSweepStopsShortOfTheFloor() {
        let full = TransitionAutomation(style: .djFilter, filterSweep: 1).frame(at: 1)
        let half = TransitionAutomation(style: .djFilter, filterSweep: 0.5).frame(at: 1)
        XCTAssertGreaterThan(half.outgoingFilter.lowPassHz, full.outgoingFilter.lowPassHz)
        XCTAssertLessThan(half.outgoingFilter.lowPassHz, TransitionAutomation.openHz)
    }

    func testBassSwapHandsTheLowEndOverOnceAtTheChosenBeat() {
        let automation = TransitionAutomation(style: .djBlend, bassSwap: true, bassSwapFraction: 0.5)
        let before = automation.frame(at: 0.4)
        let after = automation.frame(at: 0.6)

        // Before the swap: the outgoing bass plays, the incoming bass is held out.
        XCTAssertEqual(before.outgoingFilter.highPassHz, TransitionAutomation.offHz, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(before.incomingFilter.highPassHz, TransitionAutomation.bassSwapHz - 1e-6)
        // After it: the reverse.
        XCTAssertEqual(after.outgoingFilter.highPassHz, TransitionAutomation.bassSwapHz, accuracy: 1e-6)
        XCTAssertEqual(after.incomingFilter.highPassHz, TransitionAutomation.offHz, accuracy: 1e-6)
        // Midway through the ramp both are partway.
        let middle = automation.frame(at: 0.5)
        XCTAssertGreaterThan(middle.outgoingFilter.highPassHz, TransitionAutomation.offHz)
        XCTAssertLessThan(middle.outgoingFilter.highPassHz, TransitionAutomation.bassSwapHz)
        // A shallow exit low-pass, open for the first 30%, 2.2 kHz at the end.
        XCTAssertTrue(automation.frame(at: 0.25).outgoingFilter.lowPassHz >= TransitionAutomation.openHz - 1e-6)
        XCTAssertEqual(automation.frame(at: 1).outgoingFilter.lowPassHz, 2_200, accuracy: 1e-6)
    }

    func testAVocalCollisionDeepensTheBlendsSeparation() {
        let clean = TransitionAutomation(style: .djBlend, bassSwap: true, bassSwapFraction: 0.7, vocalOverlap: 0)
        let clash = TransitionAutomation(style: .djBlend, bassSwap: true, bassSwapFraction: 0.7, vocalOverlap: 1)
        XCTAssertEqual(clash.frame(at: 0).incomingFilter.highPassHz, 950, accuracy: 1e-6)
        XCTAssertEqual(clean.frame(at: 0).incomingFilter.highPassHz, 520, accuracy: 1e-6)
        XCTAssertEqual(clash.frame(at: 1).outgoingFilter.lowPassHz, 1_100, accuracy: 1e-6)
        XCTAssertLessThan(clash.frame(at: 0.2).outgoingFilter.lowPassHz, clean.frame(at: 0.2).outgoingFilter.lowPassHz)
    }

    func testPlainFadeSeparatesTwoCollidingVocalsInProportion() {
        let full = TransitionAutomation(style: .equalPower, vocalOverlap: 1)
        XCTAssertTrue(full.filtersAtAll)
        XCTAssertEqual(full.frame(at: 1).outgoingFilter.lowPassHz, 1_600, accuracy: 1e-6)
        XCTAssertEqual(full.frame(at: 0).incomingFilter.highPassHz, 700, accuracy: 1e-6)
        let marginal = TransitionAutomation(style: .equalPower, vocalOverlap: 0.25)
        XCTAssertGreaterThan(marginal.frame(at: 1).outgoingFilter.lowPassHz, 1_600)
        XCTAssertLessThan(marginal.frame(at: 0).incomingFilter.highPassHz, 700)
    }

    func testDeckFiltersStayInsideTheRendererRange() {
        let filter = DeckFilter(lowPassHz: 50_000, highPassHz: 9_000)
        XCTAssertEqual(filter.lowPassHz, TransitionAutomation.openHz)
        XCTAssertEqual(filter.highPassHz, TransitionAutomation.maxHighPassHz)
    }

    func testAutomationIsCapturedFromThePlanStyleFields() {
        let plan = TransitionPlan(transitionStyle: .djBlend, bassSwap: true, bassSwapFraction: 0.625, filterSweep: 0, vocalOverlap: 0.3)
        XCTAssertEqual(plan.automation, TransitionAutomation(style: .djBlend, bassSwap: true, bassSwapFraction: 0.625, filterSweep: 0, vocalOverlap: 0.3))
    }

    func testFadeProgressIsMeasuredFromTheCueAndTightensForAShortIncomingTrack() {
        let plan = TransitionPlan(fadeSeconds: 10, incomingCueTime: 30)
        XCTAssertEqual(plan.fadeProgress(incomingPosition: 30, incomingDuration: nil), 0)
        XCTAssertEqual(plan.fadeProgress(incomingPosition: 35, incomingDuration: nil), 0.5, accuracy: 1e-9)
        XCTAssertEqual(plan.fadeProgress(incomingPosition: 12, incomingDuration: nil), 0, "before the cue is not negative progress")
        // Only 15 s of track after the cue: the fade shrinks to a third of that.
        XCTAssertEqual(plan.fadeProgress(incomingPosition: 35, incomingDuration: 45), 1, accuracy: 1e-9)
    }
}
