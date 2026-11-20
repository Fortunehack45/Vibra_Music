import Lyrics
import QuartzCore
import XCTest
@testable import VibraMusic

/// The lyric clock when frames stop coming — the Simulator window covered, the app inactive or in
/// the background, the screen locked, Now Playing under a sheet — and then start again. Right
/// after resuming, the line shown must be the line at the engine's real position (Android:
/// rememberLyricClock restarts its effect on `foreground` and reconciles the latest report).
@MainActor
final class LyricClockResyncTests: XCTestCase {
    private let lines = LyricsDemo.wordSynced

    /// A stand-in for the engine: where it really is, as the player would read it.
    private final class Engine {
        var positionMs: Int
        var isPlaying: Bool
        init(positionMs: Int, isPlaying: Bool) {
            self.positionMs = positionMs
            self.isPlaying = isPlaying
        }
    }

    private func makeClock(engine: Engine, now: @escaping () -> CFTimeInterval) -> LyricFrameClock {
        let clock = LyricFrameClock()
        clock.now = now
        clock.isRunnable = false
        clock.source = { (engine.positionMs, engine.isPlaying) }
        clock.reset(positionMs: engine.positionMs, isPlaying: engine.isPlaying)
        return clock
    }

    private func line(at positionMs: Int) -> Int? {
        LyricFocus.currentIndex(lines, positionMs: positionMs)
    }

    /// Frames stop for ten seconds while the song plays on, and no report gets through either.
    /// The first frame back shows the engine's line, not the one frames stopped on.
    func testATenSecondFrameGapWhilePlayingResyncsOnTheFirstFrameBack() {
        var now: CFTimeInterval = 100
        let engine = Engine(positionMs: 2_500, isPlaying: true)
        let clock = makeClock(engine: engine, now: { now })
        // A second of ordinary frames and reports.
        for frame in 1...60 {
            now += 1.0 / 60
            engine.positionMs = 2_500 + Int((Double(frame) / 60 * 1_000).rounded())
            if frame % 15 == 0 { clock.report(positionMs: engine.positionMs, isPlaying: true) }
            clock.advance()
        }
        XCTAssertEqual(clock.positionMs, 3_500, accuracy: 20)
        XCTAssertEqual(line(at: clock.positionMs), 1, "\"Like a lighthouse\"")

        // Covered: ten seconds with no frames and no reports; the audio keeps going.
        now += 10
        engine.positionMs = 13_500
        clock.advance()
        XCTAssertEqual(clock.positionMs, 13_500, accuracy: 20)
        XCTAssertEqual(line(at: clock.positionMs), line(at: engine.positionMs), "the engine's line right after resuming")
        XCTAssertEqual(line(at: clock.positionMs), 4, "\"I hear you over the water\"")
    }

    /// Background and back: the loop stops while the app is away, and the moment it's runnable
    /// again the clock takes the engine's position — before any frame, before any report.
    func testABackgroundCycleResyncsTheMomentTheAppIsBack() {
        var now: CFTimeInterval = 50
        let engine = Engine(positionMs: 15_000, isPlaying: true)
        let clock = makeClock(engine: engine, now: { now })
        now += 0.5
        clock.advance()
        XCTAssertEqual(clock.positionMs, 15_500, accuracy: 20)

        clock.isRunnable = false // .background
        now += 10
        engine.positionMs = 25_600
        clock.isRunnable = true // .active
        XCTAssertEqual(clock.positionMs, 25_600, accuracy: 20)
        XCTAssertEqual(line(at: clock.positionMs), line(at: engine.positionMs))
        clock.isRunnable = false
    }

    /// Playback stopped while nobody was looking (an interruption, headphones pulled). Coming
    /// back must settle on where it stopped, not carry the old report ten seconds on.
    func testAPauseWhileAwaySettlesOnTheEnginesPositionOnResume() {
        var now: CFTimeInterval = 10
        let engine = Engine(positionMs: 2_000, isPlaying: true)
        let clock = makeClock(engine: engine, now: { now })
        now += 3
        engine.positionMs = 5_000
        engine.isPlaying = false
        clock.advance() // the first frame after the gap
        XCTAssertEqual(clock.positionMs, 5_000)
        XCTAssertFalse(clock.isPlaying)
        XCTAssertEqual(line(at: clock.positionMs), 2)
    }

    /// Right after resuming the engine may not have ticked yet: it still says what it said last
    /// time. That's stale, not a seek back — the clock carries the last report forward instead.
    func testAStaleEngineIsNotTakenForASeekBack() {
        var now: CFTimeInterval = 10
        let engine = Engine(positionMs: 12_000, isPlaying: true)
        let clock = makeClock(engine: engine, now: { now })
        now += 4
        clock.advance()
        XCTAssertEqual(clock.positionMs, 16_000, accuracy: 20)
        // Then the engine's first fresh tick lands, a little behind: a correction, held.
        now += 0.1
        engine.positionMs = 16_050
        clock.report(positionMs: engine.positionMs, isPlaying: true)
        XCTAssertEqual(clock.positionMs, 16_050)
    }

    /// Ordinary frames aren't a gap: a frame arriving on time doesn't go back to the engine.
    func testOrdinaryFramesDoNotResync() {
        var now: CFTimeInterval = 10
        let engine = Engine(positionMs: 1_000, isPlaying: true)
        let clock = makeClock(engine: engine, now: { now })
        clock.advance()
        var reads = 0
        clock.source = { reads += 1; return (engine.positionMs, engine.isPlaying) }
        for _ in 0..<30 {
            now += 1.0 / 60
            clock.advance()
        }
        XCTAssertEqual(reads, 0)
        now += 1
        clock.advance()
        XCTAssertEqual(reads, 1, "a second without frames is a gap")
    }

    /// A track opening: the player says it is playing about half a second before its clock moves.
    /// The words hold at the top until it does, then run with it: they were never ahead of the song.
    func testTheWordsWaitForAPlayerWhoseClockHasNotMovedYet() {
        var now: CFTimeInterval = 10
        let clock = LyricFrameClock()
        clock.now = { now }
        clock.isRunnable = false
        clock.reset(positionMs: 0, isPlaying: false)
        clock.report(positionMs: 0, isPlaying: true)
        for _ in 0..<36 {
            now += 1.0 / 60
            clock.advance()
            XCTAssertEqual(clock.positionMs, 0)
        }
        // A quarter second of song later, the first report that has moved.
        now += 0.25
        clock.report(positionMs: 250, isPlaying: true)
        XCTAssertEqual(clock.positionMs, 250)
        now += 0.1
        clock.advance()
        XCTAssertEqual(clock.positionMs, 350)
    }

    /// After a seek the same: the words land where it landed, and wait for the player there.
    func testTheWordsWaitForThePlayerAfterASeek() {
        var now: CFTimeInterval = 10
        let clock = LyricFrameClock()
        clock.now = { now }
        clock.isRunnable = false
        clock.reset(positionMs: 1_000, isPlaying: true)
        clock.report(positionMs: 40_000, isPlaying: true)
        now += 0.18
        clock.advance()
        XCTAssertEqual(clock.positionMs, 40_000)
        now += 0.25
        clock.report(positionMs: 40_250, isPlaying: true)
        now += 0.1
        clock.advance()
        XCTAssertEqual(clock.positionMs, 40_350)
    }

    /// The reconciler's own cases, through the clock: a late report is held, a seek jumps, a
    /// pause settles.
    func testTheReconcilerStillHoldsCorrectionsAndJumpsOnDiscontinuities() {
        var now: CFTimeInterval = 10
        let clock = LyricFrameClock()
        clock.now = { now }
        clock.isRunnable = false
        clock.reset(positionMs: 1_000, isPlaying: true)
        now += 0.2
        clock.advance()
        XCTAssertEqual(clock.positionMs, 1_200)
        clock.report(positionMs: 1_150, isPlaying: true)
        XCTAssertEqual(clock.positionMs, 1_200, "held")
        now += 0.05
        clock.report(positionMs: 40_000, isPlaying: true)
        XCTAssertEqual(clock.positionMs, 40_000, "seek")
        clock.report(positionMs: 39_900, isPlaying: false)
        XCTAssertEqual(clock.positionMs, 39_900, "pause")
    }
}
