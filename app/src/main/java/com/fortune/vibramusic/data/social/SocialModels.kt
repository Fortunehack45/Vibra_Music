package com.fortune.vibramusic.data.social

import com.fortune.vibramusic.data.model.Song
import kotlinx.serialization.Serializable

/**
 * Public profile representing a Vibra user.
 * Derived automatically from their active YouTube account in AuthStore.
 */
@Serializable
data class SocialProfile(
    val id: String,
    val handle: String,
    val displayName: String,
    val avatarUrl: String? = null,
    val bio: String = "",
    val verifiedBadge: Boolean = false,
    val followingCount: Int = 0,
    val followersCount: Int = 0,
    val friendsCount: Int = 0,
    val isFollowing: Boolean = false,
    val favoriteArtists: List<FavoriteArtist> = emptyList(),
    val referralCode: String = "",
    val invitedBy: String? = null,
    val invitesCount: Int = 0,
    val quizLives: Int = 5,
    val isUnlimitedLives: Boolean = false,
    val createdAt: String = "",
)

@Serializable
data class FavoriteArtist(
    val id: String = "",
    val name: String = "",
    val avatarUrl: String? = null,
    val artworkUrl: String? = avatarUrl,
) {
    val artistId: String get() = id
    val artistName: String get() = name
}

/**
 * Playable music card embedded directly into posts and DMs.
 */
@Serializable
data class MusicTrackAttachment(
    val videoId: String,
    val title: String,
    val artist: String,
    val thumbnailUrl: String? = null,
    val durationText: String? = null,
    val artworkUrl: String? = thumbnailUrl,
) {
    fun toSong(): Song = Song(
        videoId = videoId,
        title = title,
        artist = artist,
        thumbnailUrl = artworkUrl ?: thumbnailUrl,
        durationText = durationText,
    )

    companion object {
        fun fromSong(song: Song): MusicTrackAttachment = MusicTrackAttachment(
            videoId = song.videoId,
            title = song.title,
            artist = song.artist,
            thumbnailUrl = song.thumbnailUrl,
            durationText = song.durationText,
            artworkUrl = song.thumbnailUrl,
        )
    }
}

/**
 * Interactive poll within a social feed post.
 */
@Serializable
data class PollData(
    val question: String,
    val options: List<PollOption> = emptyList(),
    val totalVotes: Int = 0,
    val userVotedIndex: Int? = null,
)

@Serializable
data class PollOption(
    val id: String = "",
    val text: String,
    val votes: Int = 0,
)

/**
 * Summary badge when sharing a completed quiz result to the social feed.
 */
@Serializable
data class QuizResultAttachment(
    val artistId: String,
    val artistName: String,
    val artistAvatar: String? = null,
    val score: Int,
    val totalQuestions: Int = 10,
    val timeSeconds: Double,
    val percentile: Int,
)

fun formatHandle(handle: String?): String {
    val clean = handle?.trim()?.removePrefix("@")?.ifBlank { null } ?: "listener"
    return "@$clean"
}

@Serializable
data class SharedPlaylistAttachment(
    val playlistId: String,
    val title: String,
    val author: String = "",
    val thumbnailUrl: String? = null,
    val trackCount: Int = 0,
)

/**
 * A post in the Vibra Social feed (For You or Friends).
 */
@Serializable
data class SocialPost(
    val id: String,
    val authorId: String,
    val author: SocialProfile? = null,
    val content: String,
    val imageUrl: String? = null,
    val imageUrls: List<String> = emptyList(),
    val videoUrl: String? = null,
    val gifUrl: String? = null,
    val musicTrack: MusicTrackAttachment? = null,
    val pollData: PollData? = null,
    val quizResult: QuizResultAttachment? = null,
    val repostOfId: String? = null,
    val repostOf: SocialPost? = null,
    val quoteOfId: String? = null,
    val quoteOf: SocialPost? = null,
    val likesCount: Int = 0,
    val commentsCount: Int = 0,
    val repostsCount: Int = 0,
    val isLikedByMe: Boolean = false,
    val createdAt: String = "",
) {
    val authorName: String get() = author?.displayName ?: "Listener"
    val authorHandle: String get() = formatHandle(author?.handle)
    val authorAvatar: String? get() = author?.avatarUrl
    val authorVerified: Boolean get() = author?.verifiedBadge == true
    val poll: PollData? get() = pollData
    val effectiveImages: List<String>
        get() = if (imageUrls.isNotEmpty()) imageUrls else if (!imageUrl.isNullOrBlank()) listOf(imageUrl) else emptyList()
}

/**
 * Comment or nested reply on a social post.
 */
@Serializable
data class PostComment(
    val id: String,
    val postId: String,
    val authorId: String,
    val author: SocialProfile? = null,
    val parentId: String? = null,
    val content: String,
    val gifUrl: String? = null,
    val likesCount: Int = 0,
    val isLikedByMe: Boolean = false,
    val createdAt: String = "",
) {
    val authorName: String get() = author?.displayName ?: "Listener"
    val authorHandle: String get() = formatHandle(author?.handle)
    val authorAvatar: String? get() = author?.avatarUrl
}

/**
 * 1-on-1 direct message between friends.
 */
@Serializable
data class DirectMessage(
    val id: String,
    val senderId: String,
    val receiverId: String,
    val content: String,
    val imageUrl: String? = null,
    val videoUrl: String? = null,
    val audioUrl: String? = null,
    val gifUrl: String? = null,
    val sharedMusic: MusicTrackAttachment? = null,
    val sharedPlaylist: SharedPlaylistAttachment? = null,
    val isRead: Boolean = false,
    val createdAt: String = "",
) {
    val message: String get() = content
    val trackAttachment: MusicTrackAttachment? get() = sharedMusic
    val playlistAttachment: SharedPlaylistAttachment? get() = sharedPlaylist
}

/**
 * Social notifications for likes, comments, follows, friend requests, and quizzes.
 */
@Serializable
enum class NotificationType {
    LIKE,
    COMMENT,
    REPLY,
    FOLLOW,
    FRIEND_REQUEST,
    QUIZ_CHALLENGE,
}

@Serializable
data class SocialNotification(
    val id: String,
    val userId: String,
    val actorId: String,
    val actorName: String,
    val actorAvatar: String? = null,
    val actorHandle: String = "",
    val type: NotificationType,
    val targetPostId: String? = null,
    val message: String = "",
    val isRead: Boolean = false,
    val createdAt: String = "",
)

/**
 * Friendship relationship state.
 */
@Serializable
data class Friendship(
    val id: String,
    val requesterId: String,
    val receiverId: String,
    val status: FriendshipStatus,
    val createdAt: String = "",
)

@Serializable
enum class FriendshipStatus {
    PENDING,
    ACCEPTED,
    DECLINED,
    BLOCKED,
}

/**
 * Cloud-synchronized listening experience preferences and connected third-party integrations (e.g. Spotify).
 */
@Serializable
data class UserListeningExperience(
    val userId: String,
    val spotifySpdcToken: String? = null,
    val spotifyConnected: Boolean = false,
    val audioQuality: String = "HIGH",
    val equalizerEnabled: Boolean = false,
    val equalizerPreset: String = "FLAT",
    val volumeNormalization: Boolean = true,
    val bassBoostPercent: Int = 0,
    val virtualizerPercent: Int = 0,
    val pitchCents: Int = 0,
    val tempoMultiplier: Float = 1.0f,
    val autoSkipSilence: Boolean = false,
    val lyricsSource: String = "DEFAULT",
    val canvasEnabled: Boolean = true,
    val preferredGenres: List<String> = emptyList(),
)
