import Foundation

/// How "skip silence" decides what counts as silence and how much of it to keep.
///
/// The defaults are what Android's `PlaybackService.silenceSkippingRenderers`
/// passes to Media3's `SilenceSkippingAudioProcessor`: its stock retention
/// ratio, maximum kept silence and threshold, with the minimum raised from
/// Media3's 100 ms to a second. The stock threshold eats the breaths, rests and
/// pre-chorus beats *inside* a song — the setting reads as "make the music
/// sound rushed" rather than "trim dead air". A second-long floor leaves musical
/// pauses alone and still collapses the run-in and run-out of a track.
public struct SilenceSkipConfiguration: Equatable, Sendable {
    /// How long audio must stay below the threshold before any of it is skipped.
    public var minimumSilenceDuration: TimeInterval

    /// Fraction of a long silence kept (0...1) until `maxSilenceToKeepDuration` is reached.
    public var silenceRetentionRatio: Float

    /// The most silence kept from one run, padding included.
    public var maxSilenceToKeepDuration: TimeInterval

    /// A frame is silent when every sample's 16-bit magnitude is at most this.
    public var silenceThresholdLevel: Int16

    public init(minimumSilenceDuration: TimeInterval = 1.0,
                silenceRetentionRatio: Float = 0.2,
                maxSilenceToKeepDuration: TimeInterval = 2.0,
                silenceThresholdLevel: Int16 = 1024) {
        precondition((0...1).contains(silenceRetentionRatio), "silenceRetentionRatio must be within 0...1")
        self.minimumSilenceDuration = minimumSilenceDuration
        self.silenceRetentionRatio = silenceRetentionRatio
        self.maxSilenceToKeepDuration = maxSilenceToKeepDuration
        self.silenceThresholdLevel = silenceThresholdLevel
    }

    /// Vibra Music's configuration (`MIN_SILENCE_US` = 1 s, Media3 defaults otherwise).
    public static let vibraMusic = SilenceSkipConfiguration()

    /// Media3's stock `SilenceSkippingAudioProcessor()`: a 100 ms minimum.
    public static let media3Default = SilenceSkipConfiguration(minimumSilenceDuration: 0.1)

    /// The threshold as a float amplitude: a sample is loud when its 16-bit
    /// value would exceed `silenceThresholdLevel`.
    var thresholdAmplitude: Float {
        (Float(silenceThresholdLevel) + 0.5) / 32768
    }
}

/// One run of silence long enough to shorten, in source frames, and what
/// Android's silence skipping would have done with it.
///
/// Media3 keeps half a minimum-silence of padding at each end (faded out, then
/// back in), keeps `silenceRetentionRatio` of what lies between until
/// `maxSilenceToKeepDuration` of silence has been kept, and drops the rest.
/// Android drops those frames from the stream as it plays. An `AVPlayer` tap
/// can't, so this reports the cut as a range to seek over: play
/// `keptLeadingFrames` of the silence, jump to `skipRange.upperBound`, and the
/// remaining `keptTrailingFrames` lead back into the music. The total heard is
/// what Android keeps.
public struct SilenceSpan: Equatable, Sendable {
    /// First silent frame.
    public let startFrame: Int64

    /// First frame after the silence (exclusive): where sound resumed, the end
    /// of the stream, or — for an in-progress event — the frame just analysed.
    public let endFrame: Int64

    /// Silence kept before the cut: the fade-out padding plus what the retention ratio keeps.
    public let keptLeadingFrames: Int64

    /// Silence kept after the cut, leading back into the music. Zero until the silence has ended.
    public let keptTrailingFrames: Int64

    public let sampleRate: Double

    /// The silence ran to the end of the stream (a track's run-out).
    public let reachedEndOfStream: Bool

    public init(startFrame: Int64, endFrame: Int64, keptLeadingFrames: Int64, keptTrailingFrames: Int64,
                sampleRate: Double, reachedEndOfStream: Bool) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.keptLeadingFrames = keptLeadingFrames
        self.keptTrailingFrames = keptTrailingFrames
        self.sampleRate = sampleRate
        self.reachedEndOfStream = reachedEndOfStream
    }

    public var frameCount: Int64 { endFrame - startFrame }
    public var keptFrames: Int64 { keptLeadingFrames + keptTrailingFrames }
    public var skippedFrames: Int64 { frameCount - keptFrames }

    /// The frames Android would drop, as one contiguous range to seek over.
    public var skipRange: Range<Int64> {
        let lower = startFrame + keptLeadingFrames
        return lower..<max(lower, endFrame - keptTrailingFrames)
    }

    public var startTime: TimeInterval { Double(startFrame) / sampleRate }
    public var endTime: TimeInterval { Double(endFrame) / sampleRate }
    public var skipStartTime: TimeInterval { Double(skipRange.lowerBound) / sampleRate }
    public var skipEndTime: TimeInterval { Double(skipRange.upperBound) / sampleRate }
    public var skippedDuration: TimeInterval { Double(skippedFrames) / sampleRate }
}

/// Something the detector noticed, for the player to act on.
public struct SilenceEvent: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// The silence has lasted `minimumSilenceDuration`: Android would now be
        /// fading out and keeping only `silenceRetentionRatio` of what follows.
        case started
        /// `maxSilenceToKeepDuration` of silence has been kept: Android would now
        /// be dropping every further silent frame until sound resumes.
        case discarding
        /// Sound resumed (or the stream ended). The span is complete.
        case ended
        /// The stream jumped somewhere else mid-silence (a seek the detector wasn't
        /// told about, or a flush). The span stops at the last frame analysed.
        case interrupted
    }

    public let kind: Kind
    public let span: SilenceSpan

    public init(kind: Kind, span: SilenceSpan) {
        self.kind = kind
        self.span = span
    }
}

/// Where the detector is in a run of silence right now.
public enum SilencePhase: Int, Sendable {
    /// Sound, or no silence at all yet.
    case sound = 0
    /// Silent, but not yet for `minimumSilenceDuration`; nothing would be skipped so far.
    case pending = 1
    /// Past the minimum: Android keeps `silenceRetentionRatio` of this.
    case shortening = 2
    /// Past the kept maximum: Android keeps none of this.
    case discarding = 3
}

/// Finds the silences Android's "skip silence" would shorten, reproducing
/// Media3's `SilenceSkippingAudioProcessor` decisions frame for frame.
///
/// ## Why a detector and not a skipper
///
/// On Android the processor removes silent frames from the stream before they
/// reach the output. An `MTAudioProcessingTap` sees an `AVPlayer`'s audio but
/// cannot shorten the item's timeline, so on iOS this reports instead, and
/// Playback moves the player:
///
/// - **Ahead of time** — for audio that can be decoded before it plays (a
///   download, a cached file), feed it through a detector (or `scan`) and seek
///   over each span's `skipRange` when playback reaches it. This matches
///   Android exactly: the same frames are heard.
/// - **Live**, from the tap — watch `nextEvent()` / `phase`. On `.started` the
///   silence is confirmed; on `.discarding` Android would be dropping
///   everything, so call `expectSeek(toFrame:)` and seek ahead (or advance to
///   the next item if this is the run-out); on `.ended` sound is back. Telling
///   the detector about the seek first keeps the run open across the jump, so
///   one silence stays one span however many seeks it takes.
///
/// ## Threading
///
/// `process`, `finish` and `flush` run on the audio thread (or on whatever
/// single thread is decoding offline) and never allocate or lock. Events are
/// handed over through a fixed-size single-producer/single-consumer ring:
/// `nextEvent()` must be called from one consumer thread at a time.
public final class SilenceDetector: FloatAudioProcessor, @unchecked Sendable {

    public let configuration: SilenceSkipConfiguration

    private struct RenderState {
        var sampleRate = 0
        var channelCount = 0
        var bytesPerFrame = 0
        var halfBufferFrames = 0
        var bufferFrames = 0
        var maxKeepFrames = 0
        var threshold: Float = 1
        var wasEnabled = false

        var nextFrame: Int64 = 0
        var inRun = false
        var runStart: Int64 = 0
        var contents = 0
        var outputSinceNoise = 0
        var keptLeading: Int64 = 0
        var phase = SilencePhase.sound
    }

    private let render: UnsafeMutablePointer<RenderState>
    private let enabledFlag = AtomicWord(0)
    private let phaseWord = AtomicWord(Int64(SilencePhase.sound.rawValue))
    private let pendingSeek = AtomicWord(SilenceDetector.noSeek)
    private let events: SilenceEventRing

    private static let noSeek = Int64.min

    public init(configuration: SilenceSkipConfiguration = .vibraMusic, eventCapacity: Int = 64) {
        self.configuration = configuration
        events = SilenceEventRing(capacity: eventCapacity)
        render = .allocate(capacity: 1)
        render.initialize(to: RenderState())
    }

    deinit {
        render.deallocate()
    }

    // ---- Control side ------------------------------------------------------

    /// The "skip silence" setting. Off by default, as on Android. Switching it
    /// off abandons any run in progress at the next block.
    public var isEnabled: Bool {
        get { enabledFlag.load() != 0 }
        set { enabledFlag.store(newValue ? 1 : 0) }
    }

    /// The detector's phase as of the last block it analysed.
    public var phase: SilencePhase {
        SilencePhase(rawValue: Int(phaseWord.load())) ?? .sound
    }

    /// Events the ring had no room for because nobody was reading them.
    public var droppedEventCount: Int {
        events.droppedCount
    }

    /// The oldest undelivered event, or nil.
    public func nextEvent() -> SilenceEvent? {
        events.pop()
    }

    /// Every undelivered event, oldest first.
    public func drainEvents() -> [SilenceEvent] {
        var drained: [SilenceEvent] = []
        while let event = events.pop() { drained.append(event) }
        return drained
    }

    /// Announces that the player is about to seek to [frame] to skip the silence
    /// in progress, so the next discontinuity continues the same run instead of
    /// abandoning it. The frames jumped over are accounted as silence played
    /// through Media3's rules, so the phase and the span's kept/skipped figures
    /// come out as they would have on Android.
    public func expectSeek(toFrame frame: Int64) {
        pendingSeek.store(frame)
    }

    // ---- Audio side --------------------------------------------------------

    public func configure(sampleRate: Double, channelCount: Int) {
        let rs = render
        let rate = Int(sampleRate.rounded())
        rs.pointee.sampleRate = rate
        rs.pointee.channelCount = channelCount
        // Media3 counts in 16-bit frames: its shortening arithmetic rounds to
        // whole bytes of a 16-bit frame, and so does this.
        rs.pointee.bytesPerFrame = max(channelCount, 1) * 2
        // Half the minimum on each side of the cut, as Media3 splits its
        // "maybe silence" buffer. Media3 1.11 mixes frames and bytes twice:
        // it sizes that buffer in bytes from a count of frames (so for 16-bit
        // stereo its floor is 250 ms, not the second Vibra Music asked for), and
        // its keep-limit subtracts that byte length from a frame count (so a
        // long silence stops at about 1.6 s kept, not 2 s). The iOS port uses
        // the durations Vibra Music configured — the Kotlin comment on
        // MIN_SILENCE_US says a one-second floor is the point of the setting.
        // SilenceDetectionTests.testWhatAnAndroidPhoneActuallySkips measures the gap.
        let minimumFrames = Self.frames(for: configuration.minimumSilenceDuration, sampleRate: rate)
        rs.pointee.halfBufferFrames = minimumFrames / 2
        rs.pointee.bufferFrames = rs.pointee.halfBufferFrames * 2
        rs.pointee.maxKeepFrames = Self.frames(for: configuration.maxSilenceToKeepDuration, sampleRate: rate)
        rs.pointee.threshold = configuration.thresholdAmplitude
        rs.pointee.nextFrame = 0
        resetRun(emitInterrupted: false)
    }

    /// Analyses [channels], taking its first frame to follow the previous block's last.
    public func process(_ channels: DSPChannels) {
        process(channels, sourceFramePosition: nil)
    }

    /// Analyses [channels], whose first frame is [sourceFramePosition] in the
    /// item's timeline (from the tap's source time range). A position that
    /// doesn't follow on from the last block is a seek: the run in progress is
    /// abandoned (reported as `.interrupted`) unless `expectSeek` announced it.
    /// The audio is never modified.
    public func process(_ channels: DSPChannels, sourceFramePosition: Int64?) {
        let rs = render
        let frameCount = channels.frameCount
        let enabled = enabledFlag.load() != 0
        if !enabled {
            if rs.pointee.wasEnabled {
                resetRun(emitInterrupted: true)
                rs.pointee.wasEnabled = false
            }
            rs.pointee.nextFrame = (sourceFramePosition ?? rs.pointee.nextFrame) + Int64(frameCount)
            return
        }
        rs.pointee.wasEnabled = true
        let channelCount = rs.pointee.channelCount
        guard frameCount > 0, rs.pointee.bufferFrames >= 2, channels.channelCount == channelCount else {
            rs.pointee.nextFrame = (sourceFramePosition ?? rs.pointee.nextFrame) + Int64(frameCount)
            return
        }

        if let position = sourceFramePosition,
           abs(position - rs.pointee.nextFrame) > DSPChain.continuityToleranceFrames {
            handleDiscontinuity(to: position)
        }

        let stride = channels.stride
        let threshold = rs.pointee.threshold
        let first = rs.pointee.nextFrame
        // Silent frames are counted up and handed to the state machine a run at a time.
        var silentFrom = -1
        var frame = 0
        while frame < frameCount {
            let index = frame * stride
            var loud = false
            var channel = 0
            while channel < channelCount {
                if abs(channels.base(of: channel)[index]) >= threshold {
                    loud = true
                    break
                }
                channel += 1
            }
            if loud {
                if silentFrom >= 0 {
                    advanceSilence(by: frame - silentFrom, from: first + Int64(silentFrom))
                    silentFrom = -1
                }
                if rs.pointee.inRun { endRun(at: first + Int64(frame), reachedEndOfStream: false) }
            } else if silentFrom < 0 {
                silentFrom = frame
            }
            frame += 1
        }
        if silentFrom >= 0 {
            advanceSilence(by: frameCount - silentFrom, from: first + Int64(silentFrom))
        }
        rs.pointee.nextFrame = first + Int64(frameCount)
        publishPhase()
    }

    /// End of stream: a silence still open here is the track's run-out, and
    /// ends at the last frame analysed (Media3's `onQueueEndOfStream`).
    public func finish() {
        let rs = render
        if rs.pointee.inRun { endRun(at: rs.pointee.nextFrame, reachedEndOfStream: true) }
        publishPhase()
    }

    /// Forgets the run in progress and restarts frame counting at zero.
    public func flush() {
        resetRun(emitInterrupted: true)
        render.pointee.nextFrame = 0
        pendingSeek.store(Self.noSeek)
    }

    public func reset() {
        resetRun(emitInterrupted: false)
        let rs = render
        rs.pointee.nextFrame = 0
        rs.pointee.sampleRate = 0
        rs.pointee.channelCount = 0
        rs.pointee.bufferFrames = 0
        rs.pointee.halfBufferFrames = 0
        pendingSeek.store(Self.noSeek)
    }

    // ---- Media3's state machine, in frames ---------------------------------

    /// [count] silent frames, the first at [position]. Walks Media3's buffer a
    /// fill at a time rather than a frame at a time.
    private func advanceSilence(by count: Int, from position: Int64) {
        let rs = render
        if !rs.pointee.inRun {
            rs.pointee.inRun = true
            rs.pointee.runStart = position
            rs.pointee.contents = 0
            rs.pointee.outputSinceNoise = 0
            rs.pointee.keptLeading = 0
            rs.pointee.phase = .pending
        }
        var remaining = count
        var next = position
        while remaining > 0 {
            let step = min(remaining, rs.pointee.bufferFrames - rs.pointee.contents)
            rs.pointee.contents += step
            next += Int64(step)
            remaining -= step
            if rs.pointee.contents == rs.pointee.bufferFrames {
                bufferFilled(lastFrame: next - 1)
            }
        }
    }

    /// Media3's `outputShortenedSilenceBuffer(false)`: the buffer is full.
    private func bufferFilled(lastFrame position: Int64) {
        let rs = render
        let half = rs.pointee.halfBufferFrames
        if rs.pointee.outputSinceNoise == 0 {
            // FADE_OUT: the first half-buffer of silence is kept, as padding.
            rs.pointee.keptLeading += Int64(half)
            rs.pointee.outputSinceNoise += half
            rs.pointee.contents -= half
            rs.pointee.phase = .shortening
            emit(.started, endFrame: position + 1, trailing: 0, reachedEndOfStream: false)
        } else {
            // MUTE: consume all but the half-buffer held back for the fade-in,
            // keeping the retention ratio of it until the maximum is reached.
            let consumed = rs.pointee.contents - half
            let kept = shortened(consumed)
            rs.pointee.keptLeading += Int64(kept)
            rs.pointee.outputSinceNoise += kept
            rs.pointee.contents -= consumed
        }
        if rs.pointee.phase == .shortening && neededBytes() <= 0 {
            rs.pointee.phase = .discarding
            emit(.discarding, endFrame: position + 1, trailing: 0, reachedEndOfStream: false)
        }
    }

    /// Sound resumed at [position] (or the stream ended there).
    private func endRun(at position: Int64, reachedEndOfStream: Bool) {
        let rs = render
        if rs.pointee.outputSinceNoise > 0 {
            // FADE_IN: the held-back half-buffer, plus the retention ratio of
            // whatever silence arrived after it.
            let half = rs.pointee.halfBufferFrames
            let remainder = rs.pointee.contents - half
            let trailing = Int64(half + shortened(remainder))
            emit(.ended, endFrame: position, trailing: trailing, reachedEndOfStream: reachedEndOfStream)
        }
        // Otherwise the silence was shorter than the minimum and Media3 hands it
        // on unchanged (DO_NOT_CHANGE_VOLUME): nothing to skip, nothing to report.
        clearRun()
    }

    /// Media3's `calculateShortenedSilenceLength`, in frames. Float arithmetic
    /// and byte alignment as Media3 does them, so the frame counts agree.
    private func shortened(_ frames: Int) -> Int {
        let rs = render
        let bytesPerFrame = rs.pointee.bytesPerFrame
        let available = Float(max(neededBytes(), 0))
        let value = min(Float(frames * bytesPerFrame) * configuration.silenceRetentionRatio + 0.5, available)
        return Int(value) / bytesPerFrame
    }

    /// Bytes of silence that may still be kept before the maximum, net of the
    /// fade-in half-buffer that will be kept at the end.
    private func neededBytes() -> Int {
        let rs = render
        return (rs.pointee.maxKeepFrames - rs.pointee.outputSinceNoise) * rs.pointee.bytesPerFrame -
            rs.pointee.halfBufferFrames * rs.pointee.bytesPerFrame
    }

    private func handleDiscontinuity(to position: Int64) {
        let rs = render
        let announced = pendingSeek.exchange(Self.noSeek)
        let tolerance = Int64(max(2_048, rs.pointee.sampleRate / 20))
        let continuesRun = announced != Self.noSeek && abs(position - announced) <= tolerance &&
            rs.pointee.inRun && rs.pointee.outputSinceNoise > 0 && position > rs.pointee.nextFrame
        if continuesRun {
            // The frames jumped over were silence the player chose not to hear:
            // account for them as Media3 would have, had they been played through.
            advanceSilence(by: Int(position - rs.pointee.nextFrame), from: rs.pointee.nextFrame)
        } else {
            resetRun(emitInterrupted: true)
        }
        rs.pointee.nextFrame = position
    }

    private func resetRun(emitInterrupted: Bool) {
        let rs = render
        if emitInterrupted && rs.pointee.inRun && rs.pointee.outputSinceNoise > 0 {
            emit(.interrupted, endFrame: rs.pointee.nextFrame, trailing: 0, reachedEndOfStream: false)
        }
        clearRun()
        publishPhase()
    }

    private func clearRun() {
        let rs = render
        rs.pointee.inRun = false
        rs.pointee.contents = 0
        rs.pointee.outputSinceNoise = 0
        rs.pointee.keptLeading = 0
        rs.pointee.phase = .sound
    }

    private func emit(_ kind: SilenceEvent.Kind, endFrame: Int64, trailing: Int64, reachedEndOfStream: Bool) {
        let rs = render
        let span = SilenceSpan(startFrame: rs.pointee.runStart,
                               endFrame: endFrame,
                               keptLeadingFrames: rs.pointee.keptLeading,
                               keptTrailingFrames: trailing,
                               sampleRate: Double(rs.pointee.sampleRate),
                               reachedEndOfStream: reachedEndOfStream)
        events.push(SilenceEvent(kind: kind, span: span))
    }

    private func publishPhase() {
        let value = Int64(render.pointee.phase.rawValue)
        if phaseWord.load() != value { phaseWord.store(value) }
    }

    /// Media3's `durationUsToFrames`: whole microseconds × rate / 1e6, truncated.
    static func frames(for duration: TimeInterval, sampleRate: Int) -> Int {
        let microseconds = Int64((duration * 1_000_000).rounded())
        return Int(microseconds * Int64(sampleRate) / 1_000_000)
    }

    // ---- Offline -----------------------------------------------------------

    /// Every span "skip silence" would shorten in a whole decoded stream of
    /// interleaved Float32 samples — for audio decoded before it plays. Spans
    /// Media3 fades but keeps whole (a silence exactly the minimum long) have
    /// nothing to seek over and are left out.
    public static func scan(interleaved samples: UnsafeBufferPointer<Float>,
                            channelCount: Int,
                            sampleRate: Double,
                            configuration: SilenceSkipConfiguration = .vibraMusic) -> [SilenceSpan] {
        precondition(channelCount > 0, "channelCount must be positive: \(channelCount)")
        guard let base = samples.baseAddress else { return [] }
        let detector = SilenceDetector(configuration: configuration)
        detector.isEnabled = true
        detector.configure(sampleRate: sampleRate, channelCount: channelCount)
        let totalFrames = samples.count / channelCount
        let chunk = 4_096
        var spans: [SilenceSpan] = []
        func collect() {
            while let event = detector.nextEvent() {
                if event.kind == .ended && event.span.skippedFrames > 0 { spans.append(event.span) }
            }
        }
        var frame = 0
        while frame < totalFrames {
            let count = min(chunk, totalFrames - frame)
            let channels = DSPChannels(interleaved: UnsafeMutablePointer(mutating: base + frame * channelCount),
                                       channelCount: channelCount, frameCount: count)
            detector.process(channels)
            collect()
            frame += count
        }
        detector.finish()
        collect()
        return spans
    }
}

/// Fixed-capacity single-producer/single-consumer queue of `SilenceEvent`s.
/// The producer (audio thread) never blocks or allocates; when the consumer
/// falls behind, new events are dropped and counted.
final class SilenceEventRing: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<SilenceEvent>
    private let head = AtomicWord(0) // next slot to read; written by the consumer
    private let tail = AtomicWord(0) // next slot to write; written by the producer
    private let dropped = AtomicWord(0)

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
    }

    var droppedCount: Int { Int(dropped.load()) }

    /// Producer side.
    @discardableResult
    func push(_ event: SilenceEvent) -> Bool {
        let tail = self.tail.load()
        guard tail - head.load() < Int64(capacity) else {
            dropped.store(dropped.load() + 1)
            return false
        }
        (storage + Int(tail % Int64(capacity))).initialize(to: event)
        self.tail.store(tail + 1)
        return true
    }

    /// Consumer side.
    func pop() -> SilenceEvent? {
        let head = self.head.load()
        guard head < tail.load() else { return nil }
        let event = storage[Int(head % Int64(capacity))]
        self.head.store(head + 1)
        return event
    }
}
