import VibraMusicCore
import XCTest
@testable import Playback

/// Arms the standard 6 s crossfade on a 30 s track and starts it (handoff at 24 s).
@MainActor
private func startStandardFade(_ host: FakeCrossfadeHost, _ controller: CrossfadeController, at position: TimeInterval = 24) {
    host.deckA.position = 20
    controller.tick()
    host.deckB.isReadyToPlay = true
    host.deckA.position = position
    controller.tick()
}

private func equalPower(_ progress: Double) -> (rise: Float, fall: Float) {
    (Float(sin(progress * .pi / 2)), Float(cos(progress * .pi / 2)))
}

@MainActor
final class CrossfadeTimingTests: XCTestCase {
    func testArmsFourSecondsBeforeTheFadeIsDue() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 19.9
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(host.armed.isEmpty)

        host.deckA.position = 20
        controller.tick()
        XCTAssertEqual(controller.phase, .arming)
        XCTAssertEqual(host.armed.first?.item.id, "two")
        XCTAssertEqual(host.armed.first?.cue, 0)
        XCTAssertEqual(host.armed.first?.rate, 1)
        XCTAssertTrue(host.transitioning)
        XCTAssertEqual(host.deckB.volume, 0, "the incoming track arms silent")
        XCTAssertEqual(host.deckA.volume, 1)
    }

    func testFadeStartsAtTheFadePointOnceTheIncomingTrackIsReady() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        host.deckB.isReadyToPlay = true
        host.deckA.position = 23.9
        controller.tick()
        XCTAssertEqual(controller.phase, .arming)
        XCTAssertEqual(host.handoffs, 0)

        host.deckA.position = 24
        controller.tick()
        XCTAssertEqual(controller.phase, .fading)
        XCTAssertEqual(host.handoffs, 1, "the session moves as the incoming track starts, not when the blend ends")
        XCTAssertTrue(host.active === host.deckB)
        XCTAssertTrue(host.deckB.playWhenReady)
        XCTAssertEqual(host.deckB.volume, 0)
    }

    func testWaitsForAnIncomingTrackThatIsNotReadyYet() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        host.deckA.position = 24.5
        controller.tick()
        XCTAssertEqual(controller.phase, .arming)
        host.deckB.isReadyToPlay = true
        controller.tick()
        XCTAssertEqual(controller.phase, .fading)
    }

    func testGivesUpOnAnIncomingTrackThatNeverGetsReady() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        host.now += 11.9
        controller.tick()
        XCTAssertEqual(controller.phase, .arming)
        host.now += 0.2
        controller.tick()
        XCTAssertEqual(controller.phase, .idle, "past the arm timeout the queue moves on plainly")
        XCTAssertEqual(host.deckB.retiredCount, 1)
        XCTAssertEqual(host.handoffs, 0)
        XCTAssertEqual(host.deckA.volume, 1)
        XCTAssertFalse(host.transitioning)
    }

    func testFadeLengthIsCappedAtAThirdOfTheOutgoingTrack() {
        let host = FakeCrossfadeHost.playing(duration: 12)
        let controller = CrossfadeController(host: host)
        host.deckA.position = 3.9
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        host.deckA.position = 4
        controller.tick()
        XCTAssertEqual(controller.phase, .arming, "a 6 s fade on a 12 s track is cut to 4 s, armed 4 s ahead")
        XCTAssertEqual(controller.currentSpec?.overlap, 4)
        XCTAssertEqual(CrossfadeController.fadeLength(configured: 12, duration: 240), 12)
        XCTAssertEqual(CrossfadeController.fadeLength(configured: 12, duration: 30), 10)
        XCTAssertEqual(CrossfadeController.fadeLength(configured: 6, duration: nil), 6)
    }

    func testNoCrossfadeWhenItIsOff() {
        let host = FakeCrossfadeHost.playing()
        host.crossfadeSeconds = 0
        let controller = CrossfadeController(host: host)
        for position in stride(from: 20.0, through: 29.9, by: 0.5) {
            host.deckA.position = position
            controller.tick()
        }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(host.armed.isEmpty)
    }

    func testTickCadenceFollowsThePhase() {
        XCTAssertEqual(CrossfadeController.step(for: .idle), 0.25)
        XCTAssertEqual(CrossfadeController.step(for: .arming), 0.04)
        XCTAssertEqual(CrossfadeController.step(for: .fading), 0.03)
        XCTAssertEqual(CrossfadeController.step(for: .bailing), 0.015)
    }
}

@MainActor
final class CrossfadeCurveTests: XCTestCase {
    func testEqualPowerGainsHoldConstantPowerAcrossTheFade() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        startStandardFade(host, controller)
        for position in [0.0, 1.5, 3, 4.5] {
            host.deckB.position = position
            controller.tick()
            let expected = equalPower(position / 6)
            XCTAssertEqual(host.deckB.volume, expected.rise, accuracy: 0.0001, "incoming at \(position)s")
            XCTAssertEqual(host.deckA.volume, expected.fall, accuracy: 0.0001, "outgoing at \(position)s")
            let power = host.deckA.volume * host.deckA.volume + host.deckB.volume * host.deckB.volume
            XCTAssertEqual(power, 1, accuracy: 0.0001, "no dip in the middle of the blend")
        }
        host.deckB.position = 6
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.deckB.volume, 1)
        XCTAssertEqual(host.deckA.retiredCount, 1, "the outgoing deck goes back in the drawer")
        XCTAssertEqual(host.deckA.volume, 1, "retired at full volume, ready to be the next incoming deck")
        XCTAssertNotNil(controller.timeSinceTransition())
    }

    func testFadeTightensForAShortIncomingTrack() {
        let host = FakeCrossfadeHost.playing(incoming: 9)
        let controller = CrossfadeController(host: host)
        startStandardFade(host, controller)
        host.deckB.position = 1.5
        controller.tick()
        XCTAssertEqual(host.deckB.volume, equalPower(0.5).rise, accuracy: 0.0001, "a 9 s track caps the span at 3 s")
        host.deckB.position = 3
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAFadeIntoATrackOpenedPastItsSilentIntroRunsFromWhereItOpened() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        // Skip silence opened the standby past a 2 s silent intro instead of at the spec's cue of 0.
        host.deckB.position = 2
        host.deckB.isReadyToPlay = true
        host.deckA.position = 24
        controller.tick()
        XCTAssertEqual(controller.phase, .fading)
        controller.tick()
        XCTAssertEqual(host.deckB.volume, 0, accuracy: 0.0001, "the fade starts at its start, not a third of the way in")
        host.deckB.position = 5
        controller.tick()
        XCTAssertEqual(host.deckB.volume, equalPower(0.5).rise, accuracy: 0.0001)
        XCTAssertEqual(host.deckA.volume, equalPower(0.5).fall, accuracy: 0.0001)
    }

    func testAPauseParksTheFadeAndTakesTheOtherDeckWithIt() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        startStandardFade(host, controller)
        host.deckA.playWhenReady = true
        host.deckB.position = 3
        controller.tick()
        let parked = (host.deckA.volume, host.deckB.volume)

        host.deckB.playWhenReady = false
        controller.tick()
        XCTAssertFalse(host.deckA.playWhenReady, "the outgoing half follows the session's pause")
        host.now += 30
        controller.tick()
        XCTAssertEqual(host.deckA.volume, parked.0)
        XCTAssertEqual(host.deckB.volume, parked.1)
        XCTAssertEqual(controller.phase, .fading)

        host.deckB.playWhenReady = true
        controller.syncTransport()
        XCTAssertTrue(host.deckA.playWhenReady)
    }

    func testTheOutgoingTrackEndingFinishesTheFade() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        startStandardFade(host, controller)
        host.deckB.position = 2
        controller.tick()
        host.deckA.hasEnded = true
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.deckB.volume, 1)
    }
}

@MainActor
final class CrossfadeInterruptionTests: XCTestCase {
    func testASkipWhileArmingDiscardsTheStandbySilently() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        controller.onSkipRequested()
        XCTAssertEqual(controller.phase, .idle, "nothing was audible, so there is no ramp to run")
        XCTAssertEqual(host.deckB.retiredCount, 1)
        XCTAssertEqual(host.deckA.volume, 1)
        XCTAssertEqual(host.handoffs, 0)
    }

    func testASkipAfterTheHandoffRampsTheOutgoingTrackAway() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        startStandardFade(host, controller)
        host.deckB.position = 3
        controller.tick()
        let from = host.deckA.volume
        controller.onSkipRequested()
        XCTAssertEqual(controller.phase, .bailing)
        XCTAssertEqual(host.deckB.volume, 1, "the track the session is on comes up at once")
        XCTAssertFalse(host.mixInProgress)

        host.now += CrossfadeController.bailDuration / 2
        controller.tick()
        XCTAssertEqual(host.deckA.volume, from * equalPower(0.5).fall, accuracy: 0.001)
        host.now += CrossfadeController.bailDuration
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.deckA.retiredCount, 1)
    }

    func testASeekDuringTheFadeEndsIt() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        startStandardFade(host, controller)
        controller.onSeek()
        XCTAssertEqual(controller.phase, .bailing)
    }

    func testPausingWhileArmedAbandonsTheTransition() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        host.deckA.playWhenReady = false
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.deckB.retiredCount, 1)
    }

    func testAQueueChangeWhileArmingBailsButTheSameNextItemDoesNot() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        controller.onUpcomingChanged(to: "two")
        XCTAssertEqual(controller.phase, .arming, "an append further down the queue doesn't change the incoming track")
        controller.onUpcomingChanged(to: "three")
        XCTAssertEqual(controller.phase, .idle)
    }

    func testArmFailureAndErrorsBail() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        controller.onArmFailed(itemID: "other")
        XCTAssertEqual(controller.phase, .arming)
        controller.onArmFailed(itemID: "two")
        XCTAssertEqual(controller.phase, .idle)

        controller.tick()
        XCTAssertEqual(controller.phase, .arming)
        controller.onError()
        XCTAssertEqual(controller.phase, .idle)

        controller.tick()
        controller.onActiveAdvanced()
        XCTAssertEqual(controller.phase, .idle, "the session deck moved on by itself before the standby was ready")
    }

    func testSwitchingCrossfadeOffMidFadeFinishesIt() {
        let host = FakeCrossfadeHost.playing()
        let controller = CrossfadeController(host: host)
        startStandardFade(host, controller)
        host.deckB.position = 1
        controller.tick()
        host.crossfadeSeconds = 0
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.deckB.volume, 1)
    }

    func testABailOpensBothFilters() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.planner = StubPlanner(spec: TransitionSpec(startTime: 22, overlap: 8, filters: .ride(TransitionFilterRide(style: .djFilter, filterSweep: 1))))
        let controller = CrossfadeController(host: host)
        host.deckA.position = 18
        controller.tick()
        host.deckB.isReadyToPlay = true
        host.deckA.position = 22
        controller.tick()
        host.deckB.position = 2
        controller.tick()
        XCTAssertFalse(host.deckA.filter.isOpen)
        controller.onSkipRequested()
        XCTAssertTrue(host.deckA.filter.isOpen)
        XCTAssertTrue(host.deckB.filter.isOpen)
    }
}

@MainActor
final class CrossfadeRuleTests: XCTestCase {
    func testRepeatOneNeverCrossfadesATrackIntoItself() {
        let host = FakeCrossfadeHost.playing()
        host.upcoming = FakeCrossfadeHost.item("one", duration: 30)
        let controller = CrossfadeController(host: host)
        host.deckA.position = 25
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(host.window)
    }

    func testNoTransitionsInAListenTogetherParty() {
        let host = FakeCrossfadeHost.playing()
        host.transitionsSuspended = true
        let controller = CrossfadeController(host: host)
        host.deckA.position = 25
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testNothingQueuedOrNotPlayingMeansNothingToArm() {
        let host = FakeCrossfadeHost.playing()
        host.upcoming = nil
        let controller = CrossfadeController(host: host)
        host.deckA.position = 25
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)

        host.upcoming = FakeCrossfadeHost.item("two", duration: 30)
        host.deckA.playWhenReady = false
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testSleepAfterTrackFadesTheTrackOutInsteadOfTransitioning() {
        let host = FakeCrossfadeHost.playing()
        host.sleepsAfterCurrentTrack = true
        let controller = CrossfadeController(host: host)
        host.deckA.position = 20
        controller.tick()
        XCTAssertEqual(controller.phase, .idle, "no arm lead: nothing is being loaded")
        host.deckA.position = 24
        controller.tick()
        XCTAssertEqual(controller.phase, .sleepFade)
        XCTAssertTrue(host.armed.isEmpty, "no second decoder for a track that will never play")
        host.deckA.position = 27
        controller.tick()
        XCTAssertEqual(host.deckA.volume, equalPower(0.5).fall, accuracy: 0.001)
        host.deckA.position = 30
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.sleepFadesFinished, 1)
        XCTAssertFalse(host.deckA.playWhenReady)
        XCTAssertEqual(host.deckA.volume, 1)
    }

    func testTurningTheSleepTimerOffMidFadeRestoresTheVolume() {
        let host = FakeCrossfadeHost.playing()
        host.sleepsAfterCurrentTrack = true
        let controller = CrossfadeController(host: host)
        host.deckA.position = 25
        controller.tick()
        host.deckA.position = 27
        controller.tick()
        XCTAssertLessThan(host.deckA.volume, 1)
        host.sleepsAfterCurrentTrack = false
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.deckA.volume, 1)
        XCTAssertEqual(host.sleepFadesFinished, 0)
    }

    func testTheTrackEndingBeforeTheFadeOutHandsTheVolumeBackAtOnce() {
        let host = FakeCrossfadeHost.playing()
        host.sleepsAfterCurrentTrack = true
        let controller = CrossfadeController(host: host)
        host.deckA.position = 25
        controller.tick()
        host.deckA.position = 27
        controller.tick()
        XCTAssertEqual(controller.phase, .sleepFade)
        XCTAssertLessThan(host.deckA.volume, 1)
        // The engine saw the track end first and spent the timer; no tick in between.
        host.sleepsAfterCurrentTrack = false
        controller.onSleepTimerCleared()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.deckA.volume, 1)
        XCTAssertFalse(controller.isTransitioning)
    }
}

@MainActor
final class AutomixExecutionTests: XCTestCase {
    func testAPlannedTransitionIsExecutedAsSpecified() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.crossfadeSeconds = 0
        host.playbackSpeed = 1.25
        let spec = TransitionSpec(
            startTime: 20,
            overlap: 8,
            incomingCueTime: 30,
            incomingRate: 1.05,
            filters: .ride(TransitionFilterRide(style: .djFilter, filterSweep: 1)),
            markerVisible: true
        )
        let planner = StubPlanner(spec: spec)
        host.planner = planner
        host.upcomingDuration = 200
        let controller = CrossfadeController(host: host)

        host.deckA.position = 15.9
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.window?.start ?? 0, 20.0 / 30, accuracy: 0.0001)
        XCTAssertEqual(host.window?.end ?? 0, 28.0 / 30, accuracy: 0.0001)
        let context = planner.contexts.last
        XCTAssertEqual(context?.outgoing.id, "one")
        XCTAssertEqual(context?.incoming.id, "two")
        XCTAssertEqual(context?.position, 15.9)
        XCTAssertEqual(context?.duration, 30)
        XCTAssertEqual(context?.incomingDuration, 200)
        XCTAssertEqual(context?.fallbackOverlap, CrossfadeController.defaultSmartFallback, "crossfade at Off falls back to 6 s")

        host.deckA.position = 16
        controller.tick()
        XCTAssertEqual(controller.phase, .arming)
        XCTAssertEqual(host.armed.first?.cue, 30, "the incoming track opens at its mix-in point")
        XCTAssertEqual(host.armed.first?.rate ?? 0, 1.25 * 1.05, accuracy: 0.0001, "the beatmatch stretch stacks on the listener's speed")

        host.deckB.isReadyToPlay = true
        host.deckA.position = 19.9
        controller.tick()
        XCTAssertEqual(controller.phase, .arming)
        host.deckA.position = 20
        controller.tick()
        XCTAssertEqual(controller.phase, .fading)
        XCTAssertTrue(host.mixInProgress, "a cued, stretched, filtered transition is a real mix")
        XCTAssertNil(host.window)

        host.deckB.position = 34
        controller.tick()
        let half = equalPower(0.5)
        XCTAssertEqual(host.deckB.volume, half.rise, accuracy: 0.001, "progress runs from the cue, not from zero")
        XCTAssertEqual(host.deckA.volume, half.fall, accuracy: 0.001)
        XCTAssertLessThan(host.deckA.filter.lowPassHz, TransitionFilterCutoffs.openHz, "the outgoing track rides a closing low-pass")
        XCTAssertGreaterThan(host.deckB.filter.highPassHz, TransitionFilterCutoffs.offHz, "the incoming track arrives high-passed")

        host.deckB.position = 38
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(host.deckB.rate, 1.25, "the stretch is undone when the blend finishes")
        XCTAssertTrue(host.deckB.filter.isOpen)
        XCTAssertFalse(host.mixInProgress)
    }

    func testANilSpecMeansNoTransition() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.planner = StubPlanner(spec: nil)
        let controller = CrossfadeController(host: host)
        for position in stride(from: 20.0, through: 29.9, by: 0.5) {
            host.deckA.position = position
            controller.tick()
        }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(host.window)
    }

    func testWithoutAPlannerAutomixFallsBackToASixSecondFade() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.crossfadeSeconds = 0
        let controller = CrossfadeController(host: host)
        host.deckA.position = 19.9
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        host.deckA.position = 20
        controller.tick()
        XCTAssertEqual(controller.phase, .arming)
        XCTAssertEqual(controller.currentSpec?.overlap, 6)
    }

    func testVideoRowsNeverGetAutomix() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.current = FakeCrossfadeHost.item("one", duration: 30, videoOrigin: true)
        let planner = StubPlanner(spec: TransitionSpec(startTime: 20, overlap: 8))
        host.planner = planner
        let controller = CrossfadeController(host: host)
        host.deckA.position = 25
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(planner.contexts.isEmpty)
    }

    func testTurningAutomixOffMidTransitionFinishesItButAStandardFadeIgnoresIt() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.crossfadeSeconds = 0
        host.planner = StubPlanner(spec: TransitionSpec(startTime: 22, overlap: 8))
        let controller = CrossfadeController(host: host)
        host.deckA.position = 18
        controller.tick()
        host.deckB.isReadyToPlay = true
        host.deckA.position = 22
        controller.tick()
        XCTAssertEqual(controller.phase, .fading)
        host.deckB.position = 1
        controller.tick()
        XCTAssertEqual(controller.phase, .fading, "crossfade at Off doesn't read as the fade being switched off")
        host.automixActive = false
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)

        let standard = FakeCrossfadeHost.playing()
        let other = CrossfadeController(host: standard)
        startStandardFade(standard, other)
        standard.automixActive = false
        standard.deckB.position = 1
        other.tick()
        XCTAssertEqual(other.phase, .fading)
    }

    func testTurningAutomixOffTakesItsMarkerOffTheScrubber() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.crossfadeSeconds = 0
        host.planner = StubPlanner(spec: TransitionSpec(startTime: 20, overlap: 8, markerVisible: true))
        let controller = CrossfadeController(host: host)
        host.deckA.position = 10
        controller.tick()
        XCTAssertNotNil(host.window)

        host.automixActive = false
        controller.tick()
        XCTAssertNil(host.window, "no transition is coming, so none is marked")
    }

    func testTurningAutomixOffWhilePausedTakesItsMarkerOffTheScrubber() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.crossfadeSeconds = 0
        host.planner = StubPlanner(spec: TransitionSpec(startTime: 20, overlap: 8, markerVisible: true))
        let controller = CrossfadeController(host: host)
        host.deckA.position = 10
        controller.tick()
        XCTAssertNotNil(host.window)

        host.deckA.playWhenReady = false
        host.automixActive = false
        controller.tick()
        XCTAssertNil(host.window, "the marker doesn't wait for play to resume")
    }

    func testASleepTimerFadesOutFromThePlannedStart() {
        let host = FakeCrossfadeHost.playing()
        host.automixActive = true
        host.sleepsAfterCurrentTrack = true
        host.planner = StubPlanner(spec: TransitionSpec(startTime: 22, overlap: 8))
        let controller = CrossfadeController(host: host)
        host.deckA.position = 21.9
        controller.tick()
        XCTAssertEqual(controller.phase, .idle)
        host.deckA.position = 22
        controller.tick()
        XCTAssertEqual(controller.phase, .sleepFade)
    }
}
