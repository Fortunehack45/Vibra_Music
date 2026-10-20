package com.fortune.vibramusic.data.social

import kotlinx.serialization.Serializable
import java.time.Instant

import androidx.compose.ui.graphics.Color

enum class StoryMediaType {
    IMAGE,
    VIDEO,
    TEXT,
}

fun parseStoryGradient(backgroundSpec: String?): List<Color> {
    if (backgroundSpec.isNullOrBlank()) {
        return listOf(Color(0xFF8B5CF6), Color(0xFF3B82F6))
    }
    val parts = backgroundSpec.split(",").map { it.trim() }.filter { it.isNotEmpty() }
    val colors = parts.mapNotNull { hexStr ->
        runCatching {
            val clean = hexStr.removePrefix("#")
            val colorLong = clean.toLong(16)
            if (clean.length <= 6) {
                Color(colorLong or 0xFF000000)
            } else {
                Color(colorLong)
            }
        }.getOrNull()
    }
    return if (colors.size >= 2) {
        colors
    } else if (colors.size == 1) {
        listOf(colors.first(), colors.first().copy(alpha = 0.8f))
    } else {
        listOf(Color(0xFF8B5CF6), Color(0xFF3B82F6))
    }
}

@Serializable
data class UserStory(
    val id: String = java.util.UUID.randomUUID().toString(),
    val userId: String,
    val author: SocialProfile? = null,
    val mediaUrl: String? = null,
    val mediaType: StoryMediaType = StoryMediaType.IMAGE,
    val textContent: String = "",
    val backgroundColorHex: String = "#8B5CF6",
    val musicAttachment: MusicTrackAttachment? = null,
    val createdAt: String = Instant.now().toString(),
    val expiresAt: String = runCatching { Instant.now().plusSeconds(86400).toString() }.getOrDefault(""),
) {
    val isExpired: Boolean
        get() {
            val exp = runCatching { Instant.parse(expiresAt) }.getOrNull()
            return exp != null && Instant.now().isAfter(exp)
        }
}

/**
 * Group of active stories for a single user, used in the segmented story viewer.
 */
data class UserStoryGroup(
    val user: SocialProfile,
    val stories: List<UserStory>,
)
