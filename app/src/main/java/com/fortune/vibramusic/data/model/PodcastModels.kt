package com.fortune.vibramusic.data.model

/** Represents a single podcast episode from YouTube. */
data class PodcastEpisode(
    val id: String,
    val videoId: String,
    val title: String,
    val author: String,
    val description: String = "",
    val durationText: String? = null,
    val publishedTimeText: String? = null,
    val thumbnailUrl: String? = null,
    val isLive: Boolean = false,
    val hasVideo: Boolean = false,
    val showBrowseId: String? = null,
    val showTitle: String? = null,
    val authorBrowseId: String? = null,
    val progressFraction: Float = 0f,
) {
    /** Converts a podcast episode into a playable [Song] for the app's player pipeline. */
    fun toSong(): Song = Song(
        videoId = videoId,
        title = title,
        artist = author,
        artistId = authorBrowseId,
        albumName = showTitle ?: author,
        albumId = showBrowseId ?: authorBrowseId,
        thumbnailUrl = thumbnailUrl,
        durationText = durationText,
        isVideo = false,
        isVideoOrigin = false,
        playbackSource = showTitle ?: "Podcasts",
        playbackSourceType = PlaybackSourceType.PODCASTS,
        playbackSourceId = showBrowseId ?: authorBrowseId,
        description = description,
        isLiveStream = isLive,
    )
}

/** Whether a song represents a podcast episode. */
val Song.isPodcastSong: Boolean
    get() = playbackSourceType == PlaybackSourceType.PODCASTS ||
        albumId?.startsWith("MPSP") == true ||
        playbackSourceId?.startsWith("MPSP") == true ||
        artistId?.startsWith("MPSP") == true

/** Represents a podcast channel or show series. */
data class PodcastShow(
    val browseId: String,
    val title: String,
    val author: String,
    val authorBrowseId: String? = null,
    val description: String = "",
    val thumbnailUrl: String? = null,
    val bannerUrl: String? = null,
    val episodeCountText: String? = null,
    val episodes: List<PodcastEpisode> = emptyList(),
)

/** The complete podcast feed including live broadcasts, in-progress items, and curated shelves. */
data class PodcastFeed(
    val liveBroadcasts: List<PodcastEpisode> = emptyList(),
    val continueListening: List<PodcastEpisode> = emptyList(),
    val topShows: List<PodcastShow> = emptyList(),
    val latestEpisodes: List<PodcastEpisode> = emptyList(),
    val topicShelves: List<HomeShelf> = emptyList(),
)

/** These shelves without their music videos, and without any shelf that leaves empty. */
fun List<HomeShelf>.withoutVideos(): List<HomeShelf> = mapNotNull { shelf ->
    if (shelf.title.contains("video", ignoreCase = true)) return@mapNotNull null
    val items = shelf.items.filterNot { it.isVideo }
    if (items.isEmpty()) null else shelf.copy(items = items)
}
