package com.fortune.vibramusic.data

import com.fortune.vibramusic.data.Http
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.innertube.Innertube
import com.fortune.vibramusic.data.innertube.InnertubeParser
import com.fortune.vibramusic.data.model.Song
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import org.jsoup.Jsoup
import java.time.LocalDate

data class SongInfo(
    val album: String? = null,
    val releaseYear: String? = null,
    val releaseDate: String? = null,
    val views: String? = null,
    val likes: String? = null,
    val comments: String? = null,
    val failed: Boolean = false,
) {
    fun merge(other: SongInfo): SongInfo = copy(
        album = album ?: other.album,
        releaseYear = releaseYear ?: other.releaseYear,
        releaseDate = releaseDate ?: other.releaseDate,
        views = views ?: other.views,
        likes = likes ?: other.likes,
        comments = comments ?: other.comments,
        failed = failed && other.failed,
    )
}

/**
 * YouTube-style short form of a raw count: 950 -> "950", 1234 -> "1.2K",
 * 100000 -> "100K", 2345678 -> "2.3M".
 * Tolerates strings with commas or trailing words (e.g. "315,741 views", "19M likes").
 */
fun compactCount(raw: String): String {
    val trimmed = raw.trim()
    val stripped = trimmed.replace(Regex("""\s*(?:views|plays|likes|comments)\b.*$""", RegexOption.IGNORE_CASE), "").trim()
    if (Regex("""^[\d.,]+\s*[KMB]$""", RegexOption.IGNORE_CASE).matches(stripped)) {
        return stripped
    }
    val normalized = stripped.replace(",", "")
    val n = normalized.toLongOrNull()?.takeIf { it >= 0 } ?: return stripped.ifEmpty { trimmed }
    val (unit, suffix) = when {
        n >= 1_000_000_000 -> 1_000_000_000L to "B"
        n >= 1_000_000 -> 1_000_000L to "M"
        n >= 1_000 -> 1_000L to "K"
        else -> return n.toString()
    }
    val whole = n / unit
    if (whole >= 10) return "$whole$suffix"
    val tenth = n % unit * 10 / unit
    val separator = java.text.DecimalFormatSymbols.getInstance().decimalSeparator
    return if (tenth == 0L) "$whole$suffix" else "$whole$separator$tenth$suffix"
}

/** Loaded only when requested. Counts belong to this exact upload, never a search match. */
object SongInfoRepository {
    private val client = HttpClient(OkHttp) {
        engine { preconfigured = Http.client }
        install(HttpTimeout) { requestTimeoutMillis = 15_000 }
    }

    suspend fun load(song: Song): SongInfo = withContext(Dispatchers.IO) {
        if (song.localUri != null || !Regex("[A-Za-z0-9_-]{11}").matches(song.videoId)) {
            return@withContext SongInfo(album = song.albumName)
        }
        val statistics = async {
            val nextStats = attempt { fetchNextStats(song.videoId) }.getOrNull()
            val playerStats = if (nextStats?.views == null || nextStats.releaseDate == null) {
                attempt { fetchPlayerStats(song.videoId) }.getOrNull()
            } else null

            val combined = when {
                nextStats != null && playerStats != null -> nextStats.merge(playerStats)
                nextStats != null -> nextStats
                playerStats != null -> playerStats
                else -> attempt { fetchHtmlFallback(song.videoId) }.getOrNull()
            }
            combined ?: SongInfo(failed = true)
        }

        var album = song.albumName
        var year: String? = null
        val release = attempt {
            val linked = if (song.albumId == null) {
                YtMusicRepository.trackLinks(song.videoId).getOrThrow()
            } else song
            album = album ?: linked.albumName
            linked.albumId?.let { id ->
                val header = InnertubeParser.parseBrowseHeader(Innertube.browse(id))
                album = album ?: header?.title
                year = header?.subtitle?.split('•')?.map { it.trim() }
                    ?.firstOrNull { it.matches(Regex("(?:19|20)[0-9]{2}")) }
            }
        }

        val stats = statistics.await()
        val hasAnyStats = stats.views != null || stats.likes != null || stats.comments != null
        stats.copy(
            album = album ?: stats.album ?: song.albumName,
            releaseYear = year ?: stats.releaseYear,
        ).copy(
            failed = if (hasAnyStats) false else (stats.failed || release.isFailure)
        )
    }

    /**
     * Fetches primary stats (views, likes, comments) directly via Innertube WEB next endpoint,
     * avoiding anti-bot CAPTCHA interception that blocks raw HTML scraping.
     */
    private suspend fun fetchNextStats(videoId: String): SongInfo {
        val payload = buildJsonObject {
            putJsonObject("context") {
                putJsonObject("client") {
                    put("clientName", "WEB")
                    put("clientVersion", "2.20250101.01.00")
                    put("hl", Innertube.currentLanguage)
                }
            }
            put("videoId", videoId)
        }.toString()

        val response = client.post("https://www.youtube.com/youtubei/v1/next") {
            contentType(ContentType.Application.Json)
            header("Origin", "https://www.youtube.com")
            header("Referer", "https://www.youtube.com/")
            header("X-YouTube-Client-Name", "1")
            header("X-YouTube-Client-Version", "2.20250101.01.00")
            parameter("prettyPrint", "false")
            parameter("hl", Innertube.currentLanguage)
            setBody(payload)
        }
        check(response.status.value == 200) { "Next endpoint returned status ${response.status.value}" }
        val json = Json.parseToJsonElement(response.bodyAsText()).jsonObject
        return SongInfoParser.parseNext(json, videoId)
    }

    /**
     * Fetches exact view count and track description release date via Innertube player endpoint.
     */
    private suspend fun fetchPlayerStats(videoId: String): SongInfo {
        val json = Innertube.player(videoId)
        return SongInfoParser.parsePlayer(json)
    }

    /**
     * Emergency fallback to HTML watch page scrape if Innertube is unreachable.
     */
    private suspend fun fetchHtmlFallback(videoId: String): SongInfo {
        val response = client.get("https://www.youtube.com/watch") {
            header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
            header("Cookie", "SOCS=CAI")
            parameter("v", videoId)
            parameter("hl", Innertube.currentLanguage)
        }
        check(response.status.value == 200)
        return SongInfoParser.parse(response.bodyAsText(), videoId)
    }

    private suspend fun <T> attempt(block: suspend () -> T): Result<T> = try {
        Result.success(block())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }
}

internal object SongInfoParser {
    fun parseNext(json: JsonObject, videoId: String): SongInfo {
        val primary = json.find("videoPrimaryInfoRenderer").firstOrNull()

        val rawViewCount = primary?.obj("viewCount")?.obj("videoViewCountRenderer")?.let { v ->
            v.str("originalViewCount")?.takeIf { it != "0" && it.isNotBlank() }
                ?: v.obj("viewCount").str("simpleText")
                ?: v.obj("shortViewCount").str("simpleText")
        } ?: json.find("viewCountFactoidRenderer").firstNotNullOfOrNull { factoid ->
            factoid.find("factoidRenderer").firstNotNullOfOrNull { it.obj("value").str("simpleText") }
        }

        val newLike = json.find("likeButtonViewModel").firstNotNullOfOrNull { vm ->
            vm.find("buttonViewModel").firstNotNullOfOrNull { btn ->
                btn.str("title")?.takeIf { it.isNotBlank() && !it.equals("Like", ignoreCase = true) }
            }
        }
        val oldLike = primary?.find("toggleButtonRenderer")?.firstOrNull {
            it.obj("defaultIcon").str("iconType") == "LIKE"
        }?.get("defaultText")?.text()
        val likes = (newLike ?: oldLike)?.withCount()

        val comments = json.find("engagementPanelSectionListRenderer").firstNotNullOfOrNull { panel ->
            val isComments = panel.str("targetId") == "engagement-panel-comments-section" ||
                panel.str("panelIdentifier") == "engagement-panel-comments-section"
            if (!isComments) null
            else panel.find("engagementPanelTitleHeaderRenderer").firstNotNullOfOrNull {
                it["contextualInfo"]?.text()?.withCount()
            }
        } ?: json.find("commentsHeaderRenderer").firstNotNullOfOrNull {
            it["countText"]?.text()?.withCount()
        } ?: json.find("commentsEntryPointHeaderRenderer").firstNotNullOfOrNull {
            it["commentCount"]?.text()?.withCount()
        }

        val description = json.find("expandableVideoDescriptionBodyRenderer").firstNotNullOfOrNull {
            it.obj("attributedDescriptionBodyText").str("content")
        } ?: json.find("attributedDescription").firstNotNullOfOrNull {
            it.str("content")
        } ?: json.find("videoDetails").firstNotNullOfOrNull {
            it.str("shortDescription")
        }
        val releaseDate = releaseDate(description)

        return SongInfo(
            releaseDate = releaseDate,
            views = rawViewCount?.let(::compactCount),
            likes = likes?.let(::compactCount),
            comments = comments?.let(::compactCount),
            failed = false,
        )
    }

    fun parsePlayer(json: JsonObject): SongInfo {
        val details = json.obj("videoDetails")
        val viewCount = details.str("viewCount")?.takeIf { it.toLongOrNull()?.let { n -> n >= 0 } == true }
        val releaseDate = releaseDate(details.str("shortDescription"))
        return SongInfo(
            releaseDate = releaseDate,
            views = viewCount?.let(::compactCount),
            failed = false,
        )
    }

    fun parse(html: String, videoId: String): SongInfo {
        val scripts = Jsoup.parse(html).select("script").map { it.data() }
        val player = scripts.firstNotNullOfOrNull { extract(it, "ytInitialPlayerResponse") }
            ?: error("Missing player metadata")
        val details = player.obj("videoDetails")
        check(details.str("videoId") == videoId) { "Metadata belongs to another track" }
        val data = scripts.firstNotNullOfOrNull { extract(it, "ytInitialData") }
        val primary = data?.find("videoPrimaryInfoRenderer")?.firstOrNull()
        val oldLike = primary?.find("toggleButtonRenderer")?.firstOrNull {
            it.obj("defaultIcon").str("iconType") == "LIKE"
        }?.get("defaultText")?.text()
        val newLike = primary?.find("likeButtonViewModel")?.firstOrNull()
            ?.find("buttonViewModel")?.firstOrNull()?.str("title")
        val comments = data?.find("commentsHeaderRenderer")?.firstNotNullOfOrNull {
            it["countText"]?.text()?.withCount()
        }
            ?: data?.find("commentsEntryPointHeaderRenderer")?.firstOrNull()
                ?.get("commentCount")?.text()?.withCount()
            ?: data?.find("engagementPanelSectionListRenderer")?.firstOrNull {
                it.str("targetId") == "engagement-panel-comments-section" ||
                    it.str("panelIdentifier") == "engagement-panel-comments-section"
            }?.find("engagementPanelTitleHeaderRenderer")?.firstOrNull()
                ?.get("contextualInfo")?.text()?.withCount()
        return SongInfo(
            releaseDate = releaseDate(details.str("shortDescription")),
            views = details.str("viewCount")?.takeIf { it.toLongOrNull()?.let { n -> n >= 0 } == true }?.let(::compactCount),
            likes = (newLike ?: oldLike)?.withCount()?.let(::compactCount),
            comments = comments?.let(::compactCount),
            failed = data == null,
        )
    }

    private fun releaseDate(description: String?): String? {
        val date = description?.lineSequence()?.firstNotNullOfOrNull { line ->
            Regex("Released on:\\s*(\\d{4}-\\d{2}-\\d{2})", RegexOption.IGNORE_CASE)
                .find(line.trim())?.groupValues?.get(1)
        } ?: return null
        return runCatching { LocalDate.parse(date).toString() }.getOrNull()
    }

    private fun extract(script: String, name: String): JsonObject? {
        val assignment = Regex("(?:var\\s+)?${name}\\s*=\\s*").find(script) ?: return null
        val start = assignment.range.last + 1
        if (script.getOrNull(start) != '{') return null
        var depth = 0
        var quoted = false
        var escaped = false
        for (i in start until script.length) {
            val c = script[i]
            if (quoted) {
                if (escaped) escaped = false
                else if (c == '\\') escaped = true
                else if (c == '"') quoted = false
            } else when (c) {
                '"' -> quoted = true
                '{' -> depth++
                '}' -> if (--depth == 0) return runCatching {
                    Json.parseToJsonElement(script.substring(start, i + 1)) as? JsonObject
                }.getOrNull()
            }
        }
        return null
    }

    private fun JsonObject.obj(key: String) = this[key] as? JsonObject ?: JsonObject(emptyMap())
    private fun JsonObject.str(key: String) = (this[key] as? JsonPrimitive)?.contentOrNull
    private fun String.withCount(): String? = takeIf { it.any(Char::isDigit) }
    private fun JsonElement.text(): String? = (this as? JsonObject)?.let {
        it.str("simpleText") ?: (it["runs"] as? JsonArray)?.joinToString("") { run ->
            (run as? JsonObject)?.str("text").orEmpty()
        }
    }?.takeIf { it.isNotBlank() }
    private fun JsonElement.find(key: String): List<JsonObject> = when (this) {
        is JsonObject -> listOfNotNull(this[key] as? JsonObject) + values.flatMap { it.find(key) }
        is JsonArray -> flatMap { it.find(key) }
        else -> emptyList()
    }
}
