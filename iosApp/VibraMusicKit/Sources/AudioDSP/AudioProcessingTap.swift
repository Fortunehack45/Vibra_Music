import CoreMedia
import MediaToolbox

/// Where the tap sits relative to an `AVAudioMix`'s own effects (volume ramps).
public enum DSPTapPlacement: Sendable {
    /// After the mix's volume: what Android does, where the player's volume is
    /// applied before the session's `LoudnessEnhancer` sees the signal.
    case postEffects
    /// Before the mix's volume.
    case preEffects
}

public enum DSPTapError: Error, Equatable {
    case creationFailed(OSStatus)
}

extension DSPChain {
    /// An `MTAudioProcessingTap` that runs this chain over a player item's audio.
    ///
    /// Attach it with `AVMutableAudioMixInputParameters(track:)` and its
    /// `audioTapProcessor`, then set the mix as the item's `audioMix` (it works
    /// the same on an `AVAssetReaderAudioMixOutput`). The tap keeps the chain
    /// alive until the tap is released.
    ///
    /// The tap configures the chain in its prepare callback when the processing
    /// format is Float32 PCM (what `AVPlayer` uses), resets it in unprepare,
    /// and passes each callback's source time to the silence detector so spans
    /// come out in item time. Any other processing format leaves the audio
    /// untouched.
    ///
    /// One chain per player item: the chain holds that item's filter state and
    /// silence run, so a chain must back at most one prepared tap at a time.
    /// For a crossfade, give each player's item its own chain (Android kept a
    /// separate processor set per player for the same reason).
    ///
    /// Seeks need nothing from the caller: a block that doesn't follow on from
    /// the previous one flushes the filters (see `process(_:sourceFramePosition:)`).
    /// When skipping silence live, seek with tight tolerances: the detector
    /// only treats a landing within 50 ms of what `expectSeek(toFrame:)`
    /// announced as the same silence, and AVPlayer's default tolerance can be wider.
    public func makeAudioProcessingTap(placement: DSPTapPlacement = .postEffects) throws -> MTAudioProcessingTap {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: dspTapInit,
            finalize: dspTapFinalize,
            prepare: dspTapPrepare,
            unprepare: dspTapUnprepare,
            process: dspTapProcess
        )
        var tap: MTAudioProcessingTap?
        let flags: MTAudioProcessingTapCreationFlags = placement == .postEffects
            ? kMTAudioProcessingTapCreationFlag_PostEffects
            : kMTAudioProcessingTapCreationFlag_PreEffects
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, flags, &tap)
        guard status == noErr, let tap else {
            Unmanaged<DSPChain>.fromOpaque(callbacks.clientInfo!).release()
            throw DSPTapError.creationFailed(status)
        }
        return tap
    }
}

private func dspChain(_ tap: MTAudioProcessingTap) -> Unmanaged<DSPChain> {
    Unmanaged<DSPChain>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
}

private let dspTapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let dspTapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    dspChain(tap).release()
}

private let dspTapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, processingFormat in
    let description = processingFormat.pointee
    let isFloat32 = description.mFormatID == kAudioFormatLinearPCM &&
        description.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        description.mBitsPerChannel == 32
    dspChain(tap)._withUnsafeGuaranteedRef { chain in
        if isFloat32 && description.mChannelsPerFrame > 0 {
            chain.configure(sampleRate: description.mSampleRate, channelCount: Int(description.mChannelsPerFrame))
        } else {
            chain.reset()
        }
    }
}

private let dspTapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    dspChain(tap)._withUnsafeGuaranteedRef { $0.reset() }
}

private let dspTapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    var timeRange = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
    guard status == noErr else {
        numberFramesOut.pointee = 0
        return
    }
    dspChain(tap)._withUnsafeGuaranteedRef { chain in
        let sampleRate = chain.format.pointee.sampleRate
        guard sampleRate > 0 else { return }
        var position: Int64?
        if timeRange.start.isValid && timeRange.start.isNumeric {
            position = Int64((timeRange.start.seconds * sampleRate).rounded())
        }
        chain.process(bufferList: bufferListInOut, frameCount: Int(numberFramesOut.pointee), sourceFramePosition: position)
        if flagsOut.pointee & kMTAudioProcessingTapFlag_EndOfStream != 0 {
            chain.finish()
        }
    }
}
