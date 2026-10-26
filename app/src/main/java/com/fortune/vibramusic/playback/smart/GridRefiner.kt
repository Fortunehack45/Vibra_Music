/*
 * Copyright (C) 2026 Vibra Music
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.fortune.vibramusic.playback.smart

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * High-precision beat grid refiner for Spotify-parity transition alignment.
 *
 * Solves the 20ms quantization limitation of Beat This! (50 fps frame output)
 * by combining:
 * 1. Theil-Sen robust linear regression across 8-16 bar windows to estimate
 *    sub-millisecond tempo period and anchor phase.
 * 2. Circular phase estimation to naturally handle missing/dropped beats.
 * 3. Low-band transient envelope peak alignment within +/-30ms search windows
 *    at <= 2ms hop size.
 * 4. Outlier rejection to eliminate missed/spurious detections.
 * 5. Per-beat confidence tracking and encoder priming offset compensation.
 */
object GridRefiner {

    /** Default encoder priming compensation in seconds. */
    const val DEFAULT_OPUS_PRIMING_SECONDS = 0.0065 // 312 samples at 48kHz
    const val DEFAULT_AAC_PRIMING_SECONDS = 0.0213  // 1024 samples at 48kHz

    data class RefinedGrid(
        val beats: List<Double>,
        val downbeats: List<Double>,
        val bpm: Double,
        val beatInterval: Double,
        val firstBeat: Double,
        val beatConfidence: Double,
        val perBeatConfidences: List<Double>,
        val isSteadyTempo: Boolean,
        val tempoStability: Double,
        val gridSource: String = "refined_model",
    )

    /**
     * Refines a candidate list of beat times using robust period estimation,
     * circular phase unrolling, and local transient envelope peak finding.
     *
     * @param rawBeats Initial detected beat timestamps in seconds.
     * @param downbeats Candidate downbeat timestamps in seconds.
     * @param lowBandEnvelope Optional low-band (<150Hz) energy or onset envelope.
     * @param envelopeSampleRate Sample rate of the envelope signal (e.g. 500 Hz = 2ms hop).
     * @param encoderPrimingOffsetSec Known container encoder delay to subtract.
     */
    fun refine(
        rawBeats: List<Double>,
        downbeats: List<Double> = emptyList(),
        lowBandEnvelope: FloatArray? = null,
        envelopeSampleRate: Int = 500,
        encoderPrimingOffsetSec: Double = 0.0,
    ): RefinedGrid {
        if (rawBeats.size < 4) {
            val bpm = if (rawBeats.size >= 2) 60.0 / (rawBeats[1] - rawBeats[0]).coerceAtLeast(0.1) else 120.0
            return RefinedGrid(
                beats = rawBeats,
                downbeats = downbeats,
                bpm = bpm,
                beatInterval = 60.0 / bpm,
                firstBeat = rawBeats.firstOrNull() ?: 0.0,
                beatConfidence = 0.2,
                perBeatConfidences = List(rawBeats.size) { 0.2 },
                isSteadyTempo = false,
                tempoStability = 0.5,
                gridSource = "raw_fallback",
            )
        }

        // 1. Compensate for encoder priming if present
        val primedBeats = if (encoderPrimingOffsetSec != 0.0) {
            rawBeats.map { max(0.0, it - encoderPrimingOffsetSec) }
        } else {
            rawBeats
        }

        // 2. Theil-Sen robust estimator for beat interval
        val gaps = ArrayList<Double>()
        for (i in 0 until primedBeats.size - 1) {
            val step = primedBeats[i + 1] - primedBeats[i]
            if (step > 0.2 && step < 2.0) {
                gaps.add(step)
            }
        }
        val medianGap = if (gaps.isNotEmpty()) {
            gaps.sorted()[gaps.size / 2]
        } else 0.5

        // Multi-span slope estimates to be immune to missing beats
        val slopes = ArrayList<Double>()
        val maxSpan = min(16, primedBeats.size - 1)
        for (span in 1..maxSpan) {
            for (i in 0 until primedBeats.size - span) {
                val spanDiff = primedBeats[i + span] - primedBeats[i]
                val expectedSteps = (spanDiff / medianGap).roundToInt()
                if (expectedSteps in 1..16) {
                    slopes.add(spanDiff / expectedSteps)
                }
            }
        }

        val robustInterval = if (slopes.isNotEmpty()) {
            slopes.sorted()[slopes.size / 2]
        } else medianGap

        // 3. Circular phase estimation to handle missing beats and find robust anchor t0
        // Phase angle theta_i = 2 * PI * (t_i / T) mod 2*PI
        var sumSin = 0.0
        var sumCos = 0.0
        for (t in primedBeats) {
            val angle = 2.0 * PI * (t / robustInterval)
            sumSin += sin(angle)
            sumCos += cos(angle)
        }
        val meanAngle = atan2(sumSin, sumCos)
        val normalizedAngle = if (meanAngle < 0) meanAngle + 2.0 * PI else meanAngle
        val circularPhase = (normalizedAngle / (2.0 * PI)) * robustInterval

        // Find the earliest beat anchor closest to primedBeats.first()
        val firstCandidate = primedBeats.first()
        val k0 = ((firstCandidate - circularPhase) / robustInterval).roundToInt()
        val robustT0 = circularPhase + k0 * robustInterval

        // 4. Map each beat to its true integer beat index k_i
        var inlierCount = 0
        val beatIndices = primedBeats.map { t ->
            val k = ((t - robustT0) / robustInterval).roundToInt()
            val predicted = robustT0 + k * robustInterval
            val err = abs(t - predicted)
            if (err <= robustInterval * 0.15) {
                inlierCount++
            }
            k
        }

        val inlierRatio = inlierCount.toDouble() / primedBeats.size
        val isSteady = inlierRatio >= 0.80
        val tempoStability = (inlierRatio * 0.95).coerceIn(0.1, 0.99)

        // 5. Transient peak refinement if low-band envelope is provided
        val refinedBeats = ArrayList<Double>()
        val perBeatConfidences = ArrayList<Double>()

        for (i in primedBeats.indices) {
            val k = beatIndices[i]
            val nominalTime = if (isSteady) {
                robustT0 + k * robustInterval
            } else {
                primedBeats[i]
            }

            var refinedTime = nominalTime
            var confidence = if (isSteady) 0.92 else 0.70

            if (lowBandEnvelope != null && lowBandEnvelope.isNotEmpty()) {
                val peak = findLocalPeak(
                    envelope = lowBandEnvelope,
                    centerSec = nominalTime,
                    searchRadiusSec = 0.030, // +/- 30 ms
                    sampleRate = envelopeSampleRate,
                )
                if (peak != null) {
                    refinedTime = peak.timeSec
                    confidence = min(0.98, confidence + 0.06)
                }
            }

            refinedBeats.add(refinedTime)
            perBeatConfidences.add(confidence)
        }

        val finalBpm = 60.0 / robustInterval
        val avgConfidence = perBeatConfidences.average().coerceIn(0.1, 0.98)

        // Align candidate downbeats to closest refined beats
        val finalDownbeats = if (downbeats.isNotEmpty()) {
            downbeats.map { db ->
                refinedBeats.minByOrNull { abs(it - db) } ?: db
            }.distinct().sorted()
        } else {
            refinedBeats.filterIndexed { index, _ -> index % 4 == 0 }
        }

        return RefinedGrid(
            beats = refinedBeats,
            downbeats = finalDownbeats,
            bpm = finalBpm,
            beatInterval = robustInterval,
            firstBeat = refinedBeats.first(),
            beatConfidence = avgConfidence,
            perBeatConfidences = perBeatConfidences,
            isSteadyTempo = isSteady,
            tempoStability = tempoStability,
            gridSource = if (isSteady) "refined_theil_sen" else "warp_map",
        )
    }

    private data class PeakResult(val timeSec: Double, val amplitude: Float)

    /**
     * Finds the maximum transient peak in an energy envelope around [centerSec]
     * within [searchRadiusSec] using parabolic sub-sample refinement.
     */
    private fun findLocalPeak(
        envelope: FloatArray,
        centerSec: Double,
        searchRadiusSec: Double,
        sampleRate: Int,
    ): PeakResult? {
        val centerIdx = (centerSec * sampleRate).toInt()
        val radiusSamples = (searchRadiusSec * sampleRate).toInt().coerceAtLeast(1)

        val startIdx = max(1, centerIdx - radiusSamples)
        val endIdx = min(envelope.size - 2, centerIdx + radiusSamples)
        if (startIdx >= endIdx) return null

        var bestIdx = -1
        var maxAmp = 0f
        for (i in startIdx..endIdx) {
            val v = envelope[i]
            if (v > maxAmp && v > envelope[i - 1] && v > envelope[i + 1]) {
                maxAmp = v
                bestIdx = i
            }
        }

        if (bestIdx == -1) return null

        // Parabolic interpolation around peak
        val left = envelope[bestIdx - 1].toDouble()
        val center = envelope[bestIdx].toDouble()
        val right = envelope[bestIdx + 1].toDouble()
        val denom = left - 2 * center + right
        val offset = if (abs(denom) > 1e-9) {
            (0.5 * (left - right) / denom).coerceIn(-0.5, 0.5)
        } else 0.0

        val exactSample = bestIdx + offset
        val timeSec = exactSample / sampleRate.toDouble()
        return PeakResult(timeSec, maxAmp)
    }
}
