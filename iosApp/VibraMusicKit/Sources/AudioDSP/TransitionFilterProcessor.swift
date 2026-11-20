import Foundation

/// The filter a track rides through an Automix transition: a low-pass that can
/// close over the outgoing track, and a high-pass that can lift the low end out
/// of one side of a blend.
///
/// ## The filter
///
/// A topology-preserving (trapezoidal-integrator) state-variable filter, two
/// second-order sections cascaded to a 24 dB/octave Butterworth response — the
/// usual DJ-filter slope.
///
/// ## Automation
///
/// `setCutoffs` sets targets; the processor glides its cutoffs towards them
/// geometrically (so a sweep sounds even across octaves) every `glideFrames`
/// frames. Safe to call from any thread, as often as a transition ticks.
public final class TransitionFilterProcessor: FloatAudioProcessor, @unchecked Sendable {

    /// A low-pass at or above this is doing nothing audible, so it counts as off.
    public static let openHz: Float = 20_000

    /// A high-pass at or below this is doing nothing audible, so it counts as off.
    public static let offHz: Float = 20

    /// Nothing musical wants the low end lifted above this, and a typo shouldn't be able to.
    public static let maxHighPassHz: Float = 2_000

    private struct RenderState {
        var sampleRate: Float = 0
        var channelCount = 0
        var currentLowPassHz: Float = TransitionFilterProcessor.openHz
        var currentHighPassHz: Float = TransitionFilterProcessor.offHz
        /// Two integrator states per second-order section, per channel.
        var lowState: UnsafeMutablePointer<Float>?
        var highState: UnsafeMutablePointer<Float>?
        var stateCount = 0
        /// What was last published to `current`, so the audio thread only writes on change.
        var publishedCurrent: Int64 = 0
    }

    /// Target cutoffs, low-pass and high-pass, packed into one word.
    private let target = AtomicWord(FloatPair.pack(TransitionFilterProcessor.openHz, TransitionFilterProcessor.offHz))

    /// The audio thread's current cutoffs, for `isFiltering` to see the tail of a glide.
    private let current = AtomicWord(FloatPair.pack(TransitionFilterProcessor.openHz, TransitionFilterProcessor.offHz))

    private let render: UnsafeMutablePointer<RenderState>
    private let coefficients: UnsafeMutablePointer<Float>
    private let lowA1: UnsafeMutablePointer<Float>
    private let lowA2: UnsafeMutablePointer<Float>
    private let lowA3: UnsafeMutablePointer<Float>
    private let highA1: UnsafeMutablePointer<Float>
    private let highA2: UnsafeMutablePointer<Float>
    private let highA3: UnsafeMutablePointer<Float>
    private let highK: UnsafeMutablePointer<Float>

    public init() {
        let stages = Self.stages
        render = .allocate(capacity: 1)
        var initial = RenderState()
        initial.publishedCurrent = FloatPair.pack(Self.openHz, Self.offHz)
        render.initialize(to: initial)
        coefficients = .allocate(capacity: stages * 7)
        coefficients.initialize(repeating: 0, count: stages * 7)
        lowA1 = coefficients
        lowA2 = coefficients + stages
        lowA3 = coefficients + stages * 2
        highA1 = coefficients + stages * 3
        highA2 = coefficients + stages * 4
        highA3 = coefficients + stages * 5
        highK = coefficients + stages * 6
    }

    deinit {
        render.pointee.lowState?.deallocate()
        render.pointee.highState?.deallocate()
        render.deallocate()
        coefficients.deallocate()
    }

    // ---- Settings side -----------------------------------------------------

    /// Aims the filter. [lowPassHz] at or above `openHz` and [highPassHz] at or
    /// below `offHz` mean "not filtering", which is the state this returns to
    /// between transitions.
    ///
    /// NaN reads as "not filtering": once in the glide it would turn every
    /// coefficient, and then the filter state, into NaN for the rest of the item.
    public func setCutoffs(lowPassHz: Float, highPassHz: Float) {
        let low = lowPassHz.isNaN ? Self.openHz : min(max(lowPassHz, Self.minHz), Self.openHz)
        let high = highPassHz.isNaN ? Self.offHz : min(max(highPassHz, Self.offHz), Self.maxHighPassHz)
        target.store(FloatPair.pack(low, high))
    }

    /// Parks both filters. Glided, not snapped.
    public func open() {
        setCutoffs(lowPassHz: Self.openHz, highPassHz: Self.offHz)
    }

    /// The cutoffs the filter is aiming at.
    public var targetCutoffs: (lowPassHz: Float, highPassHz: Float) {
        let (low, high) = FloatPair.unpack(target.load())
        return (low, high)
    }

    /// Whether either filter is aimed somewhere audible, or still gliding back from one.
    public var isFiltering: Bool {
        let (targetLow, targetHigh) = FloatPair.unpack(target.load())
        let (currentLow, currentHigh) = FloatPair.unpack(current.load())
        return targetLow < Self.openHz || targetHigh > Self.offHz ||
            currentLow < Self.openHz - Self.settledHz || currentHigh > Self.offHz + Self.settledHz
    }

    // ---- Audio side --------------------------------------------------------

    public func configure(sampleRate: Double, channelCount: Int) {
        let rs = render
        rs.pointee.sampleRate = Float(sampleRate)
        rs.pointee.channelCount = max(channelCount, 0)
        let required = rs.pointee.channelCount * Self.stages * 2
        if rs.pointee.stateCount != required {
            rs.pointee.lowState?.deallocate()
            rs.pointee.highState?.deallocate()
            rs.pointee.lowState = required > 0 ? .allocate(capacity: required) : nil
            rs.pointee.highState = required > 0 ? .allocate(capacity: required) : nil
            rs.pointee.stateCount = required
        }
        rs.pointee.lowState?.initialize(repeating: 0, count: required)
        rs.pointee.highState?.initialize(repeating: 0, count: required)
        snapToTarget()
    }

    /// Filters [channels] in place. Headroom is preserved: nothing is clamped to ±1.
    public func process(_ channels: DSPChannels) {
        let rs = render
        let channelCount = rs.pointee.channelCount
        let frameCount = channels.frameCount
        guard frameCount > 0, channelCount >= 1, rs.pointee.sampleRate > 0,
              channels.channelCount == channelCount,
              let lowState = rs.pointee.lowState, let highState = rs.pointee.highState else { return }

        let (targetLow, targetHigh) = FloatPair.unpack(target.load())
        let parked = targetLow >= Self.openHz && targetHigh <= Self.offHz &&
            rs.pointee.currentLowPassHz >= Self.openHz - Self.settledHz &&
            rs.pointee.currentHighPassHz <= Self.offHz + Self.settledHz
        if parked { return }

        let stride = channels.stride
        let stages = Self.stages
        var remaining = frameCount
        var frameOffset = 0
        while remaining > 0 {
            let subBlock = min(remaining, Self.glideFrames)
            rs.pointee.currentLowPassHz = Self.glide(rs.pointee.currentLowPassHz, targetLow)
            rs.pointee.currentHighPassHz = Self.glide(rs.pointee.currentHighPassHz, targetHigh)
            let lowOn = rs.pointee.currentLowPassHz < Self.openHz - Self.settledHz
            let highOn = rs.pointee.currentHighPassHz > Self.offHz + Self.settledHz
            if lowOn { updateLowCoefficients() }
            if highOn { updateHighCoefficients() }

            var channel = 0
            while channel < channelCount {
                let base = channels.base(of: channel)
                let low = lowState + channel * stages * 2
                let high = highState + channel * stages * 2
                var frame = 0
                while frame < subBlock {
                    let index = (frameOffset + frame) * stride
                    var sample = base[index]
                    if lowOn {
                        var stage = 0
                        while stage < stages {
                            let integrators = low + stage * 2
                            let ic1 = integrators[0]
                            let ic2 = integrators[1]
                            let v3 = sample - ic2
                            let v1 = lowA1[stage] * ic1 + lowA2[stage] * v3
                            let v2 = ic2 + lowA2[stage] * ic1 + lowA3[stage] * v3
                            integrators[0] = 2 * v1 - ic1
                            integrators[1] = 2 * v2 - ic2
                            sample = v2
                            stage += 1
                        }
                    }
                    if highOn {
                        var stage = 0
                        while stage < stages {
                            let integrators = high + stage * 2
                            let ic1 = integrators[0]
                            let ic2 = integrators[1]
                            let v3 = sample - ic2
                            let v1 = highA1[stage] * ic1 + highA2[stage] * v3
                            let v2 = ic2 + highA2[stage] * ic1 + highA3[stage] * v3
                            integrators[0] = 2 * v1 - ic1
                            integrators[1] = 2 * v2 - ic2
                            sample -= highK[stage] * v1 + v2
                            stage += 1
                        }
                    }
                    base[index] = sample
                    frame += 1
                }
                channel += 1
            }
            frameOffset += subBlock
            remaining -= subBlock
        }
        publishCurrent()
    }

    public func flush() {
        let rs = render
        rs.pointee.lowState?.update(repeating: 0, count: rs.pointee.stateCount)
        rs.pointee.highState?.update(repeating: 0, count: rs.pointee.stateCount)
        snapToTarget()
    }

    public func reset() {
        target.store(FloatPair.pack(Self.openHz, Self.offHz))
        let rs = render
        rs.pointee.lowState?.deallocate()
        rs.pointee.highState?.deallocate()
        rs.pointee.lowState = nil
        rs.pointee.highState = nil
        rs.pointee.stateCount = 0
        rs.pointee.channelCount = 0
        rs.pointee.sampleRate = 0
        snapToTarget()
    }

    // ---- Filter ------------------------------------------------------------

    private func snapToTarget() {
        let (low, high) = FloatPair.unpack(target.load())
        render.pointee.currentLowPassHz = low
        render.pointee.currentHighPassHz = high
        publishCurrent()
    }

    private func publishCurrent() {
        let packed = FloatPair.pack(render.pointee.currentLowPassHz, render.pointee.currentHighPassHz)
        if packed != render.pointee.publishedCurrent {
            current.store(packed)
            render.pointee.publishedCurrent = packed
        }
    }

    @inline(__always)
    private static func glide(_ current: Float, _ target: Float) -> Float {
        let from = log(max(current, minHz))
        let to = log(max(target, minHz))
        return exp(from + (to - from) * glideRate)
    }

    private func usableCutoff(_ hz: Float) -> Float {
        min(max(hz, Self.minHz), render.pointee.sampleRate * Self.maxCutoffFraction)
    }

    private func updateLowCoefficients() {
        let sampleRate = render.pointee.sampleRate
        guard sampleRate > 0 else { return }
        let g = Float(tan(Double.pi * Double(usableCutoff(render.pointee.currentLowPassHz)) / Double(sampleRate)))
        var stage = 0
        while stage < Self.stages {
            let k = 1 / Self.butterworthQ(stage)
            let a1 = 1 / (1 + g * (g + k))
            lowA1[stage] = a1
            lowA2[stage] = g * a1
            lowA3[stage] = g * (g * a1)
            stage += 1
        }
    }

    private func updateHighCoefficients() {
        let sampleRate = render.pointee.sampleRate
        guard sampleRate > 0 else { return }
        let g = Float(tan(Double.pi * Double(usableCutoff(render.pointee.currentHighPassHz)) / Double(sampleRate)))
        var stage = 0
        while stage < Self.stages {
            let k = 1 / Self.butterworthQ(stage)
            let a1 = 1 / (1 + g * (g + k))
            highA1[stage] = a1
            highA2[stage] = g * a1
            highA3[stage] = g * (g * a1)
            highK[stage] = k
            stage += 1
        }
    }

    // ---- Constants ---------------------------------------------------------

    static let minHz: Float = 10

    /// Two cascaded second-order sections: 24 dB/octave.
    static let stages = 2

    /// Section Qs for a maximally flat (Butterworth) fourth-order response.
    @inline(__always)
    static func butterworthQ(_ stage: Int) -> Float {
        stage == 0 ? 0.54120 : 1.30656
    }

    /// Frames between coefficient updates. About 1.5 ms at 44.1 kHz.
    static let glideFrames = 64

    /// Per-sub-block glide fraction. About a 30 ms time constant, just under one fade tick.
    static let glideRate: Float = 0.05

    /// How close to a parked value counts as parked, so a glide terminates.
    static let settledHz: Float = 1

    /// Keeps `tan` away from its pole at Nyquist.
    static let maxCutoffFraction: Float = 0.45
}

/// The two filters a transition rides: one over the track arriving, one over
/// the track leaving.
///
/// A protocol rather than the processors themselves so the crossfade controller
/// stays testable without an audio pipeline, and so it never has to know that
/// "incoming" and "outgoing" are two players whose roles swap at the handover.
public protocol TransitionFilters: AnyObject {
    /// The track fading up — the main player, once the handover has passed it the queue.
    func incoming(lowPassHz: Float, highPassHz: Float)

    /// The track fading out.
    func outgoing(lowPassHz: Float, highPassHz: Float)

    /// Parks both. Called whenever a transition ends, however it ended.
    func open()
}

extension TransitionFilters {
    public func open() {
        incoming(lowPassHz: TransitionFilterProcessor.openHz, highPassHz: TransitionFilterProcessor.offHz)
        outgoing(lowPassHz: TransitionFilterProcessor.openHz, highPassHz: TransitionFilterProcessor.offHz)
    }
}

/// For callers with no audio pipeline to filter — tests, and the default wiring.
public final class NoTransitionFilters: TransitionFilters {
    public init() {}
    public func incoming(lowPassHz: Float, highPassHz: Float) {}
    public func outgoing(lowPassHz: Float, highPassHz: Float) {}
}
