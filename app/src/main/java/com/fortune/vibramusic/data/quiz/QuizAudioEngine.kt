package com.fortune.vibramusic.data.quiz

import android.animation.ValueAnimator
import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import com.fortune.vibramusic.data.DebugLog as Log

/**
 * Dedicated lightweight ExoPlayer engine for playing mystery music snippets
 * during the 10-question music quiz.
 *
 * Includes smooth volume fade-in to prevent loudness spikes and pops.
 */
class QuizAudioEngine(private val context: Context) {

    private val TAG = "QuizAudioEngine"
    private var player: ExoPlayer? = null
    private var fadeAnimator: ValueAnimator? = null

    init {
        initPlayer()
    }

    private fun initPlayer() {
        if (player == null) {
            player = ExoPlayer.Builder(context).build().apply {
                playWhenReady = true
                volume = 0f
            }
        }
    }

    private var preparedUrl: String? = null

    /**
     * Pre-buffers an audio snippet during the countdown or question transitions
     * with playWhenReady = false so it's ready for 0ms instantaneous playback.
     */
    fun prepareSnippet(streamUrl: String, startPositionMs: Long = 25_000L) {
        val p = player ?: return
        fadeAnimator?.cancel()
        p.stop()
        p.playWhenReady = false
        p.volume = 0f

        val mediaItem = MediaItem.fromUri(streamUrl)
        p.setMediaItem(mediaItem)
        p.prepare()
        p.seekTo(startPositionMs)
        preparedUrl = streamUrl
        Log.d(TAG, "Pre-buffering quiz snippet from $streamUrl at ${startPositionMs}ms")
    }

    /**
     * Instantly triggers playback of the pre-buffered snippet with a 250ms smooth fade-in.
     */
    fun startPreparedSnippet() {
        val p = player ?: return
        p.playWhenReady = true
        p.play()

        fadeAnimator?.cancel()
        fadeAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 250L
            addUpdateListener { anim ->
                p.volume = anim.animatedValue as Float
            }
            start()
        }
        Log.d(TAG, "Instant starting pre-buffered quiz snippet")
    }

    fun isSnippetPrepared(): Boolean = preparedUrl != null && player != null

    /**
     * Plays an audio snippet with a smooth 250ms volume fade-in.
     */
    fun playSnippet(streamUrl: String, startPositionMs: Long = 25_000L) {
        val p = player ?: return
        fadeAnimator?.cancel()
        p.stop()
        p.volume = 0f

        val mediaItem = MediaItem.fromUri(streamUrl)
        p.setMediaItem(mediaItem)
        p.prepare()
        p.seekTo(startPositionMs)
        p.playWhenReady = true
        p.play()
        preparedUrl = streamUrl

        // 250ms volume fade-in to avoid popping or loudness shock
        fadeAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 250L
            addUpdateListener { anim ->
                p.volume = anim.animatedValue as Float
            }
            start()
        }
        Log.d(TAG, "Playing quiz snippet from $streamUrl at ${startPositionMs}ms")
    }

    /**
     * Stops current playback immediately.
     */
    fun stop() {
        preparedUrl = null
        fadeAnimator?.cancel()
        player?.stop()
        player?.volume = 0f
    }

    /**
     * Releases player when quiz session ends.
     */
    fun release() {
        preparedUrl = null
        fadeAnimator?.cancel()
        player?.stop()
        player?.release()
        player = null
    }
}
