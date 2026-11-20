import AudioDSP
import AVFoundation

/// The two players the engine plays through. Each has its own audio processor, because the DSP
/// chain carries per-stream state (filter memory, a delay line) that two simultaneous streams
/// cannot share — during a crossfade both decks render at once.
public enum PlaybackDeckID: String, Hashable, Sendable, CaseIterable {
    case a
    case b
}

/// The PCM format a tap delivers. On Apple platforms this is almost always 32-bit float,
/// non-interleaved (one buffer per channel).
public struct AudioTapFormat: Hashable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var isFloat: Bool
    public var isNonInterleaved: Bool
    public var bitsPerChannel: Int

    public init(sampleRate: Double, channelCount: Int, isFloat: Bool = true, isNonInterleaved: Bool = true, bitsPerChannel: Int = 32) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isFloat = isFloat
        self.isNonInterleaved = isNonInterleaved
        self.bitsPerChannel = bitsPerChannel
    }

    init(_ asbd: AudioStreamBasicDescription) {
        self.init(
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            isFloat: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            isNonInterleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
            bitsPerChannel: Int(asbd.mBitsPerChannel)
        )
    }

    /// The measured PCM layout — "Float32 non-interleaved" — what the DSP stage's PCM Format row
    /// prints once a tap has reported it. Always carries the layout, so it is never mistaken for the
    /// "Float32" placeholder a tap-less item used to show. A description without a width (some
    /// linear-PCM descriptions carry it in the format flags) prints no width rather than a made-up
    /// one.
    public var pcmDescription: String {
        let layout = isNonInterleaved ? "non-interleaved" : "interleaved"
        guard bitsPerChannel > 0 else { return "\(isFloat ? "Float" : "Int") \(layout)" }
        return isFloat ? "Float\(bitsPerChannel) \(layout)" : "Int\(bitsPerChannel) \(layout)"
    }

    /// The tap's full measured format — "44100 Hz · 2 ch · Float32 non-interleaved" — what the
    /// Decoder stage's Format row shows as the decoder's output.
    public var measurementDescription: String {
        "\(Int(sampleRate.rounded())) Hz · \(channelCount) ch · \(pcmDescription)"
    }
}

/// Where one buffer sits in its item's own timeline, as the tap reports it.
public struct AudioTapTiming: Hashable, Sendable {
    /// The buffer's first frame, counted in frames at the tap's sample rate from the start of the
    /// item. Nil when AVFoundation gave no usable time (the first buffers after a prepare can lack
    /// one). A jump in it is a seek — what a silence detector needs to keep its runs in item time.
    ///
    /// Two measured quirks of a post-effects tap behind the time-pitch stage: the first buffers after
    /// a seek start about 0.19 s *before* the seek target (the stage's look-back), and at a speed
    /// other than 1× each buffer's frame count is output frames while this position is source time,
    /// so consecutive positions advance by `frameCount × rate`.
    public var sourceFramePosition: Int64?
    /// The item's audio ends with this buffer.
    public var isEndOfStream: Bool

    public init(sourceFramePosition: Int64? = nil, isEndOfStream: Bool = false) {
        self.sourceFramePosition = sourceFramePosition
        self.isEndOfStream = isEndOfStream
    }
}

/// Real-time processing the app plugs into every item the engine plays: the AudioDSP chain (EQ,
/// stereo widening, loudness-normalization gain, the transition filter).
///
/// The engine attaches an `MTAudioProcessingTap` to each `AVPlayerItem`'s audio mix and calls the
/// processor of the deck that item plays on. Calls from the tap arrive on the audio render thread:
/// never block, allocate or take a contended lock in ``prepare(format:maximumFrames:)``,
/// ``beginItem(_:loudnessDb:)`` or ``process(_:frameCount:format:timing:)``. The engine serialises them —
/// all three come from the render thread of the item currently rendering on that deck, and a new
/// item's ``prepare(format:maximumFrames:)`` and ``beginItem(_:loudnessDb:)`` arrive just before its
/// first ``process(_:frameCount:format:timing:)``, so gain keyed to the item is right from its first frame
/// (the reason the Android controller announced the incoming track before the standby rendered).
public protocol PlaybackAudioProcessor: AnyObject, Sendable {
    /// Render thread. The format or the stream changed; size buffers and reset state here.
    func prepare(format: AudioTapFormat, maximumFrames: Int)
    /// Render thread. The item whose audio follows. `loudnessDb` is YouTube's normalization figure
    /// (the resolved stream's, else the item's), nil when unknown.
    func beginItem(_ item: PlayableItem, loudnessDb: Double?)
    /// Render thread. Process `frameCount` frames in place. Only called for float formats.
    /// `timing` places the buffer in the item's timeline (AudioDSP's
    /// `DSPChain.process(bufferList:frameCount:sourceFramePosition:)` takes it as is, and wants
    /// `finish()` at the end of the stream).
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, format: AudioTapFormat, timing: AudioTapTiming)
    /// Main actor. Where this deck's transition filter should head; glide there rather than jump
    /// (a 24 dB/octave filter appearing in one buffer clicks). ``TransitionFilterCutoffs/open`` parks it.
    func setTransitionFilter(_ cutoffs: TransitionFilterCutoffs)
    /// Render thread. The item stopped rendering on this deck.
    func reset()
    /// Main actor. Whether the chain would change `item`'s samples at all as things stand: EQ,
    /// widening, a normalization gain other than 0 dB, or a transition filter an Automix plan may
    /// ride. Asked when an item is built and again after
    /// ``AudioPlayerEngine/audioProcessingDidChange()``. A lossless item the chain would leave alone
    /// plays with no tap at all, so the pipeline can honestly report it bit-transparent. The default
    /// is true: when in doubt, process.
    func altersSignal(for item: PlayableItem, loudnessDb: Double?) -> Bool
    /// Main actor. The loudness normalization readout for `item` — the gain being applied and the
    /// figure it came from — or nil when normalization is off or no figure is known. The pipeline
    /// sheet's Gain and Measured rows read it through the output status; nil keeps them at "Off"/"—".
    func loudnessReadout(for item: PlayableItem, loudnessDb: Double?) -> LoudnessReadout?
}

extension PlaybackAudioProcessor {
    public func altersSignal(for item: PlayableItem, loudnessDb: Double?) -> Bool { true }
    public func beginItem(_ item: PlayableItem, loudnessDb: Double?) {}
    public func setTransitionFilter(_ cutoffs: TransitionFilterCutoffs) {}
    public func reset() {}
    public func loudnessReadout(for item: PlayableItem, loudnessDb: Double?) -> LoudnessReadout? { nil }
}

/// Makes the processor for a deck. Called twice, once per deck, when the engine is created.
public typealias PlaybackAudioProcessorFactory = @MainActor (PlaybackDeckID) -> PlaybackAudioProcessor?

/// What stands between an item's decoded audio and the output.
public enum PlaybackSignalPath: Hashable, Sendable {
    /// Through the processing tap: the app's DSP chain and the silence detector.
    case processed
    /// A lossless item the DSP chain would not touch, played with no tap: the samples reach the
    /// output as decoded (bar the listener's volume and a speed other than 1×).
    case bitTransparent
    /// Dolby Atmos (E-AC-3 JOC), played with no tap and multichannel spatialization allowed. A tap
    /// sees the object mix already rendered down to PCM, which would defeat spatial rendering.
    case spatialPassthrough
    /// The system refused a tap; playing unprocessed.
    case unprocessed

    /// Whether the app's DSP chain is in the path.
    public var isProcessed: Bool { self == .processed }
}
