import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports SleepTimer.kt's behaviour: 15/30/45/60-minute presets or "end of this track", held as a
/// deadline, and the service's handling of both.
@MainActor
final class SleepTimerTests: XCTestCase {

    /// A clock the test moves by hand.
    private final class ManualClock: @unchecked Sendable {
        let base = ContinuousClock.now
        var offset: Duration = .zero
        var now: ContinuousClock.Instant { base + offset }
    }

    func testThePresetsAreTheFourTheMenuOffers() {
        XCTAssertEqual(SleepTimer.presets, [15, 30, 45, 60])
    }

    func testAPresetSetsADeadlineAndCountsDownFromIt() {
        let clock = ManualClock()
        let timer = SleepTimer(now: { clock.now })
        XCTAssertFalse(timer.isRunning)
        XCTAssertNil(timer.remainingMs())

        timer.start(minutes: 15)
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.minutes, 15)
        XCTAssertFalse(timer.afterTrack)
        XCTAssertEqual(timer.remainingMs(), 15 * 60_000)
        XCTAssertEqual(timer.countdownText(), "15:00")

        clock.offset = .seconds(14 * 60 + 1)
        XCTAssertEqual(timer.remainingMs(), 59_000)
        XCTAssertEqual(timer.countdownText(), "0:59")

        clock.offset = .seconds(3_600)
        XCTAssertEqual(timer.remainingMs(), 0, "never negative")
        timer.cancel()
    }

    func testEndOfTrackAndPresetsReplaceEachOther() {
        let timer = SleepTimer()
        timer.start(minutes: 30)
        timer.startAfterTrack()
        XCTAssertTrue(timer.afterTrack)
        XCTAssertNil(timer.minutes)
        XCTAssertNil(timer.deadline)
        XCTAssertNil(timer.countdownText())
        XCTAssertTrue(timer.isRunning)

        timer.start(minutes: 45)
        XCTAssertFalse(timer.afterTrack)
        XCTAssertEqual(timer.minutes, 45)

        timer.cancel()
        XCTAssertFalse(timer.isRunning)
        XCTAssertNil(timer.minutes)
    }

    func testTheTimerFiresOnceAtItsDeadlineAndIsThenSpent() async throws {
        let timer = SleepTimer()
        let fired = expectation(description: "expired")
        var count = 0
        timer.onExpire = {
            count += 1
            fired.fulfill()
        }
        timer.arm(after: .milliseconds(50), minutes: 15)
        await fulfillment(of: [fired], timeout: 5)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(timer.isRunning)
        XCTAssertNil(timer.minutes)
    }

    func testResettingTheTimerReplacesThePendingOneInsteadOfFiringBoth() async throws {
        let timer = SleepTimer()
        var count = 0
        timer.onExpire = { count += 1 }
        timer.arm(after: .milliseconds(50), minutes: 15)
        // Far enough out that a loaded machine oversleeping below can't reach it.
        timer.arm(after: .seconds(600), minutes: 30)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(count, 0, "the first deadline was replaced")
        XCTAssertEqual(timer.minutes, 30)
        XCTAssertTrue(timer.isRunning)

        // Replaced again by a short one: that one fires, once.
        let fired = expectation(description: "expired")
        timer.onExpire = {
            count += 1
            fired.fulfill()
        }
        timer.arm(after: .milliseconds(50), minutes: 45)
        await fulfillment(of: [fired], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(count, 1)
        XCTAssertFalse(timer.isRunning)
    }

    func testACancelledTimerNeverFires() async throws {
        let timer = SleepTimer()
        var count = 0
        timer.onExpire = { count += 1 }
        timer.arm(after: .milliseconds(30), minutes: 15)
        timer.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(count, 0)
    }

    // MARK: With the queue

    func testEndOfThisTrackPausesOnTheNextTransitionAndIsSpent() {
        let timer = SleepTimer()
        let controller = PlaybackQueueController(settings: makeSettings(), sleepTimer: timer)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("a"), testSong("b"), testSong("c")], startIndex: 0)

        timer.startAfterTrack()
        XCTAssertEqual(controller.trackDidFinish(), .advanced(index: 1))
        XCTAssertEqual(recorder.last?.song?.videoId, "b")
        XCTAssertEqual(recorder.last?.playback, .pause)
        XCTAssertFalse(timer.isRunning)

        controller.trackDidFinish()
        XCTAssertEqual(recorder.last?.playback, .keep, "only the one track")
    }

    func testEndOfThisTrackFiresUnderRepeatOneToo() {
        let timer = SleepTimer()
        let controller = PlaybackQueueController(settings: makeSettings(), sleepTimer: timer)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        controller.setRepeatMode(.one)
        timer.startAfterTrack()
        XCTAssertEqual(controller.trackDidFinish(), .repeated)
        XCTAssertEqual(recorder.last?.reason, .repeatCurrent)
        XCTAssertEqual(recorder.last?.playback, .pause)
        XCTAssertFalse(timer.isRunning)
    }

    /// "End of this track" on the queue's last track: AutoPlay's late batch still queues, but must
    /// not start playing what the listener asked to stop before.
    func testEndOfThisTrackOnTheLastTrackIsNotUndoneByAutoplayArriving() async {
        let timer = SleepTimer()
        let radio = FakeRadioSource()
        let controller = PlaybackQueueController(settings: makeSettings(autoplay: true), radioSource: radio, sleepTimer: timer)
        controller.autoplayEmptyRefreshDelay = .milliseconds(10)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("last")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.ids, ["last"], "the first station came back empty")

        timer.startAfterTrack()
        radio.setStation("last", station("late", count: 2))
        XCTAssertEqual(controller.trackDidFinish(), .ended)
        XCTAssertFalse(timer.isRunning)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.upcomingIds, ["late1", "late2"], "queued for later")
        XCTAssertEqual(controller.state.currentSong?.videoId, "last", "and not played")
        XCTAssertFalse(recorder.changes.contains { $0.song?.videoId == "late1" })
    }

    func testTheQueueRunningOutSpendsAnyTimer() {
        let timer = SleepTimer()
        let controller = PlaybackQueueController(settings: makeSettings(), sleepTimer: timer)
        controller.setItems([testSong("a")], startIndex: 0)
        timer.start(minutes: 60)
        XCTAssertEqual(controller.trackDidFinish(), .ended)
        XCTAssertFalse(timer.isRunning)
    }
}
