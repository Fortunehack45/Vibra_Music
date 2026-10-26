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

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.round

class GridRefinerTest {

    @Test
    fun testSyntheticGridRefinementSubMillisecondAccuracy() {
        val testBpms = listOf(100.0, 115.0, 128.0)
        for (bpm in testBpms) {
            val trueInterval = 60.0 / bpm
            val trueT0 = 0.125 // 125 ms initial downbeat

            // Simulate raw model output with 20ms frame quantization noise
            val rawBeats = mutableListOf<Double>()
            for (i in 0 until 32) { // 32 beats = 8 bars
                val exactTime = trueT0 + i * trueInterval
                // Quantize to 50 fps (20ms nearest frame)
                val quantized = round(exactTime * 50.0) / 50.0
                rawBeats.add(quantized)
            }

            val refined = GridRefiner.refine(rawBeats)

            val intervalErrorMs = abs(refined.beatInterval - trueInterval) * 1000.0
            val t0ErrorMs = abs(refined.firstBeat - trueT0) * 1000.0

            // Theil-Sen recovers tempo interval to sub-millisecond precision even from 20ms quantized frames
            assertTrue("Period error must be <= 0.5 ms (was ${intervalErrorMs}ms at $bpm BPM)", intervalErrorMs <= 0.5)
            // Raw 20ms frame quantization without envelope has worst-case bound of half a frame (10 ms)
            assertTrue("Raw anchor offset error must be <= 10.0 ms (was ${t0ErrorMs}ms at $bpm BPM)", t0ErrorMs <= 10.0)
            assertTrue("Steady tempo must be detected", refined.isSteadyTempo)
            assertTrue("Confidence must be >= 0.85 (was ${refined.beatConfidence})", refined.beatConfidence >= 0.85)
        }
    }

    @Test
    fun testOutlierRejectionWithMissingAndJitteredBeats() {
        val bpm = 115.0
        val trueInterval = 60.0 / bpm
        val trueT0 = 0.200

        val rawBeats = mutableListOf<Double>()
        for (i in 0 until 32) {
            if (i == 7 || i == 21) continue // 2 missing beats
            val exactTime = trueT0 + i * trueInterval
            val jitter = if (i % 3 == 0) 0.015 else -0.012 // +/-15ms jitter
            rawBeats.add(exactTime + jitter)
        }

        val refined = GridRefiner.refine(rawBeats)

        val intervalErrorMs = abs(refined.beatInterval - trueInterval) * 1000.0
        assertTrue("Interval error with missing beats must be <= 0.5 ms (was ${intervalErrorMs}ms)", intervalErrorMs <= 0.5)
        assertTrue("Steady tempo must still be identified", refined.isSteadyTempo)
    }

    @Test
    fun testBeatFMeasureOnSyntheticFixtures() {
        val bpm = 115.0
        val trueInterval = 60.0 / bpm
        val trueT0 = 0.100 // 100 ms falls on exact 50fps boundary (frame 5)

        val groundTruth = (0 until 32).map { trueT0 + it * trueInterval }
        // Quantized 50 fps input
        val rawInput = groundTruth.map { round(it * 50.0) / 50.0 }

        val refined = GridRefiner.refine(rawInput)

        // Count true positives within 3 ms tolerance window
        var truePositives = 0
        for (gt in groundTruth) {
            val closest = refined.beats.minByOrNull { abs(it - gt) }
            if (closest != null && abs(closest - gt) <= 0.003) { // 3 ms
                truePositives++
            }
        }

        val precision = truePositives.toDouble() / refined.beats.size
        val recall = truePositives.toDouble() / groundTruth.size
        val fMeasure = 2 * (precision * recall) / (precision + recall)

        assertTrue("F-measure must be >= 0.95 (was $fMeasure, precision=$precision, recall=$recall)", fMeasure >= 0.95)
    }

    @Test
    fun testEncoderPrimingCompensation() {
        val rawBeats = listOf(0.100, 0.621, 1.143, 1.665)
        val priming = 0.0213 // AAC priming ~21.3 ms

        val unprimed = GridRefiner.refine(rawBeats, encoderPrimingOffsetSec = 0.0)
        val primed = GridRefiner.refine(rawBeats, encoderPrimingOffsetSec = priming)

        val offsetDiff = unprimed.firstBeat - primed.firstBeat
        assertEquals(priming, offsetDiff, 0.0001)
    }

    @Test
    fun testTransientEnvelopePeakLockSubMillisecond() {
        val bpm = 120.0 // 0.5s per beat
        val sampleRate = 500 // 2ms hop envelope
        val envelopeLength = (5.0 * sampleRate).toInt()
        val envelope = FloatArray(envelopeLength)

        // Place sharp kick transient pulses at exact times: 0.504, 1.004, 1.504, 2.004...
        val exactKicks = listOf(0.504, 1.004, 1.504, 2.004, 2.504)
        for (kick in exactKicks) {
            val idx = (kick * sampleRate).toInt()
            envelope[idx - 1] = 0.4f
            envelope[idx] = 1.0f
            envelope[idx + 1] = 0.35f
        }

        // Quantized input at 20ms boundaries (0.500, 1.000, 1.500, 2.000, 2.500)
        val rawBeats = listOf(0.500, 1.000, 1.500, 2.000, 2.500)
        val refined = GridRefiner.refine(
            rawBeats = rawBeats,
            lowBandEnvelope = envelope,
            envelopeSampleRate = sampleRate,
        )

        for (i in exactKicks.indices) {
            val errorMs = abs(refined.beats[i] - exactKicks[i]) * 1000.0
            assertTrue("Refined beat $i must lock to exact kick within 1.0 ms (was ${errorMs}ms)", errorMs <= 1.0)
        }
    }
}
