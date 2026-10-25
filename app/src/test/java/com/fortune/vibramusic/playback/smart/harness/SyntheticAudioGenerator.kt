package com.fortune.vibramusic.playback.smart.harness

import com.fortune.vibramusic.playback.smart.LoudnessProfile
import com.fortune.vibramusic.playback.smart.MeterHypothesis
import com.fortune.vibramusic.playback.smart.TrackAnalysis
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin
import java.util.Random

/**
 * Procedural audio synthesizer for precision audio transition testing.
 * Generates 44.1 kHz PCM audio with kick, hi-hat, and bass transients at exact BPM, meter,
 * and phase configurations.
 */
object SyntheticAudioGenerator {

    const val DEFAULT_SAMPLE_RATE = 44100

    data class SyntheticTrack(
        val pcm: FloatArray,
        val sampleRate: Int,
        val bpm: Double,
        val beatsPerBar: Int,
        val phaseOffsetMs: Double,
        val durationSeconds: Double,
        val beatTimes: List<Double>,
        val downbeatTimes: List<Double>,
        val analysis: TrackAnalysis,
    )

    /**
     * Synthesizes a mono FloatArray audio signal with kick drum, hi-hat, and bass elements.
     */
    fun generateTrack(
        bpm: Double,
        beatsPerBar: Int = 4,
        durationSeconds: Double = 20.0,
        phaseOffsetMs: Double = 0.0,
        sampleRate: Int = DEFAULT_SAMPLE_RATE,
        seed: Long = 42L,
    ): SyntheticTrack {
        val totalSamples = (durationSeconds * sampleRate).toInt()
        val buffer = FloatArray(totalSamples)

        val beatInterval = 60.0 / bpm
        val phaseOffsetSec = phaseOffsetMs / 1000.0

        val beatTimes = mutableListOf<Double>()
        val downbeatTimes = mutableListOf<Double>()

        var currentBeat = 0
        var t = phaseOffsetSec
        while (t < durationSeconds) {
            if (t >= 0.0) {
                beatTimes.add(t)
                val isDownbeat = (currentBeat % beatsPerBar) == 0
                if (isDownbeat) {
                    downbeatTimes.add(t)
                }

                // Render Kick on every beat (louder on downbeat)
                val kickGain = if (isDownbeat) 1.0f else 0.85f
                renderKick(buffer, t, sampleRate, kickGain)

                // Render Hi-hat on every offbeat (halfway between beats)
                val offbeatTime = t + beatInterval * 0.5
                if (offbeatTime < durationSeconds) {
                    renderHiHat(buffer, offbeatTime, sampleRate, 0.4f, seed + currentBeat)
                }

                // Render bass note sustaining between beats
                renderBass(buffer, t, beatInterval * 0.7, sampleRate, 0.45f)
            }
            currentBeat++
            t = phaseOffsetSec + (currentBeat * beatInterval)
        }

        // Normalize buffer to -1 dBFS peak to avoid clipping
        var maxAmp = 0f
        for (s in buffer) {
            val a = kotlin.math.abs(s)
            if (a > maxAmp) maxAmp = a
        }
        if (maxAmp > 0.001f) {
            val scale = 0.891f / maxAmp // -1 dBFS peak
            for (i in buffer.indices) {
                buffer[i] = (buffer[i] * scale).coerceIn(-1.0f, 1.0f)
            }
        }

        val analysis = TrackAnalysis(
            status = TrackAnalysis.STATUS_READY,
            bpm = bpm,
            beatConfidence = 0.96,
            beats = beatTimes,
            downbeats = downbeatTimes,
            firstBeat = beatTimes.firstOrNull() ?: 0.0,
            duration = durationSeconds,
            contentEndTime = durationSeconds - 0.5,
            meter = MeterHypothesis(
                beatsPerBar = beatsPerBar,
                confidence = 0.95,
            ),
            key = "8B",
            keyConfidence = 0.90,
            loudness = LoudnessProfile(
                integratedLufs = -14.0,
                headShortTermLufs = -14.0,
                tailShortTermLufs = -14.0,
                truePeakDbfs = -1.0,
            ),
        )

        return SyntheticTrack(
            pcm = buffer,
            sampleRate = sampleRate,
            bpm = bpm,
            beatsPerBar = beatsPerBar,
            phaseOffsetMs = phaseOffsetMs,
            durationSeconds = durationSeconds,
            beatTimes = beatTimes,
            downbeatTimes = downbeatTimes,
            analysis = analysis,
        )
    }

    /**
     * Pitch-dropping sine wave kick transient (150 Hz -> 45 Hz with exponential decay).
     */
    private fun renderKick(buffer: FloatArray, startTimeSec: Double, sampleRate: Int, gain: Float) {
        val startSample = (startTimeSec * sampleRate).toInt()
        val durationSamples = (sampleRate * 0.18).toInt() // 180 ms kick
        val fStart = 150.0
        val fEnd = 45.0
        val pitchTau = 0.035
        val ampTau = 0.08

        var phase = 0.0
        for (i in 0 until durationSamples) {
            val idx = startSample + i
            if (idx >= buffer.size) break

            val t = i.toDouble() / sampleRate
            val freq = fEnd + (fStart - fEnd) * exp(-t / pitchTau)
            val dt = 1.0 / sampleRate
            phase += 2.0 * PI * freq * dt

            val envelope = exp(-t / ampTau)
            buffer[idx] += (sin(phase) * envelope * gain).toFloat()
        }
    }

    /**
     * High-frequency noise burst for hi-hat.
     */
    private fun renderHiHat(buffer: FloatArray, startTimeSec: Double, sampleRate: Int, gain: Float, seed: Long) {
        val startSample = (startTimeSec * sampleRate).toInt()
        val durationSamples = (sampleRate * 0.04).toInt() // 40 ms hat
        val random = Random(seed)

        var lastNoise = 0.0
        for (i in 0 until durationSamples) {
            val idx = startSample + i
            if (idx >= buffer.size) break

            val t = i.toDouble() / sampleRate
            val rawNoise = (random.nextFloat() * 2.0 - 1.0)
            // Highpass filter approximation: noise - lowpass(noise)
            val hp = rawNoise - lastNoise
            lastNoise = rawNoise * 0.3

            val envelope = exp(-t / 0.012)
            buffer[idx] += (hp * envelope * gain).toFloat()
        }
    }

    /**
     * Low sub-bass sine tone on the root note.
     */
    private fun renderBass(buffer: FloatArray, startTimeSec: Double, durationSec: Double, sampleRate: Int, gain: Float) {
        val startSample = (startTimeSec * sampleRate).toInt()
        val durationSamples = (sampleRate * durationSec).toInt()
        val bassFreq = 65.41 // C2

        for (i in 0 until durationSamples) {
            val idx = startSample + i
            if (idx >= buffer.size) break

            val t = i.toDouble() / sampleRate
            val envelope = (1.0 - (i.toDouble() / durationSamples)).coerceIn(0.0, 1.0)
            val bass = sin(2.0 * PI * bassFreq * t) * envelope * gain
            buffer[idx] += bass.toFloat()
        }
    }

    /**
     * Encodes a mono FloatArray to 16-bit PCM WAV byte stream.
     */
    fun encodeToWav(samples: FloatArray, sampleRate: Int = DEFAULT_SAMPLE_RATE): ByteArray {
        val out = ByteArrayOutputStream()
        val numChannels = 1
        val bitsPerSample = 16
        val byteRate = sampleRate * numChannels * (bitsPerSample / 8)
        val dataSize = samples.size * (bitsPerSample / 8)
        val chunkSize = 36 + dataSize

        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray())
        header.putInt(chunkSize)
        header.put("WAVE".toByteArray())
        header.put("fmt ".toByteArray())
        header.putInt(16) // Subchunk1Size (16 for PCM)
        header.putShort(1.toShort()) // AudioFormat (1 for PCM)
        header.putShort(numChannels.toShort())
        header.putInt(sampleRate)
        header.putInt(byteRate)
        header.putShort((numChannels * (bitsPerSample / 8)).toShort())
        header.putShort(bitsPerSample.toShort())
        header.put("data".toByteArray())
        header.putInt(dataSize)

        out.write(header.array())

        val pcmBuffer = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) {
            val clamped = s.coerceIn(-1.0f, 1.0f)
            val pcm16 = (clamped * 32767.0f).toInt().toShort()
            pcmBuffer.putShort(pcm16)
        }
        out.write(pcmBuffer.array())

        return out.toByteArray()
    }
}
