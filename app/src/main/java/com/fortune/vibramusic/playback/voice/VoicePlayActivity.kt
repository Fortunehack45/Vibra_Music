package com.fortune.vibramusic.playback.voice

import android.app.Activity
import android.app.SearchManager
import android.content.ComponentName
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import androidx.media3.common.MediaItem
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.fortune.vibramusic.playback.PlaybackService

/**
 * Headless activity dedicated to receiving [android.media.action.MEDIA_PLAY_FROM_SEARCH]
 * intents from Google Assistant, Gemini, and system voice actions.
 *
 * Dispatches the search or resume command directly to [PlaybackService] via [MediaController]
 * without ever showing an activity window, and releases itself after playback command dispatch.
 */
class VoicePlayActivity : ComponentActivity() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var controller: MediaController? = null
    private var finishRunnable: Runnable? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyNoTransition(isOpen = true)

        val incomingIntent = intent
        if (incomingIntent == null) {
            finishWithNoAnimation()
            return
        }

        val query = (incomingIntent.getStringExtra(SearchManager.QUERY)
            ?: incomingIntent.getStringExtra("query")).orEmpty().trim()

        val extrasBundle = incomingIntent.extras?.let { Bundle(it) } ?: Bundle()

        val mediaStoreFields = arrayOf(
            MediaStore.EXTRA_MEDIA_FOCUS,
            MediaStore.EXTRA_MEDIA_TITLE,
            MediaStore.EXTRA_MEDIA_ARTIST,
            MediaStore.EXTRA_MEDIA_ALBUM,
            MediaStore.EXTRA_MEDIA_PLAYLIST,
            MediaStore.EXTRA_MEDIA_GENRE,
        )
        val hasMediaField = mediaStoreFields.any { field ->
            extrasBundle.containsKey(field) && !extrasBundle.getString(field).isNullOrBlank()
        }

        try {
            val token = SessionToken(this, ComponentName(this, PlaybackService::class.java))
            val controllerFuture = MediaController.Builder(this, token).buildAsync()

            controllerFuture.addListener(
                {
                    try {
                        val activeController = controllerFuture.get()
                        controller = activeController

                        if (query.isBlank() && !hasMediaField) {
                            activeController.play()
                        } else {
                            val mediaItem = MediaItem.Builder()
                                .setMediaId("voice:search")
                                .setRequestMetadata(
                                    MediaItem.RequestMetadata.Builder()
                                        .setSearchQuery(query)
                                        .setExtras(extrasBundle)
                                        .build()
                                )
                                .build()

                            activeController.setMediaItems(listOf(mediaItem))
                            activeController.prepare()
                            activeController.play()
                        }

                        val cleanup = Runnable {
                            cleanupAndFinish()
                        }
                        finishRunnable = cleanup
                        mainHandler.postDelayed(cleanup, 1500L)
                    } catch (_: Exception) {
                        cleanupAndFinish()
                    }
                },
                ContextCompat.getMainExecutor(this)
            )
        } catch (_: Exception) {
            cleanupAndFinish()
        }
    }

    private fun cleanupAndFinish() {
        finishRunnable?.let { mainHandler.removeCallbacks(it) }
        finishRunnable = null
        try {
            controller?.release()
        } catch (_: Exception) {}
        controller = null
        finishWithNoAnimation()
    }

    private fun finishWithNoAnimation() {
        finish()
        applyNoTransition(isOpen = false)
    }

    private fun applyNoTransition(isOpen: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val transitionType = if (isOpen) {
                Activity.OVERRIDE_TRANSITION_OPEN
            } else {
                Activity.OVERRIDE_TRANSITION_CLOSE
            }
            overrideActivityTransition(transitionType, 0, 0)
        } else {
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    override fun onDestroy() {
        finishRunnable?.let { mainHandler.removeCallbacks(it) }
        finishRunnable = null
        try {
            controller?.release()
        } catch (_: Exception) {}
        controller = null
        super.onDestroy()
    }
}
