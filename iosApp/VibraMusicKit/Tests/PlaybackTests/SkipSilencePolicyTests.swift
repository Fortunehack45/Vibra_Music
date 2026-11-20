import AVFoundation
import VibraMusicTestSupport
import XCTest
@testable import Playback

final class SilenceMapTests: XCTestCase {
    private let policy = SkipSilencePolicy.standard

    func testDefaultsMatchTheAndroidConfiguration() {
        XCTAssertEqual(policy.minimumSilence, 1, "a second-long floor leaves musical rests alone")
        XCTAssertEqual(policy.thresholdLevel, 1_024.0 / 32_768.0)
        XCTAssertEqual(policy.retentionRatio, 0.2)
        XCTAssertEqual(policy.maximumRetained, 2)
        XCTAssertEqual(policy.retained(for: 2), 0.4, accuracy: 0.0001)
        XCTAssertEqual(policy.retained(for: 30), 2, "never more than two seconds kept")
    }

    func testASilentIntroIsSkippedKeepingABreath() {
        let map = SilenceMap(spans: [SilentSpan(start: 0, end: 2)], duration: nil, isComplete: false)
        XCTAssertEqual(map.startPosition(policy: policy) ?? 0, 1.8, accuracy: 0.0001)
        XCTAssertNil(map.endPosition(policy: policy), "the outro isn't known until the scan completes")
    }

    func testASilentOutroEndsTheTrackEarly() {
        let map = SilenceMap(spans: [SilentSpan(start: 10, end: 13)], duration: 13, isComplete: true)
        XCTAssertEqual(map.endPosition(policy: policy) ?? 0, 10.3, accuracy: 0.0001)
        XCTAssertNil(map.startPosition(policy: policy))
    }

    func testAGapInTheMiddleIsJumped() {
        let map = SilenceMap(spans: [SilentSpan(start: 5, end: 9)], duration: 20, isComplete: true)
        XCTAssertNil(map.skipTarget(at: 5.3, policy: policy), "the first part of the kept silence plays")
        XCTAssertEqual(map.skipTarget(at: 5.5, policy: policy) ?? 0, 8.6, accuracy: 0.0001)
        XCTAssertEqual(map.skipTarget(at: 7, policy: policy) ?? 0, 8.6, accuracy: 0.0001)
        XCTAssertNil(map.skipTarget(at: 8.6, policy: policy), "already at the landing point")
        XCTAssertNil(map.skipTarget(at: 12, policy: policy))
    }

    func testAnAllSilentTrackIsLeftAlone() {
        let map = SilenceMap(spans: [SilentSpan(start: 0, end: 5)], duration: 5, isComplete: true)
        XCTAssertNil(map.startPosition(policy: policy))
        XCTAssertNil(map.endPosition(policy: policy))
    }

    func testTheAccumulatorFindsOnlyGapsOfASecondOrMore() {
        var accumulator = SilenceAccumulator(policy: policy)
        let rate = 1_000.0
        func feed(_ seconds: Double, _ level: Float) {
            let frames = Int(seconds * rate)
            let samples = [Float](repeating: level, count: frames * 2)
            samples.withUnsafeBufferPointer { accumulator.feed(interleaved: $0, frames: frames, channels: 2, sampleRate: rate, start: nil) }
        }
        feed(1.5, 0)
        XCTAssertFalse(accumulator.hasHeardSound)
        feed(1, 0.5)
        XCTAssertTrue(accumulator.hasHeardSound)
        feed(0.5, 0)        // a rest inside the music: kept
        feed(1, 0.5)
        feed(2, 0.001)      // below −30 dBFS counts as silence
        feed(1, 0.5)
        feed(1.2, 0)
        let map = accumulator.map(complete: true)
        XCTAssertEqual(map.spans.count, 3)
        XCTAssertEqual(map.spans[0].start, 0, accuracy: 0.011)
        XCTAssertEqual(map.spans[0].end, 1.5, accuracy: 0.011)
        XCTAssertEqual(map.spans[1].start, 4, accuracy: 0.011)
        XCTAssertEqual(map.spans[1].end, 6, accuracy: 0.011)
        XCTAssertEqual(map.spans[2].end, 8.2, accuracy: 0.011)
        XCTAssertEqual(map.duration ?? 0, 8.2, accuracy: 0.011)
        XCTAssertTrue(map.isComplete)
    }

    func testTheScannerMapsARealFileAndReportsTheIntroFirst() async throws {
        let directory = try makeTemporaryDirectory()
        let url = try ToneFile.write([
            .silence(seconds: 2),
            .tone(frequency: 440, seconds: 1.5),
            .silence(seconds: 0.4),
            .tone(frequency: 440, seconds: 1),
            .silence(seconds: 1.6),
            .tone(frequency: 550, seconds: 1),
            .silence(seconds: 2),
        ], to: directory, name: "gaps")
        let leading = LockedBox<SilenceMap?>(nil)
        let map = try await SilenceScanner.scan(asset: AVURLAsset(url: url), policy: policy) { leading.value = $0 }
        XCTAssertEqual(map.spans.count, 3, "\(map.spans)")
        XCTAssertEqual(map.spans[0].end, 2, accuracy: 0.02)
        XCTAssertEqual(map.spans[1].start, 4.9, accuracy: 0.02)
        XCTAssertEqual(map.spans[1].end, 6.5, accuracy: 0.02)
        XCTAssertEqual(map.spans[2].start, 7.5, accuracy: 0.02)
        XCTAssertEqual(map.duration ?? 0, 9.5, accuracy: 0.02)
        XCTAssertEqual(map.startPosition(policy: policy) ?? 0, 1.8, accuracy: 0.02)
        XCTAssertEqual(map.endPosition(policy: policy) ?? 0, 7.7, accuracy: 0.02)
        let first = try XCTUnwrap(leading.value)
        XCTAssertFalse(first.isComplete, "the intro verdict arrives before the whole file is read")
        XCTAssertEqual(first.startPosition(policy: policy) ?? 0, 1.8, accuracy: 0.02)
    }
}

final class LiveSilenceDetectorTests: XCTestCase {
    func testTracksTheSilentRunTheTapIsIn() {
        let detector = LiveSilenceDetector(threshold: SkipSilencePolicy.standard.thresholdLevel)
        let format = AudioTapFormat(sampleRate: 1_000, channelCount: 1)
        func feed(_ level: Float, at start: TimeInterval, frames: Int = 100) {
            var samples = [Float](repeating: level, count: frames)
            samples.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                withUnsafeMutablePointer(to: &list) { pointer in
                    detector.feed(UnsafeMutableAudioBufferListPointer(pointer), frameCount: frames, format: format, sourceStart: start)
                }
            }
        }
        feed(0.5, at: 0)
        XCTAssertNil(detector.ongoingRun)
        XCTAssertEqual(detector.lastSound ?? 0, 0.1, accuracy: 0.0001)
        for step in 1...12 { feed(0, at: Double(step) / 10) }
        let run = try? XCTUnwrap(detector.ongoingRun)
        XCTAssertEqual(run?.start ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(run?.end ?? -1, 1.3, accuracy: 0.0001)
        // The engine jumps to the end of what was heard; the time-pitch look-back re-renders from a
        // little before it. Still the same run.
        feed(0, at: 1.1)
        XCTAssertEqual(detector.ongoingRun?.start ?? -1, 0.1, accuracy: 0.0001, "a landing inside the run continues it")
        XCTAssertEqual(detector.ongoingRun?.end ?? -1, 1.3, accuracy: 0.0001)
        feed(0, at: 1.3)
        XCTAssertEqual(detector.ongoingRun?.end ?? -1, 1.4, accuracy: 0.0001)
        feed(0, at: 5)
        XCTAssertEqual(detector.ongoingRun?.start ?? -1, 5, accuracy: 0.0001, "a jump well past it restarts the run")
        feed(0, at: 2)
        XCTAssertEqual(detector.ongoingRun?.start ?? -1, 2, accuracy: 0.0001, "so does a seek back before it")
        feed(0.2, at: 5.1)
        XCTAssertNil(detector.ongoingRun)
    }
}

/// A value shared with a `@Sendable` callback.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
