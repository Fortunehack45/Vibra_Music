package com.fortune.vibramusic.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import okio.Buffer
import java.net.URLEncoder
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * An artist's photo as Apple Music shows it — found from nothing but their name.
 */
object AppleArtistPhotos {

    private const val TAG = "AppleArtistPhotos"
    private const val HEAD_LIMIT = 64 * 1024
    private const val USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"

    private val known = ConcurrentHashMap<String, String>()

    private const val KEY_PREFIX = "v2|"

    private val client by lazy {
        Http.client.newBuilder()
            .callTimeout(8, TimeUnit.SECONDS)
            .connectTimeout(4, TimeUnit.SECONDS)
            .build()
    }

    private val json = Json { ignoreUnknownKeys = true }

    private val OG_IMAGE = Regex("""property="og:image"\s+content="([^"]+)"""")

    fun seed(photos: Map<String, String>) {
        photos.forEach { (key, url) ->
            if (key.startsWith(KEY_PREFIX) && (url.isEmpty() || isArtistPhoto(url))) known.putIfAbsent(key, url)
        }
    }

    fun snapshot(): Map<String, String> = HashMap(known)

    suspend fun photoFor(artistName: String, catalogue: suspend () -> Collection<String>): String? {
        val name = artistName.matchKey()
        if (name.isEmpty()) return null
        val key = KEY_PREFIX + name
        known[key]?.let { return it.ifEmpty { null } }
        val titles = AppleCatalogue.keys(runCatching { catalogue() }.getOrDefault(emptyList()))
        if (titles.isEmpty()) return null
        val found = withContext(Dispatchers.IO) {
            runCatching { lookup(artistName, name, titles) }
                .onFailure { TrackLog.d(TAG, "lookup failed for $artistName: $it") }
                .getOrElse { return@withContext null }
                ?: ""
        } ?: return null
        known[key] = found
        return found.ifEmpty { null }
    }

    private fun lookup(artistName: String, key: String, titles: Set<String>): String? {
        val url = "https://itunes.apple.com/search?term=${URLEncoder.encode(artistName, "UTF-8")}" +
            "&entity=musicArtist&limit=5"
        val body = client.newCall(Request.Builder().url(url).header("User-Agent", USER_AGENT).build())
            .execute().use { if (it.isSuccessful) it.body?.string() else null } ?: return null
        val results = json.parseToJsonElement(body).jsonObject["results"]?.jsonArray ?: return null
        return results.asSequence()
            .map { it.jsonObject }
            .filter { it.string("artistName").orEmpty().matchKey() == key }
            .filter { it.string("artistLinkUrl").orEmpty().startsWith("https://music.apple.com/") }
            .filter { result ->
                val id = result.string("artistId")?.toLongOrNull() ?: return@filter false
                AppleCatalogue.sharesTitles(id, titles).also { shares ->
                    if (!shares) TrackLog.d(TAG, "$artistName: Apple ${result.string("artistName")} ($id) shares no titles, skipped")
                }
            }
            .mapNotNull { it.string("artistLinkUrl")?.substringBefore('?') }
            .take(MATCHES_TRIED)
            .firstNotNullOfOrNull(::ogImage)
    }

    private const val MATCHES_TRIED = 2

    private fun String.matchKey(): String = AppleCatalogue.matchKey(this)

    private fun ogImage(pageUrl: String): String? =
        client.newCall(Request.Builder().url(pageUrl).header("User-Agent", USER_AGENT).build()).execute().use { response ->
            if (!response.isSuccessful) return null
            val source = response.body?.source() ?: return null
            val buffer = Buffer()
            val head = StringBuilder()
            while (head.length < HEAD_LIMIT && source.read(buffer, 8_192) != -1L) {
                head.append(buffer.readUtf8())
                OG_IMAGE.find(head)?.let { return it.groupValues[1].takeIf(::isArtistPhoto) }
                if ("</head>" in head) return null
            }
            null
        }

    private fun isArtistPhoto(url: String): Boolean {
        val bucket = url.substringAfter("mzstatic.com/image/thumb/", "").substringBefore('/')
        return bucket.startsWith("Features") || bucket.startsWith("AMCArtistImages")
    }

    private fun JsonObject.string(name: String): String? = this[name]?.jsonPrimitive?.content
}
