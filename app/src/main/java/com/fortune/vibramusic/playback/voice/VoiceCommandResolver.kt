package com.fortune.vibramusic.playback.voice

import android.content.Context
import android.provider.MediaStore
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.LocalPlaylistsStore
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.playback.LinkRequest

/**
 * Resolved playback instruction from a spoken Google Assistant voice query.
 */
sealed interface VoiceResolution {
    /** Plays an ordered queue of songs (e.g. an album or playlist) starting at index 0. */
    data class PlaySongs(val title: String, val songs: List<Song>, val announcement: String) : VoiceResolution

    /** Starts an AutoPlay radio seeded by a specific song (e.g. track search or artist radio). */
    data class PlayRadio(val song: Song, val announcement: String) : VoiceResolution

    /** Resumes current playback. */
    data object Resume : VoiceResolution

    /** No matching playable content could be found. */
    data class NotFound(val query: String, val announcement: String) : VoiceResolution
}

/**
 * Intelligent voice command resolver for Vibra Music.
 *
 * Maps unstructured natural language or structured MediaStore intent extras into
 * actionable playback actions across local playlists and the online catalog.
 */
object VoiceCommandResolver {

    suspend fun resolve(
        context: Context? = null,
        voice: LinkRequest.Voice,
    ): VoiceResolution {
        return resolve(
            context = context,
            query = voice.rawQuery,
            mediaFocus = voice.mediaFocus,
            title = voice.title,
            artist = voice.artist,
            album = voice.album,
            playlist = voice.playlist,
            genre = voice.genre,
        )
    }

    suspend fun resolve(
        context: Context? = null,
        query: String,
        mediaFocus: String? = null,
        title: String? = null,
        artist: String? = null,
        album: String? = null,
        playlist: String? = null,
        genre: String? = null,
    ): VoiceResolution {
        val rawQuery = query.trim()
        val focus = mediaFocus?.trim()
        val explicitTitle = title?.trim()?.takeIf { it.isNotEmpty() }
        val explicitArtist = artist?.trim()?.takeIf { it.isNotEmpty() }
        val explicitAlbum = album?.trim()?.takeIf { it.isNotEmpty() }
        val explicitPlaylist = playlist?.trim()?.takeIf { it.isNotEmpty() }

        // 1. Resume check: empty query and no explicit fields
        if (rawQuery.isEmpty() && focus.isNullOrEmpty() && explicitTitle == null &&
            explicitArtist == null && explicitAlbum == null && explicitPlaylist == null) {
            return VoiceResolution.Resume
        }

        // Clean spoken prefixes like "play", "play my playlist", etc.
        val cleanQuery = stripSpokenPrefixes(rawQuery)

        // 2. Playlist Focus: check local playlists first, then online playlists
        val isPlaylistFocus = focus == MediaStore.Audio.Playlists.ENTRY_CONTENT_TYPE ||
                explicitPlaylist != null ||
                hasPrefix(rawQuery, "my playlist", "playlist", "play my playlist", "play playlist")

        if (isPlaylistFocus) {
            val target = explicitPlaylist
                ?: cleanSpokenWords(rawQuery, "play my playlist", "play playlist", "my playlist", "playlist")
                ?: cleanQuery

            if (target.isNotBlank()) {
                // Check user's local playlists first
                val local = LocalPlaylistsStore.findPlaylistByTitle(target)
                if (local != null && local.songs.isNotEmpty()) {
                    val msg = formatString(
                        context,
                        R.string.voice_playing_playlist,
                        "Playing playlist ${local.title}",
                        local.title
                    )
                    return VoiceResolution.PlaySongs(
                        title = local.title,
                        songs = local.songs,
                        announcement = msg
                    )
                }

                // Query online playlists
                val onlinePlaylists = YtMusicRepository.search(target, SearchFilter.PLAYLISTS).getOrNull()
                    ?.filterIsInstance<SearchResult.Browse>()
                val topPlaylist = onlinePlaylists?.firstOrNull()
                if (topPlaylist != null) {
                    val songs = YtMusicRepository.browseSongs(topPlaylist.item.browseId).getOrNull()?.songs
                    if (!songs.isNullOrEmpty()) {
                        val msg = formatString(
                            context,
                            R.string.voice_playing_playlist,
                            "Playing playlist ${topPlaylist.item.title}",
                            topPlaylist.item.title
                        )
                        return VoiceResolution.PlaySongs(
                            title = topPlaylist.item.title,
                            songs = songs,
                            announcement = msg
                        )
                    }
                }
            }
        }

        // 3. Album Focus: search albums and queue complete tracklist
        val isAlbumFocus = focus == MediaStore.Audio.Albums.ENTRY_CONTENT_TYPE ||
                explicitAlbum != null ||
                hasPrefix(rawQuery, "album", "the album", "play album", "play the album")

        if (isAlbumFocus) {
            val target = explicitAlbum
                ?: cleanSpokenWords(rawQuery, "play the album", "play album", "the album", "album")
                ?: cleanQuery

            if (target.isNotBlank()) {
                val albums = YtMusicRepository.search(target, SearchFilter.ALBUMS).getOrNull()
                    ?.filterIsInstance<SearchResult.Browse>()
                val topAlbum = albums?.firstOrNull()
                if (topAlbum != null) {
                    val songs = YtMusicRepository.browseSongs(topAlbum.item.browseId).getOrNull()?.songs
                    if (!songs.isNullOrEmpty()) {
                        val msg = formatString(
                            context,
                            R.string.voice_playing_album,
                            "Playing album ${topAlbum.item.title}",
                            topAlbum.item.title
                        )
                        return VoiceResolution.PlaySongs(
                            title = topAlbum.item.title,
                            songs = songs,
                            announcement = msg
                        )
                    }
                }
            }
        }

        // 4. Artist Focus: search artists and seed top tracks / radio
        val isArtistFocus = (focus == MediaStore.Audio.Artists.ENTRY_CONTENT_TYPE || explicitArtist != null) &&
                explicitTitle == null

        if (isArtistFocus) {
            val target = explicitArtist
                ?: cleanSpokenWords(rawQuery, "play artist", "play music by", "play songs by", "music by", "songs by", "artist")
                ?: cleanQuery

            if (target.isNotBlank()) {
                val artists = YtMusicRepository.search(target, SearchFilter.ARTISTS).getOrNull()
                    ?.filterIsInstance<SearchResult.Browse>()
                val topArtist = artists?.firstOrNull()
                if (topArtist != null) {
                    val artistPage = YtMusicRepository.artistPage(topArtist.item.browseId).getOrNull()
                    val songs = artistPage?.songs.orEmpty()
                    if (songs.isNotEmpty()) {
                        val msg = formatString(
                            context,
                            R.string.voice_playing_artist,
                            "Playing music by ${topArtist.item.title}",
                            topArtist.item.title
                        )
                        return VoiceResolution.PlaySongs(
                            title = topArtist.item.title,
                            songs = songs,
                            announcement = msg
                        )
                    }
                }
            }
        }

        // 5. Check if query matches a local playlist before searching online tracks
        if (cleanQuery.isNotBlank()) {
            val local = LocalPlaylistsStore.findPlaylistByTitle(cleanQuery)
            if (local != null && local.songs.isNotEmpty()) {
                val msg = formatString(
                    context,
                    R.string.voice_playing_playlist,
                    "Playing playlist ${local.title}",
                    local.title
                )
                return VoiceResolution.PlaySongs(
                    title = local.title,
                    songs = local.songs,
                    announcement = msg
                )
            }
        }

        // 6. Track / Song or General Natural Language Query
        // Check for " by " pattern (e.g. "Starboy by The Weeknd")
        val parsedArtist = explicitArtist ?: if (cleanQuery.contains(" by ", ignoreCase = true)) {
            cleanQuery.substringAfterLast(" by ", "").trim().takeIf { it.isNotBlank() }
        } else null

        val parsedTitle = explicitTitle ?: if (cleanQuery.contains(" by ", ignoreCase = true)) {
            cleanQuery.substringBeforeLast(" by ", "").trim().takeIf { it.isNotBlank() }
        } else {
            cleanSpokenWords(cleanQuery, "play song", "play track", "song", "track") ?: cleanQuery
        }

        val effectiveQuery = when {
            parsedTitle != null && parsedArtist != null && !parsedTitle.contains(parsedArtist, ignoreCase = true) ->
                "$parsedTitle $parsedArtist"
            parsedTitle != null -> parsedTitle
            else -> cleanQuery
        }

        if (effectiveQuery.isNotBlank()) {
            val songs = YtMusicRepository.search(effectiveQuery, SearchFilter.SONGS).getOrNull()
                ?.filterIsInstance<SearchResult.Track>()
            val topSong = songs?.firstOrNull()?.song
            if (topSong != null) {
                val msg = formatString(
                    context,
                    R.string.voice_playing_track,
                    "Playing ${topSong.title} by ${topSong.artist}",
                    topSong.title,
                    topSong.artist
                )
                return VoiceResolution.PlayRadio(
                    song = topSong,
                    announcement = msg
                )
            }

            // Fallback: check SearchFilter.ALL
            val allResults = YtMusicRepository.search(effectiveQuery, SearchFilter.ALL).getOrNull().orEmpty()
            val fallbackSong = allResults.filterIsInstance<SearchResult.Track>().firstOrNull()?.song
                ?: allResults.filterIsInstance<SearchResult.TopTrack>().firstOrNull()?.song
            if (fallbackSong != null) {
                val msg = formatString(
                    context,
                    R.string.voice_playing_track,
                    "Playing ${fallbackSong.title} by ${fallbackSong.artist}",
                    fallbackSong.title,
                    fallbackSong.artist
                )
                return VoiceResolution.PlayRadio(
                    song = fallbackSong,
                    announcement = msg
                )
            }
        }

        val notFoundMsg = formatString(
            context,
            R.string.voice_no_results,
            "Couldn't find music matching '$rawQuery'",
            rawQuery
        )
        return VoiceResolution.NotFound(
            query = rawQuery,
            announcement = notFoundMsg
        )
    }

    private fun stripSpokenPrefixes(text: String): String {
        var res = text.trim()
        val prefixes = listOf(
            "play my playlist ", "play playlist ", "my playlist ", "playlist ",
            "play the album ", "play album ", "the album ", "album ",
            "play music by ", "play songs by ", "music by ", "songs by ", "play artist ",
            "play song ", "play track ", "play "
        )
        for (p in prefixes) {
            if (res.startsWith(p, ignoreCase = true)) {
                res = res.substring(p.length).trim()
                break
            }
        }
        return res
    }

    private fun hasPrefix(text: String, vararg prefixes: String): Boolean {
        val trimmed = text.trim()
        return prefixes.any { trimmed.startsWith(it, ignoreCase = true) }
    }

    private fun cleanSpokenWords(text: String, vararg phrases: String): String? {
        var res = text.trim()
        for (p in phrases) {
            if (res.startsWith(p, ignoreCase = true)) {
                res = res.substring(p.length).trim()
            }
        }
        return res.takeIf { it.isNotBlank() }
    }

    private fun formatString(context: Context?, resId: Int, fallback: String, vararg args: Any): String {
        return if (context != null) {
            try {
                context.getString(resId, *args)
            } catch (_: Exception) {
                fallback
            }
        } else {
            fallback
        }
    }
}
