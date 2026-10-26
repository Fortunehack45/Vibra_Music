package com.fortune.vibramusic.playback.audio

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer

/**
 * Custom AudioSink port connecting an ExoPlayer instance to the single-clock [MixEngine].
 *
 * Implements:
 * 1. Float32 PCM decoding and lock-free FIFO ingestion into [MixEngine].
 * 2. Backpressure management (returns false when MixEngine FIFO reaches 4-second capacity).
 * 3. Trimmed song excerpt bounds enforcement ([incomingEntryMs] and [outgoingExitMs]).
 * 4. Pass-through mode when transition mixing is inactive.
 */
@OptIn(UnstableApi::class)
class DeckSink(
    private val delegate: AudioSink,
    val deckId: Int,
    val mixEngine: MixEngine,
) : ForwardingAudioSink(delegate) {

    var isRoutingToMixEngine: Boolean = false
    var incomingEntryMs: Long? = null
    var outgoingExitMs: Long? = null

    private var inEncoding: PcmEncoding = PcmEncoding.PCM_16BIT
    private var sampleRate: Int = 44100
    private var channelCount: Int = 2
    private val audioBlock = AudioBlock(channelCount = 2, capacityFrames = 2048)

    override fun configure(audioSinkConfig: AudioSink.AudioSinkConfig) {
        super.configure(audioSinkConfig)
        val format = audioSinkConfig.format
        sampleRate = if (format.sampleRate != Format.NO_VALUE) format.sampleRate else 44100
        channelCount = if (format.channelCount != Format.NO_VALUE) format.channelCount else 2
        inEncoding = PrecisionAudioSink.mapToPcmEncoding(format.pcmEncoding) ?: PcmEncoding.PCM_16BIT
    }

    override fun handleBuffer(
        inputBuffer: ByteBuffer,
        presentationTimeUs: Long,
        encodedAccessUnitCount: Int
    ): Boolean {
        if (!isRoutingToMixEngine) {
            return super.handleBuffer(inputBuffer, presentationTimeUs, encodedAccessUnitCount)
        }

        // 1. Excerpt Trimming: check start boundary (incomingEntryMs)
        val entry = incomingEntryMs
        if (entry != null && presentationTimeUs != C.TIME_UNSET && presentationTimeUs < entry * 1000L) {
            // Discard frames before entry point
            inputBuffer.position(inputBuffer.limit())
            return true
        }

        // 2. Excerpt Trimming: check exit boundary (outgoingExitMs)
        val exit = outgoingExitMs
        if (exit != null && presentationTimeUs != C.TIME_UNSET && presentationTimeUs >= exit * 1000L) {
            // Reached exit point; discard frames and let track complete
            inputBuffer.position(inputBuffer.limit())
            return true
        }

        val bytesPerFrame = inEncoding.bytesPerFrame(channelCount)
        if (bytesPerFrame <= 0 || !inputBuffer.hasRemaining()) return true

        val availableFrames = inputBuffer.remaining() / bytesPerFrame
        if (availableFrames <= 0) return true

        val framesToRead = minOf(availableFrames, audioBlock.capacityFrames)
        val decodedFrames = PcmBoundary.decode(
            inputBuffer = inputBuffer,
            encoding = inEncoding,
            destinationBlock = audioBlock,
            maxFrames = framesToRead
        )

        if (decodedFrames <= 0) return true

        // 3. Write into MixEngine FIFO
        val written = mixEngine.writeDeckPcm(deckId, audioBlock.samples, 0, decodedFrames)
        if (written < decodedFrames) {
            // FIFO full; backpressure to ExoPlayer
            return false
        }

        return !inputBuffer.hasRemaining()
    }

    override fun flush() {
        super.flush()
        if (isRoutingToMixEngine) {
            mixEngine.flushDeck(deckId)
        }
    }

    override fun reset() {
        super.reset()
        if (isRoutingToMixEngine) {
            mixEngine.flushDeck(deckId)
        }
    }
}
