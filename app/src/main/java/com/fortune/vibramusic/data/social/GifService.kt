package com.fortune.vibramusic.data.social

import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URLEncoder

@Serializable
data class GifItem(
    val id: String,
    val url: String,
    val previewUrl: String = url,
    val title: String = "",
    val category: String = "",
)

object GifService {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val client = HttpClient(OkHttp)

    private const val TENOR_API_KEY = "AIzaSyCZt6SSh5VgVPzD9fhyzG1DprdPRhtoaR4"
    private const val TENOR_CLIENT_KEY = "tenor_web"

    val categories = listOf(
        "Trending",
        "Vibes",
        "Party",
        "Fire",
        "Dance",
        "Shock",
        "Love",
        "Sad",
    )

    // Curated high-performance fallback reaction GIFs
    private val curatedGifs = mapOf(
        "Trending" to listOf(
            GifItem("t1", "https://media.giphy.com/media/blSTtZehjAZ8I/giphy.gif", title = "Dancing Vibe"),
            GifItem("t2", "https://media.giphy.com/media/l41lI4bYmcsPJX9Go/giphy.gif", title = "Listening to Music"),
            GifItem("t3", "https://media.giphy.com/media/3o7qDSOvfaCO9b3MlO/giphy.gif", title = "Headphones Beat"),
            GifItem("t4", "https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif", title = "Hype Concert"),
            GifItem("t5", "https://media.giphy.com/media/jpbnoe3UIa8TU8LM13/giphy.gif", title = "Cat Jam"),
            GifItem("t6", "https://media.giphy.com/media/artj92V8o75VPL7AeQ/giphy.gif", title = "Groove"),
        ),
        "Vibes" to listOf(
            GifItem("v1", "https://media.giphy.com/media/jpbnoe3UIa8TU8LM13/giphy.gif", title = "Cat Vibing"),
            GifItem("v2", "https://media.giphy.com/media/blSTtZehjAZ8I/giphy.gif", title = "Smooth Vibe"),
            GifItem("v3", "https://media.giphy.com/media/3o7aD2saalBwwftBIY/giphy.gif", title = "Chill Waves"),
            GifItem("v4", "https://media.giphy.com/media/l4pT0NtPS2v8EwU4E/giphy.gif", title = "Late Night Drive"),
            GifItem("v5", "https://media.giphy.com/media/xT0xeJpnrWC4XWblEk/giphy.gif", title = "Vinyl Record Spinning"),
            GifItem("v6", "https://media.giphy.com/media/3oKIPnAiaMCws8nOsE/giphy.gif", title = "Headphones Bliss"),
        ),
        "Party" to listOf(
            GifItem("p1", "https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif", title = "Club Party"),
            GifItem("p2", "https://media.giphy.com/media/artj92V8o75VPL7AeQ/giphy.gif", title = "DJ Drop"),
            GifItem("p3", "https://media.giphy.com/media/13hxeOYjoTWtK8/giphy.gif", title = "Confetti Celebration"),
            GifItem("p4", "https://media.giphy.com/media/DhstvI455Y099E5NQJ/giphy.gif", title = "Let's Go Party"),
            GifItem("p5", "https://media.giphy.com/media/3KC2jD2Q38OSY/giphy.gif", title = "Party Dance"),
        ),
        "Fire" to listOf(
            GifItem("f1", "https://media.giphy.com/media/Lopx9eUi34rbq/giphy.gif", title = "Elmo Fire"),
            GifItem("f2", "https://media.giphy.com/media/QMHoU66sBXCAHonWVg/giphy.gif", title = "This is Fine"),
            GifItem("f3", "https://media.giphy.com/media/3o72FfM5HJydzafgUE/giphy.gif", title = "Flame Beat"),
            GifItem("f4", "https://media.giphy.com/media/26AHG5KGFxSkUWw1i/giphy.gif", title = "Hot Track"),
        ),
        "Dance" to listOf(
            GifItem("d1", "https://media.giphy.com/media/blSTtZehjAZ8I/giphy.gif", title = "Street Dance"),
            GifItem("d2", "https://media.giphy.com/media/3o7qDSOvfaCO9b3MlO/giphy.gif", title = "Rhythm"),
            GifItem("d3", "https://media.giphy.com/media/14qb1Uhf40ndw4/giphy.gif", title = "Breakdance"),
            GifItem("d4", "https://media.giphy.com/media/l3q2wJsC23ikJg9xe/giphy.gif", title = "Pop Dance"),
        ),
        "Shock" to listOf(
            GifItem("s1", "https://media.giphy.com/media/tfUW8mhiFk8NlJhgEh/giphy.gif", title = "Mind Blown"),
            GifItem("s2", "https://media.giphy.com/media/26ufdipQqU2lhNA4g/giphy.gif", title = "Shocked Face"),
            GifItem("s3", "https://media.giphy.com/media/6nWhy3ulBL7GSCvKw6/giphy.gif", title = "Surprised Pikachu"),
            GifItem("s4", "https://media.giphy.com/media/l3q2K5jinAlChoCLS/giphy.gif", title = "Blinking Guy"),
        ),
        "Love" to listOf(
            GifItem("l1", "https://media.giphy.com/media/26FLdm964upIslUZ2/giphy.gif", title = "Heart Eyes"),
            GifItem("l2", "https://media.giphy.com/media/3o7TKoWXm3okO1kgHC/giphy.gif", title = "Sending Love"),
            GifItem("l3", "https://media.giphy.com/media/l4pTdcifPZLpDjL1e/giphy.gif", title = "Love The Song"),
            GifItem("l4", "https://media.giphy.com/media/ICOgUNjpvO0PC/giphy.gif", title = "Cat Love"),
        ),
        "Sad" to listOf(
            GifItem("sd1", "https://media.giphy.com/media/L95W4wv8nnb9K/giphy.gif", title = "Sad Tears"),
            GifItem("sd2", "https://media.giphy.com/media/OPU6wzx8JrHna/giphy.gif", title = "Crying"),
            GifItem("sd3", "https://media.giphy.com/media/d2lcHJTG5Tscg/giphy.gif", title = "Heartbroken Melody"),
        ),
    )

    suspend fun getTrendingGifs(category: String = "Trending"): List<GifItem> = withContext(Dispatchers.IO) {
        val remoteGifs = runCatching {
            val url = if (category.equals("Trending", ignoreCase = true)) {
                "https://tenor.googleapis.com/v2/featured?key=$TENOR_API_KEY&client_key=$TENOR_CLIENT_KEY&limit=30"
            } else {
                val encoded = URLEncoder.encode(category, "UTF-8")
                "https://tenor.googleapis.com/v2/search?q=$encoded&key=$TENOR_API_KEY&client_key=$TENOR_CLIENT_KEY&limit=30"
            }
            val response = client.get(url)
            if (response.status.isSuccess()) {
                parseTenorResults(response.bodyAsText(), category)
            } else {
                emptyList()
            }
        }.getOrDefault(emptyList())

        if (remoteGifs.isNotEmpty()) {
            remoteGifs
        } else {
            curatedGifs[category] ?: curatedGifs["Trending"].orEmpty()
        }
    }

    suspend fun searchGifs(query: String): List<GifItem> = withContext(Dispatchers.IO) {
        val q = query.trim()
        if (q.isBlank()) return@withContext getTrendingGifs()

        val remoteResults = runCatching {
            val encoded = URLEncoder.encode(q, "UTF-8")
            val url = "https://tenor.googleapis.com/v2/search?q=$encoded&key=$TENOR_API_KEY&client_key=$TENOR_CLIENT_KEY&limit=30"
            val response = client.get(url)
            if (response.status.isSuccess()) {
                parseTenorResults(response.bodyAsText(), "Search: $q")
            } else {
                emptyList()
            }
        }.getOrDefault(emptyList())

        if (remoteResults.isNotEmpty()) {
            return@withContext remoteResults
        }

        // Fallback to local curated
        val lowerQ = q.lowercase()
        val localMatches = curatedGifs.values.flatten()
            .filter { it.title.lowercase().contains(lowerQ) || it.category.lowercase().contains(lowerQ) }
            .distinctBy { it.url }

        if (localMatches.isNotEmpty()) {
            return@withContext localMatches
        }

        val categoryMatch = curatedGifs.entries.firstOrNull { it.key.lowercase().contains(lowerQ) }?.value
        if (!categoryMatch.isNullOrEmpty()) {
            return@withContext categoryMatch
        }

        curatedGifs["Trending"].orEmpty()
    }

    private fun parseTenorResults(rawJson: String, categoryName: String): List<GifItem> = runCatching {
        val root = json.parseToJsonElement(rawJson).jsonObject
        val results = root["results"]?.jsonArray ?: return@runCatching emptyList()
        results.mapNotNull { item ->
            val obj = item.jsonObject
            val id = obj["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
            val desc = obj["content_description"]?.jsonPrimitive?.content
                ?: obj["h1_title"]?.jsonPrimitive?.content ?: "GIF"

            val mediaFormats = obj["media_formats"]?.jsonObject ?: return@mapNotNull null
            val gifObj = mediaFormats["gif"]?.jsonObject ?: mediaFormats["mediumgif"]?.jsonObject
            val gifUrl = gifObj?.get("url")?.jsonPrimitive?.content ?: return@mapNotNull null

            val tinyObj = mediaFormats["tinygif"]?.jsonObject ?: mediaFormats["nanogif"]?.jsonObject
            val previewUrl = tinyObj?.get("url")?.jsonPrimitive?.content ?: gifUrl

            GifItem(
                id = id,
                url = gifUrl,
                previewUrl = previewUrl,
                title = desc,
                category = categoryName,
            )
        }
    }.getOrDefault(emptyList())
}
