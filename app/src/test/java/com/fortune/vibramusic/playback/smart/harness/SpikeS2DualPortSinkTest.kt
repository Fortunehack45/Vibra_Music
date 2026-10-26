package com.fortune.vibramusic.playback.smart.harness

import com.fortune.vibramusic.playback.audio.MixEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Phase 2 Spike S2: Dual-port AudioSink capacity verification.
 * Validates concurrent feeding of Deck 0 and Deck 1 without buffer underruns,
 * confirming backpressure behavior when capacity is reached.
 */
class SpikeS2DualPortSinkTest {

    @Test
    fun testDualPortConcurrentIngestion() {
        val sampleRate = 44100.0f
        val engine = MixEngine(sampleRate = sampleRate, channels = 2)

        val blockSize = 512
        val deck0Pcm = FloatArray(blockSize * 2) { 0.5f }
        val deck1Pcm = FloatArray(blockSize * 2) { -0.5f }

        // Write 1 second into Deck 0 and Deck 1
        val blocks = (sampleRate / blockSize).toInt()
        var deck0TotalWritten = 0
        var deck1TotalWritten = 0

        for (b in 0 until blocks) {
            deck0TotalWritten += engine.writeDeckPcm(0, deck0Pcm, 0, blockSize)
            deck1TotalWritten += engine.writeDeckPcm(1, deck1Pcm, 0, blockSize)
        }

        assertEquals(blocks * blockSize, deck0TotalWritten)
        assertEquals(blocks * blockSize, deck1TotalWritten)
        assertEquals(deck0TotalWritten, engine.getDeckBufferedFrames(0))
        assertEquals(deck1TotalWritten, engine.getDeckBufferedFrames(1))

        // Render audio and verify both decks are mixed
        val output = FloatArray(blockSize * 2)
        val rendered = engine.render(output, 0, blockSize)

        assertEquals(blockSize, rendered)
        assertEquals(deck0TotalWritten - blockSize, engine.getDeckBufferedFrames(0))
    }

    @Test
    fun testBackpressureOnBufferFull() {
        val sampleRate = 44100.0f
        val engine = MixEngine(sampleRate = sampleRate, channels = 2)

        // FIFO capacity is 4 seconds
        val capacity = (sampleRate * 4).toInt()
        val largeBlock = FloatArray(capacity * 2) { 0.2f }

        val written = engine.writeDeckPcm(0, largeBlock, 0, capacity)
        assertEquals(capacity, written)

        // Next write should return 0 (backpressure) because FIFO is completely full
        val extraPcm = FloatArray(1024 * 2) { 0.2f }
        val overflowWritten = engine.writeDeckPcm(0, extraPcm, 0, 1024)
        assertEquals(0, overflowWritten)

        // Drain 1024 frames
        val out = FloatArray(1024 * 2)
        engine.render(out, 0, 1024)

        // Now writing 1024 frames should succeed
        val retryWritten = engine.writeDeckPcm(0, extraPcm, 0, 1024)
        assertEquals(1024, retryWritten)
    }

    @Test
    fun testDeckFlush() {
        val engine = MixEngine(sampleRate = 44100.0f, channels = 2)
        val pcm = FloatArray(2048 * 2) { 0.3f }

        engine.writeDeckPcm(0, pcm, 0, 2048)
        assertTrue(engine.getDeckBufferedFrames(0) > 0)

        engine.flushDeck(0)
        assertEquals(0, engine.getDeckBufferedFrames(0))
    }
}
