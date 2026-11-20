import AVFoundation
import XCTest
@testable import Playback

/// Skip silence as the engine executes it on real files: silent intros are opened past, gaps are
/// jumped, silent outros end the track early.
@MainActor
final class SkipSilenceEngineTests: EngineTestCase {
    func testAFileWithATwoSecondSilentIntroStartsAtAboutTwoSeconds() async throws {
        let url = try ToneFile.write([.silence(seconds: 2), .tone(frequency: 440, seconds: 3)], to: directory, name: "silence-intro")
        let item = PlayableItem.file(url, id: "silence-intro")
        let h = harness(queue: [item])
        h.engine.skipSilence = true
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        // A fifth of the gap is kept (Media3's retention), half of it before the cut: 1.8 s.
        XCTAssertGreaterThanOrEqual(h.engine.position, 1.7)
        XCTAssertLessThan(h.engine.position, 2.3)
        // The processor never saw the silent part being played from 0:00.
        let processor = try XCTUnwrap(h.processors[h.engine.activeDeckID])
        await waitUntil("frames") { !processor.framePositions.isEmpty }
        let first = Double(processor.framePositions[0]) / ToneFile.sampleRate
        XCTAssertGreaterThan(first, 1.4, "opened past the intro, not played into it and jumped")
    }

    func testWithSkipSilenceOffTheIntroPlays() async throws {
        let url = try ToneFile.write([.silence(seconds: 2), .tone(frequency: 440, seconds: 2)], to: directory, name: "silence-off")
        let item = PlayableItem.file(url, id: "silence-off")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        XCTAssertLessThan(h.engine.position, 0.5)
    }

    func testAGapInTheMiddleIsJumped() async throws {
        let url = try ToneFile.write([
            .tone(frequency: 440, seconds: 1),
            .silence(seconds: 3),
            .tone(frequency: 660, seconds: 2),
        ], to: directory, name: "silence-gap")
        let item = PlayableItem.file(url, id: "silence-gap")
        let h = harness(queue: [item])
        h.engine.skipSilence = true
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        let clock = Date()
        // 3 s of silence keeps 0.6 s: from about 1.3 s the playhead jumps to about 3.7 s.
        await waitUntil("past the gap", timeout: 4) { h.engine.position > 3.6 }
        XCTAssertLessThan(Date().timeIntervalSince(clock), 2.6, "the gap was skipped, not sat through")
    }

    func testASilentOutroEndsTheTrackEarlyAndTheNextFollows() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 1.2), .silence(seconds: 4)], to: directory, name: "silence-outro")
        let first = PlayableItem.file(url, id: "silence-outro")
        let second = try tone(2, frequency: 660, name: "silence-next")
        let h = harness(queue: [first, second])
        h.engine.skipSilence = true
        // The scan that finds the outro runs alongside playback, and a 1.2 s tone leaves it about
        // a second and a half: a busy runner lost that race and played the whole four seconds out
        // (CI). Open paused and wait for the trim, so what is timed is the trim.
        h.engine.load(first, playWhenReady: false)
        await waitUntil("opened") { h.engine.duration > 0 && !h.engine.isBuffering }
        let entry = try XCTUnwrap(h.engine.deck(h.engine.activeDeckID).current)
        let trimmed = await waitUntil("the outro is trimmed") { entry.effectiveEnd.map { $0 < 3 } ?? false }
        guard trimmed else { return }
        h.engine.play()
        await waitUntil("playing") { h.engine.isPlaying }
        let clock = Date()
        await waitUntil("next track", timeout: 5) { h.engine.currentItem?.id == second.id }
        XCTAssertLessThan(Date().timeIntervalSince(clock), 2.5, "the four silent seconds were not played out")
        XCTAssertEqual(h.delegate.changes.last?.reason, .ended)
    }

    func testATrimFoundWhilePlayingEndsTheTrackAtTheNewEnd() async throws {
        // The tone is long enough that the scan always finishes while the tone is still playing,
        // so the trim lands mid-playback and not in front of the outro.
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 12), .silence(seconds: 4)], to: directory, name: "silence-trim-playing")
        let first = PlayableItem.file(url, id: "silence-trim-playing")
        let second = try tone(2, frequency: 660, name: "silence-trim-next")
        let h = harness(queue: [first, second])
        h.engine.skipSilence = true
        h.engine.load(first, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        let entry = try XCTUnwrap(h.engine.deck(h.engine.activeDeckID).current)
        let trimmed = await waitUntil("the outro is trimmed", timeout: 6) { entry.effectiveEnd.map { $0 < 15 } ?? false }
        guard trimmed else { return }
        XCTAssertTrue(h.engine.isPlaying, "the trim arrived while the track was playing")
        XCTAssertLessThan(h.engine.position, 11, "the scan finished before the outro was reached")
        h.engine.seek(to: 12)
        let clock = Date()
        await waitUntil("next track", timeout: 5) { h.engine.currentItem?.id == second.id }
        XCTAssertLessThan(Date().timeIntervalSince(clock), 2.5, "the four silent seconds were not played out")
        XCTAssertEqual(h.delegate.changes.last?.reason, .ended)
    }

    func testTheLiveDetectorSkipsAGapWhenTheTrackCannotBeScanned() async throws {
        let url = try ToneFile.write([
            .tone(frequency: 440, seconds: 1),
            .silence(seconds: 4),
            .tone(frequency: 660, seconds: 2),
        ], to: directory, name: "silence-live")
        let item = PlayableItem.file(url, id: "silence-live")
        let h = harness(queue: [item], scansAheadForSilence: false)
        h.engine.skipSilence = true
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing") { h.engine.isPlaying }
        let clock = Date()
        await waitUntil("past the gap", timeout: 6) { h.engine.position > 5.0 }
        XCTAssertLessThan(Date().timeIntervalSince(clock), 4.0, "the tap's detector fast-forwarded through the silence")
    }

    func testTurningItOnMidTrackTrimsTheOutroOfTheLoadedItem() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 2), .silence(seconds: 3)], to: directory, name: "silence-toggle")
        let item = PlayableItem.file(url, id: "silence-toggle")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: false)
        await waitUntil("opened") { h.engine.duration > 0 && !h.engine.isBuffering }
        h.engine.skipSilence = true
        let entry = try XCTUnwrap(h.engine.deck(h.engine.activeDeckID).current)
        await waitUntil("scanned and trimmed") { entry.effectiveEnd.map { $0 < 3 } ?? false }
        XCTAssertEqual(entry.effectiveEnd ?? 0, 2.3, accuracy: 0.1)
        h.engine.skipSilence = false
        XCTAssertEqual(entry.effectiveEnd ?? 0, 5, accuracy: 0.05)
    }
}
