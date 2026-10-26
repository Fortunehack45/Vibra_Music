package com.fortune.vibramusic.playback.voice

import android.content.Context
import android.provider.MediaStore
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.LocalPlaylistsStore
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.BrowseType
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

        // Clean spoken prefixes like "play", "play my playlist", etc.
        val cleanQuery = stripSpokenPrefixes(rawQuery)

        // 1. Resume check: empty query, or query cleaned down to empty or generic request
        val isGenericMusicRequest = cleanQuery.isBlank() ||
                cleanQuery.equals("music", ignoreCase = true) ||
                cleanQuery.equals("songs", ignoreCase = true) ||
                cleanQuery.equals("some music", ignoreCase = true) ||
                cleanQuery.equals("some songs", ignoreCase = true) ||
                cleanQuery.equals("something", ignoreCase = true)

        if ((rawQuery.isEmpty() || isGenericMusicRequest) &&
            focus.isNullOrEmpty() && explicitTitle == null &&
            explicitArtist == null && explicitAlbum == null && explicitPlaylist == null
        ) {
            return VoiceResolution.Resume
        }

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
            // First check if query directly names an artist without a specific song
            val directArtists = YtMusicRepository.search(effectiveQuery, SearchFilter.ARTISTS).getOrNull()
                ?.filterIsInstance<SearchResult.Browse>()
            val directArtist = directArtists?.firstOrNull {
                it.item.title.equals(effectiveQuery, ignoreCase = true)
            } ?: if (parsedArtist != null) directArtists?.firstOrNull() else null

            if (directArtist != null && parsedTitle == null) {
                val artistPage = YtMusicRepository.artistPage(directArtist.item.browseId).getOrNull()
                val songs = artistPage?.songs.orEmpty()
                if (songs.isNotEmpty()) {
                    val msg = formatString(
                        context,
                        R.string.voice_playing_artist,
                        "Playing music by ${directArtist.item.title}",
                        directArtist.item.title
                    )
                    return VoiceResolution.PlaySongs(
                        title = directArtist.item.title,
                        songs = songs,
                        announcement = msg
                    )
                }
            }

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

            // Fallback: check SearchFilter.ALL (matches top entity whether track, artist, album, or playlist)
            val allResults = YtMusicRepository.search(effectiveQuery, SearchFilter.ALL).getOrNull().orEmpty()
            val topBrowse = allResults.firstOrNull() as? SearchResult.Browse
            if (topBrowse != null) {
                when (topBrowse.item.type) {
                    BrowseType.ARTIST -> {
                        val artistPage = YtMusicRepository.artistPage(topBrowse.item.browseId).getOrNull()
                        val artistSongs = artistPage?.songs.orEmpty()
                        if (artistSongs.isNotEmpty()) {
                            val msg = formatString(
                                context,
                                R.string.voice_playing_artist,
                                "Playing music by ${topBrowse.item.title}",
                                topBrowse.item.title
                            )
                            return VoiceResolution.PlaySongs(
                                title = topBrowse.item.title,
                                songs = artistSongs,
                                announcement = msg
                            )
                        }
                    }
                    BrowseType.ALBUM -> {
                        val albumSongs = YtMusicRepository.browseSongs(topBrowse.item.browseId).getOrNull()?.songs
                        if (!albumSongs.isNullOrEmpty()) {
                            val msg = formatString(
                                context,
                                R.string.voice_playing_album,
                                "Playing album ${topBrowse.item.title}",
                                topBrowse.item.title
                            )
                            return VoiceResolution.PlaySongs(
                                title = topBrowse.item.title,
                                songs = albumSongs,
                                announcement = msg
                            )
                        }
                    }
                    BrowseType.PLAYLIST -> {
                        val playlistSongs = YtMusicRepository.browseSongs(topBrowse.item.browseId).getOrNull()?.songs
                        if (!playlistSongs.isNullOrEmpty()) {
                            val msg = formatString(
                                context,
                                R.string.voice_playing_playlist,
                                "Playing playlist ${topBrowse.item.title}",
                                topBrowse.item.title
                            )
                            return VoiceResolution.PlaySongs(
                                title = topBrowse.item.title,
                                songs = playlistSongs,
                                announcement = msg
                            )
                        }
                    }
                    else -> Unit
                }
            }

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

    fun cleanSpokenQuery(text: String): String {
        var res = text.trim()

        // 1. Strip trailing app qualifiers (e.g. "on Vibra Music", "in Vibra")
        val trailingAppPhrases = listOf(
            " on vibra music app", " in vibra music app",
            " on vibra music", " in vibra music",
            " on vibra", " in vibra",
            " on siren music app", " in siren music app",
            " on siren music", " in siren music",
            " on siren", " in siren",
            " using vibra music", " with vibra music",
            " using vibra", " with vibra",
        )
        for (suffix in trailingAppPhrases) {
            if (res.endsWith(suffix, ignoreCase = true)) {
                res = res.substring(0, res.length - suffix.length).trim()
                break
            }
        }

        // 2. Strip conversational preambles
        val conversationalPrefixes = listOf(
            "just help me to play ",
            "just help me play ",
            "help me to play ",
            "help me play ",
            "can you please play ",
            "can you play ",
            "please play ",
            "i want to hear ",
            "i want to listen to ",
            "start playing ",
            "put on ",
            "go ahead and play ",
            "and play ",
            "play some music by ",
            "play some songs by ",
            "play something by ",
            "play my playlist ",
            "play playlist ",
            "my playlist ",
            "play the album ",
            "play album ",
            "the album ",
            "play music by ",
            "play songs by ",
            "music by ",
            "songs by ",
            "play artist ",
            "play song ",
            "play track ",
            "play ",
        )
        for (p in conversationalPrefixes) {
            if (res.startsWith(p, ignoreCase = true)) {
                res = res.substring(p.length).trim()
                break
            }
        }

        // 3. Strip leading single/quantity tokens and trailing music/song/track tokens:
        // Handles "one Asake song" -> "Asake", "some Asake music" -> "Asake", "play Asake song" -> "Asake"
        val quantityPrefixes = listOf("one ", "a ", "an ", "some ")
        val trailingTokens = listOf(" song", " songs", " track", " tracks", " music")

        val hasTrailingToken = trailingTokens.any { res.endsWith(it, ignoreCase = true) }
        if (hasTrailingToken) {
            for (qp in quantityPrefixes) {
                if (res.startsWith(qp, ignoreCase = true)) {
                    res = res.substring(qp.length).trim()
                    break
                }
            }
            for (tt in trailingTokens) {
                if (res.endsWith(tt, ignoreCase = true)) {
                    res = res.substring(0, res.length - tt.length).trim()
                    break
                }
            }
        } else {
            for (qp in listOf("one ")) {
                if (res.startsWith(qp, ignoreCase = true)) {
                    res = res.substring(qp.length).trim()
                    break
                }
            }
        }

        return res
    }

    private fun stripSpokenPrefixes(text: String): String = cleanSpokenQuery(text)

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
