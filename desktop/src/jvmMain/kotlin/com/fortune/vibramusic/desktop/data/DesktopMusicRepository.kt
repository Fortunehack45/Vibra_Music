package com.fortune.vibramusic.desktop.data

import com.fortune.vibramusic.desktop.model.DesktopLyricLine
import com.fortune.vibramusic.desktop.model.DesktopSong
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.get
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.services.youtube.YoutubeService
import org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor
import java.io.IOException

object DesktopMusicRepository {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    private val httpClient = HttpClient(OkHttp) {
        install(ContentNegotiation) {
            json(json)
        }
    }

    private val newPipeDownloader = object : Downloader() {
        private val okHttp = okhttp3.OkHttpClient.Builder().build()

        override fun execute(request: Request): Response {
            val reqBuilder = okhttp3.Request.Builder()
                .url(request.url())
                .method(request.httpMethod(), request.dataToSend()?.let {
                    okhttp3.RequestBody.create(null, it)
                })

            request.headers().forEach { (k, v) ->
                v.forEach { reqBuilder.addHeader(k, it) }
            }

            val resp = okHttp.newCall(reqBuilder.build()).execute()
            val headersMap = mutableMapOf<String, List<String>>()
            resp.headers.names().forEach { name ->
                headersMap[name] = resp.headers.values(name)
            }

            return Response(
                resp.code,
                resp.message,
                headersMap,
                resp.body?.string(),
                resp.request.url.toString()
            )
        }
    }

    init {
        try {
            NewPipe.init(newPipeDownloader)
        } catch (_: Throwable) {}
    }

    /**
     * Featured / Quick Picks for the Home Screen.
     */
    fun getFeaturedSongs(): List<DesktopSong> {
        return listOf(
            DesktopSong(
                id = "kJQP7kiw5Fk",
                title = "Despacito",
                artist = "Luis Fonsi ft. Daddy Yankee",
                album = "VIDA",
                thumbnailUrl = "https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg",
                durationSeconds = 282,
            ),
            DesktopSong(
                id = "JGwWNGJdvx8",
                title = "Shape of You",
                artist = "Ed Sheeran",
                album = "÷ (Divide)",
                thumbnailUrl = "https://i.ytimg.com/vi/JGwWNGJdvx8/hqdefault.jpg",
                durationSeconds = 233,
            ),
            DesktopSong(
                id = "4NRXx6U8ABQ",
                title = "Blinding Lights",
                artist = "The Weeknd",
                album = "After Hours",
                thumbnailUrl = "https://i.ytimg.com/vi/4NRXx6U8ABQ/hqdefault.jpg",
                durationSeconds = 200,
            ),
            DesktopSong(
                id = "fJ9rUzIMcZQ",
                title = "Bohemian Rhapsody",
                artist = "Queen",
                album = "A Night at the Opera",
                thumbnailUrl = "https://i.ytimg.com/vi/fJ9rUzIMcZQ/hqdefault.jpg",
                durationSeconds = 359,
            ),
            DesktopSong(
                id = "k2qgadSvNyU",
                title = "New Rules",
                artist = "Dua Lipa",
                album = "Dua Lipa",
                thumbnailUrl = "https://i.ytimg.com/vi/k2qgadSvNyU/hqdefault.jpg",
                durationSeconds = 225,
            ),
            DesktopSong(
                id = "hT_nvWreIhg",
                title = "Counting Stars",
                artist = "OneRepublic",
                album = "Native",
                thumbnailUrl = "https://i.ytimg.com/vi/hT_nvWreIhg/hqdefault.jpg",
                durationSeconds = 257,
            ),
        )
    }

    /**
     * Search songs by query using YouTube Music / InnerTube.
     */
    suspend fun search(query: String): List<DesktopSong> = withContext(Dispatchers.IO) {
        if (query.isBlank()) return@withContext emptyList()
        try {
            val requestBody = buildJsonObject {
                putJsonObject("context") {
                    putJsonObject("client") {
                        put("clientName", "WEB_REMIX")
                        put("clientVersion", "1.20250101.01.00")
                        put("hl", "en")
                        put("gl", "US")
                    }
                }
                put("query", query)
                put("params", "EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D") // Filter to songs
            }

            val responseText = httpClient.post("https://music.youtube.com/youtubei/v1/search") {
                contentType(ContentType.Application.Json)
                setBody(requestBody.toString())
            }.bodyAsText()

            parseSearchResponse(responseText)
        } catch (t: Throwable) {
            println("[DesktopMusicRepository] Search error: ${t.message}")
            emptyList()
        }
    }

    private fun parseSearchResponse(jsonString: String): List<DesktopSong> {
        val results = mutableListOf<DesktopSong>()
        try {
            val root = json.parseToJsonElement(jsonString).jsonObject
            val contents = root["contents"]?.jsonObject
                ?.get("tabbedSearchResultsRenderer")?.jsonObject
                ?.get("tabs")?.jsonArray?.getOrNull(0)?.jsonObject
                ?.get("tabRenderer")?.jsonObject
                ?.get("content")?.jsonObject
                ?.get("sectionListRenderer")?.jsonObject
                ?.get("contents")?.jsonArray ?: return results

            for (section in contents) {
                val shelfContents = section.jsonObject["musicShelfRenderer"]?.jsonObject
                    ?.get("contents")?.jsonArray ?: continue

                for (item in shelfContents) {
                    val flexItem = item.jsonObject["musicResponsiveListItemRenderer"]?.jsonObject ?: continue
                    val flexColumns = flexItem["flexColumns"]?.jsonArray ?: continue

                    // Title
                    val titleRuns = flexColumns.getOrNull(0)?.jsonObject
                        ?.get("musicResponsiveListItemFlexColumnRenderer")?.jsonObject
                        ?.get("text")?.jsonObject
                        ?.get("runs")?.jsonArray
                    val title = titleRuns?.getOrNull(0)?.jsonObject?.get("text")?.jsonPrimitive?.contentOrNull ?: continue

                    // Video ID
                    val navEndpoint = flexItem["navigationEndpoint"]?.jsonObject
                        ?: flexColumns.getOrNull(0)?.jsonObject
                            ?.get("musicResponsiveListItemFlexColumnRenderer")?.jsonObject
                            ?.get("text")?.jsonObject
                            ?.get("runs")?.jsonArray?.getOrNull(0)?.jsonObject
                            ?.get("navigationEndpoint")?.jsonObject
                    val videoId = navEndpoint?.get("watchEndpoint")?.jsonObject
                        ?.get("videoId")?.jsonPrimitive?.contentOrNull ?: continue

                    // Artist & Album
                    val subtitleRuns = flexColumns.getOrNull(1)?.jsonObject
                        ?.get("musicResponsiveListItemFlexColumnRenderer")?.jsonObject
                        ?.get("text")?.jsonObject
                        ?.get("runs")?.jsonArray
                    val artist = subtitleRuns?.getOrNull(0)?.jsonObject?.get("text")?.jsonPrimitive?.contentOrNull ?: "Unknown Artist"
                    val album = subtitleRuns?.getOrNull(2)?.jsonObject?.get("text")?.jsonPrimitive?.contentOrNull ?: ""

                    // Thumbnail
                    val thumbnails = flexItem["thumbnail"]?.jsonObject
                        ?.get("musicThumbnailRenderer")?.jsonObject
                        ?.get("thumbnail")?.jsonObject
                        ?.get("thumbnails")?.jsonArray
                    val thumbUrl = thumbnails?.lastOrNull()?.jsonObject
                        ?.get("url")?.jsonPrimitive?.contentOrNull
                        ?: "https://i.ytimg.com/vi/$videoId/hqdefault.jpg"

                    results.add(
                        DesktopSong(
                            id = videoId,
                            title = title,
                            artist = artist,
                            album = album,
                            thumbnailUrl = thumbUrl,
                        )
                    )
                }
            }
        } catch (e: Exception) {
            println("[DesktopMusicRepository] JSON parse error: ${e.message}")
        }
        return results
    }

    /**
     * Resolves the direct audio stream URL for a given video ID via NewPipeExtractor.
     */
    suspend fun resolveStreamUrl(videoId: String): String? = withContext(Dispatchers.IO) {
        try {
            val url = "https://www.youtube.com/watch?v=$videoId"
            val extractor = YoutubeStreamExtractor(YoutubeService(0), url)
            extractor.fetchPage()

            val audioStreams = extractor.audioStreams
            if (!audioStreams.isNullOrEmpty()) {
                // Prefer Opus / WebM or M4A high bitrate
                val best = audioStreams.maxByOrNull { it.averageBitrate }
                return@withContext best?.content
            }
            null
        } catch (t: Throwable) {
            println("[DesktopMusicRepository] Stream extraction error for $videoId: ${t.message}")
            null
        }
    }

    /**
     * Fetches synchronized lyrics from LRCLIB.
     */
    suspend fun fetchLyrics(title: String, artist: String, durationSeconds: Int): List<DesktopLyricLine> = withContext(Dispatchers.IO) {
        try {
            val response = httpClient.get("https://lrclib.net/api/get") {
                parameter("track_name", title)
                parameter("artist_name", artist)
                if (durationSeconds > 0) parameter("duration", durationSeconds)
            }
            val body = response.bodyAsText()
            val parsed = json.parseToJsonElement(body).jsonObject
            val syncedLyrics = parsed["syncedLyrics"]?.jsonPrimitive?.contentOrNull
            if (!syncedLyrics.isNullOrBlank()) {
                return@withContext parseLrc(syncedLyrics)
            }
        } catch (_: Throwable) {}
        emptyList()
    }

    private fun parseLrc(lrcText: String): List<DesktopLyricLine> {
        val lines = mutableListOf<DesktopLyricLine>()
        val regex = Regex("""\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)""")
        for (rawLine in lrcText.lines()) {
            val match = regex.find(rawLine.trim()) ?: continue
            val min = match.groupValues[1].toLongOrNull() ?: 0L
            val sec = match.groupValues[2].toLongOrNull() ?: 0L
            val frac = match.groupValues[3].padEnd(3, '0').take(3).toLongOrNull() ?: 0L
            val text = match.groupValues[4].trim()
            val timeMs = min * 60000 + sec * 1000 + frac
            lines.add(DesktopLyricLine(timeMs = timeMs, words = text))
        }
        return lines.sortedBy { it.timeMs }
    }
}
