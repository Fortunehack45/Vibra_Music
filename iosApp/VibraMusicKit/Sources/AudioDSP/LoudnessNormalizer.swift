import Foundation
import os

/// What the audio pipeline readout shows for loudness normalization.
///
/// The two values Android publishes through `AudioOutputStatus.publishLoudness`:
/// both nil whenever the setting is off or the track's figure isn't known yet.
public struct LoudnessReadout: Equatable, Sendable {
    /// The gain being applied, in decibels (whole millibels / 100).
    public let gainDb: Float?

    /// YouTube's own loudness figure for the track, shown as "measured".
    public let loudnessDb: Float?

    public init(gainDb: Float?, loudnessDb: Float?) {
        self.gainDb = gainDb
        self.loudnessDb = loudnessDb
    }

    public static let inactive = LoudnessReadout(gainDb: nil, loudnessDb: nil)

    /// Whether normalization is altering samples.
    public var isActive: Bool { gainDb != nil }
}

/// Levels every track to the same loudness using YouTube's own normalization
/// figure for it (`playerConfig.audioConfig.loudnessDb`, resolved alongside the
/// stream).
///
/// ## What Android does, and what this ports
///
/// `PlaybackService.setupLoudnessEnhancer` turns the figure into a target gain
/// of `(-loudnessDb × 100).roundToInt()` millibels held to -1500...+300, and
/// hands it to the platform `LoudnessEnhancer` effect on the audio session —
/// or switches the effect off when the setting is off or no figure is known.
/// `gainMillibels(forLoudnessDb:)` is that computation exactly.
///
/// `LoudnessEnhancer` is more than a multiply. AOSP's implementation
/// (`EffectLoudnessEnhancer.cpp`, `dynamic_range_compression.cpp`) applies the
/// gain on the input of a feed-forward compressor — knee at -8 dBFS for every
/// gain Vibra Music can ask for, 7:1 ratio, 1 ms attack, 15 ms release, stereo
/// linked — and hard-limits at ±32767/32768. This stage ports that compressor
/// sample for sample, including its fast-log approximation, so a track lands
/// at the level it lands at on Android. The compressor is reset whenever a
/// gain is applied, as `setTargetGain` resets it there.
///
/// Android runs the effect on the whole session, after its per-player DSP; the
/// iOS chain runs it last for the same reason, but per player item, so during a
/// crossfade each side keeps its own track's gain rather than sharing one.
///
/// Mono and multichannel streams are linked across every channel, which is
/// what the stereo compressor does for two.
public final class LoudnessNormalizer: FloatAudioProcessor, @unchecked Sendable {

    /// Bounds on the target gain, in millibels (Android's `MIN/MAX_LOUDNESS_GAIN_MB`).
    public static let minGainMillibels = -1500
    public static let maxGainMillibels = 300

    /// How long to wait before looking a track's figure up once more, when it
    /// had not resolved yet at the start of the track (Android's `LOUDNESS_RETRY_MS`).
    ///
    /// Android retries once, and only if the figure is still missing and the
    /// track is still current, so it neither overwrites a value that already
    /// arrived nor reaches into a track the listener has since moved past. The
    /// substitute lookup that wins the race for a JioSaavn or add-on track is
    /// often quicker than the YouTube walk running alongside it.
    public static let retryDelay: TimeInterval = 6

    /// The target gain for a track whose YouTube loudness figure is [loudnessDb],
    /// in millibels: `(-loudnessDb × 100)` rounded as Kotlin's `roundToInt`
    /// rounds (ties toward +∞), held to `minGainMillibels...maxGainMillibels`.
    ///
    /// nil for NaN or infinite input, which Android would have thrown on.
    public static func gainMillibels(forLoudnessDb loudnessDb: Double) -> Int? {
        guard loudnessDb.isFinite else { return nil }
        // Pre-clamped only so an absurd figure can't overflow the rounding; any
        // value this far out lands on a bound either way.
        let scaled = min(max(-loudnessDb * 100.0, -1e9), 1e9)
        let rounded = JavaRounding.round(scaled)
        return Int(min(max(rounded, Int64(minGainMillibels)), Int64(maxGainMillibels)))
    }

    /// What the readout shows for this setting and figure — Android's
    /// `publishLoudness(gainDb = gainMb / 100f, lufs = loudnessDb)`.
    public static func readout(enabled: Bool, loudnessDb: Double?) -> LoudnessReadout {
        guard enabled, let loudnessDb, let millibels = gainMillibels(forLoudnessDb: loudnessDb) else {
            return .inactive
        }
        return LoudnessReadout(gainDb: Float(millibels) / 100, loudnessDb: Float(loudnessDb))
    }

    // ---- Settings side -----------------------------------------------------

    private struct Settings {
        var isEnabled = true
        var loudnessDb: Double?
        var generation: Int64 = 0
    }

    private let settings = OSAllocatedUnfairLock(initialState: Settings())

    /// Packed: bits 0...31 millibels, bit 32 active, bits 33... generation.
    private let published = AtomicWord(0)

    /// Android turns normalization on by default.
    public init() {
        render = .allocate(capacity: 1)
        render.initialize(to: RenderState())
    }

    deinit {
        render.deallocate()
    }

    /// The loudness normalization setting. Returns the new readout.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LoudnessReadout {
        update { $0.isEnabled = enabled }
    }

    /// The current track's YouTube loudness figure, or nil while it is unknown.
    /// Call it at every track change, as Android does, and again when a
    /// late-resolving figure arrives. Returns the new readout.
    @discardableResult
    public func setTrackLoudness(_ loudnessDb: Double?) -> LoudnessReadout {
        update { $0.loudnessDb = loudnessDb }
    }

    /// Both at once.
    @discardableResult
    public func apply(enabled: Bool, loudnessDb: Double?) -> LoudnessReadout {
        update {
            $0.isEnabled = enabled
            $0.loudnessDb = loudnessDb
        }
    }

    /// What the readout should show right now.
    public var readout: LoudnessReadout {
        settings.withLock { Self.readout(enabled: $0.isEnabled, loudnessDb: $0.loudnessDb) }
    }

    /// Whether normalization is altering samples: switched on, with a figure known.
    public var isActive: Bool {
        readout.isActive
    }

    private func update(_ change: @Sendable (inout Settings) -> Void) -> LoudnessReadout {
        settings.withLock { state in
            change(&state)
            state.generation += 1
            let readout = Self.readout(enabled: state.isEnabled, loudnessDb: state.loudnessDb)
            let millibels = state.loudnessDb.flatMap(Self.gainMillibels(forLoudnessDb:)) ?? 0
            let active: Int64 = readout.isActive ? 1 : 0
            let word = (state.generation & 0x3FFF_FFFF) << 33 | active << 32 |
                Int64(UInt32(bitPattern: Int32(millibels)))
            published.store(word)
            return readout
        }
    }

    // ---- Audio side --------------------------------------------------------

    private struct RenderState {
        var sampleRate: Float = 0
        var channelCount = 0
        var seenWord: Int64 = 0
        var isActive = false
        var inputAmplitude: Float = 1
        var compressor = LoudnessCompressor()
    }

    private let render: UnsafeMutablePointer<RenderState>

    public func configure(sampleRate: Double, channelCount: Int) {
        render.pointee.sampleRate = Float(sampleRate)
        render.pointee.channelCount = channelCount
        adopt(published.load())
    }

    public func process(_ channels: DSPChannels) {
        let rs = render
        let word = published.load()
        if word != rs.pointee.seenWord { adopt(word) }
        let frameCount = channels.frameCount
        let channelCount = channels.channelCount
        guard rs.pointee.isActive, frameCount > 0, rs.pointee.sampleRate > 0,
              channelCount == rs.pointee.channelCount else { return }

        let stride = channels.stride
        let inputAmplitude = rs.pointee.inputAmplitude
        let inverseScale = LoudnessCompressor.inverseScale
        var compressor = rs.pointee.compressor
        if channelCount == 2 {
            let left = channels.base(of: 0)
            let right = channels.base(of: 1)
            var frame = 0
            while frame < frameCount {
                let index = frame * stride
                let gain = compressor.gain(forPeak: max(abs(left[index] * inputAmplitude),
                                                        abs(right[index] * inputAmplitude)))
                left[index] = LoudnessCompressor.limit(left[index] * inputAmplitude * gain) * inverseScale
                right[index] = LoudnessCompressor.limit(right[index] * inputAmplitude * gain) * inverseScale
                frame += 1
            }
        } else {
            var frame = 0
            while frame < frameCount {
                let index = frame * stride
                var peak: Float = 0
                var channel = 0
                while channel < channelCount {
                    peak = max(peak, abs(channels.base(of: channel)[index] * inputAmplitude))
                    channel += 1
                }
                let gain = compressor.gain(forPeak: peak)
                channel = 0
                while channel < channelCount {
                    let base = channels.base(of: channel)
                    base[index] = LoudnessCompressor.limit(base[index] * inputAmplitude * gain) * inverseScale
                    channel += 1
                }
                frame += 1
            }
        }
        rs.pointee.compressor = compressor
    }

    /// The session effect Android uses is not flushed on a seek, so neither is this.
    public func flush() {}

    public func reset() {
        render.pointee.sampleRate = 0
        render.pointee.channelCount = 0
        render.pointee.isActive = false
        render.pointee.seenWord = 0
    }

    /// Takes a newly published setting: `LE_reset` on Android, which re-arms the
    /// compressor with the new target.
    private func adopt(_ word: Int64) {
        let rs = render
        rs.pointee.seenWord = word
        rs.pointee.isActive = (word >> 32) & 1 == 1
        let millibels = Int32(truncatingIfNeeded: word)
        // `pow(10, mB / 2000.0f)`: millibels to a linear amplitude.
        let targetAmplitude = Float(pow(10.0, Double(Float(millibels) / 2000)))
        rs.pointee.inputAmplitude = targetAmplitude * LoudnessCompressor.scale
        rs.pointee.compressor.initialize(targetGain: targetAmplitude, sampleRate: rs.pointee.sampleRate)
    }
}

/// AOSP's `le_fx::AdaptiveDynamicRangeCompression`, which is what Android's
/// `LoudnessEnhancer` runs its gained signal through. Works in 16-bit sample
/// units (full scale 32768) like the original, whose float build scales in and
/// out around it.
struct LoudnessCompressor {
    static let scale: Float = 32768
    static let inverseScale: Float = 1 / 32768
    static let minLogAbsValue: Float = 0.032767
    static let fixedPointLimit: Float = 32767
    static let compressionRatio: Float = 7
    static let tauAttack: Float = 0.001
    static let tauRelease: Float = 0.015

    var state: Float = 0
    var compressorGain: Float = 1
    var alphaAttack: Float = 0
    var alphaRelease: Float = 0
    var slope: Float = 1 / 7 - 1
    var kneeThreshold: Float = 0

    mutating func initialize(targetGain: Float, sampleRate: Float) {
        kneeThreshold = Self.kneeThreshold(decibels: Self.kneeDecibels(forTargetGain: targetGain))
        state = 0
        compressorGain = 1
        alphaAttack = sampleRate > 0 ? exp(-1 / (Self.tauAttack * sampleRate)) : 0
        alphaRelease = sampleRate > 0 ? exp(-1 / (Self.tauRelease * sampleRate)) : 0
        slope = 1 / Self.compressionRatio - 1
    }

    /// Advances the envelope by one frame whose loudest channel is [peak]
    /// (already gained, in 16-bit units) and returns the gain to apply to it.
    @inline(__always)
    mutating func gain(forPeak peak: Float) -> Float {
        let peakLog = Self.fastLog(max(peak, Self.minLogAbsValue))
        let overshoot = peakLog - kneeThreshold
        let controlVoltage = max(overshoot, 0) * slope
        let previous = state
        if controlVoltage <= state {
            state = alphaAttack * state + (1 - alphaAttack) * controlVoltage
        } else {
            state = alphaRelease * state + (1 - alphaRelease) * controlVoltage
        }
        compressorGain *= exp(state - previous)
        return compressorGain
    }

    @inline(__always)
    static func limit(_ value: Float) -> Float {
        min(max(value, -fixedPointLimit), fixedPointLimit)
    }

    /// Knee in dBFS, interpolated from the target gain the way
    /// `set_knee_threshold_via_target_gain` does, clamped at the table's ends.
    static func kneeDecibels(forTargetGain gain: Float) -> Float {
        let gains: (Float, Float, Float, Float, Float) = (1, 2, 3, 4, 5)
        let knees: (Float, Float, Float, Float, Float) = (-8, -8, -8.5, -9, -10)
        if gain <= gains.0 { return knees.0 }
        if gain <= gains.1 { return knees.0 + (knees.1 - knees.0) * (gain - gains.0) / (gains.1 - gains.0) }
        if gain <= gains.2 { return knees.1 + (knees.2 - knees.1) * (gain - gains.1) / (gains.2 - gains.1) }
        if gain <= gains.3 { return knees.2 + (knees.3 - knees.2) * (gain - gains.2) / (gains.3 - gains.2) }
        if gain <= gains.4 { return knees.3 + (knees.4 - knees.3) * (gain - gains.3) / (gains.4 - gains.3) }
        return knees.4
    }

    /// The knee in natural-log units of a 16-bit amplitude: ln(10)/20 × dB + ln(32767).
    static func kneeThreshold(decibels: Float) -> Float {
        0.1151292546497023 * decibels + 10.397177190355384
    }

    /// `le_fx::math::fast_log`: a bit-twiddled log2 with a quadratic mantissa fit, times ln 2.
    @inline(__always)
    static func fastLog(_ value: Float) -> Float {
        fastLog2(value) * 0.6931471805599453
    }

    @inline(__always)
    static func fastLog2(_ value: Float) -> Float {
        var bits = Int32(bitPattern: value.bitPattern)
        let log2 = Int32((bits >> 23) & 255) - 128
        bits &= ~(255 << 23)
        bits += 127 << 23
        let mantissa = Float(bitPattern: UInt32(bitPattern: bits))
        let fitted = ((-1.0 / 3) * mantissa + 2) * mantissa - 2.0 / 3
        return fitted + Float(log2)
    }
}
