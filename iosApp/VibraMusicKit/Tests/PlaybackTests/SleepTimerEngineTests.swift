import AVFoundation
import XCTest
@testable import Playback

/// The sleep timer as the engine executes it: a deadline that pauses, or the end of the track
/// playing now (port of `SleepTimer` and the service's `watchSleepTimer` / "sleep after this song").
@MainActor
final class SleepTimerEngineTests: EngineTestCase {
    func testTheTimerPausesAtItsDeadline() async throws {
        let item = try tone(6, name: "sleep-deadline")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.engine.startSleepTimer(.duration(1.0))
        XCTAssertNotNil(h.engine.sleepTimer?.deadline)
        XCTAssertFalse(h.engine.sleepTimer?.afterTrack ?? true)
        let remaining = try XCTUnwrap(h.engine.sleepTimerRemaining)
        XCTAssertEqual(remaining, 1.0, accuracy: 0.1)

        await pause(for: 0.5)
        XCTAssertTrue(h.engine.isPlaying, "not before the deadline")
        await waitUntil("paused by the timer", timeout: 3) { !h.engine.playWhenReady }
        XCTAssertNil(h.engine.sleepTimer, "a timer that ran out is spent")
        XCTAssertNil(h.engine.sleepTimerRemaining)
        await waitUntil("stopped") { !h.engine.isPlaying }
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
    }

    func testSettingTheTimerAgainReplacesTheWait() async throws {
        let item = try tone(6, name: "sleep-reset")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.engine.startSleepTimer(.duration(0.6))
        h.engine.startSleepTimer(.minutes(15))
        XCTAssertEqual(h.engine.sleepTimer?.presetMinutes, 15)
        XCTAssertEqual(h.engine.sleepTimerRemaining ?? 0, 900, accuracy: 1)
        await pause(for: 1.0)
        XCTAssertTrue(h.engine.playWhenReady, "the earlier, shorter wait was cancelled, not left to fire")

        h.engine.cancelSleepTimer()
        XCTAssertNil(h.engine.sleepTimer)
    }

    func testStoppingForgetsTheTimer() async throws {
        let item = try tone(6, name: "sleep-stop")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.engine.startSleepTimer(.minutes(15))
        h.engine.stop()
        XCTAssertNil(h.engine.sleepTimer, "clearing the queue takes the timer with it")
        XCTAssertNil(h.engine.sleepTimerRemaining)
    }

    func testEndOfTrackPausesOnTheNextTrackWithoutPlayingIt() async throws {
        let first = try tone(1.2, frequency: 440, name: "sleep-eot-1")
        let second = try tone(3, frequency: 660, name: "sleep-eot-2")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        h.engine.startSleepTimer(.endOfTrack)
        XCTAssertEqual(h.engine.sleepTimer?.afterTrack, true)
        XCTAssertNil(h.engine.sleepTimerRemaining, "no deadline: it waits for the track to end")

        await waitUntil("moved on", timeout: 5) { h.engine.currentItem?.id == second.id }
        XCTAssertEqual(h.delegate.changes.last?.reason, .ended)
        XCTAssertFalse(h.engine.playWhenReady)
        XCTAssertNil(h.engine.sleepTimer)
        await pause(for: 0.5)
        XCTAssertFalse(h.engine.isPlaying, "the next track is cued, not heard")
        XCTAssertLessThan(h.engine.position, 0.3)
        XCTAssertEqual(h.processors[h.engine.activeDeckID]?.begunItems.map(\.id).contains(second.id), false)
    }

    func testEndOfTrackOnTheLastTrackStopsThere() async throws {
        let item = try tone(1, name: "sleep-eot-last")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        h.engine.startSleepTimer(.endOfTrack)
        await waitUntil("finished", timeout: 5) { h.engine.hasEnded }
        XCTAssertNil(h.engine.sleepTimer)
        XCTAssertFalse(h.engine.playWhenReady)
    }

    func testEndOfTrackWithCrossfadeFadesTheTrackOutAndPauses() async throws {
        // With a crossfade set there is still no next track to fade into: the track fades to
        // silence over the crossfade span and playback pauses.
        let first = try tone(3, frequency: 440, name: "sleep-fade-1")
        let second = try tone(3, frequency: 660, name: "sleep-fade-2")
        let h = harness(queue: [first, second])
        h.engine.crossfadeDuration = 1
        h.engine.load(first, playWhenReady: true)
        h.engine.startSleepTimer(.endOfTrack)
        let deck = h.engine.activeDeckID

        await waitUntil("fading out", timeout: 5) { h.engine.crossfade.phase == .sleepFade }
        XCTAssertTrue(h.engine.isTransitioning)
        await waitUntil("quieter", timeout: 2) { h.engine.deck(deck).volume < 0.7 }
        await waitUntil("paused", timeout: 3) { !h.engine.playWhenReady }
        XCTAssertNil(h.engine.sleepTimer)
        XCTAssertEqual(h.engine.deck(deck).volume, 1, "the deck is handed back at full volume for next time")
        XCTAssertNil(h.engine.deck(deck == .a ? .b : .a).current, "no second deck was armed")
        XCTAssertFalse(h.delegate.changes.contains { $0.item.id == second.id && $0.reason == .crossfade })
    }
}
