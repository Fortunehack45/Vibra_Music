import Accelerate
import AVFoundation
import os

/// What "skip silence" treats as silence and how much of it it keeps.
///
/// The numbers are Media3's `SilenceSkippingAudioProcessor` defaults as the Android service
/// configured them, with one deliberate change it made: the shortest gap touched is a whole second
/// (`MIN_SILENCE_US`) rather than 100 ms. The stock threshold ate the breaths, rests and pre-chorus
/// beats *inside* a song, so the setting read as "make the music sound rushed" rather than "trim dead
/// air". A second-long floor leaves musical pauses alone and still collapses a track's run-in and
/// run-out.
public struct SkipSilencePolicy: Hashable, Sendable {
    /// Shortest gap that is skipped.
    public var minimumSilence: TimeInterval
    /// Peak level below which audio counts as silent: Media3's 1024 on the 16-bit scale (−30 dBFS).
    public var thresholdLevel: Float
    /// Fraction of a skipped gap kept, split either side of the cut, so the edit breathes.
    public var retentionRatio: Double
    /// Most of a gap ever kept.
    public var maximumRetained: TimeInterval

    public init(
        minimumSilence: TimeInterval = 1.0,
        thresholdLevel: Float = 1_024.0 / 32_768.0,
        retentionRatio: Double = 0.2,
        maximumRetained: TimeInterval = 2.0
    ) {
        self.minimumSilence = minimumSilence
        self.thresholdLevel = thresholdLevel
        self.retentionRatio = retentionRatio
        self.maximumRetained = maximumRetained
    }

    public static let standard = SkipSilencePolicy()

    /// How much of a gap of `length` seconds is kept in total.
    func retained(for length: TimeInterval) -> TimeInterval {
        min(length * retentionRatio, maximumRetained)
    }
}

/// A silent stretch of a track, in its own timeline (seconds).
struct SilentSpan: Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var length: TimeInterval { end - start }
}

/// The silent spans found in one track, and where playback should jump because of them.
struct SilenceMap: Hashable, Sendable {
    /// Spans of at least the policy's minimum, in order.
    var spans: [SilentSpan]
    /// The track's length as the scan measured it.
    var duration: TimeInterval?
    /// Whether the whole track has been scanned (the leading verdict arrives first).
    var isComplete: Bool

    static let edgeTolerance: TimeInterval = 0.02

    /// Where playback should start: past a silent intro, keeping half of what the policy retains.
    func startPosition(policy: SkipSilencePolicy) -> TimeInterval? {
        guard let first = spans.first, first.start <= Self.edgeTolerance, first.length >= policy.minimumSilence else { return nil }
        if let duration, first.end >= duration - Self.edgeTolerance { return nil } // all silence: leave it be
        return first.end - policy.retained(for: first.length) / 2
    }

    /// Where playback should end: before a silent outro, keeping half of what the policy retains.
    func endPosition(policy: SkipSilencePolicy) -> TimeInterval? {
        guard isComplete, let duration, let last = spans.last, last.end >= duration - Self.edgeTolerance,
              last.length >= policy.minimumSilence, last.start > Self.edgeTolerance else { return nil }
        return last.start + policy.retained(for: last.length) / 2
    }

    /// Where to jump to from `position` when it is inside a silent gap in the middle of the track.
    func skipTarget(at position: TimeInterval, policy: SkipSilencePolicy) -> TimeInterval? {
        for span in spans where span.length >= policy.minimumSilence {
            if span.start <= Self.edgeTolerance { continue }
            if let duration, span.end >= duration - Self.edgeTolerance { continue }
            let keep = policy.retained(for: span.length) / 2
            let from = span.start + keep
            let to = span.end - keep
            if position >= from, position < to - 0.05 { return to }
        }
        return nil
    }
}

/// Finds silent spans ahead of the playhead by decoding the track with `AVAssetReader`.
///
/// A tap only sees audio as it is rendered, half a second ahead at most, so it can tell that
/// silence has begun but not where it ends — and Media3's approach of dropping silent frames as
/// they pass has no equivalent on `AVPlayer`, whose tap must hand back as many frames as it took.
/// Skipping by seeking needs to know where the silence ends, so the track is scanned in the
/// background as it is loaded (the preloaded next track long before it plays). The leading verdict
/// is reported the moment the first sound is found, so a silent intro is skipped from the first
/// frame.
enum SilenceScanner {
    /// Scans `asset`. `onLeadingVerdict` fires once, as soon as the start position is known.
    static func scan(
        asset: AVAsset,
        policy: SkipSilencePolicy,
        onLeadingVerdict: @Sendable (SilenceMap) -> Void
    ) async throws -> SilenceMap {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PlaybackSourceError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PlaybackSourceError.noAudioTrack }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? PlaybackSourceError.noAudioTrack }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var accumulator = SilenceAccumulator(policy: policy)
        var scratch: [Float] = []
        var reportedLeading = false
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let channels = max(Int(asbd.mChannelsPerFrame), 1)
            let frames = CMSampleBufferGetNumSamples(sample)
            let bytes = CMBlockBufferGetDataLength(block)
            let count = bytes / MemoryLayout<Float>.size
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let copied = scratch.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!)
            }
            guard copied == kCMBlockBufferNoErr else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            scratch.withUnsafeBufferPointer { samples in
                accumulator.feed(interleaved: samples, frames: min(frames, count / channels), channels: channels, sampleRate: asbd.mSampleRate, start: start.isFinite ? start : nil)
            }
            if !reportedLeading, accumulator.hasHeardSound {
                reportedLeading = true
                onLeadingVerdict(accumulator.map(complete: false))
            }
        }
        if reader.status == .failed { throw reader.error ?? PlaybackSourceError.noAudioTrack }
        let map = accumulator.map(complete: true)
        if !reportedLeading { onLeadingVerdict(map) }
        return map
    }
}

/// Run-length encodes silent 10 ms windows into spans. Shared by the scanner and the tests.
struct SilenceAccumulator {
    let policy: SkipSilencePolicy
    private(set) var spans: [SilentSpan] = []
    private(set) var hasHeardSound = false
    private var runStart: TimeInterval?
    private var clock: TimeInterval = 0
    private var windowPeak: Float = 0
    private var windowFrames = 0
    private var sampleRate: Double = 44_100

    init(policy: SkipSilencePolicy) {
        self.policy = policy
    }

    mutating func feed(interleaved samples: UnsafeBufferPointer<Float>, frames: Int, channels: Int, sampleRate: Double, start: TimeInterval?) {
        guard sampleRate > 0, channels > 0, let base = samples.baseAddress else { return }
        let frames = min(frames, samples.count / channels)
        self.sampleRate = sampleRate
        if let start, abs(start - clock) > 0.05, windowFrames == 0 { clock = start }
        let windowLength = max(Int(sampleRate / 100), 1)
        var frame = 0
        while frame < frames {
            // One window (or what is left of it) at a time, each channel's peak taken with vDSP:
            // a whole track is scanned before it plays, and a per-sample loop made that take longer
            // than the silent intro it was meant to skip.
            let take = min(windowLength - windowFrames, frames - frame)
            for channel in 0..<channels {
                var peak: Float = 0
                vDSP_maxmgv(base + frame * channels + channel, vDSP_Stride(channels), &peak, vDSP_Length(take))
                if peak > windowPeak { windowPeak = peak }
            }
            windowFrames += take
            frame += take
            if windowFrames == windowLength {
                closeWindow(length: Double(windowFrames) / sampleRate)
            }
        }
    }

    private mutating func closeWindow(length: TimeInterval) {
        let silent = windowPeak < policy.thresholdLevel
        if silent {
            if runStart == nil { runStart = clock }
        } else {
            hasHeardSound = true
            closeRun(at: clock)
        }
        clock += length
        windowPeak = 0
        windowFrames = 0
    }

    private mutating func closeRun(at end: TimeInterval) {
        guard let start = runStart else { return }
        runStart = nil
        if end - start >= policy.minimumSilence { spans.append(SilentSpan(start: start, end: end)) }
    }

    func map(complete: Bool) -> SilenceMap {
        var copy = self
        if complete {
            if copy.windowFrames > 0 { copy.closeWindow(length: Double(copy.windowFrames) / copy.sampleRate) }
            copy.closeRun(at: copy.clock)
        }
        return SilenceMap(spans: copy.spans, duration: complete ? copy.clock : nil, isComplete: complete)
    }
}

/// The tap's silence-detector hook: tracks the silent run the render thread is in right now, in the
/// item's own timeline.
///
/// This is what skip silence falls back on when a track can't be scanned ahead (a stream
/// `AVAssetReader` can't open). The tap renders only a few hundredths of a second ahead of what is
/// heard, so it can't say where a gap ends in time to seek there. Instead, once the run has lasted
/// the policy's minimum, the engine fast-forwards the deck through it (``beginSkipping()``) — the
/// iOS stand-in for Media3 dropping silent frames — and the detector mutes everything it passes
/// while skipping. The first sound it meets is recorded (``resumePoint``) and muted too; the engine
/// then drops back to normal speed and seeks to just before it, so the overshoot is never heard.
/// Written from the render thread, read by the engine's position tick.
final class LiveSilenceDetector: @unchecked Sendable {
    private let threshold: Float
    private var lock = os_unfair_lock()
    private var runStart: TimeInterval?
    private var runEnd: TimeInterval = 0
    private var lastSoundEnd: TimeInterval?
    private var skipping = false
    private var resumeAt: TimeInterval?

    init(threshold: Float) {
        self.threshold = threshold
    }

    /// The silent run the tap is currently inside, if any.
    var ongoingRun: SilentSpan? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let start = runStart else { return nil }
        return SilentSpan(start: start, end: runEnd)
    }

    /// Where the tap last heard sound, if it has.
    var lastSound: TimeInterval? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return lastSoundEnd
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        runStart = nil
        runEnd = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Main actor. The deck is fast-forwarding through the run: mute from here on, and note where
    /// sound comes back.
    func beginSkipping() {
        os_unfair_lock_lock(&lock)
        skipping = true
        resumeAt = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Main actor. Back to normal playback.
    func endSkipping() {
        os_unfair_lock_lock(&lock)
        skipping = false
        resumeAt = nil
        runStart = nil
        runEnd = 0
        os_unfair_lock_unlock(&lock)
    }

    var isSkipping: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return skipping
    }

    /// Where sound came back while skipping, in item time; nil until it has.
    var resumePoint: TimeInterval? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return resumeAt
    }

    /// `sourceEnd` defaults to the frames' length at 1×; the tap passes the buffer's real source
    /// span, which differs at other speeds.
    func feed(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, format: AudioTapFormat, sourceStart: TimeInterval, sourceEnd: TimeInterval? = nil) {
        let peak = Self.peak(buffers, frameCount: frameCount, format: format)
        let end = sourceEnd ?? sourceStart + Double(frameCount) / max(format.sampleRate, 1)
        os_unfair_lock_lock(&lock)
        if peak < threshold {
            // A seek to before the run, or well past it, restarts the run where the new audio
            // begins. Landing inside what was already heard as silent continues it: that is where
            // the engine's own jump lands (the time-pitch stage re-renders ~0.2 s of look-back
            // before the target), and restarting there would make every jump wait out the minimum
            // gap again.
            if let start = runStart, sourceStart >= start - 0.05, sourceStart <= runEnd + 0.25 {
                runEnd = max(runEnd, end)
            } else {
                runStart = sourceStart
                runEnd = end
            }
        } else {
            if skipping, resumeAt == nil {
                // At 8× one buffer spans most of a second of the track: place the onset inside it
                // rather than at its start, or the return lands well before the music.
                let fraction = Double(Self.firstLoudFrame(buffers, frameCount: frameCount, format: format, threshold: threshold)) / Double(max(frameCount, 1))
                resumeAt = sourceStart + fraction * (end - sourceStart)
            }
            if !skipping {
                runStart = nil
                lastSoundEnd = end
            }
        }
        let mute = skipping
        os_unfair_lock_unlock(&lock)
        if mute { Self.silence(buffers, frameCount: frameCount, format: format) }
    }

    /// The first frame at or above `threshold` in any channel; 0 when the format isn't readable.
    private static func firstLoudFrame(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, format: AudioTapFormat, threshold: Float) -> Int {
        guard format.isFloat, format.bitsPerChannel == 32 else { return 0 }
        var first = frameCount
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let stride = Int(max(buffer.mNumberChannels, 1))
            let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frameCount * stride)
            let samples = data.assumingMemoryBound(to: Float.self)
            var index = 0
            while index < min(count, first * stride) {
                if abs(samples[index]) >= threshold {
                    first = min(first, index / stride)
                    break
                }
                index += 1
            }
        }
        return first == frameCount ? 0 : first
    }

    /// Zeroes what the tap hands on, while fast-forwarding.
    private static func silence(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, format: AudioTapFormat) {
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    static func peak(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, format: AudioTapFormat) -> Float {
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samplesPerFrame = Int(max(buffer.mNumberChannels, 1))
            if format.isFloat, format.bitsPerChannel == 32 {
                let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, frameCount * samplesPerFrame)
                guard count > 0 else { continue }
                var bufferPeak: Float = 0
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &bufferPeak, vDSP_Length(count))
                peak = max(peak, bufferPeak)
            } else if !format.isFloat, format.bitsPerChannel == 16 {
                let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size, frameCount * samplesPerFrame)
                let samples = data.assumingMemoryBound(to: Int16.self)
                for index in 0..<count {
                    let value = abs(Float(samples[index]) / 32_768)
                    if value > peak { peak = value }
                }
            } else {
                // A format nothing here reads: report it as sound, so nothing is ever skipped for it.
                return 1
            }
        }
        return peak
    }
}
