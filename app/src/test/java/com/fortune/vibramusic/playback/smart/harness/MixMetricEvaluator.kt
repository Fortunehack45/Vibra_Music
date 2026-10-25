package com.fortune.vibramusic.playback.smart.harness

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * Objective DSP metric evaluator for audio transitions.
 * Measures kick-grid tempo, phase error, double-kick artifacts, bar alignment,
 * loudness dip/bump, true peak, and click discontinuities.
 */
object MixMetricEvaluator {

    data class TransitionMetrics(
        val deckATempoBpm: Double,
        val deckBTempoBpm: Double,
        val mixedTempoBpm: Double,
        val kickPhaseOffsetMedianMs: Double,
        val kickPhaseOffsetP95Ms: Double,
        val doubleKickCount: Int,
        val doubleKickTimesSec: List<Double>,
        val downbeatBarOffsetBeats: Double,
        val midpointDipDb: Double,
        val truePeakDb: Double,
        val hasClipping: Boolean,
        val clickDiscontinuityCount: Int,
    )

    /**
     * Evaluates a rendered transition given the dry stems and the mixed output.
     */
    fun evaluate(
        deckA: FloatArray,
        deckB: FloatArray,
        mixed: FloatArray,
        overlapStartSec: Double,
        overlapEndSec: Double,
        sampleRate: Int = 44100,
        expectedBpmA: Double = 115.0,
        expectedBpmB: Double = 115.0,
        beatsPerBar: Int = 4,
    ): TransitionMetrics {
        // 1. Detect kick onsets in low band (< 150 Hz) for all three signals
        val kicksA = detectKickOnsets(deckA, sampleRate)
        val kicksB = detectKickOnsets(deckB, sampleRate)
        val kicksMixed = detectKickOnsets(mixed, sampleRate)

        // 2. Measure tempo
        val tempoA = estimateTempoFromOnsets(kicksA)
        val tempoB = estimateTempoFromOnsets(kicksB)
        val tempoMixed = estimateTempoFromOnsets(kicksMixed)

        // 3. Kick phase offset inside overlap window
        val overlapKicksA = kicksA.filter { it in overlapStartSec..overlapEndSec }
        val overlapKicksB = kicksB.filter { it in overlapStartSec..overlapEndSec }

        val phaseOffsetsMs = mutableListOf<Double>()
        for (kB in overlapKicksB) {
            val nearestA = overlapKicksA.minByOrNull { abs(it - kB) }
            if (nearestA != null) {
                val diffMs = abs(kB - nearestA) * 1000.0
                phaseOffsetsMs.add(diffMs)
            }
        }
        val medianPhaseMs = if (phaseOffsetsMs.isNotEmpty()) {
            val sorted = phaseOffsetsMs.sorted()
            sorted[sorted.size / 2]
        } else 0.0

        val p95PhaseMs = if (phaseOffsetsMs.isNotEmpty()) {
            val sorted = phaseOffsetsMs.sorted()
            val idx = (sorted.size * 0.95).toInt().coerceAtMost(sorted.size - 1)
            sorted[idx]
        } else 0.0

        // 4. Double-kick / Flam detection in mixed output
        // An onset in mixed output is a "double kick" if it lands in the overlap window
        // with an inter-onset interval < 70% of the nominal beat period, indicating flamming.
        val overlapKicksMixed = kicksMixed.filter { it in overlapStartSec..overlapEndSec }
        val doubleKickTimes = mutableListOf<Double>()
        val nominalBeatSec = 60.0 / expectedBpmA
        val minIntervalSec = nominalBeatSec * 0.70

        for (i in 1 until overlapKicksMixed.size) {
            val interval = overlapKicksMixed[i] - overlapKicksMixed[i - 1]
            if (interval in 0.040..minIntervalSec) {
                doubleKickTimes.add(overlapKicksMixed[i])
            }
        }

        // 5. Downbeat alignment (bar-position error in beats)
        val downbeatBarOffsetBeats = if (overlapKicksA.isNotEmpty() && overlapKicksB.isNotEmpty()) {
            val firstB = overlapKicksB.first()
            val nearestA = overlapKicksA.minByOrNull { abs(it - firstB) } ?: overlapKicksA.first()
            val beatError = abs(firstB - nearestA) / nominalBeatSec
            beatError % beatsPerBar
        } else 0.0

        // 6. Loudness & True Peak & Midpoint Dip
        val overlapStartSample = (overlapStartSec * sampleRate).toInt().coerceIn(0, mixed.size)
        val overlapEndSample = (overlapEndSec * sampleRate).toInt().coerceIn(0, mixed.size)
        val midpointSample = (overlapStartSample + overlapEndSample) / 2
        val windowSize = (sampleRate * 0.40).toInt() // 400ms window

        val nominalRmsA = computeRms(deckA, max(0, overlapStartSample - windowSize), overlapStartSample)
        val midpointRms = computeRms(
            mixed,
            max(0, midpointSample - windowSize / 2),
            min(mixed.size, midpointSample + windowSize / 2),
        )

        val midpointDipDb = if (nominalRmsA > 1e-5 && midpointRms > 1e-5) {
            20.0 * log10(midpointRms / nominalRmsA)
        } else 0.0

        var maxAbs = 0f
        var hasClipping = false
        for (i in overlapStartSample until overlapEndSample) {
            val s = abs(mixed[i])
            if (s > maxAbs) maxAbs = s
            if (s > 0.999f) hasClipping = true
        }
        val truePeakDb = if (maxAbs > 1e-5) 20.0 * log10(maxAbs.toDouble()) else -96.0

        // 7. Click / Discontinuity detector
        var clickCount = 0
        for (i in 1 until mixed.size) {
            val delta = abs(mixed[i] - mixed[i - 1])
            if (delta > 0.40f) {
                clickCount++
            }
        }

        return TransitionMetrics(
            deckATempoBpm = tempoA,
            deckBTempoBpm = tempoB,
            mixedTempoBpm = tempoMixed,
            kickPhaseOffsetMedianMs = medianPhaseMs,
            kickPhaseOffsetP95Ms = p95PhaseMs,
            doubleKickCount = doubleKickTimes.size,
            doubleKickTimesSec = doubleKickTimes,
            downbeatBarOffsetBeats = downbeatBarOffsetBeats,
            midpointDipDb = midpointDipDb,
            truePeakDb = truePeakDb,
            hasClipping = hasClipping,
            clickDiscontinuityCount = clickCount,
        )
    }

    /**
     * Detects kick drum onsets using a 2nd-order Butterworth low-pass filter (150 Hz)
     * and energy derivative thresholding.
     */
    fun detectKickOnsets(samples: FloatArray, sampleRate: Int): List<Double> {
        val filtered = lowPassFilter150Hz(samples, sampleRate)
        val onsets = mutableListOf<Double>()

        val frameSize = (sampleRate * 0.010).toInt() // 10ms frame
        val hopSize = (sampleRate * 0.005).toInt()   // 5ms hop
        val numFrames = (filtered.size - frameSize) / hopSize
        if (numFrames <= 0) return emptyList()

        val energies = DoubleArray(numFrames)
        for (f in 0 until numFrames) {
            var sumSq = 0.0
            val offset = f * hopSize
            for (i in 0 until frameSize) {
                val s = filtered[offset + i]
                sumSq += s * s
            }
            energies[f] = sqrt(sumSq / frameSize)
        }

        // Adaptive peak picking on energy derivative
        val minDistanceFrames = (0.22 / 0.005).toInt() // minimum 220ms between kicks
        var lastPeakFrame = -minDistanceFrames
        val threshold = 0.08

        for (f in 1 until numFrames - 1) {
            val diff = energies[f] - energies[f - 1]
            if (diff > threshold && energies[f] > energies[f + 1] && (f - lastPeakFrame) >= minDistanceFrames) {
                lastPeakFrame = f
                val timeSec = (f * hopSize).toDouble() / sampleRate
                onsets.add(timeSec)
            }
        }

        return onsets
    }

    /**
     * 2nd-order Butterworth lowpass filter at 150 Hz.
     */
    private fun lowPassFilter150Hz(input: FloatArray, sampleRate: Int): FloatArray {
        val output = FloatArray(input.size)
        val cutoff = 150.0
        val w0 = 2.0 * PI * cutoff / sampleRate
        val cosW0 = kotlin.math.cos(w0)
        val sinW0 = kotlin.math.sin(w0)
        val alpha = sinW0 / (2.0 * 0.7071) // Q = 0.7071

        val b0 = (1.0 - cosW0) / 2.0
        val b1 = 1.0 - cosW0
        val b2 = (1.0 - cosW0) / 2.0
        val a0 = 1.0 + alpha
        val a1 = -2.0 * cosW0
        val a2 = 1.0 - alpha

        var x1 = 0f; var x2 = 0f
        var y1 = 0f; var y2 = 0f

        val invA0 = 1.0f / a0.toFloat()
        val b0_a0 = (b0 * invA0).toFloat()
        val b1_a0 = (b1 * invA0).toFloat()
        val b2_a0 = (b2 * invA0).toFloat()
        val a1_a0 = (a1 * invA0).toFloat()
        val a2_a0 = (a2 * invA0).toFloat()

        for (i in input.indices) {
            val x0 = input[i]
            val y0 = b0_a0 * x0 + b1_a0 * x1 + b2_a0 * x2 - a1_a0 * y1 - a2_a0 * y2
            output[i] = y0

            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }

        return output
    }

    private fun estimateTempoFromOnsets(onsets: List<Double>): Double {
        if (onsets.size < 2) return 0.0
        val intervals = mutableListOf<Double>()
        for (i in 1 until onsets.size) {
            val dt = onsets[i] - onsets[i - 1]
            if (dt in 0.30..1.20) { // 50 to 200 BPM
                intervals.add(dt)
            }
        }
        if (intervals.isEmpty()) return 0.0
        val sorted = intervals.sorted()
        val medianDt = sorted[sorted.size / 2]
        return if (medianDt > 0) 60.0 / medianDt else 0.0
    }

    private fun computeRms(samples: FloatArray, start: Int, end: Int): Double {
        val s = start.coerceIn(0, samples.size)
        val e = end.coerceIn(0, samples.size)
        if (e <= s) return 0.0
        var sumSq = 0.0
        for (i in s until e) {
            val v = samples[i]
            sumSq += v * v
        }
        return sqrt(sumSq / (e - s))
    }
}
