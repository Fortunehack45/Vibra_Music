@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.fortune.vibramusic.ios

import com.fortune.vibramusic.data.listentogether.PartySnapshot
import com.fortune.vibramusic.data.model.Song
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import platform.AVFAudio.*
import platform.AVFoundation.*
import platform.CoreMedia.*
import platform.Foundation.*
import platform.MediaPlayer.*

/**
 * Native iOS playback engine backed by AVPlayer, AVAudioSession, and MPNowPlayingInfoCenter.
 * Preserves current track and exact playhead position when disconnecting from a Listen Together
 * session so playback continues seamlessly without reverting to a pre-party track.
 */
object IosPlaybackEngine {
    private val player = AVPlayer()

    private val _queue = MutableStateFlow<List<Song>>(emptyList())
    val queue: StateFlow<List<Song>> = _queue.asStateFlow()

    private val _currentIndex = MutableStateFlow(0)
    val currentIndex: StateFlow<Int> = _currentIndex.asStateFlow()

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()

    private val _positionMs = MutableStateFlow(0L)
    val positionMs: StateFlow<Long> = _positionMs.asStateFlow()

    private val _durationMs = MutableStateFlow(0L)
    val durationMs: StateFlow<Long> = _durationMs.asStateFlow()

    private val _partyState = MutableStateFlow<PartySnapshot?>(null)
    val partyState: StateFlow<PartySnapshot?> = _partyState.asStateFlow()

    init {
        configureAudioSession()
        configureRemoteCommands()
    }

    private fun configureAudioSession() {
        runCatching {
            val session = AVAudioSession.sharedInstance()
            session.setCategory(AVAudioSessionCategoryPlayback, error = null)
            session.setActive(true, error = null)
        }
    }

    private fun configureRemoteCommands() {
        runCatching {
            val center = MPRemoteCommandCenter.sharedCommandCenter()
            center.playCommand.addTargetWithHandler {
                play()
                MPRemoteCommandHandlerStatusSuccess
            }
            center.pauseCommand.addTargetWithHandler {
                pause()
                MPRemoteCommandHandlerStatusSuccess
            }
            center.nextTrackCommand.addTargetWithHandler {
                skipNext()
                MPRemoteCommandHandlerStatusSuccess
            }
            center.previousTrackCommand.addTargetWithHandler {
                skipPrevious()
                MPRemoteCommandHandlerStatusSuccess
            }
        }
    }

    fun setQueue(songs: List<Song>, startIndex: Int = 0, startPositionMs: Long = 0L, autoPlay: Boolean = true) {
        if (songs.isEmpty()) return
        val safeIndex = startIndex.coerceIn(0, songs.lastIndex)
        _queue.value = songs
        _currentIndex.value = safeIndex
        loadCurrentSong(songs[safeIndex], startPositionMs, autoPlay)
    }

    private fun parseDurationMs(durationText: String?): Long {
        if (durationText.isNullOrBlank()) return 210_000L
        val parts = durationText.trim().split(':').mapNotNull { it.toLongOrNull() }
        return when (parts.size) {
            2 -> (parts[0] * 60L + parts[1]) * 1000L
            3 -> (parts[0] * 3600L + parts[1] * 60L + parts[2]) * 1000L
            else -> 210_000L
        }.coerceAtLeast(1_000L)
    }

    private fun loadCurrentSong(song: Song, startPositionMs: Long, autoPlay: Boolean) {
        _positionMs.value = startPositionMs
        _durationMs.value = parseDurationMs(song.durationText)
        val streamUrl = song.localUri ?: return
        val nsUrl = NSURL.URLWithString(streamUrl) ?: return
        val item = AVPlayerItem.playerItemWithURL(nsUrl)
        player.replaceCurrentItemWithPlayerItem(item)
        if (startPositionMs > 0L) {
            seekTo(startPositionMs)
        }
        if (autoPlay) {
            play()
        } else {
            pause()
        }
        updateNowPlayingInfo()
    }

    fun play() {
        player.play()
        _isPlaying.value = true
        updateNowPlayingInfo()
    }

    fun pause() {
        player.pause()
        _isPlaying.value = false
        updateNowPlayingInfo()
    }

    fun togglePlayPause() {
        if (_isPlaying.value) pause() else play()
    }

    fun seekTo(targetMs: Long) {
        val clamped = targetMs.coerceAtLeast(0L)
        _positionMs.value = clamped
        val time = CMTimeMakeWithSeconds(clamped.toDouble() / 1000.0, 1000)
        player.seekToTime(time)
        updateNowPlayingInfo()
    }

    fun skipNext() {
        val list = _queue.value
        if (list.isEmpty()) return
        val next = (_currentIndex.value + 1) % list.size
        _currentIndex.value = next
        loadCurrentSong(list[next], 0L, _isPlaying.value)
    }

    fun skipPrevious() {
        if (_positionMs.value > 3_000L) {
            seekTo(0L)
            return
        }
        val list = _queue.value
        if (list.isEmpty()) return
        val prev = if (_currentIndex.value - 1 >= 0) _currentIndex.value - 1 else list.lastIndex
        _currentIndex.value = prev
        loadCurrentSong(list[prev], 0L, _isPlaying.value)
    }

    fun onPartyStateChanged(state: PartySnapshot?) {
        _partyState.value = state
        if (state == null) return
        if (state.queue.items.isNotEmpty()) {
            val mapped = state.queue.items.map { track ->
                Song(
                    videoId = track.videoId,
                    title = track.title,
                    artist = track.artist,
                    thumbnailUrl = track.thumbnailUrl,
                )
            }
            _queue.value = mapped
            _currentIndex.value = state.queue.index.coerceIn(0, mapped.lastIndex)
        }
    }

    /**
     * Leaves the Listen Together session while continuing playback of the current song
     * from its exact current playhead position without reverting to a prior personal queue.
     */
    fun leavePartyContinuingCurrentTrack() {
        val currentPosSeconds = CMTimeGetSeconds(player.currentTime())
        if (!currentPosSeconds.isNaN() && currentPosSeconds > 0.0) {
            _positionMs.value = (currentPosSeconds * 1000.0).toLong()
        }
        _partyState.value = null
        updateNowPlayingInfo()
    }

    private fun updateNowPlayingInfo() {
        val song = _queue.value.getOrNull(_currentIndex.value) ?: return
        runCatching {
            val info = mapOf<Any?, Any?>(
                MPMediaItemPropertyTitle to song.title,
                MPMediaItemPropertyArtist to song.artist,
                MPMediaItemPropertyPlaybackDuration to (_durationMs.value.toDouble() / 1000.0),
                MPNowPlayingInfoPropertyElapsedPlaybackTime to (_positionMs.value.toDouble() / 1000.0),
                MPNowPlayingInfoPropertyPlaybackRate to if (_isPlaying.value) 1.0 else 0.0,
            )
            MPNowPlayingInfoCenter.defaultCenter().nowPlayingInfo = info
        }
    }
}
