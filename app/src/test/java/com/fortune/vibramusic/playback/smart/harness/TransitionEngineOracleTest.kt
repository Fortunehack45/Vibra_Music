package com.fortune.vibramusic.playback.smart.harness

import com.fortune.vibramusic.playback.audio.MixEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sin

/**
 * Phase 2 Oracle Test Suite for the Single-Clock Transition Engine.
 * Verifies M1 (Sample-accurate entry), M3 (Zero kick flams), M6 (Sum flatness), and M7 (Peak ceiling).
 */
class TransitionEngineOracleTest {

    @Test
    fun testSampleAccurateTriggerGating() {
        val sampleRate = 44100.0f
        val engine = MixEngine(sampleRate = sampleRate, channels = 2)

        val triggerOffsetFrames = 2048L

        // Deck 0: silent
        // Deck 1: constant 0.5f signal
        val testPcm = FloatArray(4096 * 2) { 0.5f }
        engine.writeDeckPcm(1, testPcm, 0, 4096)

        // Arm Deck 1 to trigger at frame 2048
        engine.armDeck(1, triggerOffsetFrames)

        val out = FloatArray(4096 * 2)
        engine.render(out, 0, 4096)

        // Frames 0 until 2048 should have no signal from Deck 1
        for (i in 0 until triggerOffsetFrames.toInt()) {
            assertEquals("Frame $i must be silent before gate trigger", 0.0f, out[i * 2], 1e-4f)
        }

        // Frames from 2048 onwards must have the signal from Deck 1
        var detectedSignalAfterTrigger = false
        for (i in triggerOffsetFrames.toInt() until 4096) {
            if (abs(out[i * 2]) > 0.05f) {
                detectedSignalAfterTrigger = true
                break
            }
        }
        assertTrue("Deck 1 signal must appear immediately after trigger frame", detectedSignalAfterTrigger)
    }

    @Test
    fun testLR4CrossoverSumFlatness() {
        val sampleRate = 44100.0f
        val engine = MixEngine(sampleRate = sampleRate, channels = 2)

        // Test frequencies covering sub-bass, crossover 1 (200 Hz), midrange, crossover 2 (2500 Hz), and treble
        val testFreqs = listOf(50.0, 100.0, 190.0, 200.0, 210.0, 500.0, 1000.0, 2400.0, 2500.0, 2600.0, 5000.0, 10000.0)

        for (freq in testFreqs) {
            val frames = 4096
            val inputPcm = FloatArray(frames * 2)
            for (i in 0 until frames) {
                val s = sin(2.0 * Math.PI * freq * (i / sampleRate)).toFloat() * 0.5f
                inputPcm[i * 2] = s
                inputPcm[i * 2 + 1] = s
            }

            engine.reset()
            engine.writeDeckPcm(0, inputPcm, 0, frames)
            engine.setDeckParameters(0, volume = 1.0f, lowGain = 1.0f, midGain = 1.0f, highGain = 1.0f)

            val out = FloatArray(frames * 2)
            engine.render(out, 0, frames)

            // Measure steady-state amplitude (skip initial filter settling frames)
            var maxIn = 0.0f
            var maxOut = 0.0f
            for (i in 1000 until frames) {
                maxIn = max(maxIn, abs(inputPcm[i * 2]))
                maxOut = max(maxOut, abs(out[i * 2]))
            }

            val gainDb = 20.0 * log10((maxOut / maxIn).toDouble())
            assertTrue(
                "LR4 3-band crossover sum at $freq Hz must be 0 dB +/- 0.15 dB (measured $gainDb dB)",
                abs(gainDb) <= 0.15
            )
        }
    }

    @Test
    fun testLookaheadLimiterCeiling() {
        val sampleRate = 44100.0f
        val engine = MixEngine(sampleRate = sampleRate, channels = 2)

        // Extreme overloaded signal: +6 dB (amplitude 2.0)
        val frames = 2048
        val overloadPcm = FloatArray(frames * 2) { 2.0f }

        engine.writeDeckPcm(0, overloadPcm, 0, frames)
        engine.setDeckParameters(0, volume = 1.0f)

        val out = FloatArray(frames * 2)
        engine.render(out, 0, frames)

        val ceiling = 0.94406f // -0.5 dBFS
        var truePeak = 0.0f
        for (s in out) {
            truePeak = max(truePeak, abs(s))
        }

        assertTrue("True peak ($truePeak) must not exceed ceiling $ceiling (-0.5 dBFS)", truePeak <= ceiling + 1e-4f)
    }

    @Test
    fun testZeroFlamHandoverOnMasterClock() {
        val sampleRate = 44100.0f
        val engine = MixEngine(sampleRate = sampleRate, channels = 2)

        val bpm = 115.0
        val beatFrames = (sampleRate * 60.0 / bpm).toInt() // 23008 frames
        val halfBeat = beatFrames / 2

        // Deck 0 plays kick on beat 0
        val deck0Pcm = FloatArray(beatFrames * 2)
        for (i in 0 until 500) {
            val kick = (sin(2.0 * Math.PI * 60.0 * (i / sampleRate)) * (1.0 - i / 500.0)).toFloat()
            deck0Pcm[i * 2] = kick
            deck0Pcm[i * 2 + 1] = kick
        }

        // Deck 1 plays kick on next beat (beat 1)
        val deck1Pcm = FloatArray(beatFrames * 2)
        for (i in 0 until 500) {
            val kick = (sin(2.0 * Math.PI * 60.0 * (i / sampleRate)) * (1.0 - i / 500.0)).toFloat()
            deck1Pcm[i * 2] = kick
            deck1Pcm[i * 2 + 1] = kick
        }

        engine.writeDeckPcm(0, deck0Pcm, 0, beatFrames)
        engine.writeDeckPcm(1, deck1Pcm, 0, beatFrames)

        // Arm Deck 1 exactly at beat 1 (beatFrames offset)
        engine.armDeck(1, beatFrames.toLong())

        val totalFrames = beatFrames * 2
        val mixedOut = FloatArray(totalFrames * 2)
        engine.render(mixedOut, 0, totalFrames)

        // Use Phase 0 MixMetricEvaluator to confirm 0 flams
        val monoPcm = FloatArray(totalFrames) { i -> (mixedOut[i * 2] + mixedOut[i * 2 + 1]) * 0.5f }
        val flams = MixMetricEvaluator.detectFlams(monoPcm, sampleRate.toInt(), bpm)

        assertEquals("Zero flams expected on single-clock handover", 0, flams)
    }
}
