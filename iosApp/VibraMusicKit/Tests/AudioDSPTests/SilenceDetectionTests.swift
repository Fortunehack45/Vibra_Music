import XCTest
@testable import AudioDSP

/// "Skip silence": which silences Android's Media3 processor would shorten, by
/// how much, and how the detector reports them so an `AVPlayer` can seek over
/// them. PORTING.md's done-test is "silent intros and outros are skipped".
///
/// Most tests run at 8 kHz stereo so the Media3 arithmetic is easy to follow:
/// the 1 s minimum is 8000 frames, split into two 4000-frame halves; 2 s kept
/// at most is 16000 frames; a 16-bit stereo frame is 4 bytes.
final class SilenceDetectionTests: XCTestCase {

    private let rate = 8_000
    private var sampleRate: Double { Double(rate) }

    // ---- What gets shortened ----------------------------------------------------

    func testSilenceShorterThanTheMinimumIsLeftAlone() {
        let signal = Signal().loud(1_000).silent(7_999).loud(1_000)
        let (events, detector) = detect(signal)
        XCTAssertEqual(events, [])
        XCTAssertEqual(detector.phase, .sound)
    }

    /// A run exactly the minimum long is faded out and back in — Media3 still
    /// treats it as silence — but every frame is kept, so there is nothing to seek over.
    func testExactlyTheMinimumIsFadedButNothingIsSkipped() {
        let signal = Signal().loud(100).silent(8_000).loud(100)
        let (events, _) = detect(signal)
        XCTAssertEqual(events.map(\.kind), [.started, .ended])
        XCTAssertEqual(events.last?.span.skippedFrames, 0)
        XCTAssertTrue(events.last?.span.skipRange.isEmpty ?? false)
        XCTAssertEqual(scan(signal), [], "scan only reports spans with something to skip")
    }

    /// Two seconds: half a second of fade-out, 20% of each following half
    /// second, and half a second of fade-in — 1.2 s kept, 0.8 s skipped.
    func testTwoSecondsOfSilenceKeepsOnePointTwo() {
        let signal = Signal().loud(500).silent(16_000).loud(500)
        let span = endedSpans(signal).first
        XCTAssertEqual(span?.startFrame, 500)
        XCTAssertEqual(span?.endFrame, 16_500)
        XCTAssertEqual(span?.keptLeadingFrames, 4_000 + 800 + 800)
        XCTAssertEqual(span?.keptTrailingFrames, 4_000)
        XCTAssertEqual(span?.skippedFrames, 6_400)
        XCTAssertEqual(span?.skipRange, 6_100..<12_500)
        XCTAssertEqual(span?.reachedEndOfStream, false)
    }

    /// Ten seconds: kept silence stops growing at the 2 s maximum, and from
    /// there Android drops every silent frame until the music comes back.
    func testTenSecondsKeepsTheTwoSecondMaximum() {
        let signal = Signal().loud(8).silent(80_000).loud(8)
        let (events, _) = detect(signal)
        XCTAssertEqual(events.map(\.kind), [.started, .discarding, .ended])
        XCTAssertEqual(events[0].span.endFrame, 8 + 8_000, "confirmed once the minimum has passed")
        XCTAssertEqual(events[1].span.endFrame, 8 + 48_000, "ten 20% slices of half a second reach the cap")
        XCTAssertEqual(events[1].span.keptLeadingFrames, 12_000)
        let span = events[2].span
        XCTAssertEqual(span.keptFrames, 16_000)
        XCTAssertEqual(span.skippedFrames, 64_000)
        XCTAssertEqual(span.skipStartTime, (8.0 + 12_000) / 8_000, accuracy: 1e-9)
        XCTAssertEqual(span.skipEndTime, (8.0 + 80_000 - 4_000) / 8_000, accuracy: 1e-9)
        XCTAssertEqual(span.skippedDuration, 8, accuracy: 1e-9)
    }

    /// The run-in and the run-out of a track, which is what the setting is for.
    func testSilentIntrosAndOutrosAreFound() {
        let signal = Signal().silent(24_000).loud(16_000).silent(40_000)
        let spans = endedSpans(signal)
        XCTAssertEqual(spans.count, 2)

        XCTAssertEqual(spans[0].startFrame, 0)
        XCTAssertEqual(spans[0].endFrame, 24_000)
        XCTAssertEqual(spans[0].keptFrames, 4_000 + 4 * 800 + 4_000)
        XCTAssertEqual(spans[0].skippedFrames, 12_800)
        XCTAssertFalse(spans[0].reachedEndOfStream)

        XCTAssertEqual(spans[1].startFrame, 40_000)
        XCTAssertEqual(spans[1].endFrame, 80_000)
        XCTAssertEqual(spans[1].keptFrames, 4_000 + 8 * 800 + 4_000)
        XCTAssertEqual(spans[1].skippedFrames, 25_600)
        XCTAssertTrue(spans[1].reachedEndOfStream)
    }

    /// Media3 calls a sample loud when its 16-bit magnitude is *over* 1024.
    func testTheThresholdLevelItselfCountsAsSilence() {
        XCTAssertEqual(endedSpans(Signal().loud(10).silent(20_000, level: 1_024).loud(10)).count, 1)
        XCTAssertEqual(endedSpans(Signal().loud(10).silent(20_000, level: 1_025).loud(10)).count, 0)
        XCTAssertEqual(endedSpans(Signal().loud(10).silent(20_000, level: -1_025).loud(10)).count, 0)
    }

    func testOneLoudChannelMakesTheFrameLoud() {
        let signal = Signal().loud(10).silent(20_000, rightLevel: 5_000).loud(10)
        XCTAssertEqual(endedSpans(signal), [])
    }

    func testMedia3sStockMinimumShortensBriefGaps() {
        let signal = Signal().loud(100).silent(2_400).loud(100) // 0.3 s
        XCTAssertEqual(endedSpans(signal), [], "Vibra Music's one-second floor leaves a 0.3 s rest alone")
        let spans = endedSpans(signal, configuration: .media3Default)
        XCTAssertEqual(spans.count, 1)
        XCTAssertGreaterThan(spans.first?.skippedFrames ?? 0, 0)
    }

    // ---- Equivalence with Media3 ---------------------------------------------------

    /// Randomised material — runs of silence and sound of every length, loud
    /// frames on one channel or both, levels right at the threshold — fed in
    /// random-sized chunks to both the detector and a literal port of Media3's
    /// byte-level processor, with Media3's two frame/byte mix-ups converted to
    /// the units Vibra Music's durations describe (`Arithmetic.intended`). The
    /// frames that processor drops must be exactly the frames the detector says
    /// to skip. `testWhatAnAndroidPhoneActuallySkips` covers the verbatim arithmetic.
    func testSkipsExactlyWhatMedia3Drops() {
        for (seed, configuration) in [(1, SilenceSkipConfiguration.vibraMusic), (2, .vibraMusic), (3, .media3Default),
                                      (4, SilenceSkipConfiguration(minimumSilenceDuration: 0.5, silenceRetentionRatio: 0.5,
                                                                   maxSilenceToKeepDuration: 1.2)),
                                      (5, SilenceSkipConfiguration(silenceRetentionRatio: 0, maxSilenceToKeepDuration: 1)),
                                      (6, SilenceSkipConfiguration(silenceRetentionRatio: 1))] {
            var random = SplitMix64(seed: UInt64(seed))
            let signal = Signal.random(using: &random, segments: 40, rate: rate)

            let reference = Media3SilenceSkipperReference(
                configuration: configuration, sampleRate: rate, channelCount: 2, arithmetic: .intended)
            let bytes = signal.int16Bytes
            var offset = 0
            while offset < bytes.count {
                let count = min(Int(random.next() % 3_000 + 1) * 4, bytes.count - offset)
                reference.queueInput(Array(bytes[offset..<(offset + count)]))
                offset += count
            }
            reference.queueEndOfStream()

            let spans = endedSpans(signal, configuration: configuration, chunking: &random)
            let skipped = spans.reduce(0) { $0 + Int($1.skippedFrames) }
            XCTAssertEqual(skipped, reference.skippedFrames, "seed \(seed)")
            XCTAssertEqual(signal.frames - skipped, reference.outputBytes / 4, "seed \(seed): frames heard")
            XCTAssertGreaterThan(reference.skippedFrames, 0, "seed \(seed) should exercise skipping")
        }
    }

    /// Why the port measures its buffer in frames: Media3 sizes its "maybe
    /// silence" buffer by passing a frame count through a byte-alignment helper,
    /// so for 16-bit stereo its effective floor is a quarter of the configured
    /// minimum — 250 ms where Vibra Music asked for a second.
    func testMedia3sOwnSizingWouldShrinkTheOneSecondFloor() {
        let media3 = Media3SilenceSkipperReference.mediaThreeBufferBytes(minimumSilence: 1, sampleRate: 44_100, channelCount: 2)
        XCTAssertEqual(media3 / 4, 11_024, "frames: about 0.25 s at 44.1 kHz")
        let intended = Media3SilenceSkipperReference.intendedBufferBytes(minimumSilence: 1, sampleRate: 44_100, channelCount: 2)
        XCTAssertEqual(intended / 4, 44_100)
    }

    /// The deviation, measured: Media3 1.11 verbatim, as Vibra Music configures it,
    /// on 48 kHz 16-bit stereo. Its buffer sizing makes the floor 250 ms rather
    /// than a second, so a half-second rest inside a song is shortened; and its
    /// keep-limit arithmetic stops a long silence at about 1.6 s kept rather than
    /// 2 s. The detector follows the durations Vibra Music asked for instead.
    func testWhatAnAndroidPhoneActuallySkips() {
        let rate = 48_000
        func android(_ signal: Signal) -> (skipped: Int, heard: Int) {
            let reference = Media3SilenceSkipperReference(configuration: .vibraMusic, sampleRate: rate,
                                                          channelCount: 2, arithmetic: .media3)
            let bytes = signal.int16Bytes
            var offset = 0
            while offset < bytes.count { // in sink-sized pieces, as Media3 is fed
                let count = min(16_384, bytes.count - offset)
                reference.queueInput(Array(bytes[offset..<(offset + count)]))
                offset += count
            }
            reference.queueEndOfStream()
            return (reference.skippedFrames, reference.outputBytes / 4)
        }
        func detector(_ signal: Signal) -> [SilenceSpan] {
            signal.samples.withUnsafeBufferPointer {
                SilenceDetector.scan(interleaved: $0, channelCount: 2, sampleRate: Double(rate))
            }
        }

        let rest = Signal().loud(4_800).silent(24_000).loud(4_800) // a 0.5 s rest
        XCTAssertGreaterThan(android(rest).skipped, 0, "Android shortens a half-second rest")
        XCTAssertEqual(detector(rest), [], "the detector leaves anything under a second alone")
        XCTAssertEqual(Media3SilenceSkipperReference.mediaThreeBufferBytes(minimumSilence: 1, sampleRate: rate,
                                                                            channelCount: 2) / 4,
                       12_000, "Media3's effective floor: 12 000 frames, 250 ms")

        let gap = Signal().loud(4_800).silent(480_000).loud(4_800) // 10 s of silence
        let keptOnAndroid = android(gap).heard - 9_600
        XCTAssertEqual(Double(keptOnAndroid) / Double(rate), 1.625, accuracy: 0.01,
                       "Android keeps about 1.6 s of a long silence")
        XCTAssertEqual(detector(gap).first?.keptFrames, 96_000, "the detector keeps the 2 s Vibra Music configured")
    }

    func testChunkingDoesNotChangeWhatIsReported() {
        var random = SplitMix64(seed: 99)
        let signal = Signal.random(using: &random, segments: 40, rate: rate)
        let whole = detect(signal, chunkFrames: signal.frames).events
        var chunking = SplitMix64(seed: 7)
        let (pieces, _) = detect(signal, chunking: &chunking)
        XCTAssertEqual(pieces, whole)
        XCTAssertFalse(whole.isEmpty)
    }

    func testScanReportsWhatStreamingReports() {
        var random = SplitMix64(seed: 5)
        let signal = Signal.random(using: &random, segments: 30, rate: rate)
        let streamed = detect(signal).events.filter { $0.kind == .ended && $0.span.skippedFrames > 0 }.map(\.span)
        XCTAssertEqual(scan(signal), streamed)
    }

    // ---- Live use from a tap ---------------------------------------------------------

    func testThePhaseFollowsTheRun() {
        let detector = makeDetector()
        func feed(_ signal: Signal) { signal.withChannels { detector.process($0) } }

        feed(Signal().loud(100))
        XCTAssertEqual(detector.phase, .sound)
        feed(Signal().silent(100))
        XCTAssertEqual(detector.phase, .pending)
        feed(Signal().silent(7_900))
        XCTAssertEqual(detector.phase, .shortening)
        feed(Signal().silent(40_000))
        XCTAssertEqual(detector.phase, .discarding)
        feed(Signal().loud(1))
        XCTAssertEqual(detector.phase, .sound)
        XCTAssertEqual(detector.drainEvents().map(\.kind), [.started, .discarding, .ended])
    }

    /// A seek the detector wasn't told about abandons the silence in progress.
    func testAnUnannouncedSeekInterruptsTheRun() {
        let detector = makeDetector()
        Signal().loud(10).silent(12_000).withChannels { detector.process($0, sourceFramePosition: 0) }
        XCTAssertEqual(detector.drainEvents().map(\.kind), [.started])

        Signal().silent(100).withChannels { detector.process($0, sourceFramePosition: 200_000) }
        let events = detector.drainEvents()
        XCTAssertEqual(events.map(\.kind), [.interrupted])
        XCTAssertEqual(events.first?.span.startFrame, 10)
        XCTAssertEqual(events.first?.span.endFrame, 12_010)
        XCTAssertEqual(detector.phase, .pending, "a new run starts at the new position")
    }

    /// The player seeks ahead through a silence it was told about: the run
    /// carries on across the jump, and the jumped frames count as dropped.
    func testAnAnnouncedSeekContinuesTheRun() {
        let detector = makeDetector()
        Signal().loud(10).silent(12_000).withChannels { detector.process($0, sourceFramePosition: 0) }
        XCTAssertEqual(detector.drainEvents().map(\.kind), [.started])

        detector.expectSeek(toFrame: 100_000)
        Signal().silent(8_000).loud(10).withChannels { detector.process($0, sourceFramePosition: 100_512) }
        let events = detector.drainEvents()
        XCTAssertEqual(events.map(\.kind), [.discarding, .ended])
        let span = events.last!.span
        XCTAssertEqual(span.startFrame, 10)
        XCTAssertEqual(span.endFrame, 108_512)
        XCTAssertGreaterThan(span.skippedFrames, 88_000, "the jump is part of what was skipped")
        XCTAssertLessThanOrEqual(span.keptFrames, 16_000)
    }

    /// A source time rounded to the neighbouring frame is not a seek.
    func testAFrameOfRoundingDoesNotInterruptTheRun() {
        let detector = makeDetector()
        Signal().loud(10).silent(12_000).withChannels { detector.process($0, sourceFramePosition: 0) }
        Signal().silent(12_000).withChannels { detector.process($0, sourceFramePosition: 12_011) }
        Signal().silent(12_000).loud(10).withChannels { detector.process($0, sourceFramePosition: 24_009) }
        let events = detector.drainEvents()
        XCTAssertEqual(events.map(\.kind), [.started, .ended], "one run, never interrupted")
        XCTAssertEqual(events.last?.span.startFrame, 10)
        XCTAssertEqual(events.last?.span.endFrame, 36_010)
    }

    func testPositionsFollowTheSourceTimeline() {
        let detector = makeDetector()
        Signal().loud(10).withChannels { detector.process($0, sourceFramePosition: 1_000) }
        Signal().silent(20_000).loud(10).withChannels { detector.process($0, sourceFramePosition: 1_010) }
        let span = detector.drainEvents().last?.span
        XCTAssertEqual(span?.startFrame, 1_010)
        XCTAssertEqual(span?.endFrame, 21_010)
    }

    func testADisabledDetectorReportsNothingAndSwitchingOffInterrupts() {
        let detector = makeDetector()
        detector.isEnabled = false
        Signal().silent(40_000).loud(10).withChannels { detector.process($0) }
        XCTAssertEqual(detector.drainEvents(), [])

        detector.isEnabled = true
        Signal().silent(10_000).withChannels { detector.process($0) }
        detector.isEnabled = false
        Signal().silent(10).withChannels { detector.process($0) }
        XCTAssertEqual(detector.drainEvents().map(\.kind), [.started, .interrupted])
        XCTAssertEqual(detector.phase, .sound)
    }

    func testTheAudioIsNeverModified() {
        let detector = makeDetector()
        var signal = Signal().loud(100).silent(20_000).loud(100)
        let before = signal.samples
        signal.withMutableChannels { detector.process($0) }
        XCTAssertEqual(signal.samples, before)
    }

    func testEventsBeyondTheRingsCapacityAreDroppedAndCounted() {
        let detector = SilenceDetector(configuration: .vibraMusic, eventCapacity: 2)
        detector.isEnabled = true
        detector.configure(sampleRate: sampleRate, channelCount: 2)
        Signal().silent(9_000).loud(1).silent(9_000).loud(1).silent(9_000).loud(1).withChannels { detector.process($0) }
        XCTAssertEqual(detector.drainEvents().count, 2)
        XCTAssertEqual(detector.droppedEventCount, 4)
    }

    func testFlushForgetsTheRunAndRestartsCounting() {
        let detector = makeDetector()
        Signal().silent(9_000).withChannels { detector.process($0) }
        detector.flush()
        XCTAssertEqual(detector.drainEvents().map(\.kind), [.started, .interrupted])
        Signal().loud(5).silent(20_000).loud(1).withChannels { detector.process($0) }
        XCTAssertEqual(detector.drainEvents().last?.span.startFrame, 5)
    }

    // ---- Harness ------------------------------------------------------------------

    private func makeDetector(_ configuration: SilenceSkipConfiguration = .vibraMusic) -> SilenceDetector {
        let detector = SilenceDetector(configuration: configuration, eventCapacity: 256)
        detector.isEnabled = true
        detector.configure(sampleRate: sampleRate, channelCount: 2)
        return detector
    }

    private func detect(_ signal: Signal, configuration: SilenceSkipConfiguration = .vibraMusic,
                        chunkFrames: Int = 512) -> (events: [SilenceEvent], detector: SilenceDetector) {
        let detector = makeDetector(configuration)
        var events: [SilenceEvent] = []
        var frame = 0
        while frame < signal.frames {
            let count = min(chunkFrames, signal.frames - frame)
            signal.withChannels(from: frame, count: count) { detector.process($0) }
            events += detector.drainEvents()
            frame += count
        }
        detector.finish()
        events += detector.drainEvents()
        return (events, detector)
    }

    private func detect(_ signal: Signal, configuration: SilenceSkipConfiguration = .vibraMusic,
                        chunking random: inout SplitMix64) -> (events: [SilenceEvent], detector: SilenceDetector) {
        let detector = makeDetector(configuration)
        var events: [SilenceEvent] = []
        var frame = 0
        while frame < signal.frames {
            let count = min(Int(random.next() % 4_096) + 1, signal.frames - frame)
            signal.withChannels(from: frame, count: count) { detector.process($0) }
            events += detector.drainEvents()
            frame += count
        }
        detector.finish()
        events += detector.drainEvents()
        return (events, detector)
    }

    private func endedSpans(_ signal: Signal, configuration: SilenceSkipConfiguration = .vibraMusic) -> [SilenceSpan] {
        detect(signal, configuration: configuration).events.filter { $0.kind == .ended && $0.span.skippedFrames > 0 }.map(\.span)
    }

    private func endedSpans(_ signal: Signal, configuration: SilenceSkipConfiguration,
                            chunking random: inout SplitMix64) -> [SilenceSpan] {
        detect(signal, configuration: configuration, chunking: &random).events.filter { $0.kind == .ended }.map(\.span)
    }

    private func scan(_ signal: Signal) -> [SilenceSpan] {
        signal.samples.withUnsafeBufferPointer {
            SilenceDetector.scan(interleaved: $0, channelCount: 2, sampleRate: sampleRate)
        }
    }
}

/// A stereo test signal built from runs of sound and silence, at 16-bit sample values.
struct Signal {
    private(set) var samples: [Float] = []
    var frames: Int { samples.count / 2 }

    func loud(_ count: Int, level: Int16 = 12_000) -> Signal {
        var copy = self
        copy.appendLoud(count, level: level)
        return copy
    }

    func silent(_ count: Int, level: Int16 = 300, rightLevel: Int16? = nil) -> Signal {
        var copy = self
        copy.appendSilent(count, level: level, rightLevel: rightLevel)
        return copy
    }

    mutating func appendLoud(_ count: Int, level: Int16 = 12_000) {
        samples.reserveCapacity(samples.count + count * 2)
        for frame in 0..<count {
            let value = Float(frame % 2 == 0 ? level : -level) / 32_768
            samples.append(value)
            samples.append(value)
        }
    }

    mutating func appendSilent(_ count: Int, level: Int16 = 300, rightLevel: Int16? = nil) {
        samples.reserveCapacity(samples.count + count * 2)
        let left = Float(level) / 32_768
        let right = Float(rightLevel ?? level) / 32_768
        for frame in 0..<count {
            let sign: Float = frame % 3 == 0 ? -1 : 1
            samples.append(sign * left)
            samples.append(sign * right)
        }
    }

    var int16Bytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: Int16((sample * 32_768).rounded()))
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8(value >> 8))
        }
        return bytes
    }

    static func random(using random: inout SplitMix64, segments: Int, rate: Int) -> Signal {
        var signal = Signal()
        for _ in 0..<segments {
            switch random.next() % 6 {
            case 0: signal.appendLoud(Int(random.next() % 600) + 1)
            case 1: signal.appendLoud(Int(random.next() % 40) + 1, level: 1_025)
            case 2: signal.appendSilent(Int(random.next() % UInt64(rate / 2)) + 1, level: Int16(random.next() % 1_025))
            case 3: signal.appendSilent(Int(random.next() % UInt64(rate * 6)) + 1, level: 1_024)
            case 4: signal.appendSilent(Int(random.next() % UInt64(rate * 3)) + 1, level: 10, rightLevel: -1_024)
            default: signal.appendSilent(Int(random.next() % UInt64(rate * 12)) + 1)
            }
        }
        return signal
    }

    /// Hands a detector a read-only window of the signal. The detector never writes.
    func withChannels(from frame: Int = 0, count: Int? = nil, _ body: (DSPChannels) -> Void) {
        let count = count ?? frames - frame
        samples.withUnsafeBufferPointer { buffer in
            body(DSPChannels(interleaved: UnsafeMutablePointer(mutating: buffer.baseAddress! + frame * 2),
                             channelCount: 2, frameCount: count))
        }
    }

    mutating func withMutableChannels(_ body: (DSPChannels) -> Void) {
        let frames = self.frames
        samples.withUnsafeMutableBufferPointer { buffer in
            body(DSPChannels(interleaved: buffer.baseAddress!, channelCount: 2, frameCount: frames))
        }
    }
}

/// Deterministic pseudo-random numbers for reproducible randomised tests.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
