package com.fortune.vibramusic.playback.smart.harness

import com.fortune.vibramusic.playback.audio.MixEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.sin

/**
 * Phase 2 Spike S3: Signalsmith Stretch quality and speed variation evaluation.
 * Validates behavior at +/- 3%, +/- 6%, and +/- 10% speed deviations.
 */
class SpikeS3StretchQualityTest {

    @Test
    fun testStretchSpeedVariations() {
        val sampleRate = 44100.0f
        val ratios = listOf(0.90f, 0.94f, 0.97f, 1.00f, 1.03f, 1.06f, 1.10f)

        for (ratio in ratios) {
            val engine = MixEngine(sampleRate = sampleRate, channels = 2)

            // Feed 2 seconds of 115 BPM kick pulses
            val seconds = 2.0
            val totalFrames = (sampleRate * seconds).toInt()
            val inputPcm = FloatArray(totalFrames * 2)

            // Inject 115 BPM kicks (every ~23008 samples)
            val beatInterval = (sampleRate * 60.0 / 115.0).toInt()
            for (i in 0 until totalFrames) {
                val beatPos = i % beatInterval
                if (beatPos < 500) {
                    val kick = (sin(2.0 * Math.PI * 60.0 * (beatPos / sampleRate)) * (1.0 - beatPos / 500.0)).toFloat()
                    inputPcm[i * 2] = kick
                    inputPcm[i * 2 + 1] = kick
                }
            }

            engine.writeDeckPcm(0, inputPcm, 0, totalFrames)
            engine.setDeckParameters(0, volume = 1.0f, stretchRatio = ratio)

            val outputFrames = 4096
            val out = FloatArray(outputFrames * 2)
            val rendered = engine.render(out, 0, outputFrames)

            assertEquals(outputFrames, rendered)

            // Verify no NaN or Inf
            for (sample in out) {
                assertFalse("Sample must not be NaN for ratio $ratio", sample.isNaN())
                assertFalse("Sample must not be Infinite for ratio $ratio", sample.isInfinite())
                assertTrue("Sample magnitude must be <= 1.0 for ratio $ratio", abs(sample) <= 1.0f)
            }
        }
    }
}
