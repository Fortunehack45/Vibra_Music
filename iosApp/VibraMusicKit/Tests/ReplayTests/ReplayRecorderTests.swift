import XCTest
import VibraMusicTestSupport
import VibraMusicCore
@testable import Replay

// Ports the threshold half of the recorder contract: what counts as a listen, and how sampling
// accumulates minutes and plays.

final class ReplayRecorderThresholdTests: XCTestCase {
    func testThresholdUnknownLengthNeedsThirtySeconds() {
        XCTAssertEqual(ReplayListeningRecorder.playThresholdMs(trackLengthMs: 0), 30_000)
        XCTAssertEqual(ReplayListeningRecorder.playThresholdMs(trackLengthMs: -5), 30_000)
    }

    func testThresholdHalfBelowFloorStaysAtFloor() {
        // A 60 s track: half is exactly the 30 s floor.
        XCTAssertEqual(ReplayListeningRecorder.playThresholdMs(trackLengthMs: 60_000), 30_000)
        XCTAssertEqual(ReplayListeningRecorder.playThresholdMs(trackLengthMs: 100_000), 50_000)
    }

    func testThresholdHalfAboveCeilingStaysAtCeiling() {
        // Past four minutes, half a track is more listening than anyone disputes.
        XCTAssertEqual(ReplayListeningRecorder.playThresholdMs(trackLengthMs: 10 * 60_000), 4 * 60_000)
        XCTAssertEqual(ReplayListeningRecorder.playThresholdMs(trackLengthMs: 7 * 60_000), 3 * 60_000 + 30_000)
    }

    func testFirstSampleAnchorsAndContributesNothing() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        recorder.onSample(replaySong("a"), durationMs: 200_000)
        XCTAssertTrue(spy.samples.isEmpty)
        clock.advance(by: 5_000)
        recorder.onSample(replaySong("a"), durationMs: 200_000)
        XCTAssertEqual(spy.samples.count, 1)
        XCTAssertEqual(spy.samples[0].ms, 5_000)
    }

    func testStepCappedAcrossPause() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        recorder.onSample(replaySong("a"), durationMs: 200_000)
        clock.advance(by: 3_600_000)
        recorder.onSample(replaySong("a"), durationMs: 200_000)
        // An hour on the lock screen must not arrive as an hour of listening.
        XCTAssertEqual(spy.samples.first?.ms, ReplayListeningRecorder.maxStepMs)
    }

    func testZeroStepRecordsNothing() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        recorder.onSample(replaySong("a"), durationMs: 200_000)
        recorder.onSample(replaySong("a"), durationMs: 200_000)
        XCTAssertTrue(spy.samples.isEmpty)
    }

    func testPlayCountedOnceAtThreshold() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        // 200 s track: threshold is 100 s. Six-second ticks (under the 8 s cap).
        let song = replaySong("a", duration: "3:20")
        recorder.onSample(song, durationMs: 0)
        for _ in 0..<30 {
            clock.advance(by: 6_000)
            recorder.onSample(song, durationMs: 0)
        }
        let counted = spy.samples.filter(\.countsAsPlay)
        XCTAssertEqual(counted.count, 1)
        // The play lands once enough has gone by: 100 s / 6 s ticks, on the 17th sample.
        XCTAssertEqual(spy.samples.firstIndex(where: \.countsAsPlay), 16)
        XCTAssertGreaterThanOrEqual(counted.first?.ms ?? 0, 0)
    }

    func testShortTrackUsesFloor() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        // 60 s track via duration text: threshold is the 30 s floor.
        let song = replaySong("a", duration: "1:00")
        recorder.onSample(song, durationMs: 0)
        for _ in 0..<4 {
            clock.advance(by: 6_000)
            recorder.onSample(song, durationMs: 0)
        }
        XCTAssertFalse(spy.samples.contains(where: \.countsAsPlay))
        clock.advance(by: 6_000)
        recorder.onSample(song, durationMs: 0)
        XCTAssertEqual(spy.samples.filter(\.countsAsPlay).count, 1)
    }

    func testDecoderDurationBeatsRowStatedRuntime() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        // Row says 1:00 (floor 30 s) but the decoder says 10 minutes (threshold 4 min): no play yet.
        let song = replaySong("a", duration: "1:00")
        recorder.onSample(song, durationMs: 600_000)
        for _ in 0..<10 {
            clock.advance(by: 6_000)
            recorder.onSample(song, durationMs: 600_000)
        }
        XCTAssertFalse(spy.samples.contains(where: \.countsAsPlay))
    }

    func testStoppedMakesNextTickAnchor() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        let song = replaySong("a")
        recorder.onSample(song, durationMs: 200_000)
        clock.advance(by: 5_000)
        recorder.onSample(song, durationMs: 200_000)
        XCTAssertEqual(spy.samples.count, 1)
        recorder.onStopped()
        let flushesAfterStop = spy.flushes
        XCTAssertGreaterThanOrEqual(flushesAfterStop, 1)
        // Whatever is on screen when playback resumes anchors rather than contributes.
        clock.advance(by: 60_000)
        recorder.onSample(song, durationMs: 200_000)
        XCTAssertEqual(spy.samples.count, 1)
    }

    func testFlushEverySixSamples() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        let song = replaySong("a")
        recorder.onSample(song, durationMs: 200_000)
        for _ in 0..<6 {
            clock.advance(by: 5_000)
            recorder.onSample(song, durationMs: 200_000)
        }
        XCTAssertEqual(spy.flushes, 1)
        for _ in 0..<6 {
            clock.advance(by: 5_000)
            recorder.onSample(song, durationMs: 200_000)
        }
        XCTAssertEqual(spy.flushes, 2)
    }

    func testNewTrackResetsPlayCounting() {
        let spy = ReplaySinkSpy()
        let clock = ReplayFixedClock(start: 1_000_000)
        let recorder = ReplayListeningRecorder(sink: spy, nowMillis: clock.now)
        // Drive track A past its threshold, then switch: B must earn its own play.
        let a = replaySong("a", duration: "1:00")
        recorder.onSample(a, durationMs: 0)
        for _ in 0..<6 {
            clock.advance(by: 6_000)
            recorder.onSample(a, durationMs: 0)
        }
        XCTAssertEqual(spy.samples.filter(\.countsAsPlay).count, 1)
        let b = replaySong("b", duration: "1:00")
        recorder.onSample(b, durationMs: 0)
        clock.advance(by: 6_000)
        recorder.onSample(b, durationMs: 0)
        XCTAssertEqual(spy.samples.filter(\.countsAsPlay).count, 1)
    }
}

final class ReplayFixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var millis: Int64

    init(start: Int64) { millis = start }

    func now() -> Int64 { lock.withLock { millis } }

    func advance(by step: Int64) { lock.withLock { millis += step } }
}
