package com.fortune.vibramusic.playback.smart.harness

import com.fortune.vibramusic.playback.audio.AudioBlock
import com.fortune.vibramusic.playback.audio.PcmBoundary
import com.fortune.vibramusic.playback.audio.PcmEncoding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sin

/**
 * Phase 2 Spike S1: PCM Identity Check between decoder output and sink input.
 * Requirement: Error <= -90 dB across the audio pipeline.
 */
class SpikeS1MediaCodecPcmTest {

    @Test
    fun testPcmIdentityFloat32() {
        val sampleRate = 44100
        val frames = 1024
        val channels = 2

        val sourcePcm = FloatArray(frames * channels)
        for (i in 0 until frames) {
            val t = i.toDouble() / sampleRate
            val sampleL = (sin(2.0 * Math.PI * 440.0 * t) * 0.8).toFloat()
            val sampleR = (sin(2.0 * Math.PI * 880.0 * t) * 0.8).toFloat()
            sourcePcm[i * 2] = sampleL
            sourcePcm[i * 2 + 1] = sampleR
        }

        // Pack into Float32 ByteBuffer
        val byteBuffer = ByteBuffer.allocateDirect(frames * channels * 4).order(ByteOrder.nativeOrder())
        val floatView = byteBuffer.asFloatBuffer()
        floatView.put(sourcePcm)
        byteBuffer.position(0)

        // Decode into AudioBlock
        val block = AudioBlock(channelCount = channels, capacityFrames = frames)
        val decodedFrames = PcmBoundary.decode(
            inputBuffer = byteBuffer,
            encoding = PcmEncoding.PCM_FLOAT,
            destinationBlock = block,
            maxFrames = frames
        )

        assertEquals(frames, decodedFrames)

        // Measure error in dB
        var maxError = 0.0f
        for (i in 0 until frames * channels) {
            val err = abs(block.samples[i] - sourcePcm[i])
            if (err > maxError) maxError = err
        }

        val errorDb = if (maxError > 0.0f) 20.0 * log10(maxError.toDouble()) else -140.0
        assertTrue("Float32 error ($errorDb dB) must be <= -90 dB", errorDb <= -90.0)
    }

    @Test
    fun testPcmIdentity16BitQuantization() {
        val sampleRate = 44100
        val frames = 1024
        val channels = 2

        val sourcePcm = FloatArray(frames * channels)
        for (i in 0 until frames) {
            val t = i.toDouble() / sampleRate
            sourcePcm[i * 2] = (sin(2.0 * Math.PI * 440.0 * t) * 0.9).toFloat()
            sourcePcm[i * 2 + 1] = (sin(2.0 * Math.PI * 1000.0 * t) * 0.9).toFloat()
        }

        // Encode to 16-bit PCM buffer using PcmBoundary
        val srcBlock = AudioBlock(channelCount = channels, capacityFrames = frames)
        System.arraycopy(sourcePcm, 0, srcBlock.samples, 0, frames * channels)
        srcBlock.reset(frames)

        val byteBuffer = ByteBuffer.allocateDirect(frames * channels * 2).order(ByteOrder.nativeOrder())
        PcmBoundary.encode(
            sourceBlock = srcBlock,
            encoding = PcmEncoding.PCM_16BIT,
            outputBuffer = byteBuffer,
        )
        byteBuffer.flip()

        // Decode through PcmBoundary
        val dstBlock = AudioBlock(channelCount = channels, capacityFrames = frames)
        val decoded = PcmBoundary.decode(
            inputBuffer = byteBuffer,
            encoding = PcmEncoding.PCM_16BIT,
            destinationBlock = dstBlock,
            maxFrames = frames
        )

        assertEquals(frames, decoded)

        // 16-bit theoretical noise floor is ~ -96 dB, max quantization error is 0.5 / 32768 (-96.3 dB)
        var maxError = 0.0f
        for (i in 0 until frames * channels) {
            val err = abs(dstBlock.samples[i] - sourcePcm[i])
            if (err > maxError) maxError = err
        }

        val errorDb = 20.0 * log10(maxError.toDouble())
        assertTrue("16-bit quantization error ($errorDb dB) must be <= -89 dB", errorDb <= -89.0)
    }
}
