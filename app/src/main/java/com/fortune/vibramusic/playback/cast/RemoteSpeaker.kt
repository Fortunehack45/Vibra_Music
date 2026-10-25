package com.fortune.vibramusic.playback.cast

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player

interface CastSink {
    fun onRemotePlaybackChanged()
    fun onRemoteRouteChanged()
    fun onRemoteVolumeChanged()
}

/**
 * Something other than this phone playing the phone's queue.
 */
interface RemoteSpeaker {
    var sink: CastSink?

    val active: Boolean
    val playWhenReady: Boolean
    val isPlaying: Boolean
    val playbackState: Int
    val positionMs: Long
    val durationMs: Long
    val deviceVolume: Int

    fun play()
    fun pause()
    fun seekTo(positionMs: Long)
    fun setVolume(fraction: Float)
    fun onLocalTransition(item: MediaItem?, reason: Int)
    fun onLocalQueueChanged()
    fun onLocalRepeatChanged(repeatMode: Int)
    fun onLocalStartedPlaying(player: Player)
}
