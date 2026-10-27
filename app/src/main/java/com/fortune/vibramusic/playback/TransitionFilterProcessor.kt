package com.fortune.vibramusic.playback

import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import com.fortune.vibramusic.playback.audio.AudioBlock
import com.fortune.vibramusic.playback.audio.FloatAudioProcessor
import com.fortune.vibramusic.playback.audio.PcmBoundary
import com.fortune.vibramusic.playback.mix.EffectType
import java.nio.ByteOrder
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.min
import kotlin.math.tan

/**
 * The filter a track rides through a Automix transition: a low-pass that can
 * close over the outgoing track, and a high-pass that can lift the low end out
 * of one side of a blend.
 *
 * ## The filter
 *
 * A topology-preserving (trapezoidal-integrator) state-variable filter, two
 * second-order sections cascaded to a 24 dB/octave Butterworth response.
 */
@UnstableApi
class TransitionFilterProcessor : BaseAudioProcessor() {

    @Volatile
    private var targetLowPassHz: Float = OPEN_HZ

    @Volatile
    private var targetHighPassHz: Float = OFF_HZ

    private var channelCount = 0
    private var sampleRate = 0

    private var currentLowPassHz = OPEN_HZ
    private var currentHighPassHz = OFF_HZ

    /** Two integrator states per second-order section, per channel. */
    private var lowState = FloatArray(0)
    private var highState = FloatArray(0)

    private val lowA1 = FloatArray(STAGES)
    private val lowA2 = FloatArray(STAGES)
    private val lowA3 = FloatArray(STAGES)
    private val highA1 = FloatArray(STAGES)
    private val highA2 = FloatArray(STAGES)
    private val highA3 = FloatArray(STAGES)
    private val highK = FloatArray(STAGES)

    @Volatile
    private var bassGain: Float = 1.0f

    @Volatile
    private var midGain: Float = 1.0f

    @Volatile
    private var trebleGain: Float = 1.0f

    // 2-Pole Cascaded Low-Pass for 12 dB/octave DJ EQ Isolator
    private var eqLowState1 = FloatArray(0)
    private var eqLowState2 = FloatArray(0)
    private var eqHighState1 = FloatArray(0)

    // Spatial Effects DSP (Echo & Reverb)
    @Volatile
    private var effectType: EffectType? = null

    @Volatile
    private var effectWet: Float = 0f

    @Volatile
    private var echoDelayFrames: Int = 0

    @Volatile
    private var echoFeedback: Float = 0.52f

    private var delayBuffer = FloatArray(0)
    private var delayWriteIndex = 0

    /**
     * Aims the filter. [lowPassHz] at or above [OPEN_HZ] and [highPassHz] at or
     * below [OFF_HZ] mean "not filtering", which is the state this returns to
     * between transitions.
     */
    fun setCutoffs(lowPassHz: Float, highPassHz: Float) {
        targetLowPassHz = lowPassHz.coerceIn(MIN_HZ, OPEN_HZ)
        targetHighPassHz = highPassHz.coerceIn(OFF_HZ, MAX_HIGH_PASS_HZ)
    }

    /**
     * Sets per-band EQ gain in decibels for transition automation.
     */
    fun setEq(bassDb: Float, midDb: Float, trebleDb: Float) {
        bassGain = Math.pow(10.0, (bassDb.coerceIn(-36f, 6f) / 20f).toDouble()).toFloat()
        midGain = Math.pow(10.0, (midDb.coerceIn(-36f, 6f) / 20f).toDouble()).toFloat()
        trebleGain = Math.pow(10.0, (trebleDb.coerceIn(-36f, 6f) / 20f).toDouble()).toFloat()
    }

    /**
     * Sets real-time spatial effect parameters for transition automation.
     */
    fun setEffect(type: EffectType?, wet: Float, echoBeats: Float? = null, bpm: Float = 120f) {
        effectType = type
        val clampedWet = wet.coerceIn(0f, 1f)
        effectWet = clampedWet
        if (type == EffectType.ECHO && sampleRate > 0) {
            val beats = echoBeats ?: 0.5f
            val safeBpm = if (bpm in 40f..240f) bpm else 120f
            val delaySec = (60.0f / safeBpm) * beats
            val frames = (delaySec * sampleRate).toInt()
            val maxFrames = delayBuffer.size / channelCount.coerceAtLeast(1)
            echoDelayFrames = frames.coerceIn(64, (maxFrames - 1).coerceAtLeast(64))
            echoFeedback = 0.52f
        }
    }

    /** Parks both filters and resets EQ gains. Glided, not snapped. */
    fun open() {
        setCutoffs(OPEN_HZ, OFF_HZ)
        bassGain = 1.0f
        midGain = 1.0f
        trebleGain = 1.0f
        effectType = null
        effectWet = 0f
    }

    val isFiltering: Boolean
        get() = targetLowPassHz < OPEN_HZ || targetHighPassHz > OFF_HZ ||
            currentLowPassHz < OPEN_HZ - SETTLED_HZ || currentHighPassHz > OFF_HZ + SETTLED_HZ ||
            bassGain != 1.0f || midGain != 1.0f || trebleGain != 1.0f ||
            (effectType != null && effectWet > 0.001f)

    /**
     * Configures the Float32 DSP engine for [sampleRate] and [channelCount].
     */
    fun configure(sampleRate: Int, channelCount: Int) {
        this.sampleRate = sampleRate
        this.channelCount = channelCount
        val requiredSize = channelCount * STAGES * 2
        if (lowState.size != requiredSize) {
            lowState = FloatArray(requiredSize)
            highState = FloatArray(requiredSize)
        }
        if (eqLowState1.size != channelCount) {
            eqLowState1 = FloatArray(channelCount)
            eqLowState2 = FloatArray(channelCount)
            eqHighState1 = FloatArray(channelCount)
        }
        val maxFrames = (sampleRate * 2.0).toInt().coerceAtLeast(1)
        val requiredDelaySize = maxFrames * channelCount
        if (delayBuffer.size != requiredDelaySize) {
            delayBuffer = FloatArray(requiredDelaySize)
            delayWriteIndex = 0
        }
        currentLowPassHz = targetLowPassHz
        currentHighPassHz = targetHighPassHz
    }

    /**
     * Processes interleaved Float32 audio samples in [block] in-place.
     * Preserves dynamic headroom without clamping to [-1.0f, +1.0f].
     */
    fun process(block: AudioBlock) {
        val frameCount = block.frameCount
        if (frameCount == 0 || channelCount < 1 || sampleRate <= 0) return

        val targetLow = targetLowPassHz
        val targetHigh = targetHighPassHz
        val parked = !isFiltering
        if (parked) {
            return
        }

        val eqActive = bassGain != 1.0f || midGain != 1.0f || trebleGain != 1.0f
        val fxActive = effectType != null && effectWet > 0.001f
        var remaining = frameCount
        var frameOffset = 0
        while (remaining > 0) {
            val subBlock = min(remaining, GLIDE_FRAMES)
            currentLowPassHz = glide(currentLowPassHz, targetLow)
            currentHighPassHz = glide(currentHighPassHz, targetHigh)
            val lowOn = currentLowPassHz < OPEN_HZ - SETTLED_HZ
            val highOn = currentHighPassHz > OFF_HZ + SETTLED_HZ
            if (lowOn) updateLowCoefficients()
            if (highOn) updateHighCoefficients()

            for (f in 0 until subBlock) {
                val baseIdx = (frameOffset + f) * channelCount
                for (channel in 0 until channelCount) {
                    var sample = block.samples[baseIdx + channel]
                    if (lowOn) sample = lowPass(channel, sample)
                    if (highOn) sample = highPass(channel, sample)
                    if (eqActive) sample = applyEq(channel, sample)
                    if (fxActive) sample = applyEffects(channel, sample)
                    // Headroom preserved: no clamping to [-1.0f, +1.0f]
                    block.samples[baseIdx + channel] = sample
                }
                if (delayBuffer.isNotEmpty() && channelCount > 0) {
                    delayWriteIndex = (delayWriteIndex + 1) % (delayBuffer.size / channelCount)
                }
            }
            frameOffset += subBlock
            remaining -= subBlock
        }
    }

    /**
     * 16-bit PCM only.
     */
    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT || inputAudioFormat.channelCount < 1) {
            Log.w(
                TAG,
                "Transition filtering inactive: encoding=${inputAudioFormat.encoding} " +
                    "channels=${inputAudioFormat.channelCount} is not 16-bit PCM",
            )
            return AudioProcessor.AudioFormat.NOT_SET
        }
        configure(inputAudioFormat.sampleRate, inputAudioFormat.channelCount)
        return inputAudioFormat
    }

    override fun onFlush() {
        lowState.fill(0f)
        highState.fill(0f)
        eqLowState1.fill(0f)
        eqLowState2.fill(0f)
        eqHighState1.fill(0f)
        delayBuffer.fill(0f)
        delayWriteIndex = 0
        currentLowPassHz = targetLowPassHz
        currentHighPassHz = targetHighPassHz
    }

    override fun onReset() {
        targetLowPassHz = OPEN_HZ
        targetHighPassHz = OFF_HZ
        bassGain = 1.0f
        midGain = 1.0f
        trebleGain = 1.0f
        effectType = null
        effectWet = 0f
        lowState = FloatArray(0)
        highState = FloatArray(0)
        eqLowState1 = FloatArray(0)
        eqLowState2 = FloatArray(0)
        eqHighState1 = FloatArray(0)
        delayBuffer = FloatArray(0)
        delayWriteIndex = 0
        channelCount = 0
        sampleRate = 0
    }

    override fun queueInput(inputBuffer: java.nio.ByteBuffer) {
        val bytesPerFrame = BYTES_PER_SAMPLE * channelCount
        if (bytesPerFrame == 0) return
        val frameCount = inputBuffer.remaining() / bytesPerFrame
        if (frameCount == 0) return
        val outputBuffer = replaceOutputBuffer(frameCount * bytesPerFrame)

        val targetLow = targetLowPassHz
        val targetHigh = targetHighPassHz
        val parked = !isFiltering
        if (parked) {
            outputBuffer.put(inputBuffer)
            outputBuffer.flip()
            return
        }

        inputBuffer.order(ByteOrder.nativeOrder())
        outputBuffer.order(ByteOrder.nativeOrder())

        val invScale = 1.0f / 32768.0f
        val eqActive = bassGain != 1.0f || midGain != 1.0f || trebleGain != 1.0f
        val fxActive = effectType != null && effectWet > 0.001f
        var remaining = frameCount
        while (remaining > 0) {
            val subBlock = min(remaining, GLIDE_FRAMES)
            currentLowPassHz = glide(currentLowPassHz, targetLow)
            currentHighPassHz = glide(currentHighPassHz, targetHigh)
            val lowOn = currentLowPassHz < OPEN_HZ - SETTLED_HZ
            val highOn = currentHighPassHz > OFF_HZ + SETTLED_HZ
            if (lowOn) updateLowCoefficients()
            if (highOn) updateHighCoefficients()

            repeat(subBlock) {
                for (channel in 0 until channelCount) {
                    var sample = inputBuffer.short.toFloat() * invScale
                    if (lowOn) sample = lowPass(channel, sample)
                    if (highOn) sample = highPass(channel, sample)
                    if (eqActive) sample = applyEq(channel, sample)
                    if (fxActive) sample = applyEffects(channel, sample)
                    outputBuffer.putShort(PcmBoundary.clamp16FromFloat(sample))
                }
                if (delayBuffer.isNotEmpty() && channelCount > 0) {
                    delayWriteIndex = (delayWriteIndex + 1) % (delayBuffer.size / channelCount)
                }
            }
            remaining -= subBlock
        }
        outputBuffer.flip()
    }

    private fun applyEq(channel: Int, input: Float): Float {
        if (channel >= eqLowState1.size || channel >= eqHighState1.size) return input
        val sr = sampleRate.coerceAtLeast(1)
        val alphaLow = (2.0 * Math.PI * 300.0 / sr).toFloat().coerceIn(0.001f, 0.45f)
        val alphaHigh = (2.0 * Math.PI * 3500.0 / sr).toFloat().coerceIn(0.001f, 0.45f)

        // 2-pole cascaded low-pass for 12 dB/octave steep cutoff
        val low1 = eqLowState1[channel] + alphaLow * (input - eqLowState1[channel])
        eqLowState1[channel] = low1
        val low2 = eqLowState2[channel] + alphaLow * (low1 - eqLowState2[channel])
        eqLowState2[channel] = low2
        val low = low2

        // High-frequency band
        val highPrev = eqHighState1[channel]
        val high = (1f - alphaHigh) * (highPrev + input - low)
        eqHighState1[channel] = high

        val mid = input - low - high

        // Full isolator kill when gain drops below -30dB
        val effectiveBassGain = if (bassGain < 0.04f) 0f else bassGain
        val effectiveMidGain = if (midGain < 0.04f) 0f else midGain
        val effectiveTrebleGain = if (trebleGain < 0.04f) 0f else trebleGain

        return low * effectiveBassGain + mid * effectiveMidGain + high * effectiveTrebleGain
    }

    private fun applyEffects(channel: Int, input: Float): Float {
        val type = effectType
        val wet = effectWet
        if (type == null || wet <= 0.001f || delayBuffer.isEmpty() || channelCount < 1) return input

        val totalFrames = delayBuffer.size / channelCount
        val writeIdx = delayWriteIndex * channelCount + channel

        return when (type) {
            EffectType.ECHO -> {
                val readFrame = (delayWriteIndex - echoDelayFrames + totalFrames) % totalFrames
                val readIdx = readFrame * channelCount + channel
                val delayed = delayBuffer[readIdx]
                delayBuffer[writeIdx] = input + delayed * echoFeedback
                input * (1f - wet * 0.35f) + delayed * (wet * 0.85f)
            }
            EffectType.REVERB -> {
                // Multi-tap diffused delay network for lush hall wash
                val t1 = (delayWriteIndex - (sampleRate * 0.029f).toInt() + totalFrames) % totalFrames
                val t2 = (delayWriteIndex - (sampleRate * 0.043f).toInt() + totalFrames) % totalFrames
                val t3 = (delayWriteIndex - (sampleRate * 0.067f).toInt() + totalFrames) % totalFrames
                val t4 = (delayWriteIndex - (sampleRate * 0.091f).toInt() + totalFrames) % totalFrames
                val d1 = delayBuffer[t1 * channelCount + channel]
                val d2 = delayBuffer[t2 * channelCount + channel]
                val d3 = delayBuffer[t3 * channelCount + channel]
                val d4 = delayBuffer[t4 * channelCount + channel]
                val reverbSignal = (d1 + d2 * 0.75f + d3 * 0.55f + d4 * 0.35f) * 0.55f
                delayBuffer[writeIdx] = input + reverbSignal * 0.5f
                input * (1f - wet * 0.3f) + reverbSignal * (wet * 0.8f)
            }
        }
    }

    // ---- Filter ------------------------------------------------------------

    private fun glide(current: Float, target: Float): Float {
        val from = ln(current.coerceAtLeast(MIN_HZ))
        val to = ln(target.coerceAtLeast(MIN_HZ))
        return exp(from + (to - from) * GLIDE_RATE)
    }

    private fun usableCutoff(hz: Float): Float =
        hz.coerceIn(MIN_HZ, sampleRate * MAX_CUTOFF_FRACTION)

    private fun updateLowCoefficients() {
        if (sampleRate <= 0) return
        val g = tan(Math.PI * usableCutoff(currentLowPassHz) / sampleRate).toFloat()
        for (stage in 0 until STAGES) {
            val k = 1f / BUTTERWORTH_Q[stage]
            val a1 = 1f / (1f + g * (g + k))
            lowA1[stage] = a1
            lowA2[stage] = g * a1
            lowA3[stage] = g * (g * a1)
        }
    }

    private fun updateHighCoefficients() {
        if (sampleRate <= 0) return
        val g = tan(Math.PI * usableCutoff(currentHighPassHz) / sampleRate).toFloat()
        for (stage in 0 until STAGES) {
            val k = 1f / BUTTERWORTH_Q[stage]
            val a1 = 1f / (1f + g * (g + k))
            highA1[stage] = a1
            highA2[stage] = g * a1
            highA3[stage] = g * (g * a1)
            highK[stage] = k
        }
    }

    private fun lowPass(channel: Int, input: Float): Float {
        var value = input
        for (stage in 0 until STAGES) {
            val i = (channel * STAGES + stage) * 2
            val ic1 = lowState[i]
            val ic2 = lowState[i + 1]
            val v3 = value - ic2
            val v1 = lowA1[stage] * ic1 + lowA2[stage] * v3
            val v2 = ic2 + lowA2[stage] * ic1 + lowA3[stage] * v3
            lowState[i] = 2f * v1 - ic1
            lowState[i + 1] = 2f * v2 - ic2
            value = v2
        }
        return value
    }

    private fun highPass(channel: Int, input: Float): Float {
        var value = input
        for (stage in 0 until STAGES) {
            val i = (channel * STAGES + stage) * 2
            val ic1 = highState[i]
            val ic2 = highState[i + 1]
            val v3 = value - ic2
            val v1 = highA1[stage] * ic1 + highA2[stage] * v3
            val v2 = ic2 + highA2[stage] * ic1 + highA3[stage] * v3
            highState[i] = 2f * v1 - ic1
            highState[i + 1] = 2f * v2 - ic2
            value -= highK[stage] * v1 + v2
        }
        return value
    }

    companion object {
        private const val TAG = "VibraMusicTransitionFilter"

        /** A low-pass at or above this is doing nothing audible, so it counts as off. */
        const val OPEN_HZ = 20_000f

        /** A high-pass at or below this is doing nothing audible, so it counts as off. */
        const val OFF_HZ = 20f

        /** Nothing musical wants the low end lifted above this, and a typo shouldn't be able to. */
        const val MAX_HIGH_PASS_HZ = 10_000f

        private const val MIN_HZ = 10f
        private const val BYTES_PER_SAMPLE = 2

        /** Two cascaded second-order sections: 24 dB/octave, the usual DJ-filter slope. */
        private const val STAGES = 2

        /** Section Qs for a maximally flat (Butterworth) fourth-order response. */
        private val BUTTERWORTH_Q = floatArrayOf(0.54120f, 1.30656f)

        /** Frames between coefficient updates. ~1.5 ms at 44.1 kHz. */
        private const val GLIDE_FRAMES = 64

        /** Per-sub-block glide fraction. ~30 ms time constant, just under one fade tick. */
        private const val GLIDE_RATE = 0.05f

        /** How close to a parked value counts as parked, so a glide terminates. */
        private const val SETTLED_HZ = 1f

        /** Keeps `tan` away from its pole at Nyquist. */
        private const val MAX_CUTOFF_FRACTION = 0.45f
    }
}

/**
 * The two filters a transition rides: one over the track arriving, one over the
 * track leaving.
 *
 * An interface rather than the processors themselves so [CrossfadeController]
 * stays testable without an audio sink, and so it never has to know that
 * "incoming" and "outgoing" are two different ExoPlayers whose roles swap at the
 * lap.
 */
interface TransitionFilters {
    /** The track fading up — the session player, once the lap has handed the queue over. */
    fun incoming(lowPassHz: Float, highPassHz: Float)

    /** The track fading out — the ghost player. */
    fun outgoing(lowPassHz: Float, highPassHz: Float)

    /** Per-track EQ adjustments for incoming track during transition. Default no-op. */
    fun incomingEq(bassDb: Float = 0f, midDb: Float = 0f, trebleDb: Float = 0f) = Unit

    /** Per-track EQ adjustments for outgoing track during transition. Default no-op. */
    fun outgoingEq(bassDb: Float = 0f, midDb: Float = 0f, trebleDb: Float = 0f) = Unit

    /** Spatial effect adjustments for outgoing track during transition. Default no-op. */
    fun outgoingEffect(type: EffectType?, wet: Float, echoBeats: Float? = null, bpm: Float = 120f) = Unit

    /** Spatial effect adjustments for incoming track during transition. Default no-op. */
    fun incomingEffect(type: EffectType?, wet: Float, echoBeats: Float? = null, bpm: Float = 120f) = Unit

    /** Parks both filters and restores flat transition EQ and neutral effects. Called whenever a transition ends. */
    fun open() {
        incoming(TransitionFilterProcessor.OPEN_HZ, TransitionFilterProcessor.OFF_HZ)
        outgoing(TransitionFilterProcessor.OPEN_HZ, TransitionFilterProcessor.OFF_HZ)
        incomingEq(0f, 0f, 0f)
        outgoingEq(0f, 0f, 0f)
        outgoingEffect(null, 0f)
        incomingEffect(null, 0f)
    }

    /** For callers with no audio sink to filter — tests, and the default wiring. */
    object None : TransitionFilters {
        override fun incoming(lowPassHz: Float, highPassHz: Float) = Unit
        override fun outgoing(lowPassHz: Float, highPassHz: Float) = Unit
        override fun incomingEq(bassDb: Float, midDb: Float, trebleDb: Float) = Unit
        override fun outgoingEq(bassDb: Float, midDb: Float, trebleDb: Float) = Unit
        override fun outgoingEffect(type: EffectType?, wet: Float, echoBeats: Float?, bpm: Float) = Unit
        override fun incomingEffect(type: EffectType?, wet: Float, echoBeats: Float?, bpm: Float) = Unit
    }
}
