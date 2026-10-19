package com.fortune.vibramusic.data.social

import kotlinx.serialization.Serializable
import java.time.Instant

enum class StoryMediaType {
    IMAGE,
    VIDEO,
    TEXT,
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
