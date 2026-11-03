package com.fortune.vibramusic.data.model

import java.text.Normalizer
import java.util.Locale
import kotlinx.serialization.Serializable

@Serializable
data class ArtistRef(
    val name: String,
    val browseId: String? = null,
)

fun normalizedArtistName(raw: String): String =
    Normalizer.normalize(raw, Normalizer.Form.NFD)
        .replace(COMBINING_MARKS, "")
        .lowercase(Locale.ROOT)
        .replace(REPEATED_SPACE, " ")
        .trim()

private val COMBINING_MARKS = Regex("\\p{InCombiningDiacriticalMarks}+")
private val REPEATED_SPACE = Regex("\\s+")

fun isExactArtistMatch(answer: String, wanted: String): Boolean {
    val name = normalizedArtistName(wanted)
    if (name.isEmpty()) return false
    return normalizedArtistName(answer) == name
}
