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

    /**
     * Plays an audio snippet with a smooth 300ms volume fade-in.
     */
    fun playSnippet(streamUrl: String, startPositionMs: Long = 20_000L) {
        val p = player ?: return
        fadeAnimator?.cancel()
        p.stop()
        p.volume = 0f

        val mediaItem = MediaItem.fromUri(streamUrl)
        p.setMediaItem(mediaItem)
        p.prepare()
        p.seekTo(startPositionMs)
        p.play()

        // 300ms volume fade-in to avoid popping or loudness shock
        fadeAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 300L
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
        fadeAnimator?.cancel()
        player?.stop()
        player?.volume = 0f
    }

    /**
     * Releases player when quiz session ends.
     */
    fun release() {
        fadeAnimator?.cancel()
        player?.stop()
        player?.release()
        player = null
    }
}
