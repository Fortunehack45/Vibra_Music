package com.fortune.vibramusic.desktop.player

import com.fortune.vibramusic.desktop.audio.DesktopAudioEngine
import com.fortune.vibramusic.desktop.data.DesktopMusicRepository
import com.fortune.vibramusic.desktop.model.DesktopSong
import com.fortune.vibramusic.desktop.model.DesktopTab
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class DesktopUiState(
    val currentSong: DesktopSong? = null,
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val currentPositionMs: Long = 0L,
    val durationMs: Long = 0L,
    val volume: Float = 1.0f,
    val queue: List<DesktopSong> = emptyList(),
    val queueIndex: Int = 0,
    val currentTab: DesktopTab = DesktopTab.Home,
    val isNowPlayingExpanded: Boolean = false,
    val searchResults: List<DesktopSong> = emptyList(),
    val isSearching: Boolean = false,
    val partyCode: String = "",
    val partyStatus: String = "Offline",
    val likedSongIds: Set<String> = emptySet(),
    val history: List<DesktopSong> = emptyList(),
)

object DesktopPlayerController {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val audioEngine = DesktopAudioEngine()

    private val _uiState = MutableStateFlow(DesktopUiState())
    val uiState: StateFlow<DesktopUiState> = _uiState.asStateFlow()

    init {
        // Collect playback snapshots from VLCJ
        scope.launch {
            audioEngine.snapshot.collect { snap ->
                _uiState.value = _uiState.value.copy(
                    isPlaying = snap.isPlaying,
                    isBuffering = snap.isBuffering,
                    currentPositionMs = snap.currentPositionMs,
                    durationMs = if (snap.durationMs > 0) snap.durationMs else _uiState.value.durationMs,
                    volume = snap.volume,
                )
            }
        }
    }

    fun setTab(tab: DesktopTab) {
        _uiState.value = _uiState.value.copy(currentTab = tab)
    }

    fun setNowPlayingExpanded(expanded: Boolean) {
        _uiState.value = _uiState.value.copy(isNowPlayingExpanded = expanded)
    }

    fun search(query: String) {
        if (query.isBlank()) {
            _uiState.value = _uiState.value.copy(searchResults = emptyList(), isSearching = false)
            return
        }
        _uiState.value = _uiState.value.copy(isSearching = true)
        scope.launch(Dispatchers.IO) {
            val results = DesktopMusicRepository.search(query)
            _uiState.value = _uiState.value.copy(
                searchResults = results,
                isSearching = false,
            )
        }
    }

    fun toggleLike(song: DesktopSong) {
        val currentLikes = _uiState.value.likedSongIds.toMutableSet()
        if (currentLikes.contains(song.id)) {
            currentLikes.remove(song.id)
        } else {
            currentLikes.add(song.id)
        }
        _uiState.value = _uiState.value.copy(likedSongIds = currentLikes)
    }

    fun playSong(song: DesktopSong, newQueue: List<DesktopSong> = emptyList()) {
        val queue = if (newQueue.isNotEmpty()) newQueue else listOf(song)
        val idx = queue.indexOfFirst { it.id == song.id }.coerceAtLeast(0)

        // Add to history (deduplicated at top)
        val newHistory = (listOf(song) + _uiState.value.history.filterNot { it.id == song.id }).take(30)

        _uiState.value = _uiState.value.copy(
            currentSong = song,
            queue = queue,
            queueIndex = idx,
            isBuffering = true,
            currentPositionMs = 0L,
            durationMs = (song.durationSeconds * 1000L),
            history = newHistory,
        )

        scope.launch(Dispatchers.IO) {
            // Resolve stream URL
            val streamUrl = song.streamUrl ?: DesktopMusicRepository.resolveStreamUrl(song.id)
            if (!streamUrl.isNullOrBlank()) {
                audioEngine.play(streamUrl)
            } else {
                _uiState.value = _uiState.value.copy(isBuffering = false)
            }

            // Fetch synchronized lyrics
            val lyrics = DesktopMusicRepository.fetchLyrics(
                title = song.title,
                artist = song.artist,
                durationSeconds = song.durationSeconds,
            )
            if (lyrics.isNotEmpty() && _uiState.value.currentSong?.id == song.id) {
                _uiState.value = _uiState.value.copy(
                    currentSong = _uiState.value.currentSong?.copy(lyrics = lyrics)
                )
            }
        }
    }

    fun togglePlayPause() {
        audioEngine.togglePlayPause()
    }

    fun seekTo(positionMs: Long) {
        audioEngine.seekTo(positionMs)
        _uiState.value = _uiState.value.copy(currentPositionMs = positionMs)
    }

    fun setVolume(volume: Float) {
        audioEngine.setVolume(volume)
    }

    fun next() {
        val state = _uiState.value
        if (state.queue.isNotEmpty()) {
            val nextIdx = (state.queueIndex + 1) % state.queue.size
            playSong(state.queue[nextIdx], state.queue)
        }
    }

    fun previous() {
        val state = _uiState.value
        if (state.queue.isNotEmpty()) {
            val prevIdx = if (state.queueIndex > 0) state.queueIndex - 1 else state.queue.size - 1
            playSong(state.queue[prevIdx], state.queue)
        }
    }

    fun joinParty(code: String) {
        _uiState.value = _uiState.value.copy(
            partyCode = code,
            partyStatus = "Connected to room $code",
        )
    }
}
