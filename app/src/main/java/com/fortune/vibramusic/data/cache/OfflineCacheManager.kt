package com.fortune.vibramusic.data.cache

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.media3.common.util.UnstableApi
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.playback.AudioCache
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.util.Locale

@Serializable
data class CachedSongMetadata(
    val videoId: String,
    val title: String,
    val artist: String,
    val thumbnailUrl: String? = null,
    val durationText: String? = null,
    val cachedAtMillis: Long = System.currentTimeMillis(),
) {
    fun toSong(): Song = Song(
        videoId = videoId,
        title = title,
        artist = artist,
        thumbnailUrl = thumbnailUrl,
        durationText = durationText,
    )
}

@UnstableApi
object OfflineCacheManager {

    private const val PREFS_NAME = "vibra_offline_cache"
    private const val KEY_CACHED_METADATA = "cached_tracks_metadata"

    private lateinit var prefs: SharedPreferences
    private val json = Json { ignoreUnknownKeys = true }
    private val metadataSerializer = MapSerializer(String.serializer(), CachedSongMetadata.serializer())
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private val _cachedSongs = MutableStateFlow<List<Song>>(emptyList())
    val cachedSongs: StateFlow<List<Song>> = _cachedSongs.asStateFlow()

    private val _totalCacheSizeFormatted = MutableStateFlow("0 B")
    val totalCacheSizeFormatted: StateFlow<String> = _totalCacheSizeFormatted.asStateFlow()

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        refresh()
    }

    /**
     * Record a played or streamed song in the offline cache registry.
     */
    fun recordCachedSong(song: Song) {
        if (song.videoId.isBlank()) return
        scope.launch {
            if (!::prefs.isInitialized) return@launch
            val currentMap = loadMetadataMap().toMutableMap()
            currentMap[song.videoId] = CachedSongMetadata(
                videoId = song.videoId,
                title = song.title,
                artist = song.artist,
                thumbnailUrl = song.thumbnailUrl,
                durationText = song.durationText,
                cachedAtMillis = System.currentTimeMillis(),
            )
            saveMetadataMap(currentMap)
            refresh()
        }
    }

    /**
     * Re-scans disk cache and synchronizes cached songs with actual bytes on disk.
     */
    fun refresh() {
        scope.launch {
            val songs = getCachedSongs()
            _cachedSongs.value = songs
            _totalCacheSizeFormatted.value = formatBytes(AudioCache.totalCacheSpace())
        }
    }

    /**
     * Returns all songs whose audio streams currently reside on disk in AudioCache.
     */
    suspend fun getCachedSongs(): List<Song> = withContext(Dispatchers.IO) {
        if (!::prefs.isInitialized) return@withContext emptyList()
        val allOnDisk = AudioCache.allCachedVideoIds()
        val metadataMap = loadMetadataMap()

        // Prune entries no longer on disk
        val validSongs = mutableListOf<Song>()
        val prunedMap = mutableMapOf<String, CachedSongMetadata>()

        for ((id, meta) in metadataMap) {
            if (id in allOnDisk) {
                prunedMap[id] = meta
                validSongs.add(meta.toSong())
            }
        }

        if (prunedMap.size != metadataMap.size) {
            saveMetadataMap(prunedMap)
        }

        // Return sorted by most recently cached
        validSongs.sortedByDescending { song ->
            metadataMap[song.videoId]?.cachedAtMillis ?: 0L
        }
    }

    /**
     * Remove a song from the offline cache and discard its disk spans.
     */
    fun removeSong(videoId: String) {
        scope.launch {
            val uri = Uri.parse("siren://watch?v=$videoId")
            AudioCache.discard(uri)
            if (!::prefs.isInitialized) return@launch
            val currentMap = loadMetadataMap().toMutableMap()
            currentMap.remove(videoId)
            saveMetadataMap(currentMap)
            refresh()
        }
    }

    /**
     * Clear all cached music from disk and metadata.
     */
    fun clearCache(onComplete: () -> Unit = {}) {
        scope.launch {
            AudioCache.clear {
                if (::prefs.isInitialized) {
                    prefs.edit().remove(KEY_CACHED_METADATA).apply()
                }
                _cachedSongs.value = emptyList()
                _totalCacheSizeFormatted.value = "0 B"
                onComplete()
            }
        }
    }

    private fun loadMetadataMap(): Map<String, CachedSongMetadata> {
        return runCatching {
            val raw = prefs.getString(KEY_CACHED_METADATA, null) ?: return emptyMap()
            json.decodeFromString(metadataSerializer, raw)
        }.getOrDefault(emptyMap())
    }

    private fun saveMetadataMap(map: Map<String, CachedSongMetadata>) {
        runCatching {
            val raw = json.encodeToString(metadataSerializer, map)
            prefs.edit().putString(KEY_CACHED_METADATA, raw).apply()
        }
    }

    fun formatBytes(bytes: Long): String {
        if (bytes <= 0) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        val digitGroups = (Math.log10(bytes.toDouble()) / Math.log10(1024.0)).toInt().coerceIn(0, units.lastIndex)
        return String.format(Locale.US, "%.1f %s", bytes / Math.pow(1024.0, digitGroups.toDouble()), units[digitGroups])
    }
}
