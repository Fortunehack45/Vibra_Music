package com.fortune.vibramusic.data

import com.fortune.vibramusic.data.model.ArtistPage
import com.fortune.vibramusic.data.model.HomeShelf
import com.fortune.vibramusic.data.model.Song
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import java.util.Locale

/**
 * Proof that an Apple Music artist found by name is the YouTube artist meant.
 */
object AppleCatalogue {

    private const val USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"

    private val json = Json { ignoreUnknownKeys = true }

    fun matchKey(name: String): String =
        java.text.Normalizer.normalize(name.lowercase(Locale.ROOT).replace('$', 's'), java.text.Normalizer.Form.NFD)
            .filter { it.isLetterOrDigit() }

    fun titleKey(title: String): String? =
        matchKey(
            title.substringBefore(" (").substringBefore(" [")
                .removeSuffix(" - Single").removeSuffix(" - EP"),
        ).takeIf { it.length >= 4 }

    fun keys(titles: Collection<String>): Set<String> = titles.mapNotNullTo(HashSet(), ::titleKey)

    fun sharesTitles(artistId: Long, keys: Set<String>): Boolean {
        if (keys.isEmpty()) return false
        val request = Request.Builder()
            .url("https://itunes.apple.com/lookup?id=$artistId&entity=song&limit=200")
            .header("User-Agent", USER_AGENT)
            .build()
        val body = Http.client.newCall(request).execute()
            .use { if (it.isSuccessful) it.body?.string() else null } ?: return false
        val rows = json.parseToJsonElement(body).jsonObject["results"]?.jsonArray ?: return false
        return rows.any { row ->
            val o = row.jsonObject
            listOf("trackName", "collectionName").any { field ->
                o[field]?.jsonPrimitive?.content?.let(::titleKey) in keys
            }
        }
    }

    fun titlesOf(songs: List<Song>, sections: List<HomeShelf>): List<String> =
        songs.map { it.title } +
            sections.flatMap { it.items }.filter { it.browseId?.startsWith("MPRE") == true }.map { it.title }

    fun titlesOf(page: ArtistPage): List<String> = titlesOf(page.songs, page.sections)
}
