package com.fortune.vibramusic.playback.smart

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.Log
import com.fortune.vibramusic.data.canvas.SpotifyToken
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.durationMillis
import com.fortune.vibramusic.playback.AudioCache
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.concurrent.ConcurrentHashMap

/**
 * Provides instant and verified BPM and Camelot Key metadata for tracks.
 * Backed by a verified catalog seed, an in-memory LRU cache, disk persistence,
 * background pre-warming, and Spotify audio-features resolution.
 */
object AcousticCatalogService {

    private const val TAG = "AcousticCatalogService"
    private const val PREFS_NAME = "acoustic_catalog_cache_v3"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val memoryCache = ConcurrentHashMap<String, AcousticData>()
    private val requested = ConcurrentHashMap.newKeySet<String>()
    private var prefs: SharedPreferences? = null
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val client = HttpClient(OkHttp)

    data class AcousticData(
        val bpm: Double,
        val camelotKey: String,
    )

    internal fun clearCache() {
        memoryCache.clear()
        requested.clear()
    }

    fun put(videoId: String, bpm: Double, key: String) {
        if (videoId.isBlank() || bpm <= 0.0) return
        val camelot = CamelotKey.parse(key)?.code ?: key.takeIf { it.isNotBlank() } ?: ""
        val data = AcousticData(bpm, camelot)
        memoryCache[videoId] = data
        prefs?.edit()?.putString(videoId, "$bpm:$camelot")?.apply()
        AnalysisStore.notifyUpdated(videoId)
    }

    fun init(context: Context) {
        if (prefs == null) {
            val appCtx = runCatching { context.applicationContext }.getOrNull() ?: context
            prefs = appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    private fun normalizeString(text: String): String {
        return text.lowercase()
            .replace("’", "'")
            .replace("`", "'")
            .replace("$", "s")
            .replace(Regex("""\s*\(.*?\)|\[.*?\]"""), "")
            .replace(Regex("""\s*\b(feat\.?|ft\.?|with)\b.*""", RegexOption.IGNORE_CASE), "")
            .replace(Regex("""[^a-z0-9\s]"""), " ")
            .trim()
            .replace(Regex("""\s+"""), " ")
    }

    private fun primaryArtist(artist: String): String {
        val first = artist.split(Regex("""[,&/]|(\bfeat\.?\b)|(\bft\.?\b)|(\bwith\b)|(\bx\b)|(\bvs\.?\b)""", RegexOption.IGNORE_CASE))
            .firstOrNull() ?: artist
        return normalizeString(first)
    }

    private fun candidateKeys(artist: String, title: String): List<String> {
        val cleanTitle = normalizeString(title)
        val pArtist = primaryArtist(artist)
        val fullArtist = normalizeString(artist)
        val splitArtists = artist.split(Regex("""[,&/]|(\bfeat\.?\b)|(\bft\.?\b)|(\bwith\b)|(\bx\b)|(\bvs\.?\b)""", RegexOption.IGNORE_CASE))
            .map { normalizeString(it) }
            .filter { it.isNotBlank() }

        val list = mutableListOf<String>()
        if (pArtist.isNotBlank() && cleanTitle.isNotBlank()) list += "${pArtist}_$cleanTitle"
        splitArtists.forEach { a ->
            if (a.isNotBlank() && cleanTitle.isNotBlank()) list += "${a}_$cleanTitle"
        }
        if (fullArtist.isNotBlank() && cleanTitle.isNotBlank()) list += "${fullArtist}_$cleanTitle"
        if (cleanTitle.isNotBlank()) list += cleanTitle
        return list.distinct()
    }

    fun get(song: Song, store: AnalysisStore? = null): AcousticData? {
        memoryCache[song.videoId]?.let { return it }

        // 0. Read from in-memory TrackMetaRepository (0ms sync, safe in Compose)
        TrackMetaRepository.peek(song.videoId)?.let { meta ->
            val bpm = meta.bpm?.value
            val key = meta.key?.value?.code
            if (bpm != null && bpm > 0.0) {
                val data = AcousticData(bpm, key ?: "")
                memoryCache[song.videoId] = data
                return data
            }
        }

        // 1. Read from on-device persistent analysis store
        store?.load(song.videoId)?.let { analysis ->
            if (analysis.isUsable && analysis.beats.isNotEmpty()) {
                val camelot = CamelotKey.parse(analysis.key)?.code ?: analysis.key
                val data = AcousticData(analysis.bpm, camelot)
                memoryCache[song.videoId] = data
                return data
            }
        }

        // 2. Read from in-memory analyzer instance if available
        TrackAnalyzer.peekInstance()?.getAnalysis(song.videoId)?.let { analysis ->
            if (analysis.isUsable && analysis.beats.isNotEmpty()) {
                val camelot = CamelotKey.parse(analysis.key)?.code ?: analysis.key
                val data = AcousticData(analysis.bpm, camelot)
                memoryCache[song.videoId] = data
                return data
            }
        }

        // 3. Check local persistent cache
        prefs?.let { p ->
            val stored = p.getString(song.videoId, null)
            if (stored != null) {
                val parts = stored.split(":")
                if (parts.size == 2) {
                    val bpm = parts[0].toDoubleOrNull() ?: 0.0
                    val key = parts[1]
                    if (bpm > 0.0) {
                        val data = AcousticData(bpm, key)
                        memoryCache[song.videoId] = data
                        return data
                    }
                }
            }
        }

        return null
    }

    /**
     * Retrieves genuine metadata or null. Never invents fake numbers.
     */
    fun getOrEstimate(song: Song, store: AnalysisStore? = null): AcousticData? {
        return get(song, store)
    }

    /**
     * Resolves an entire playlist rapidly in the background using the prioritized
     * scheduler (shared public cache lookup + fast on-device analysis).
     */
    fun resolvePlaylistFast(context: Context, songs: List<Song>, store: AnalysisStore) {
        init(context)
        MetaSchedulerHolder.get(context).prefetch(songs, MetaPriority.PLAYLIST)
    }

    /**
     * Purges old fabricated estimates and synthesized analyses that have no measured beat grid.
     */
    fun purgeFabricatedMeta(context: Context, store: AnalysisStore) {
        init(context)
        val p = prefs ?: return
        val alreadyPurged = p.getBoolean("fabricated_meta_purged_v1", false)
        if (alreadyPurged) return

        p.edit().clear().putBoolean("fabricated_meta_purged_v1", true).apply()
        memoryCache.clear()

        store.allTrackIds().forEach { id ->
            val a = store.load(id) ?: return@forEach
            val synthesized = a.beats.isEmpty() && a.downbeats.isEmpty() && a.energyCurve.isEmpty()
            if (synthesized) {
                store.delete(id)
            }
        }
    }

    fun resolve(context: Context, song: Song, store: AnalysisStore) {
        init(context)
        val existing = get(song, store)
        if (existing != null) return

        if (!requested.add(song.videoId)) return

        scope.launch {
            try {
                // 1. Trigger dynamic on-device native C++ DSP analysis
                val opusUri = AutomixAnalysisSource.opusUri(song.videoId)
                val uri = Uri.parse(opusUri)
                val analyzer = TrackAnalyzer.getInstance(context)
                val durSec = (song.durationMillis() / 1000.0).takeIf { it > 10.0 } ?: 0.0
                analyzer.request(song.videoId, uri, durSec)

                // 2. Parallel dynamic cloud metadata resolution if Spotify token is active
                val token = SpotifyToken.accessToken()
                if (token != null) {
                    val query = "${song.title} ${song.artist}"
                    val searchUrl = "https://api.spotify.com/v1/search?q=${java.net.URLEncoder.encode(query, "UTF-8")}&type=track&limit=1"
                    val searchResp = client.get(searchUrl) {
                        header("Authorization", "Bearer $token")
                    }.bodyAsText()

                    val root = json.parseToJsonElement(searchResp).jsonObject
                    val trackItem = root["tracks"]?.jsonObject?.get("items")?.jsonArray?.firstOrNull()?.jsonObject
                    val trackId = trackItem?.get("id")?.jsonPrimitive?.content
                    if (trackId != null) {
                        val featuresUrl = "https://api.spotify.com/v1/audio-features/$trackId"
                        val featuresResp = client.get(featuresUrl) {
                            header("Authorization", "Bearer $token")
                        }.bodyAsText()

                        val featObj = json.parseToJsonElement(featuresResp).jsonObject
                        val tempo = featObj["tempo"]?.jsonPrimitive?.content?.toDoubleOrNull()
                        val keyInt = featObj["key"]?.jsonPrimitive?.content?.toIntOrNull() ?: 0
                        val modeInt = featObj["mode"]?.jsonPrimitive?.content?.toIntOrNull() ?: 1

                        if (tempo != null && tempo > 0.0) {
                            val camelot = spotifyKeyToCamelot(keyInt, modeInt) ?: ""
                            val data = AcousticData(tempo, camelot)
                            memoryCache[song.videoId] = data
                            prefs?.edit()?.putString(song.videoId, "$tempo:$camelot")?.apply()

                            val camelotObj = CamelotKey.parse(camelot)
                            TrackMetaRepository.ingest(
                                TrackMeta(
                                    trackId = song.videoId,
                                    bpm = Field(tempo, 0.85f, MetaSource.SHARED),
                                    key = camelotObj?.let { Field(it, 0.85f, MetaSource.SHARED) },
                                    updatedAt = System.currentTimeMillis(),
                                ),
                                MetaSchedulerHolder.getDao(context),
                            )
                            AnalysisStore.notifyUpdated(song.videoId)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.d(TAG, "Acoustic resolution failed for ${song.title}: ${e.message}")
                requested.remove(song.videoId)
            }
        }
    }

    internal fun normalizeTempo(raw: Double): Double {
        if (raw <= 0.0) return 120.0
        var b = raw
        while (b < 75.0) {
            b *= 2.0
        }
        while (b > 165.0) {
            b /= 2.0
        }
        return b
    }

    internal fun spotifyKeyToCamelot(key: Int, mode: Int): String? {
        if (key !in 0..11) return null
        val isMajor = mode == 1
        val pitchName = when (key) {
            0 -> "c"
            1 -> "c#"
            2 -> "d"
            3 -> "d#"
            4 -> "e"
            5 -> "f"
            6 -> "f#"
            7 -> "g"
            8 -> "g#"
            9 -> "a"
            10 -> "a#"
            11 -> "b"
            else -> return null
        }
        val notation = if (isMajor) "${pitchName}maj" else "${pitchName}m"
        return CamelotKey.parse(notation)?.code
    }
}
