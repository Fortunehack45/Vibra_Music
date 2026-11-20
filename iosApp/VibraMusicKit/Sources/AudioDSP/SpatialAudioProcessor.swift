/// Cheap stand-in for "spatial audio": widens the mid/side image and mixes in a
/// short, low-passed cross-feed between channels — the same trick most consumer
/// virtual-surround plugins use. O(1) per sample, no FFT or convolution, so it
/// costs nothing worth measuring on a phone CPU.
///
/// On Android this exists because the platform `Virtualizer` produced no
/// audible difference on the reference device. iOS has no app-level equivalent
/// either (system Spatial Audio is the listener's, not the app's), so the same
/// widening runs inside the app's own tap.
///
/// Stereo only: the widening is written in terms of a left and a right sample,
/// and there is no mid/side of a mono voice note or of a 5.1 mix to widen. Any
/// other channel count passes through untouched rather than failing — on
/// Android, throwing for those formats killed playback of every mono or
/// multichannel local file.
public final class SpatialAudioProcessor: FloatAudioProcessor, @unchecked Sendable {

    /// How much wider the stereo image gets. 1.0 = untouched. The audio
    /// pipeline readout shows it as "250%".
    public static let widthGain: Float = 2.5

    /// Make-up attenuation after widening, so the wider side energy doesn't clip.
    public static let outputGain: Float = 0.82

    /// How much of the delayed, low-passed opposite channel gets mixed back in.
    public static let crossfeedGain: Float = 0.2

    /// One-pole low-pass factor on the cross-fed signal — dulls it, like a far ear would.
    public static let lowpassCoefficient: Float = 0.3

    /// Cross-feed delay.
    public static let delayMilliseconds = 15

    private struct RenderState {
        var sampleRate: Double = 0
        var channelCount = 0
        var delayLeft: UnsafeMutablePointer<Float>?
        var delayRight: UnsafeMutablePointer<Float>?
        var delaySize = 0
        var delayIndex = 0
        var lowpassLeft: Float = 0
        var lowpassRight: Float = 0
    }

    private let enabledFlag = AtomicWord(0)
    private let appliesFlag = AtomicWord(0)
    private let render: UnsafeMutablePointer<RenderState>

    public init() {
        render = .allocate(capacity: 1)
        render.initialize(to: RenderState())
    }

    deinit {
        releaseDelay()
        render.deallocate()
    }

    /// The listener's toggle. Takes effect at the next block; safe from any thread.
    public var isEnabled: Bool {
        get { enabledFlag.load() != 0 }
        set { enabledFlag.store(newValue ? 1 : 0) }
    }

    /// Whether the configured stream is one the widening applies to (stereo).
    public var appliesToConfiguredFormat: Bool {
        appliesFlag.load() != 0
    }

    public func configure(sampleRate: Double, channelCount: Int) {
        let rs = render
        rs.pointee.sampleRate = sampleRate
        rs.pointee.channelCount = channelCount
        guard channelCount == 2, sampleRate > 0 else {
            releaseDelay()
            rs.pointee.delayIndex = 0
            rs.pointee.lowpassLeft = 0
            rs.pointee.lowpassRight = 0
            appliesFlag.store(0)
            return
        }
        appliesFlag.store(1)
        // Android rounds `sampleRate * 15 / 1000f` with Math.round: 44.1 kHz gives 662.
        let delaySamples = max(Int(JavaRounding.round(Float(Int(sampleRate) * Self.delayMilliseconds) / 1000)), 1)
        if rs.pointee.delaySize != delaySamples {
            releaseDelay()
            rs.pointee.delayLeft = .allocate(capacity: delaySamples)
            rs.pointee.delayRight = .allocate(capacity: delaySamples)
            rs.pointee.delayLeft?.initialize(repeating: 0, count: delaySamples)
            rs.pointee.delayRight?.initialize(repeating: 0, count: delaySamples)
            rs.pointee.delaySize = delaySamples
        }
        flush()
    }

    /// Widens [channels] in place. Headroom is preserved: nothing is clamped to ±1.
    public func process(_ channels: DSPChannels) {
        let frameCount = channels.frameCount
        guard enabledFlag.load() != 0, frameCount > 0, channels.channelCount == 2 else { return }
        let rs = render
        let delaySize = rs.pointee.delaySize
        guard delaySize > 0, let delayLeft = rs.pointee.delayLeft, let delayRight = rs.pointee.delayRight else { return }

        let left = channels.base(of: 0)
        let right = channels.base(of: 1)
        let stride = channels.stride
        let widthGain = Self.widthGain
        let outputGain = Self.outputGain
        let crossfeedGain = Self.crossfeedGain
        let lowpass = Self.lowpassCoefficient

        var delayIndex = rs.pointee.delayIndex
        var lowpassLeft = rs.pointee.lowpassLeft
        var lowpassRight = rs.pointee.lowpassRight

        var frame = 0
        while frame < frameCount {
            let index = frame * stride
            let inLeft = left[index]
            let inRight = right[index]

            let mid = (inLeft + inRight) * 0.5
            let side = (inLeft - inRight) * 0.5 * widthGain
            var widenedLeft = mid + side
            var widenedRight = mid - side

            let delayedRight = delayRight[delayIndex]
            let delayedLeft = delayLeft[delayIndex]
            lowpassLeft += lowpass * (delayedRight - lowpassLeft)
            lowpassRight += lowpass * (delayedLeft - lowpassRight)
            widenedLeft += lowpassLeft * crossfeedGain
            widenedRight += lowpassRight * crossfeedGain

            delayLeft[delayIndex] = inLeft
            delayRight[delayIndex] = inRight
            delayIndex = (delayIndex + 1) % delaySize

            left[index] = widenedLeft * outputGain
            right[index] = widenedRight * outputGain
            frame += 1
        }

        rs.pointee.delayIndex = delayIndex
        rs.pointee.lowpassLeft = lowpassLeft
        rs.pointee.lowpassRight = lowpassRight
    }

    public func flush() {
        let rs = render
        let size = rs.pointee.delaySize
        rs.pointee.delayLeft?.update(repeating: 0, count: size)
        rs.pointee.delayRight?.update(repeating: 0, count: size)
        rs.pointee.delayIndex = 0
        rs.pointee.lowpassLeft = 0
        rs.pointee.lowpassRight = 0
    }

    public func reset() {
        releaseDelay()
        appliesFlag.store(0)
        let rs = render
        rs.pointee.delayIndex = 0
        rs.pointee.lowpassLeft = 0
        rs.pointee.lowpassRight = 0
        rs.pointee.channelCount = 0
        rs.pointee.sampleRate = 0
    }

    private func releaseDelay() {
        let rs = render
        rs.pointee.delayLeft?.deallocate()
        rs.pointee.delayRight?.deallocate()
        rs.pointee.delayLeft = nil
        rs.pointee.delayRight = nil
        rs.pointee.delaySize = 0
    }
}
