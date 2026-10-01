package com.fortune.vibramusic.desktop.audio

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import uk.co.caprica.vlcj.factory.MediaPlayerFactory
import uk.co.caprica.vlcj.factory.discovery.NativeDiscovery
import uk.co.caprica.vlcj.player.base.MediaPlayer
import uk.co.caprica.vlcj.player.base.MediaPlayerEventAdapter

data class DesktopPlaybackSnapshot(
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val currentPositionMs: Long = 0L,
    val durationMs: Long = 0L,
    val volume: Float = 1.0f,
    val error: String? = null,
)

class DesktopAudioEngine {
    private val _snapshot = MutableStateFlow(DesktopPlaybackSnapshot())
    val snapshot: StateFlow<DesktopPlaybackSnapshot> = _snapshot.asStateFlow()

    private var factory: MediaPlayerFactory? = null
    private var mediaPlayer: MediaPlayer? = null

    init {
        try {
            // Auto-discover libvlc (e.g. C:\Program Files\VideoLAN\VLC)
            val discovered = NativeDiscovery().discover()
            println("[DesktopAudioEngine] Native VLC discovery: $discovered")
            factory = MediaPlayerFactory("--no-video", "--quiet")
            mediaPlayer = factory?.mediaPlayers()?.newMediaPlayer()?.apply {
                events().addMediaPlayerEventListener(object : MediaPlayerEventAdapter() {
                    override fun playing(mediaPlayer: MediaPlayer) {
                        _snapshot.value = _snapshot.value.copy(isPlaying = true, isBuffering = false)
                    }

                    override fun paused(mediaPlayer: MediaPlayer) {
                        _snapshot.value = _snapshot.value.copy(isPlaying = false)
                    }

                    override fun stopped(mediaPlayer: MediaPlayer) {
                        _snapshot.value = _snapshot.value.copy(isPlaying = false)
                    }

                    override fun finished(mediaPlayer: MediaPlayer) {
                        _snapshot.value = _snapshot.value.copy(isPlaying = false, currentPositionMs = 0L)
                    }

                    override fun buffering(mediaPlayer: MediaPlayer, newCache: Float) {
                        _snapshot.value = _snapshot.value.copy(isBuffering = newCache < 100f)
                    }

                    override fun timeChanged(mediaPlayer: MediaPlayer, newTime: Long) {
                        _snapshot.value = _snapshot.value.copy(currentPositionMs = newTime)
                    }

                    override fun lengthChanged(mediaPlayer: MediaPlayer, newLength: Long) {
                        _snapshot.value = _snapshot.value.copy(durationMs = newLength)
                    }

                    override fun error(mediaPlayer: MediaPlayer) {
                        _snapshot.value = _snapshot.value.copy(
                            isPlaying = false,
                            isBuffering = false,
                            error = "Playback error occurred",
                        )
                    }
                })
            }
        } catch (t: Throwable) {
            println("[DesktopAudioEngine] Failed to initialize VLC engine: ${t.message}")
            _snapshot.value = _snapshot.value.copy(error = t.message)
        }
    }

    fun play(mediaUri: String) {
        mediaPlayer?.media()?.play(mediaUri)
    }

    fun pause() {
        mediaPlayer?.controls()?.pause()
    }

    fun resume() {
        mediaPlayer?.controls()?.play()
    }

    fun togglePlayPause() {
        if (_snapshot.value.isPlaying) pause() else resume()
    }

    fun seekTo(positionMs: Long) {
        mediaPlayer?.controls()?.setTime(positionMs)
    }

    fun setVolume(volume: Float) {
        val clamped = volume.coerceIn(0f, 1f)
        val vlcVol = (clamped * 100).toInt()
        mediaPlayer?.audio()?.setVolume(vlcVol)
        _snapshot.value = _snapshot.value.copy(volume = clamped)
    }

    fun release() {
        mediaPlayer?.release()
        factory?.release()
    }
}
