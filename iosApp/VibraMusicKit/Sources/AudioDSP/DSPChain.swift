import CoreAudio
import os

/// Vibra Music's audio processors in their canonical order, run in place on Float32 PCM:
///
///     spatial widening → equaliser → transition filter → [silence detection] → loudness normalization
///
/// Transition filtering comes last of the three filters: widening is a property
/// of the track, and a bass swap that ran before it would have its own low end
/// fed back in by the cross-feed — or by whatever the listener's low band was
/// set to. The equaliser sits between them for the same reason: it belongs to
/// the listener and the whole session, while the transition filter belongs to
/// one handoff and has to have the last word on it.
///
/// Silence detection sees the filtered signal and loudness normalization runs
/// after everything, matching where Android's Media3 silence skipper (in the
/// sink, after the DSP chain) and `LoudnessEnhancer` (a session effect, after
/// the sink) sit.
///
/// ## Staying out of the way
///
/// Every stage self-bypasses when its setting is off, returning before it
/// reads a sample rather than multiplying through by unity. With every stage
/// idle the audio leaves this chain bit-identical to how it arrived.
///
/// ## Use from a processing tap
///
/// `configure` from the tap's prepare callback, `process(bufferList:...)` from
/// its process callback, `reset` from unprepare — or let
/// `makeAudioProcessingTap()` do that wiring. Settings (`apply`, and each
/// stage's own setters) are safe from any thread at any time.
public final class DSPChain: FloatAudioProcessor, @unchecked Sendable {
    public let spatial: SpatialAudioProcessor
    public let equalizer: EqualizerProcessor
    public let transition: TransitionFilterProcessor
    public let silenceDetector: SilenceDetector
    public let loudness: LoudnessNormalizer

    struct Format {
        var sampleRate: Double = 0
        var channelCount = 0
        /// Where the next block should start in the item's timeline, or -1
        /// while unknown. A block that starts elsewhere follows a seek.
        var nextSourceFrame: Int64 = -1
    }

    /// How far a block may start from where the last one ended and still count
    /// as continuous: rounding a source time to a frame can land one off.
    static let continuityToleranceFrames: Int64 = 2

    /// Read by the tap's callbacks, which run on the audio side.
    let format: UnsafeMutablePointer<Format>

    /// The same, for any other thread: sample rate and channel count as two floats.
    private let formatWord = AtomicWord(0)

    private static let log = Logger(subsystem: "com.fortune.vibramusic.ios", category: "AudioDSP")

    public init(spatial: SpatialAudioProcessor = SpatialAudioProcessor(),
                equalizer: EqualizerProcessor = EqualizerProcessor(),
                transition: TransitionFilterProcessor = TransitionFilterProcessor(),
                silenceDetector: SilenceDetector = SilenceDetector(),
                loudness: LoudnessNormalizer = LoudnessNormalizer()) {
        self.spatial = spatial
        self.equalizer = equalizer
        self.transition = transition
        self.silenceDetector = silenceDetector
        self.loudness = loudness
        format = .allocate(capacity: 1)
        format.initialize(to: Format())
    }

    deinit {
        format.deallocate()
    }

    // ---- Settings ----------------------------------------------------------

    /// Pushes every listener setting onto the chain. Safe from any thread.
    public func apply(_ settings: AudioDSPSettings) {
        equalizer.apply(settings.equalizer)
        spatial.isEnabled = settings.spatialAudio
        loudness.setEnabled(settings.loudnessNormalization)
        silenceDetector.isEnabled = settings.skipSilence
    }

    /// Which stages are changing samples right now, for the audio pipeline
    /// readout ("with EQ on, the dialog shows the signal as altered").
    public var signalAlteration: SignalAlteration {
        SignalAlteration(loudnessActive: loudness.isActive,
                         equalizerActive: equalizer.isEnabled,
                         spatialAudioActive: spatial.isEnabled,
                         transitionFilterActive: transition.isFiltering)
    }

    /// The format the chain was last configured for, or nil.
    public var configuredFormat: (sampleRate: Double, channelCount: Int)? {
        let (sampleRate, channelCount) = FloatPair.unpack(formatWord.load())
        return channelCount > 0 ? (Double(sampleRate), Int(channelCount)) : nil
    }

    // ---- Audio -------------------------------------------------------------

    public func configure(sampleRate: Double, channelCount: Int) {
        format.pointee = Format(sampleRate: sampleRate, channelCount: channelCount, nextSourceFrame: -1)
        formatWord.store(FloatPair.pack(Float(sampleRate), Float(max(channelCount, 0))))
        spatial.configure(sampleRate: sampleRate, channelCount: channelCount)
        equalizer.configure(sampleRate: sampleRate, channelCount: channelCount)
        transition.configure(sampleRate: sampleRate, channelCount: channelCount)
        silenceDetector.configure(sampleRate: sampleRate, channelCount: channelCount)
        loudness.configure(sampleRate: sampleRate, channelCount: channelCount)
        if channelCount != 2 {
            Self.log.info("DSP configured for \(channelCount) channel(s) at \(sampleRate) Hz; spatial widening needs stereo and stays off")
        }
    }

    public func process(_ channels: DSPChannels) {
        process(channels, sourceFramePosition: nil)
    }

    /// Runs every stage over [channels]. [sourceFramePosition] is the first
    /// frame's position in the item's timeline, when known; the silence
    /// detector uses it to report spans in item time and to notice seeks.
    ///
    /// A block that doesn't start where the previous one ended follows a seek,
    /// and the filters are flushed before it, as Media3 flushes every audio
    /// processor on a seek: otherwise the cross-feed's delay line and the
    /// filters' integrators would carry audio from before the jump into the
    /// first milliseconds after it. The silence detector and loudness stage
    /// handle the jump themselves (Android's `LoudnessEnhancer` is a session
    /// effect and is never flushed).
    public func process(_ channels: DSPChannels, sourceFramePosition: Int64?) {
        guard channels.frameCount > 0 else { return }
        let expected = format.pointee.nextSourceFrame
        if let position = sourceFramePosition {
            if expected >= 0 && abs(position - expected) > Self.continuityToleranceFrames {
                spatial.flush()
                equalizer.flush()
                transition.flush()
            }
            format.pointee.nextSourceFrame = position + Int64(channels.frameCount)
        } else if expected >= 0 {
            format.pointee.nextSourceFrame = expected + Int64(channels.frameCount)
        }
        spatial.process(channels)
        equalizer.process(channels)
        transition.process(channels)
        silenceDetector.process(channels, sourceFramePosition: sourceFramePosition)
        loudness.process(channels)
    }

    /// Runs the chain over Float32 samples in an `AudioBufferList` — what an
    /// `MTAudioProcessingTap` delivers. Returns false, leaving the audio
    /// untouched, when the layout isn't one `DSPChannels` understands.
    @discardableResult
    public func process(bufferList: UnsafeMutablePointer<AudioBufferList>,
                        frameCount: Int,
                        sourceFramePosition: Int64? = nil) -> Bool {
        guard let channels = DSPChannels(bufferList: bufferList, frameCount: frameCount) else { return false }
        process(channels, sourceFramePosition: sourceFramePosition)
        return true
    }

    /// Runs the chain over interleaved Float32 samples.
    public func process(interleaved samples: UnsafeMutablePointer<Float>,
                        frameCount: Int,
                        channelCount: Int,
                        sourceFramePosition: Int64? = nil) {
        process(DSPChannels(interleaved: samples, channelCount: channelCount, frameCount: frameCount),
                sourceFramePosition: sourceFramePosition)
    }

    /// End of the item's audio: closes a run-out silence.
    public func finish() {
        silenceDetector.finish()
    }

    public func flush() {
        spatial.flush()
        equalizer.flush()
        transition.flush()
        silenceDetector.flush()
        loudness.flush()
    }

    public func reset() {
        format.pointee = Format()
        formatWord.store(0)
        spatial.reset()
        equalizer.reset()
        transition.reset()
        silenceDetector.reset()
        loudness.reset()
    }
}

/// The listener settings the chain renders — Android's `AppSettings` fields
/// for the equaliser, spatial audio, loudness normalization and skip silence,
/// with Android's defaults.
public struct AudioDSPSettings: Equatable, Sendable {
    public var equalizer: EqualizerSettings

    /// The effective spatial-audio state. Android forces it off while the
    /// active track is Dolby Atmos; that decision belongs to whoever builds this.
    public var spatialAudio: Bool

    /// On by default, as on Android.
    public var loudnessNormalization: Bool

    public var skipSilence: Bool

    public init(equalizer: EqualizerSettings = EqualizerSettings(),
                spatialAudio: Bool = false,
                loudnessNormalization: Bool = true,
                skipSilence: Bool = false) {
        self.equalizer = equalizer
        self.spatialAudio = spatialAudio
        self.loudnessNormalization = loudnessNormalization
        self.skipSilence = skipSilence
    }
}

/// A stage that changes samples when it runs.
public enum DSPStage: String, CaseIterable, Sendable {
    case loudnessNormalization
    case equalizer
    case spatialAudio
    case transitionFilter
}

/// Whether decoded samples reach the output unaltered, and what is altering
/// them when they aren't — the verdict row of the audio pipeline readout.
///
/// Every stage is a filter or a gain, and none of them can run and leave the
/// output bit-exact. Stages are listed in the order Android's readout names
/// them — loudness normalization, then the equaliser, then spatial audio — so
/// `primaryStage` is the one the readout should name, which is also the first
/// thing a listener chasing an untouched signal would switch off. The
/// transition filter, which Android's readout doesn't mention because it only
/// runs for the length of an Automix blend, comes last.
public struct SignalAlteration: Equatable, Sendable {
    public let alteringStages: [DSPStage]

    public init(loudnessActive: Bool,
                equalizerActive: Bool,
                spatialAudioActive: Bool,
                transitionFilterActive: Bool = false) {
        var stages: [DSPStage] = []
        if loudnessActive { stages.append(.loudnessNormalization) }
        if equalizerActive { stages.append(.equalizer) }
        if spatialAudioActive { stages.append(.spatialAudio) }
        if transitionFilterActive { stages.append(.transitionFilter) }
        alteringStages = stages
    }

    /// The readout's verdict from settings alone, for a screen that has the
    /// settings but not the chain: loudness counts only once a gain is known.
    public init(settings: AudioDSPSettings, loudness: LoudnessReadout) {
        self.init(loudnessActive: settings.loudnessNormalization && loudness.isActive,
                  equalizerActive: settings.equalizer.isEnabled,
                  spatialAudioActive: settings.spatialAudio)
    }

    public var isAltered: Bool { !alteringStages.isEmpty }

    /// The stage the readout names.
    public var primaryStage: DSPStage? { alteringStages.first }
}
