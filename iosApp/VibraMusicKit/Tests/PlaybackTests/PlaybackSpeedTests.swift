import AVFoundation
import MediaPlayer
import XCTest
@testable import Playback

/// Playback speed 0.5×–2×, pitch preserved.
@MainActor
final class PlaybackSpeedTests: EngineTestCase {
    func testASpeedChangeRunsThePlayerFasterWithPitchKept() async throws {
        let item = try tone(8, name: "speed-fast")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying && h.engine.position > 0.3 }

        h.engine.rate = 1.5
        let deck = h.engine.deck(h.engine.activeDeckID)
        XCTAssertEqual(deck.player.rate, 1.5, accuracy: 0.001)
        XCTAssertEqual(deck.player.defaultRate, 1.5, accuracy: 0.001, "play() after a pause keeps the speed")
        XCTAssertEqual(deck.current?.playerItem.audioTimePitchAlgorithm, .spectral)

        // The playhead covers about 1.5 s of the track per second.
        let start = h.engine.position
        let clock = Date()
        await pause(for: 1.0)
        let covered = h.engine.position - start
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertEqual(covered / elapsed, 1.5, accuracy: 0.25)

        // The lock screen extrapolates at the new rate.
        XCTAssertEqual(h.nowPlaying.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(h.nowPlaying.info?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double ?? 0, 1.5, accuracy: 0.001)

        // Pause and resume keep it.
        h.engine.pause()
        await waitUntil("paused") { !h.engine.isPlaying }
        h.engine.play()
        await waitUntil("playing again") { h.engine.isPlaying }
        XCTAssertEqual(deck.player.rate, 1.5, accuracy: 0.001)
    }

    func testTheSpeedIsClampedToHalfToDouble() {
        let h = harness()
        h.engine.rate = 3
        XCTAssertEqual(h.engine.rate, 2)
        h.engine.rate = 0.1
        XCTAssertEqual(h.engine.rate, 0.5)
        h.engine.rate = 0.75
        XCTAssertEqual(h.engine.rate, 0.75)
        XCTAssertEqual(h.engine.deck(.a).player.defaultRate, 0.75, "both decks follow, so a crossfade's incoming track matches")
        XCTAssertEqual(h.engine.deck(.b).player.defaultRate, 0.75)
    }

    func testANewItemStartsAtTheChosenSpeed() async throws {
        let item = try tone(4, name: "speed-slow")
        let h = harness(queue: [item])
        h.engine.rate = 0.5
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        XCTAssertEqual(h.engine.deck(h.engine.activeDeckID).player.rate, 0.5, accuracy: 0.001)
    }

    func testASpeedChangeMidTransitionLandsWhenItFinishes() async throws {
        let first = try tone(3, name: "speed-xfade-1")
        let second = try tone(5, frequency: 550, name: "speed-xfade-2")
        let h = harness(queue: [first, second])
        h.engine.crossfadeDuration = 1
        h.engine.load(first, playWhenReady: true)
        await waitUntil("fading", timeout: 6) { h.engine.crossfade.phase == .fading }
        h.engine.rate = 1.25
        XCTAssertEqual(h.engine.rate, 1.25)
        await waitUntil("done", timeout: 4) { !h.engine.isTransitioning }
        XCTAssertEqual(h.engine.deck(h.engine.activeDeckID).player.rate, 1.25, accuracy: 0.001)
    }
}
