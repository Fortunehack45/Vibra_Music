package com.fortune.vibramusic.data.supabase

import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.UserListeningExperience
import com.fortune.vibramusic.data.model.UserPlaylist
import com.fortune.vibramusic.data.settings.AppSettings
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Service for syncing music listening experience, replay metrics, liked songs,
 * and user playlist metadata with Supabase. Strictly NO audio bytes are synced.
 */
object SupabaseService {

    private const val TAG = "SupabaseService"

    private val client by lazy {
        HttpClient(OkHttp) {
            install(ContentNegotiation) {
                json(Json {
                    ignoreUnknownKeys = true
                    isLenient = true
                    coerceInputValues = true
                })
            }
        }
    }

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    private fun baseUrl(table: String): String {
        val root = SupabaseConfig.url.trimEnd('/')
        return "$root/rest/v1/$table"
    }

    private fun JsonObject.str(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content?.takeIf { it.isNotBlank() && it != "null" }

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content?.toIntOrNull()

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content?.toBooleanStrictOrNull()

    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content?.toDoubleOrNull()

    private fun JsonObject.arr(key: String): JsonArray? = this[key] as? JsonArray

    private fun jsonQuote(text: String): String = PostgrestSanitizer.safeJsonString(text)

    /**
     * Pings the database to keep free-tier projects from pausing after inactivity.
     * Enforces a 5-day client-side interval.
     */
    suspend fun pingDatabase(force: Boolean = false): Result<Boolean> = withContext(Dispatchers.IO) {
        runCatching {
            val now = System.currentTimeMillis()
            val fiveDaysMs = 5L * 24 * 60 * 60 * 1000
            if (!force && (now - AppSettings.lastSupabasePingTimestamp) < fiveDaysMs) {
                return@runCatching true
            }
            val response = client.get(baseUrl("user_listening_experience")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("select", "user_id")
                parameter("limit", "1")
            }
            if (response.status.isSuccess()) {
                AppSettings.lastSupabasePingTimestamp = now
                Log.d(TAG, "Database keepalive ping successful.")
                true
            } else {
                Log.w(TAG, "Database ping returned ${response.status}")
                false
            }
        }
    }

    /**
     * Synchronizes listening experience preferences and connected Spotify session.
     */
    suspend fun syncListeningExperience(
        userId: String,
        spotifySpdcToken: String?,
        spotifyConnected: Boolean,
        audioQuality: String,
        equalizerEnabled: Boolean,
        equalizerPreset: String,
        volumeNormalization: Boolean,
        bassBoostPercent: Int,
        virtualizerPercent: Int,
        pitchCents: Int,
        tempoMultiplier: Float,
        autoSkipSilence: Boolean,
        lyricsSource: String,
        canvasEnabled: Boolean,
        preferredGenres: List<String> = emptyList(),
        listeningStatsJson: String? = null,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val genresJson = preferredGenres.joinToString(prefix = "[", postfix = "]", separator = ",") { jsonQuote(it) }
            val body = buildString {
                append("{")
                append("\"user_id\":\"$userId\",")
                if (spotifySpdcToken != null) append("\"spotify_spdc_token\":${jsonQuote(spotifySpdcToken)},")
                append("\"spotify_connected\":$spotifyConnected,")
                append("\"audio_quality\":${jsonQuote(audioQuality)},")
                append("\"equalizer_enabled\":$equalizerEnabled,")
                append("\"equalizer_preset\":${jsonQuote(equalizerPreset)},")
                append("\"volume_normalization\":$volumeNormalization,")
                append("\"bass_boost_percent\":$bassBoostPercent,")
                append("\"virtualizer_percent\":$virtualizerPercent,")
                append("\"pitch_cents\":$pitchCents,")
                append("\"tempo_multiplier\":$tempoMultiplier,")
                append("\"auto_skip_silence\":$autoSkipSilence,")
                append("\"lyrics_source\":${jsonQuote(lyricsSource)},")
                append("\"canvas_enabled\":$canvasEnabled,")
                append("\"preferred_genres\":$genresJson")
                if (listeningStatsJson != null) append(",\"listening_stats_json\":${jsonQuote(listeningStatsJson)}")
                append("}")
            }
            val res = client.post("${baseUrl("user_listening_experience")}?on_conflict=user_id") {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "syncListeningExperience returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Fetches saved listening experience and connected Spotify session for a user.
     */
    suspend fun fetchListeningExperience(userId: String): Result<UserListeningExperience?> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("user_listening_experience")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchListeningExperience ${response.status}: $err")
                return@runCatching null
            }
            val root = json.parseToJsonElement(response.bodyAsText())
            if (root !is JsonArray) {
                Log.w(TAG, "fetchListeningExperience: expected array, got: ${response.bodyAsText().take(300)}")
                return@runCatching null
            }
            val obj = root.firstOrNull() as? JsonObject ?: return@runCatching null
            val genres = obj.arr("preferred_genres")?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p !is JsonNull }?.content?.takeIf { s -> s.isNotBlank() && s != "null" } } ?: emptyList()
            UserListeningExperience(
                userId = userId,
                spotifySpdcToken = obj.str("spotify_spdc_token"),
                spotifyConnected = obj.bool("spotify_connected") ?: false,
                audioQuality = obj.str("audio_quality") ?: "HIGH",
                equalizerEnabled = obj.bool("equalizer_enabled") ?: false,
                equalizerPreset = obj.str("equalizer_preset") ?: "FLAT",
                volumeNormalization = obj.bool("volume_normalization") ?: true,
                bassBoostPercent = obj.int("bass_boost_percent") ?: 0,
                virtualizerPercent = obj.int("virtualizer_percent") ?: 0,
                pitchCents = obj.int("pitch_cents") ?: 0,
                tempoMultiplier = obj.double("tempo_multiplier")?.toFloat() ?: 1.0f,
                autoSkipSilence = obj.bool("auto_skip_silence") ?: false,
                lyricsSource = obj.str("lyrics_source") ?: "DEFAULT",
                canvasEnabled = obj.bool("canvas_enabled") ?: true,
                preferredGenres = genres,
                listeningStatsJson = obj.str("listening_stats_json"),
            )
        }
    }

    /**
     * Records a liked music track (metadata only, no audio bytes).
     */
    suspend fun syncLikedTrack(userId: String, song: Song): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val body = buildString {
                append("{")
                append("\"user_id\":\"$userId\",")
                append("\"video_id\":\"${song.videoId}\",")
                append("\"title\":${jsonQuote(song.title)},")
                append("\"artist\":${jsonQuote(song.artist)}")
                if (song.thumbnailUrl != null) append(",\"thumbnail_url\":${jsonQuote(song.thumbnailUrl)}")
                if (song.durationText != null) append(",\"duration_text\":${jsonQuote(song.durationText)}")
                append("}")
            }
            val res = client.post(baseUrl("user_liked_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "syncLikedTrack returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Removes a liked track from the user's cloud library.
     */
    suspend fun removeLikedTrack(userId: String, videoId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val res = client.delete(baseUrl("user_liked_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("video_id", "eq.$videoId")
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "removeLikedTrack returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Fetches all liked tracks for a user from Supabase.
     */
    suspend fun fetchLikedTracks(userId: String): Result<List<Song>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("user_liked_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("order", "liked_at.desc")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchLikedTracks ${response.status}: $err")
                return@runCatching emptyList()
            }
            val root = json.parseToJsonElement(response.bodyAsText())
            if (root !is JsonArray) {
                Log.w(TAG, "fetchLikedTracks: expected array, got: ${response.bodyAsText().take(300)}")
                return@runCatching emptyList()
            }
            root.mapNotNull { el ->
                val obj = el as? JsonObject ?: return@mapNotNull null
                val videoId = obj.str("video_id") ?: return@mapNotNull null
                val title = obj.str("title") ?: return@mapNotNull null
                val artist = obj.str("artist") ?: ""
                val thumb = obj.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" }
                val duration = obj.str("duration_text")
                Song(
                    videoId = videoId,
                    title = title,
                    artist = artist,
                    thumbnailUrl = thumb,
                    durationText = duration,
                )
            }
        }
    }

    /**
     * Synchronizes a user playlist metadata to the cloud.
     */
    suspend fun syncPlaylist(
        userId: String,
        playlistId: String,
        title: String,
        description: String = "",
        thumbnailUrl: String? = null,
        trackCount: Int = 0,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val body = buildString {
                append("{")
                append("\"id\":\"$playlistId\",")
                append("\"user_id\":\"$userId\",")
                append("\"title\":${jsonQuote(title)},")
                append("\"description\":${jsonQuote(description)},")
                if (thumbnailUrl != null) append("\"thumbnail_url\":${jsonQuote(thumbnailUrl)},")
                append("\"track_count\":$trackCount")
                append("}")
            }
            val res = client.post(baseUrl("user_playlists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "syncPlaylist returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Deletes a user playlist and its tracks from the cloud.
     */
    suspend fun deletePlaylist(userId: String, playlistId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val res = client.delete(baseUrl("user_playlists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$playlistId")
                parameter("user_id", "eq.$userId")
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "deletePlaylist returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Synchronizes the tracks of a playlist (metadata only, no audio bytes).
     */
    suspend fun syncPlaylistTracks(
        userId: String,
        playlistId: String,
        tracks: List<Song>,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            client.delete(baseUrl("user_playlist_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("playlist_id", "eq.$playlistId")
            }
            if (tracks.isNotEmpty()) {
                val tracksJson = tracks.mapIndexed { idx, song ->
                    buildString {
                        append("{")
                        append("\"playlist_id\":\"$playlistId\",")
                        append("\"user_id\":\"$userId\",")
                        append("\"video_id\":\"${song.videoId}\",")
                        append("\"title\":${jsonQuote(song.title)},")
                        append("\"artist\":${jsonQuote(song.artist)},")
                        if (song.thumbnailUrl != null) append("\"thumbnail_url\":${jsonQuote(song.thumbnailUrl)},")
                        if (song.durationText != null) append("\"duration_text\":${jsonQuote(song.durationText)},")
                        append("\"position\":$idx")
                        append("}")
                    }
                }.joinToString(",", "[", "]")

                val res = client.post(baseUrl("user_playlist_tracks")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody(tracksJson)
                }
                if (!res.status.isSuccess()) {
                    Log.w(TAG, "syncPlaylistTracks returned ${res.status}: ${res.bodyAsText().take(300)}")
                }
            }
            Unit
        }
    }

    /**
     * Fetches all user playlists along with their track items from the cloud.
     */
    suspend fun fetchUserPlaylistsWithTracks(
        userId: String,
    ): Result<List<Pair<UserPlaylist, List<Song>>>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("user_playlists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("order", "created_at.desc")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchUserPlaylistsWithTracks ${response.status}: $err")
                return@runCatching emptyList()
            }
            val root = json.parseToJsonElement(response.bodyAsText())
            if (root !is JsonArray) {
                Log.w(TAG, "fetchUserPlaylistsWithTracks: expected array, got: ${response.bodyAsText().take(300)}")
                return@runCatching emptyList()
            }
            val result = mutableListOf<Pair<UserPlaylist, List<Song>>>()

            for (item in root) {
                val pObj = item as? JsonObject ?: continue
                val pId = pObj.str("id") ?: continue
                val pTitle = pObj.str("title") ?: "Playlist"
                val pThumb = pObj.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" }

                val tracksResp = client.get(baseUrl("user_playlist_tracks")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("playlist_id", "eq.$pId")
                    parameter("order", "position.asc")
                }
                if (!tracksResp.status.isSuccess()) {
                    Log.w(TAG, "fetchUserPlaylistsWithTracks tracks ${tracksResp.status}: ${tracksResp.bodyAsText().take(300)}")
                    continue
                }
                val tracksRoot = json.parseToJsonElement(tracksResp.bodyAsText())
                val songs = if (tracksRoot is JsonArray) {
                    tracksRoot.mapNotNull { tItem ->
                        val tObj = tItem as? JsonObject ?: return@mapNotNull null
                        val vId = tObj.str("video_id") ?: return@mapNotNull null
                        val title = tObj.str("title") ?: return@mapNotNull null
                        val artist = tObj.str("artist") ?: ""
                        val thumb = tObj.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" }
                        val duration = tObj.str("duration_text")
                        Song(
                            videoId = vId,
                            title = title,
                            artist = artist,
                            thumbnailUrl = thumb,
                            durationText = duration,
                        )
                    }
                } else emptyList()

                val userPlaylist = UserPlaylist(
                    playlistId = pId,
                    title = pTitle,
                    subtitle = "${songs.size} " + if (songs.size == 1) "song" else "songs",
                    thumbnailUrl = pThumb ?: songs.firstOrNull()?.thumbnailUrl,
                )
                result.add(userPlaylist to songs)
            }
            result
        }
    }
}
