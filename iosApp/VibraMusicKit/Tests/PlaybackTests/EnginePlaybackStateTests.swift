import AVFoundation
import VibraMusicCore
import XCTest
@testable import Playback

/// The engine's observable state through a track's life: loading, playing, pausing, seeking,
/// ending, stopping — against real audio files played by AVFoundation.
@MainActor
final class EnginePlaybackStateTests: EngineTestCase {
    #if os(iOS)
    /// On a USB DAC the session's rate is the DAC's rate, so the track's rate must be asked for
    /// before the deck plays — otherwise the opening plays at the previous rate.
    func testTheRateIsRequestedBeforePlayStarts() async throws {
        let item = try tone(4, name: "state-rate-first")
        let h = harness(queue: [item])
        let session = FakeAudioSession()
        session.playbackStateProbe = { h.engine.active.wantsToPlay }
        h.engine.audioSession = session

        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.2 }

        XCTAssertEqual(session.trackSampleRate, 44_100)
        XCTAssertFalse(session.rateRequestedWhilePlaying.isEmpty)
        XCTAssertEqual(session.rateRequestedWhilePlaying.first, false, "the rate request must come before play")
    }
    #endif

    func testLoadingBuffersThenPlays() async throws {
        let item = try tone(3, name: "state-load")
        let h = harness(queue: [item])
        XCTAssertNil(h.engine.currentItem)
        XCTAssertFalse(h.engine.isPlaying)

        h.engine.load(item, playWhenReady: true)
        // The item is current at once, before its audio has opened, and the engine says it is
        // waiting on it.
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
        XCTAssertTrue(h.engine.playWhenReady)
        XCTAssertTrue(h.engine.isBuffering)
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested])

        await waitUntil("playing") { h.engine.isPlaying }
        XCTAssertFalse(h.engine.isBuffering)
        // A track now sounds on its first samples, which can be a moment before the
        // decoder's length is read for an item that states none.
        await waitUntil("the decoder's length") { abs(h.engine.duration - 3) < 0.05 }
        XCTAssertEqual(h.engine.duration, 3, accuracy: 0.05)
        await waitUntil("position advancing") { h.engine.position > 0.3 }
        XCTAssertNil(h.engine.lastError)
    }

    func testPauseAndPlayHoldThePosition() async throws {
        let item = try tone(4, name: "state-pause")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.4 }

        h.engine.pause()
        XCTAssertFalse(h.engine.playWhenReady)
        await waitUntil("stopped") { !h.engine.isPlaying }
        let parked = h.engine.position
        await pause(for: 0.4)
        XCTAssertEqual(h.engine.position, parked, accuracy: 0.06, "a paused engine keeps its place")

        h.engine.togglePlayPause()
        XCTAssertTrue(h.engine.playWhenReady)
        await waitUntil("playing again") { h.engine.isPlaying && h.engine.position > parked + 0.2 }
    }

    func testLoadingPausedRestoresWithoutPlaying() async throws {
        // What a cold start does with the last queue: the track is there, at its position, silent.
        let item = try tone(5, name: "state-restore")
        let h = harness(queue: [item])
        h.engine.load(item, startingAt: 2.5, playWhenReady: false)
        await waitUntil("loaded") { !h.engine.isBuffering && h.engine.duration > 0 }
        await pause(for: 0.3)
        XCTAssertFalse(h.engine.isPlaying)
        XCTAssertFalse(h.engine.playWhenReady)
        XCTAssertEqual(h.engine.position, 2.5, accuracy: 0.05)

        h.engine.play()
        await waitUntil("playing from the restored position") { h.engine.isPlaying && h.engine.position > 2.6 }
    }

    func testSeekMovesThePlayheadAndClampsToTheTrack() async throws {
        let item = try tone(6, name: "state-seek")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }

        h.engine.seek(to: 4)
        XCTAssertEqual(h.engine.position, 4, accuracy: 0.01, "the scrubber moves at once, not when the seek lands")
        await waitUntil("playing past the seek") { h.engine.isPlaying && h.engine.position > 4.1 }

        h.engine.skip(by: -10)
        XCTAssertEqual(h.engine.position, 0, accuracy: 0.01)
        h.engine.seek(to: 60)
        XCTAssertLessThanOrEqual(h.engine.position, 6)
    }

    func testTheLastTrackEndingStopsAndReportsTheQueueFinished() async throws {
        let item = try tone(1, name: "state-end")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("queue finished", timeout: 6) { h.engine.hasEnded }
        XCTAssertEqual(h.delegate.finished.map(\.id), [item.id])
        // `isPlaying` follows the player's own time-control status, which settles a beat after the
        // end-of-item notice that sets `hasEnded`: sampled at that instant it can still read true
        // (CI: a bare XCTAssertFalse failed here 4 times, each passing on retry).
        await waitUntil("the player stops") { !h.engine.isPlaying }
        XCTAssertFalse(h.engine.playWhenReady, "the play button goes back to play")
        XCTAssertEqual(h.engine.currentItem?.id, item.id, "the finished track stays on screen")

        // Play starts it over.
        h.engine.play()
        await waitUntil("restarted") { h.engine.isPlaying && h.engine.position < 0.9 }
        XCTAssertFalse(h.engine.hasEnded, "playing again clears the finished state")
    }

    func testStopForgetsTheItem() async throws {
        let item = try tone(3, name: "state-stop")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        h.engine.stop()
        XCTAssertNil(h.engine.currentItem)
        XCTAssertFalse(h.engine.isPlaying)
        XCTAssertFalse(h.engine.isBuffering)
        XCTAssertEqual(h.engine.position, 0)
        XCTAssertEqual(h.engine.duration, 0)
        XCTAssertEqual(h.nowPlaying.lastState?.hasItem, false)
        XCTAssertNil(h.nowPlaying.info)
    }

    func testCheckpointsFollowPlayPauseSeekAndTheSampler() async throws {
        // Position persistence: the delegate hears where playback is at the moments the Android
        // service saved it — play/pause, item changes, seeks, and every sample interval.
        let item = try tone(4, name: "state-checkpoint")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        await waitUntil("a playing checkpoint") { h.delegate.checkpoints.contains { $0.isPlaying && $0.position > 0 } }

        h.engine.seek(to: 2)
        XCTAssertEqual(h.delegate.checkpoints.last?.position ?? -1, 2, accuracy: 0.01)
        XCTAssertEqual(h.delegate.checkpoints.last?.itemID, item.id)

        // The sampler (every 0.5 s in the harness) keeps saving while it plays.
        let count = h.delegate.checkpoints.count
        await waitUntil("sampler checkpoints", timeout: 3) { h.delegate.checkpoints.count >= count + 2 }

        h.engine.pause()
        await waitUntil("paused checkpoint") { h.delegate.checkpoints.last?.isPlaying == false }
        XCTAssertGreaterThan(h.delegate.checkpoints.last?.position ?? 0, 2)
    }

    func testRestartsOnPreviousAfterTenSeconds() async throws {
        let item = try tone(12, name: "state-previous")
        let h = harness(queue: [item])
        h.engine.load(item, startingAt: 3, playWhenReady: false)
        await waitUntil("loaded") { h.engine.duration > 0 }
        XCTAssertFalse(h.engine.restartsOnPrevious)
        h.engine.seek(to: 10.5)
        XCTAssertTrue(h.engine.restartsOnPrevious, "past ten seconds, previous restarts the track (BACK_RESTARTS_AFTER_MS)")
    }

    func testTheCatalogueDurationShowsUntilTheDecoderKnows() throws {
        let url = try ToneFile.tone(2, in: directory, name: "state-catalogue")
        let item = PlayableItem(id: "c", title: "C", artist: "A", duration: 185, source: .file(url))
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: false)
        XCTAssertEqual(h.engine.duration, 185, "the row's own duration stands in while the item opens")
    }
}
