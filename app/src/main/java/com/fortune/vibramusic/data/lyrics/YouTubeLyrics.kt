package com.fortune.vibramusic.data.lyrics

import com.fortune.vibramusic.data.innertube.Innertube
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/** Lyrics exposed by YouTube Music's Lyrics tab for the exact playing video. */
object YouTubeMusicLyrics {
    suspend fun lyrics(videoId: String): List<LyricLine>? = withContext(Dispatchers.IO) {
        if (!YOUTUBE_ID.matches(videoId)) return@withContext null
        val next = runCatching { Innertube.next(videoId) }.getOrNull() ?: return@withContext null
        val endpoint = next.objectsNamed("tabRenderer")
            .firstOrNull { it.youtubeStrings().any { text -> text.equals("Lyrics", ignoreCase = true) } }
            ?.objectsNamed("browseEndpoint")?.firstOrNull()
            ?: next.objectsNamed("tabRenderer").drop(1).firstNotNullOfOrNull {
                it.objectsNamed("browseEndpoint").firstOrNull()
            }
            ?: return@withContext null
        val browseId = (endpoint["browseId"] as? JsonPrimitive)?.contentOrNull
            ?: return@withContext null
        val params = (endpoint["params"] as? JsonPrimitive)?.contentOrNull
        val page = runCatching { Innertube.browse(browseId, params) }.getOrNull() ?: return@withContext null
        val shelf = page.objectsNamed("musicDescriptionShelfRenderer").firstOrNull()
            ?: return@withContext null
        val text = shelf["description"]?.youtubeStrings()?.joinToString("").orEmpty().trim()
        text.lineSequence().map(String::trim).filter(String::isNotEmpty)
            .map { LyricLine(0L, it) }.toList().takeIf { it.isNotEmpty() }
    }
}

/** Timed YouTube transcript/captions for the exact playing video. */
object YouTubeTranscriptLyrics {
    suspend fun lyrics(videoId: String): List<LyricLine>? = withContext(Dispatchers.IO) {
        if (!YOUTUBE_ID.matches(videoId)) return@withContext null

        // 1. Try Player Captions first
        val fromPlayer = runCatching { fetchPlayerCaptions(videoId) }.getOrNull()
        if (!fromPlayer.isNullOrEmpty()) return@withContext fromPlayer

        // 2. Fallback to Innertube.transcript
        val response = runCatching { Innertube.transcript(videoId) }.getOrNull()
            ?: return@withContext null
        response.objectsNamed("transcriptCueRenderer").mapNotNull { cue ->
            val start = (cue["startOffsetMs"] as? JsonPrimitive)?.longOrNull
                ?: return@mapNotNull null
            val text = cue["cue"]?.youtubeStrings()?.joinToString("").orEmpty()
                .trim(' ', '\n', '?')
            text.takeIf { it.isNotEmpty() }?.let { LyricLine(start, it) }
        }.sortedBy { it.timeMs }.toList().takeIf { it.isNotEmpty() }
    }

    private suspend fun fetchPlayerCaptions(videoId: String): List<LyricLine>? {
        val playerResp = runCatching { Innertube.player(videoId) }.getOrNull() ?: return null
        val tracks = com.fortune.vibramusic.data.innertube.InnertubeParser.parseCaptionTracks(playerResp)
        if (tracks.isEmpty()) return null
        val bestTrack = tracks.firstOrNull { it.languageCode.startsWith("en") } ?: tracks.first()
        val url = bestTrack.baseUrl
        // Try json3 format
        val jsonUrl = if (url.contains("fmt=")) url else "$url&fmt=json3"
        val jsonBody = lyricsGet(jsonUrl)
        if (!jsonBody.isNullOrBlank() && jsonBody.trimStart().startsWith("{")) {
            val parsed = parseJson3TimedText(jsonBody)
            if (!parsed.isNullOrEmpty()) return parsed
        }
        // Fallback to XML
        val xmlBody = lyricsGet(url)
        if (!xmlBody.isNullOrBlank()) {
            val parsedXml = parseXmlTimedText(xmlBody)
            if (!parsedXml.isNullOrEmpty()) return parsedXml
        }
        return null
    }

    private fun parseJson3TimedText(rawJson: String): List<LyricLine>? = runCatching {
        val element = kotlinx.serialization.json.Json.parseToJsonElement(rawJson)
        val events = (element as? JsonObject)?.get("events") as? JsonArray ?: return null
        events.mapNotNull { evElem ->
            val ev = evElem as? JsonObject ?: return@mapNotNull null
            val startMs = (ev["tStartMs"] as? JsonPrimitive)?.longOrNull ?: return@mapNotNull null
            val segs = ev["segs"] as? JsonArray ?: return@mapNotNull null
            val text = segs.mapNotNull {
                ((it as? JsonObject)?.get("utf8") as? JsonPrimitive)?.contentOrNull
            }.joinToString("").trim(' ', '\n', '?')
            text.takeIf { it.isNotEmpty() }?.let { LyricLine(startMs, it) }
        }.sortedBy { it.timeMs }.takeIf { it.isNotEmpty() }
    }.getOrNull()

    private val XML_TEXT_REGEX = Regex("""<text\s+start="([\d.]+)"(?:\s+dur="[\d.]+")?>([^<]+)</text>""")
    private fun parseXmlTimedText(xml: String): List<LyricLine> {
        val lines = mutableListOf<LyricLine>()
        XML_TEXT_REGEX.findAll(xml).forEach { match ->
            val startSec = match.groupValues[1].toDoubleOrNull() ?: return@forEach
            val rawText = match.groupValues[2]
            val decoded = EnhancedLrc.decodeEntities(rawText).trim(' ', '\n', '?')
            if (decoded.isNotEmpty()) {
                lines.add(LyricLine((startSec * 1000).toLong(), decoded))
            }
        }
        return lines.sortedBy { it.timeMs }
    }
}

private val YOUTUBE_ID = Regex("""[A-Za-z0-9_-]{11}""")

private fun JsonElement.objectsNamed(name: String): Sequence<JsonObject> = sequence {
    when (this@objectsNamed) {
        is JsonObject -> for ((key, value) in this@objectsNamed) {
            if (key == name && value is JsonObject) yield(value)
            yieldAll(value.objectsNamed(name))
        }
        is JsonArray -> for (value in this@objectsNamed) yieldAll(value.objectsNamed(name))
        else -> Unit
    }
}

internal fun JsonElement.youtubeStrings(): List<String> = when (this) {
    is JsonPrimitive -> contentOrNull?.let(::listOf).orEmpty()
    is JsonArray -> flatMap { it.youtubeStrings() }
    is JsonObject -> {
        val direct = (this["text"] as? JsonPrimitive)?.contentOrNull
            ?: (this["simpleText"] as? JsonPrimitive)?.contentOrNull
        direct?.let(::listOf) ?: values.flatMap { it.youtubeStrings() }
    }
}
