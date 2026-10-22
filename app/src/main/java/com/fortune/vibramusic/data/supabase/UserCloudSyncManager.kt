package com.fortune.vibramusic.data.supabase

import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.LikeState
import com.fortune.vibramusic.data.LocalLikesStore
import com.fortune.vibramusic.data.LocalPlaylistsStore
import com.fortune.vibramusic.data.model.LikeStatus
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.UserPlaylist
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.data.settings.AudioQuality
import com.fortune.vibramusic.data.stats.ListeningStats
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Manages bidirectional cloud synchronization between the local client and Supabase:
 * - Listening experience & connected Spotify session
 * - Liked music tracks (metadata only, strictly NO audio bytes)
 * - User-created playlists & playlist items (metadata only, strictly NO audio bytes)
 * - Full data restoration whenever a user logs in with their YouTube account
 */
object UserCloudSyncManager {

    private const val TAG = "UserCloudSyncManager"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var activeUserId: String? = null

    fun setActiveUserId(id: String) {
        if (id.isNotBlank()) activeUserId = id
    }

    fun getActiveUserId(): String =
        activeUserId?.takeIf { it.isNotBlank() } ?: AppSettings.deviceUserId

    /**
     * Restores all cloud data for the given YouTube user:
     * - Connected Spotify account session (sp_dc cookie)
     * - Audio quality and listening experience preferences
     * - Liked songs (metadata restored into LocalLikesStore & LikeState)
     * - User playlists & track items (metadata restored into LocalPlaylistsStore)
     */
    fun restoreUserData(userId: String, onComplete: (() -> Unit)? = null) {
        if (!SupabaseConfig.isConfigured || userId.isBlank()) return
        setActiveUserId(userId)
        scope.launch {
            Log.d(TAG, "Initiating cloud data restore for user: $userId")
            runCatching {
                // 1. Restore Listening Experience & Connected Spotify Session
                SupabaseService.fetchListeningExperience(userId).onSuccess { exp ->
                    if (exp != null) {
                        withContext(Dispatchers.Main) {
                            if (!exp.spotifySpdcToken.isNullOrBlank()) {
                                AppSettings.setSpotifySpdcToken(exp.spotifySpdcToken)
                                Log.d(TAG, "Restored connected Spotify account session from cloud.")
                            }
                            runCatching {
                                val quality = AudioQuality.valueOf(exp.audioQuality)
                                AppSettings.setAudioQualityWifi(quality)
                                AppSettings.setAudioQualityCellular(quality)
                            }
                            AppSettings.setLoudnessNormalization(exp.volumeNormalization)
                            AppSettings.setAnimatedCanvas(exp.canvasEnabled)
                            if (exp.preferredGenres.isNotEmpty()) {
                                AppSettings.setPreferredGenres(exp.preferredGenres.toSet())
                            }
                        }
                        if (!exp.listeningStatsJson.isNullOrBlank()) {
                            ListeningStats.importBucketsJson(exp.listeningStatsJson)
                            Log.d(TAG, "Restored listening experience stats buckets from cloud.")
                        }
                    }
                }

                // 2. Restore Liked Music Tracks (Metadata only, NO audio bytes)
                SupabaseService.fetchLikedTracks(userId).onSuccess { tracks ->
                    if (tracks.isNotEmpty()) {
                        Log.d(TAG, "Restored ${tracks.size} liked tracks from cloud.")
                        tracks.forEach { song ->
                            LocalLikesStore.set(song.videoId, LikeStatus.LIKE, song)
                        }
                        LikeState.seedLiked(tracks.map { it.videoId }.toSet())
                    }
                }

                // 3. Restore User Playlists and Playlist Tracks (Metadata only, NO audio bytes)
                SupabaseService.fetchUserPlaylistsWithTracks(userId).onSuccess { playlists ->
                    if (playlists.isNotEmpty()) {
                        Log.d(TAG, "Restored ${playlists.size} playlists from cloud.")
                        playlists.forEach { (playlist, songs) ->
                            val existing = LocalPlaylistsStore.getPlaylists().any { it.title == playlist.title }
                            if (!existing) {
                                LocalPlaylistsStore.savePlaylist(playlist.title, songs)
                            }
                        }
                    }
                }

                Log.d(TAG, "Cloud data restore completed successfully for user: $userId")
            }.onFailure { err ->
                Log.e(TAG, "Error restoring cloud user data: ${err.message}")
            }
            withContext(Dispatchers.Main) {
                onComplete?.invoke()
            }
        }
    }

    /**
     * Backs up listening experience & connected Spotify session to Supabase.
     */
    fun backupListeningExperience(userId: String = "") {
        val targetId = userId.takeIf { it.isNotBlank() } ?: getActiveUserId()
        if (!SupabaseConfig.isConfigured || targetId.isBlank()) return
        scope.launch {
            backupListeningExperienceSync(targetId)
        }
    }

    suspend fun backupListeningExperienceSync(userId: String = "") {
        val targetId = userId.takeIf { it.isNotBlank() } ?: getActiveUserId()
        if (!SupabaseConfig.isConfigured || targetId.isBlank()) return
        runCatching {
            val spotifyToken = AppSettings.spotifySpdcToken.value.takeIf { it.isNotBlank() }
            val quality = AppSettings.effectiveAudioQuality.name
            val norm = AppSettings.loudnessNormalization.value
            val canvas = AppSettings.animatedCanvas.value
            val statsJson = runCatching { ListeningStats.exportBucketsJson() }.getOrNull()

            SupabaseService.syncListeningExperience(
                userId = targetId,
                spotifySpdcToken = spotifyToken,
                spotifyConnected = !spotifyToken.isNullOrBlank(),
                audioQuality = quality,
                equalizerEnabled = false,
                equalizerPreset = "FLAT",
                volumeNormalization = norm,
                bassBoostPercent = 0,
                virtualizerPercent = 0,
                pitchCents = 0,
                tempoMultiplier = 1.0f,
                autoSkipSilence = false,
                lyricsSource = "DEFAULT",
                canvasEnabled = canvas,
                preferredGenres = AppSettings.preferredGenres.value.toList(),
                listeningStatsJson = statsJson,
            )
        }.onFailure { Log.w(TAG, "Failed to backup listening experience: ${it.message}") }
    }

    /**
     * Synchronizes a track like/unlike event with Supabase (metadata only).
     */
    fun syncLikeChange(userId: String, videoId: String, status: LikeStatus, song: Song? = null) {
        if (!SupabaseConfig.isConfigured || userId.isBlank()) return
        scope.launch {
            if (status == LikeStatus.LIKE) {
                val toSync = song ?: LocalLikesStore.getLikedSongs().firstOrNull { it.videoId == videoId }
                if (toSync != null) {
                    SupabaseService.syncLikedTrack(userId, toSync)
                }
            } else {
                SupabaseService.removeLikedTrack(userId, videoId)
            }
        }
    }

    /**
     * Backs up a user playlist and its track items to Supabase.
     */
    fun syncPlaylist(userId: String, playlist: UserPlaylist, songs: List<Song>) {
        if (!SupabaseConfig.isConfigured || userId.isBlank()) return
        scope.launch {
            SupabaseService.syncPlaylist(
                userId = userId,
                playlistId = playlist.playlistId,
                title = playlist.title,
                thumbnailUrl = playlist.thumbnailUrl,
                trackCount = songs.size,
            )
            SupabaseService.syncPlaylistTracks(userId, playlist.playlistId, songs)
        }
    }

    /**
     * Deletes a user playlist from Supabase.
     */
    fun deletePlaylist(userId: String, playlistId: String) {
        if (!SupabaseConfig.isConfigured || userId.isBlank()) return
        scope.launch {
            SupabaseService.deletePlaylist(userId, playlistId)
        }
    }

    /**
     * Full initial sync: backs up all current local data to Supabase.
     */
    fun backupAllUserData(userId: String) {
        if (!SupabaseConfig.isConfigured || userId.isBlank()) return
        setActiveUserId(userId)
        scope.launch {
            backupListeningExperience(userId)
            val likedSongs = LocalLikesStore.getLikedSongs()
            likedSongs.forEach { song ->
                SupabaseService.syncLikedTrack(userId, song)
            }
            val playlists = LocalPlaylistsStore.getPlaylists()
            playlists.forEach { p ->
                val songs = LocalPlaylistsStore.getSongs(p.playlistId)
                syncPlaylist(userId, p, songs)
            }
        }
    }

    /**
     * Clears local user caches when signing out so another user's session remains isolated.
     */
    fun clearLocalUserData() {
        LocalLikesStore.clear()
        LocalPlaylistsStore.clear()
        LikeState.clear()
        AppSettings.setSpotifySpdcToken("")
    }
}
