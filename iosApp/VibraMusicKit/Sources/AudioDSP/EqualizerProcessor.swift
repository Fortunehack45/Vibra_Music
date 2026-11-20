import Foundation
import os

/// Ten-section parametric equaliser (seven manual bands, the tone pad's three),
/// automatic make-up gain and left/right balance.
///
/// ## The layout
///
/// `EqualizerLayout` fixes the sections. The manual tab's ends are shelves
/// (cornered at 60 Hz and 14 kHz) with bells between them; the tone pad owns a
/// 250 Hz low shelf, a 1 kHz bell and a 4 kHz high shelf. Balance is an output
/// trim rather than an extra section, and is ignored for anything but stereo.
///
/// ## State-variable filters
///
/// Two-integrator state-variable sections using the bilinear transform with
/// frequency pre-warping (the standard trapezoidal SVF). Chosen because SVFs
/// decouple frequency from Q — changing gain or bandwidth does not shift the
/// centre — and because their internal states stay bounded under parameter
/// modulation, which lets the user drag a band smoothly without transients.
///
/// ## Gliding
///
/// Every slider change is a target, not a step. The processor updates its
/// coefficients once per `glideFrames` frames, chasing the target curve. That
/// turns an abrupt preset switch into a short, inaudible glide instead of a
/// transient that would clip or click.
///
/// ## Threading
///
/// `setTuning` and `apply` may be called from any thread; the target curve is
/// handed to the audio thread through a lock-free triple buffer. See
/// `FloatAudioProcessor` for which calls belong to the audio thread. The render
/// path loops with `while` rather than `for … in` a range: unoptimised builds
/// heap-allocate a range iterator per step, and a Debug build of the app still
/// runs this code on the audio thread.
public final class EqualizerProcessor: FloatAudioProcessor, @unchecked Sendable {

    /// What the settings side last asked for.
    private struct Tuning {
        var isEnabled: Bool
        var curve: EqualizerCurve
        var balance: Float

        static let off = Tuning(isEnabled: false, curve: .flat, balance: 0)
    }

    /// Everything the audio thread owns that isn't a per-slot array. Kept in
    /// manually allocated memory so the render path does no exclusivity checks
    /// and no retain/release on Swift containers.
    private struct RenderState {
        var sampleRate: Float = 0
        var channelCount = 0
        var currentPreampDb: Float = 0
        var currentBalance: Float = 0
        /// Two integrator states per section, per channel.
        var filterState: UnsafeMutablePointer<Float>?
        var filterStateCount = 0
        /// Output trim per channel: make-up attenuation, and balance where stereo.
        var channelGain: UnsafeMutablePointer<Float>?
        var channelGainCount = 0
    }

    // Target layout inside a triple-buffer slot.
    private static let targetGains = 0
    private static let targetQs = EqualizerLayout.slotCount
    private static let targetPreamp = 2 * EqualizerLayout.slotCount
    private static let targetBalance = targetPreamp + 1
    private static let targetLength = targetBalance + 1

    private let targets: FloatTripleBuffer
    private let control = OSAllocatedUnfairLock(initialState: Tuning.off)

    private let render: UnsafeMutablePointer<RenderState>
    private let slotBank: UnsafeMutablePointer<Float>
    private let slotFrequency: UnsafeMutablePointer<Float>
    private let slotKind: UnsafeMutablePointer<EqualizerFilterKind>
    private let currentGainDb: UnsafeMutablePointer<Float>
    private let currentQ: UnsafeMutablePointer<Float>
    private let coeffA1: UnsafeMutablePointer<Float>
    private let coeffA2: UnsafeMutablePointer<Float>
    private let coeffA3: UnsafeMutablePointer<Float>
    private let mixInput: UnsafeMutablePointer<Float>
    private let mixBand: UnsafeMutablePointer<Float>
    private let mixLow: UnsafeMutablePointer<Float>
    /// Which sections are worth running this sub-block, and whether each ran last time.
    private let activeSlots: UnsafeMutablePointer<Int>
    private let running: UnsafeMutablePointer<Bool>

    public init() {
        let slots = EqualizerLayout.slotCount
        targets = FloatTripleBuffer(initial: Self.encode(.off))
        render = .allocate(capacity: 1)
        render.initialize(to: RenderState())
        slotBank = .allocate(capacity: slots * 9)
        slotBank.initialize(repeating: 0, count: slots * 9)
        slotFrequency = slotBank
        currentGainDb = slotBank + slots
        currentQ = slotBank + slots * 2
        coeffA1 = slotBank + slots * 3
        coeffA2 = slotBank + slots * 4
        coeffA3 = slotBank + slots * 5
        mixInput = slotBank + slots * 6
        mixBand = slotBank + slots * 7
        mixLow = slotBank + slots * 8
        currentQ.update(repeating: EqualizerLayout.restingQ, count: slots)
        slotKind = .allocate(capacity: slots)
        activeSlots = .allocate(capacity: slots)
        activeSlots.initialize(repeating: 0, count: slots)
        running = .allocate(capacity: slots)
        running.initialize(repeating: false, count: slots)
        for (index, slot) in EqualizerLayout.slots.enumerated() {
            slotFrequency[index] = slot.frequencyHz
            (slotKind + index).initialize(to: slot.kind)
        }
    }

    deinit {
        render.pointee.filterState?.deallocate()
        render.pointee.channelGain?.deallocate()
        render.deallocate()
        slotBank.deallocate()
        slotKind.deallocate()
        activeSlots.deallocate()
        running.deallocate()
    }

    // ---- Settings side -----------------------------------------------------

    /// Aims the equaliser. Nothing here is read until the next sub-block boundary.
    ///
    /// `enabled = false` is a flat curve and a centred balance rather than a
    /// bypass flag, so switching the equaliser off glides down to nothing like
    /// every other change instead of cutting the current curve out from under a
    /// playing track. Once the glide lands the processor hands samples back
    /// untouched.
    public func setTuning(enabled: Bool, curve: EqualizerCurve, balance: Float) {
        let tuning = enabled
            ? Tuning(isEnabled: true, curve: curve, balance: EqualizerSettings.clampedBalance(balance))
            : Tuning.off
        let encoded = Self.encode(tuning)
        control.withLock { current in
            current = tuning
            targets.publish { slot in
                encoded.withUnsafeBufferPointer { slot.update(from: $0.baseAddress!, count: Self.targetLength) }
            }
        }
    }

    /// Renders [settings] into a curve and aims the equaliser at it.
    public func apply(_ settings: EqualizerSettings) {
        setTuning(enabled: settings.isEnabled, curve: settings.curve, balance: settings.balance)
    }

    /// Whether the equaliser is switched on (even to a flat curve) — the
    /// setting, not whether the glide has finished.
    public var isEnabled: Bool {
        control.withLock { $0.isEnabled }
    }

    /// The curve the equaliser is aiming at: `EqualizerCurve.flat` while off.
    public var targetCurve: EqualizerCurve {
        control.withLock { $0.curve }
    }

    /// The balance the equaliser is aiming at: 0 while off.
    public var targetBalance: Float {
        control.withLock { $0.balance }
    }

    private static func encode(_ tuning: Tuning) -> [Float] {
        var values = [Float](repeating: 0, count: targetLength)
        for slot in 0..<EqualizerLayout.slotCount {
            values[targetGains + slot] = tuning.curve.gainsDb[slot]
            values[targetQs + slot] = tuning.curve.qs[slot]
        }
        values[targetPreamp] = tuning.curve.preampDb
        values[targetBalance] = tuning.balance
        return values
    }

    // ---- Audio side --------------------------------------------------------

    public func configure(sampleRate: Double, channelCount: Int) {
        let rs = render
        rs.pointee.sampleRate = Float(sampleRate)
        rs.pointee.channelCount = max(channelCount, 0)
        let required = rs.pointee.channelCount * EqualizerLayout.slotCount * 2
        if rs.pointee.filterStateCount != required {
            rs.pointee.filterState?.deallocate()
            rs.pointee.filterState = required > 0 ? .allocate(capacity: required) : nil
            rs.pointee.filterStateCount = required
        }
        rs.pointee.filterState?.initialize(repeating: 0, count: required)
        if rs.pointee.channelGainCount != rs.pointee.channelCount {
            rs.pointee.channelGain?.deallocate()
            rs.pointee.channelGain = channelCount > 0 ? .allocate(capacity: channelCount) : nil
            rs.pointee.channelGainCount = rs.pointee.channelCount
        }
        rs.pointee.channelGain?.initialize(repeating: 1, count: rs.pointee.channelGainCount)
        running.update(repeating: false, count: EqualizerLayout.slotCount)
        snapToTarget()
    }

    /// Filters [channels] in place. Headroom is preserved: nothing is clamped to ±1.
    ///
    /// A buffer whose channel count differs from the configured one is left
    /// untouched rather than mis-addressed.
    public func process(_ channels: DSPChannels) {
        let rs = render
        let channelCount = rs.pointee.channelCount
        let frameCount = channels.frameCount
        guard frameCount > 0, channelCount >= 1, rs.pointee.sampleRate > 0,
              channels.channelCount == channelCount,
              let filterState = rs.pointee.filterState,
              let channelGain = rs.pointee.channelGain else { return }

        let target = targets.acquire().values
        if isFlat(target) && isSettled(target) { return }

        let stride = channels.stride
        let slots = EqualizerLayout.slotCount
        var remaining = frameCount
        var frameOffset = 0
        while remaining > 0 {
            let subBlock = min(remaining, Self.glideFrames)
            glide(towards: target)
            let active = prepareSections()
            prepareChannelGains()

            var channel = 0
            while channel < channelCount {
                let base = channels.base(of: channel)
                let gain = channelGain[channel]
                let state = filterState + channel * slots * 2
                var frame = 0
                while frame < subBlock {
                    let index = (frameOffset + frame) * stride
                    var sample = base[index]
                    var position = 0
                    while position < active {
                        let slot = activeSlots[position]
                        let integrators = state + slot * 2
                        let ic1 = integrators[0]
                        let ic2 = integrators[1]
                        let v3 = sample - ic2
                        let v1 = coeffA1[slot] * ic1 + coeffA2[slot] * v3
                        let v2 = ic2 + coeffA2[slot] * ic1 + coeffA3[slot] * v3
                        integrators[0] = 2 * v1 - ic1
                        integrators[1] = 2 * v2 - ic2
                        sample = mixInput[slot] * sample + mixBand[slot] * v1 + mixLow[slot] * v2
                        position += 1
                    }
                    base[index] = sample * gain
                    frame += 1
                }
                channel += 1
            }
            flushDenormals(active, filterState: filterState, channelCount: channelCount)
            frameOffset += subBlock
            remaining -= subBlock
        }
    }

    public func flush() {
        if let filterState = render.pointee.filterState {
            filterState.update(repeating: 0, count: render.pointee.filterStateCount)
        }
        running.update(repeating: false, count: EqualizerLayout.slotCount)
        snapToTarget()
    }

    public func reset() {
        let rs = render
        rs.pointee.filterState?.deallocate()
        rs.pointee.filterState = nil
        rs.pointee.filterStateCount = 0
        rs.pointee.channelGain?.deallocate()
        rs.pointee.channelGain = nil
        rs.pointee.channelGainCount = 0
        rs.pointee.channelCount = 0
        rs.pointee.sampleRate = 0
        running.update(repeating: false, count: EqualizerLayout.slotCount)
    }

    // ---- Gliding -----------------------------------------------------------

    private func snapToTarget() {
        let target = targets.acquire().values
        currentGainDb.update(from: target + Self.targetGains, count: EqualizerLayout.slotCount)
        currentQ.update(from: target + Self.targetQs, count: EqualizerLayout.slotCount)
        render.pointee.currentPreampDb = target[Self.targetPreamp]
        render.pointee.currentBalance = target[Self.targetBalance]
    }

    private func glide(towards target: UnsafePointer<Float>) {
        var slot = 0
        while slot < EqualizerLayout.slotCount {
            currentGainDb[slot] = Self.linearGlide(currentGainDb[slot], target[Self.targetGains + slot])
            currentQ[slot] = Self.geometricGlide(currentQ[slot], target[Self.targetQs + slot])
            slot += 1
        }
        render.pointee.currentPreampDb = Self.linearGlide(render.pointee.currentPreampDb, target[Self.targetPreamp])
        render.pointee.currentBalance = Self.linearGlide(render.pointee.currentBalance, target[Self.targetBalance])
    }

    @inline(__always)
    private static func linearGlide(_ current: Float, _ target: Float) -> Float {
        current + (target - current) * glideRate
    }

    @inline(__always)
    private static func geometricGlide(_ current: Float, _ target: Float) -> Float {
        let from = log(max(current, minQ))
        let to = log(max(target, minQ))
        return exp(from + (to - from) * glideRate)
    }

    private func isFlat(_ target: UnsafePointer<Float>) -> Bool {
        guard abs(target[Self.targetBalance]) < Self.settledBalance,
              abs(target[Self.targetPreamp]) < Self.settledDb else { return false }
        var slot = 0
        while slot < EqualizerLayout.slotCount {
            if abs(target[Self.targetGains + slot]) >= Self.settledDb { return false }
            slot += 1
        }
        return true
    }

    private func isSettled(_ target: UnsafePointer<Float>) -> Bool {
        if abs(render.pointee.currentBalance - target[Self.targetBalance]) >= Self.settledBalance { return false }
        if abs(render.pointee.currentPreampDb - target[Self.targetPreamp]) >= Self.settledDb { return false }
        var slot = 0
        while slot < EqualizerLayout.slotCount {
            if abs(currentGainDb[slot] - target[Self.targetGains + slot]) >= Self.settledDb { return false }
            slot += 1
        }
        return true
    }

    // ---- Coefficients ------------------------------------------------------

    private func prepareSections() -> Int {
        var active = 0
        var slot = 0
        while slot < EqualizerLayout.slotCount {
            if abs(currentGainDb[slot]) >= Self.settledDb {
                updateCoefficients(slot)
                activeSlots[active] = slot
                active += 1
                running[slot] = true
            } else if running[slot] {
                clearState(slot)
                running[slot] = false
            }
            slot += 1
        }
        return active
    }

    private func updateCoefficients(_ slot: Int) {
        let sampleRate = render.pointee.sampleRate
        guard sampleRate > 0 else { return }
        let a = pow(Float(10), currentGainDb[slot] / 40)
        let q = max(currentQ[slot], Self.minQ)
        let usable = min(max(slotFrequency[slot], Self.minHz), sampleRate * Self.maxFrequencyFraction)
        let base = Float(tan(Double.pi * Double(usable) / Double(sampleRate)))
        let g: Float
        let k: Float
        switch slotKind[slot] {
        case .bell:
            g = base
            k = 1 / (q * a)
            mixInput[slot] = 1
            mixBand[slot] = k * (a * a - 1)
            mixLow[slot] = 0
        case .lowShelf:
            g = base / a.squareRoot()
            k = 1 / q
            mixInput[slot] = 1
            mixBand[slot] = k * (a - 1)
            mixLow[slot] = a * a - 1
        case .highShelf:
            g = base * a.squareRoot()
            k = 1 / q
            mixInput[slot] = a * a
            mixBand[slot] = k * (1 - a) * a
            mixLow[slot] = 1 - a * a
        }
        let d = 1 / (1 + g * (g + k))
        coeffA1[slot] = d
        coeffA2[slot] = g * d
        coeffA3[slot] = g * (g * d)
    }

    private func prepareChannelGains() {
        let rs = render
        guard let channelGain = rs.pointee.channelGain else { return }
        let preamp = pow(Float(10), rs.pointee.currentPreampDb / 20)
        let count = rs.pointee.channelGainCount
        if count == 2 {
            let balance = rs.pointee.currentBalance
            channelGain[0] = preamp * min(1, 1 - balance)
            channelGain[1] = preamp * min(1, 1 + balance)
        } else {
            channelGain.update(repeating: preamp, count: count)
        }
    }

    // ---- Filter state ------------------------------------------------------

    private func clearState(_ slot: Int) {
        guard let filterState = render.pointee.filterState else { return }
        var channel = 0
        while channel < render.pointee.channelCount {
            let index = (channel * EqualizerLayout.slotCount + slot) * 2
            filterState[index] = 0
            filterState[index + 1] = 0
            channel += 1
        }
    }

    private func flushDenormals(_ active: Int, filterState: UnsafeMutablePointer<Float>, channelCount: Int) {
        var position = 0
        while position < active {
            let slot = activeSlots[position]
            var channel = 0
            while channel < channelCount {
                let index = (channel * EqualizerLayout.slotCount + slot) * 2
                if abs(filterState[index]) < Self.denormalFloor { filterState[index] = 0 }
                if abs(filterState[index + 1]) < Self.denormalFloor { filterState[index + 1] = 0 }
                channel += 1
            }
            position += 1
        }
    }

    // ---- Constants ---------------------------------------------------------

    /// Frames between coefficient updates. About 1.5 ms at 44.1 kHz.
    static let glideFrames = 64

    /// Per-sub-block glide fraction. About an 18 ms time constant — a fast drag still tracks.
    static let glideRate: Float = 0.08

    /// Below this a band is doing nothing anyone can hear, so it counts as flat.
    static let settledDb: Float = 0.01

    /// Same idea for the balance trim, where the scale is -1 to 1.
    static let settledBalance: Float = 0.0005

    static let minQ: Float = 0.05
    static let minHz: Float = 10

    /// Keeps `tan` away from its pole at Nyquist.
    static let maxFrequencyFraction: Float = 0.45

    /// Integrator states below this are flushed to zero, so a decaying filter
    /// never lands in denormal arithmetic.
    static let denormalFloor: Float = 1e-12
}
