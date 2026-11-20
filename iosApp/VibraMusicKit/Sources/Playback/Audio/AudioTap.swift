import AVFoundation
import MediaToolbox
import os

/// One deck's processor, shared by every tap on that deck, with the bookkeeping that serialises
/// preparation onto the render thread.
///
/// AVFoundation prepares a queued item's tap while the current item is still rendering (that is how
/// the gapless advance is seamless), so a processor prepared from the tap's own prepare callback
/// would be re-initialised under the item still playing. Instead each tap prepares the processor
/// from its first process call, when it is the one rendering.
final class DeckProcessorBinding: @unchecked Sendable {
    let processor: PlaybackAudioProcessor?
    private var lock = os_unfair_lock()
    private var owner: ObjectIdentifier?
    private var ownerFormat: AudioTapFormat?

    init(processor: PlaybackAudioProcessor?) {
        self.processor = processor
    }

    /// Returns true when `context` has just taken the processor over (so it must prepare and begin).
    func claim(by context: TapContext, format: AudioTapFormat) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let id = ObjectIdentifier(context)
        if owner == id, ownerFormat == format { return false }
        owner = id
        ownerFormat = format
        return true
    }

    func release(by context: TapContext) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard owner == ObjectIdentifier(context) else { return false }
        owner = nil
        ownerFormat = nil
        return true
    }
}

/// Everything one item's tap needs, retained by the tap for its lifetime.
final class TapContext: @unchecked Sendable {
    let item: PlayableItem
    let loudnessDb: Double?
    let binding: DeckProcessorBinding
    let silence: LiveSilenceDetector

    private var lock = os_unfair_lock()
    private var format: AudioTapFormat?
    private var maximumFrames = 0
    private var framesProcessed = 0
    private var nextStart: Double?

    init(item: PlayableItem, loudnessDb: Double?, binding: DeckProcessorBinding, silence: LiveSilenceDetector) {
        self.item = item
        self.loudnessDb = loudnessDb
        self.binding = binding
        self.silence = silence
    }

    /// Frames that have passed through this tap, for tests and diagnostics.
    var processedFrameCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return framesProcessed
    }

    var currentFormat: AudioTapFormat? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return format
    }

    fileprivate func prepare(maxFrames: Int, asbd: AudioStreamBasicDescription) {
        os_unfair_lock_lock(&lock)
        format = AudioTapFormat(asbd)
        maximumFrames = maxFrames
        nextStart = nil
        os_unfair_lock_unlock(&lock)
    }

    fileprivate func unprepare() {
        if binding.release(by: self) { binding.processor?.reset() }
    }

    fileprivate func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, range: CMTimeRange, endOfStream: Bool) {
        guard frames > 0 else { return }
        os_unfair_lock_lock(&lock)
        let format = self.format
        let maxFrames = maximumFrames
        // The first buffers after a prepare or a seek can carry an invalid range; carry the clock
        // on from the previous buffer rather than dropping the measurement.
        let start: Double
        // A start more than a second before the item's beginning is not a place in the item: the
        // first buffers of a deck primed with `preroll(atRate:)` have been seen to carry times
        // hundreds of seconds negative. Treated like a missing time.
        let reported = range.start.isValid && range.start.isNumeric && range.start.seconds.isFinite && range.start.seconds > -1
        if reported {
            start = range.start.seconds
        } else {
            start = nextStart ?? 0
        }
        // The source time this buffer covers: the range's own duration when it has one, since at a
        // speed other than 1× the frames are output frames and span `frames × rate` of the item.
        let sampleRate = format?.sampleRate ?? 44_100
        let span: Double
        if reported, range.duration.isValid, range.duration.isNumeric, range.duration.seconds > 0 {
            span = range.duration.seconds
        } else {
            span = Double(frames) / sampleRate
        }
        nextStart = start + span
        framesProcessed += frames
        os_unfair_lock_unlock(&lock)

        guard let format else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        if format.isFloat, let processor = binding.processor {
            if binding.claim(by: self, format: format) {
                processor.prepare(format: format, maximumFrames: max(maxFrames, frames))
                processor.beginItem(item, loudnessDb: loudnessDb)
            }
            let timing = AudioTapTiming(
                sourceFramePosition: reported ? Int64((start * format.sampleRate).rounded()) : nil,
                isEndOfStream: endOfStream
            )
            processor.process(buffers, frameCount: frames, format: format, timing: timing)
        }
        silence.feed(buffers, frameCount: frames, format: format, sourceStart: start, sourceEnd: start + span)
    }
}

enum AudioTap {
    /// A tap calling into `context`, or nil if the system refused one — playback then simply runs
    /// unprocessed.
    ///
    /// Post-effects, like AudioDSP's own tap. The engine puts no volume ramps on the audio mix (a
    /// crossfade moves `AVPlayer.volume`, which applies after any tap, so the processor and the
    /// silence detector always see the track at full level), so the placement changes nothing
    /// audible — but measured on a Mac, a pre-effects tap delays the moment a started player is
    /// heard by about 0.45 s against 0.25 s for a post-effects one, and that delay is exactly what a
    /// crossfade has to start early to hide.
    static func make(context: TapContext) -> MTAudioProcessingTap? {
        let retained = Unmanaged.passRetained(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap = tap?.takeRetainedValue() else {
            retained.release()
            return nil
        }
        return tap
    }

    /// An audio mix carrying a tap on `track`.
    static func audioMix(for track: AVAssetTrack, context: TapContext) -> AVAudioMix? {
        guard let tap = make(context: context) else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

private func context(of tap: MTAudioProcessingTap) -> TapContext {
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    context(of: tap).prepare(maxFrames: Int(maxFrames), asbd: format.pointee)
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    context(of: tap).unprepare()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferList, framesOut, flagsOut in
    var range = CMTimeRange.invalid
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, &range, framesOut)
    guard status == noErr else {
        framesOut.pointee = 0
        return
    }
    let endOfStream = flagsOut.pointee & kMTAudioProcessingTapFlag_EndOfStream != 0
    context(of: tap).process(bufferList, frames: Int(framesOut.pointee), range: range, endOfStream: endOfStream)
}
