package com.fortune.vibramusic.data.podcast

import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.innertube.Innertube
import com.fortune.vibramusic.data.model.HomeShelf
import com.fortune.vibramusic.data.model.PodcastEpisode
import com.fortune.vibramusic.data.model.PodcastFeed
import com.fortune.vibramusic.data.model.PodcastShow
import com.fortune.vibramusic.data.model.ShelfItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

object PodcastRepository {
    private const val TAG = "PodcastRepository"
    private const val BROWSE_PODCASTS = "FEpodcasts"

    // Official InnerTube filter chips for Podcasts and Episodes
    private const val FILTER_PODCASTS = "EgWKAQJQAWoSEBEQAxAJEAUQEBAEEAoQDhAV"
    private const val FILTER_EPISODES = "EgWKAQJIAWoSEBEQAxAJEAUQEBAEEAoQDhAV"

    @Volatile
    private var cachedFeed: PodcastFeed? = null

    /**
     * Loads the main Podcast hub feed swiftly using concurrent InnerTube queries
     * for Top Shows, Trending Episodes, and Live Broadcasts, backed by memory cache.
     */
    suspend fun getPodcastFeed(forceRefresh: Boolean = false): Result<PodcastFeed> = withContext(Dispatchers.IO) {
        if (!forceRefresh && cachedFeed != null) {
            return@withContext Result.success(cachedFeed!!)
        }

        try {
            val feed = buildResilientPodcastFeed()
            if (feed.topShows.isNotEmpty() || feed.latestEpisodes.isNotEmpty() || feed.liveBroadcasts.isNotEmpty()) {
                cachedFeed = feed
                return@withContext Result.success(feed)
            }
            cachedFeed?.let { return@withContext Result.success(it) }
            Result.success(feed)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load podcast feed: ${e.message}", e)
            cachedFeed?.let { return@withContext Result.success(it) }
            Result.failure(e)
        }
    }

    /**
     * Builds a comprehensive podcast feed quickly by querying top shows, trending episodes,
     * and live podcast streams in parallel.
     */
    private suspend fun buildResilientPodcastFeed(): PodcastFeed = coroutineScope {
        val topShowsDeferred = async { fetchSearchShelf("podcasts", FILTER_PODCASTS, "Top Shows") }
        val trendingEpisodesDeferred = async { fetchSearchShelf("podcast episodes", FILTER_EPISODES, "Trending Episodes") }
        val liveDeferred = async { fetchSearchShelf("live podcast", null, "Live Broadcasts") }

        val topShowsShelf = topShowsDeferred.await()
        val trendingEpisodesShelf = trendingEpisodesDeferred.await()
        val liveShelf = liveDeferred.await()

        val allShows = mutableListOf<PodcastShow>()
        val allEpisodes = mutableListOf<PodcastEpisode>()
        val liveBroadcasts = mutableListOf<PodcastEpisode>()
        val shelves = mutableListOf<HomeShelf>()

        fun processShelf(result: Pair<HomeShelf, List<Any>>, isLiveShelf: Boolean = false) {
            val (shelf, items) = result
            if (shelf.items.isNotEmpty()) {
                shelves.add(shelf)
                items.forEach { item ->
                    when (item) {
                        is PodcastShow -> allShows.add(item)
                        is PodcastEpisode -> {
                            if (item.isLive || isLiveShelf) {
                                val liveEp = if (!item.isLive) item.copy(isLive = true) else item
                                liveBroadcasts.add(liveEp)
                                allEpisodes.add(liveEp)
                            } else {
                                allEpisodes.add(item)
                            }
                        }
                    }
                }
            }
        }

        processShelf(topShowsShelf)
        processShelf(trendingEpisodesShelf)
        processShelf(liveShelf, isLiveShelf = true)

        PodcastFeed(
            liveBroadcasts = liveBroadcasts.distinctBy { it.videoId },
            continueListening = emptyList(),
            topShows = allShows.distinctBy { it.browseId },
            latestEpisodes = allEpisodes.distinctBy { it.videoId },
            topicShelves = shelves,
        )
    }

    /**
     * Queries InnerTube search with a category filter and produces a HomeShelf and parsed items.
     */
    private suspend fun fetchSearchShelf(
        query: String,
        params: String?,
        shelfTitle: String,
    ): Pair<HomeShelf, List<Any>> = runCatching {
        val response = Innertube.search(query, params)
        val tab = response.obj("contents")
            ?.obj("tabbedSearchResultsRenderer")
            ?.arr("tabs")?.firstOrNull()
            ?.obj("tabRenderer")?.obj("content")

        val sectionList = tab?.obj("sectionListRenderer")?.arr("contents")
        val shelfRenderer = sectionList?.firstOrNull()?.obj("musicShelfRenderer")
            ?: sectionList?.firstOrNull()?.obj("musicCardShelfRenderer")

        val rawItems = shelfRenderer?.arr("contents") ?: JsonArray(emptyList())
        val shelfItems = mutableListOf<ShelfItem>()
        val domainItems = mutableListOf<Any>()

        rawItems.forEach { itemElem ->
            val row = itemElem.obj("musicResponsiveListItemRenderer") ?: return@forEach
            val flex = row.arr("flexColumns") ?: return@forEach

            val title = flex.getOrNull(0)?.obj("musicResponsiveListItemFlexColumnRenderer")
                ?.obj("text")?.runsText().orEmpty()
            if (title.isBlank()) return@forEach

            val subtitle = flex.getOrNull(1)?.obj("musicResponsiveListItemFlexColumnRenderer")
                ?.obj("text")?.runsText().orEmpty()

            val thumb = row.obj("thumbnail")
                ?.obj("musicThumbnailRenderer")
                ?.obj("thumbnail")
                ?.bestThumbnailUrl()

            val nav = row.obj("navigationEndpoint")
            val browseId = nav?.obj("browseEndpoint")?.str("browseId")
                ?: row.arr("menu")?.firstOrNull()?.obj("menuNavigationItemRenderer")
                    ?.obj("navigationEndpoint")?.obj("browseEndpoint")?.str("browseId")

            val videoId = row.obj("playlistItemData")?.str("videoId")
                ?: row.obj("overlay")?.obj("musicItemThumbnailOverlayRenderer")
                    ?.obj("content")?.obj("musicPlayButtonRenderer")
                    ?.obj("playNavigationEndpoint")?.obj("watchEndpoint")?.str("videoId")
                ?: nav?.obj("watchEndpoint")?.str("videoId")

            val isLive = shelfTitle.contains("Live", ignoreCase = true) ||
                row.arr("badges")?.any {
                    (it as? JsonObject)?.obj("liveBadgeRenderer") != null ||
                        (it as? JsonObject)?.runsText()?.contains("LIVE", ignoreCase = true) == true
                } == true || subtitle.contains("LIVE", ignoreCase = true) ||
                subtitle.contains("watching", ignoreCase = true)

            if (browseId != null && !isLive) {
                val show = PodcastShow(
                    browseId = browseId,
                    title = title,
                    author = subtitle,
                    description = "",
                    thumbnailUrl = thumb,
                    bannerUrl = thumb,
                    episodeCountText = subtitle,
                )
                domainItems.add(show)
                shelfItems.add(ShelfItem(title = title, subtitle = subtitle, thumbnailUrl = thumb, videoId = null, browseId = browseId))
            } else if (videoId != null) {
                val episode = PodcastEpisode(
                    id = videoId,
                    videoId = videoId,
                    title = title,
                    author = subtitle,
                    description = subtitle,
                    durationText = if (isLive) "LIVE" else null,
                    publishedTimeText = subtitle,
                    thumbnailUrl = thumb,
                    isLive = isLive,
                    hasVideo = false,
                )
                domainItems.add(episode)
                shelfItems.add(ShelfItem(title = title, subtitle = subtitle, thumbnailUrl = thumb, videoId = videoId, browseId = null))
            }
        }

        Pair(HomeShelf(title = shelfTitle, items = shelfItems), domainItems)
    }.getOrElse { Pair(HomeShelf(title = shelfTitle, items = emptyList()), emptyList()) }

    /**
     * Loads a specific podcast show details and all its episodes.
     */
    suspend fun getPodcastShow(browseId: String): Result<PodcastShow> = withContext(Dispatchers.IO) {
        try {
            val normalizedId = if (browseId.startsWith("VL")) browseId else "VL$browseId"
            val response = runCatching { Innertube.browse(browseId) }
                .getOrElse { Innertube.browse(normalizedId) }

            val show = parsePodcastShowResponse(browseId, response)
            Result.success(show)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load podcast show $browseId: ${e.message}", e)
            Result.failure(e)
        }
    }

    /**
     * Parses the InnerTube browse response for FEpodcasts when available.
     */
    private fun parsePodcastFeedResponse(root: JsonObject): PodcastFeed {
        val liveBroadcasts = mutableListOf<PodcastEpisode>()
        val topShows = mutableListOf<PodcastShow>()
        val latestEpisodes = mutableListOf<PodcastEpisode>()
        val shelves = mutableListOf<HomeShelf>()

        val tabs = root.obj("contents")
            ?.obj("singleColumnBrowseResultsRenderer")
            ?.arr("tabs")
            ?: root.obj("contents")?.obj("twoColumnBrowseResultsRenderer")?.arr("tabs")

        val tabContent = tabs?.firstOrNull()?.obj("tabRenderer")?.obj("content")
        val sections = tabContent?.obj("sectionListRenderer")?.arr("contents") ?: JsonArray(emptyList())

        sections.forEach { sectionElement ->
            val sectionObj = sectionElement as? JsonObject ?: return@forEach

            // 1. Carousel Shelves
            sectionObj.obj("musicCarouselShelfRenderer")?.let { carousel ->
                val headerObj = carousel.obj("header")?.obj("musicCarouselShelfBasicHeaderRenderer")
                val shelfTitle = headerObj?.obj("title")?.runsText() ?: "Podcasts"
                val shelfSubtitle = headerObj?.obj("strapline")?.runsText().orEmpty()

                val items = mutableListOf<ShelfItem>()
                val shelfEpisodes = mutableListOf<PodcastEpisode>()
                val shelfShows = mutableListOf<PodcastShow>()

                carousel.arr("contents")?.forEach { itemElement ->
                    val itemObj = itemElement as? JsonObject ?: return@forEach

                    itemObj.obj("musicTwoRowItemRenderer")?.let { twoRow ->
                        val title = twoRow.obj("title")?.runsText().orEmpty()
                        val subtitle = twoRow.obj("subtitle")?.runsText().orEmpty()
                        val thumb = twoRow.obj("thumbnailRenderer")
                            ?.obj("musicThumbnailRenderer")
                            ?.obj("thumbnail")
                            ?.bestThumbnailUrl()

                        val navigationEndpoint = twoRow.obj("navigationEndpoint")
                        val browseEndpoint = navigationEndpoint?.obj("browseEndpoint")
                        val watchEndpoint = navigationEndpoint?.obj("watchEndpoint")

                        val browseId = browseEndpoint?.str("browseId")
                        val videoId = watchEndpoint?.str("videoId")

                        val isLive = subtitle.contains("LIVE", ignoreCase = true) ||
                            twoRow.arr("badges")?.any {
                                (it as? JsonObject)?.obj("liveBadgeRenderer") != null ||
                                    (it as? JsonObject)?.runsText()?.contains("LIVE", ignoreCase = true) == true
                            } == true

                        if (browseId != null) {
                            val show = PodcastShow(
                                browseId = browseId,
                                title = title,
                                author = subtitle,
                                description = "",
                                thumbnailUrl = thumb,
                                bannerUrl = thumb,
                                episodeCountText = subtitle,
                            )
                            shelfShows.add(show)
                            items.add(ShelfItem(title, subtitle, thumb, null, browseId))
                        } else if (videoId != null) {
                            val episode = PodcastEpisode(
                                id = videoId,
                                videoId = videoId,
                                title = title,
                                author = subtitle,
                                description = subtitle,
                                durationText = null,
                                publishedTimeText = subtitle,
                                thumbnailUrl = thumb,
                                isLive = isLive,
                                hasVideo = false,
                            )
                            if (isLive) liveBroadcasts.add(episode)
                            shelfEpisodes.add(episode)
                            items.add(ShelfItem(title, subtitle, thumb, videoId, null))
                        }
                    }

                    itemObj.obj("musicResponsiveListItemRenderer")?.let { responsive ->
                        parseResponsiveEpisode(responsive)?.let { episode ->
                            if (episode.isLive) liveBroadcasts.add(episode)
                            else latestEpisodes.add(episode)
                            items.add(ShelfItem(episode.title, episode.author, episode.thumbnailUrl, episode.videoId, null))
                        }
                    }
                }

                if (shelfTitle.contains("Live", ignoreCase = true)) {
                    liveBroadcasts.addAll(shelfEpisodes)
                } else if (shelfTitle.contains("Show", ignoreCase = true) || shelfTitle.contains("Popular", ignoreCase = true)) {
                    topShows.addAll(shelfShows)
                } else if (shelfTitle.contains("Episode", ignoreCase = true)) {
                    latestEpisodes.addAll(shelfEpisodes)
                }

                if (items.isNotEmpty()) {
                    shelves.add(HomeShelf(title = shelfTitle, items = items, subtitle = shelfSubtitle))
                }
            }

            // 2. Standard Music Shelf
            sectionObj.obj("musicShelfRenderer")?.let { shelf ->
                val shelfTitle = shelf.obj("title")?.runsText() ?: "Episodes"
                val items = mutableListOf<ShelfItem>()
                shelf.arr("contents")?.forEach { rowElement ->
                    val rowObj = rowElement as? JsonObject ?: return@forEach
                    rowObj.obj("musicResponsiveListItemRenderer")?.let { responsive ->
                        parseResponsiveEpisode(responsive)?.let { episode ->
                            latestEpisodes.add(episode)
                            items.add(ShelfItem(episode.title, episode.author, episode.thumbnailUrl, episode.videoId, null))
                        }
                    }
                }
                if (items.isNotEmpty()) {
                    shelves.add(HomeShelf(title = shelfTitle, items = items))
                }
            }
        }

        val distinctShows = topShows.distinctBy { it.browseId }
        val distinctEpisodes = latestEpisodes.distinctBy { it.videoId }

        return PodcastFeed(
            liveBroadcasts = liveBroadcasts.distinctBy { it.videoId },
            continueListening = emptyList(),
            topShows = distinctShows,
            latestEpisodes = distinctEpisodes,
            topicShelves = shelves,
        )
    }

    /**
     * Parses a responsive list item into a PodcastEpisode (pure audio).
     */
    private fun parseResponsiveEpisode(responsive: JsonObject): PodcastEpisode? {
        val flexColumns = responsive.arr("flexColumns") ?: return null
        val col0 = flexColumns.getOrNull(0) as? JsonObject
        val col1 = flexColumns.getOrNull(1) as? JsonObject

        val titleRuns = col0?.obj("musicResponsiveListItemFlexColumnRenderer")
            ?.obj("text")
        val title = titleRuns?.runsText().orEmpty()
        if (title.isBlank()) return null

        val subtitleRuns = col1?.obj("musicResponsiveListItemFlexColumnRenderer")
            ?.obj("text")
        val author = subtitleRuns?.runsText().orEmpty()

        val thumb = responsive.obj("thumbnail")
            ?.obj("musicThumbnailRenderer")
            ?.obj("thumbnail")
            ?.bestThumbnailUrl()

        val playEndpoint = responsive.obj("overlay")
            ?.obj("musicItemThumbnailOverlayRenderer")
            ?.obj("content")
            ?.obj("musicPlayButtonRenderer")
            ?.obj("playNavigationEndpoint")
            ?.obj("watchEndpoint")

        val videoId = responsive.obj("playlistItemData")?.str("videoId")
            ?: playEndpoint?.str("videoId")
            ?: responsive.obj("navigationEndpoint")?.obj("watchEndpoint")?.str("videoId")
            ?: responsive.obj("onTap")?.obj("watchEndpoint")?.str("videoId")
            ?: responsive.obj("playbackEndpoint")?.obj("watchEndpoint")?.str("videoId")
            ?: responsive.obj("playNavigationEndpoint")?.obj("watchEndpoint")?.str("videoId")
            ?: return null

        val isLive = responsive.arr("badges")?.any {
            (it as? JsonObject)?.obj("liveBadgeRenderer") != null ||
                (it as? JsonObject)?.runsText()?.contains("LIVE", ignoreCase = true) == true
        } == true || author.contains("LIVE", ignoreCase = true)

        val fixedColumns = responsive.arr("fixedColumns")
        val durationText = fixedColumns?.firstOrNull()?.let {
            (it as? JsonObject)?.obj("musicResponsiveListItemFixedColumnRenderer")
                ?.obj("text")?.runsText()
        }

        return PodcastEpisode(
            id = videoId,
            videoId = videoId,
            title = title,
            author = author,
            description = author,
            durationText = durationText,
            publishedTimeText = null,
            thumbnailUrl = thumb,
            isLive = isLive,
            hasVideo = false,
        )
    }

    /**
     * Parses a multi-row podcast item into a PodcastEpisode.
     */
    private fun parseMultiRowEpisode(multiRow: JsonObject): PodcastEpisode? {
        val playEndpoint = multiRow.obj("overlay")
            ?.obj("musicItemThumbnailOverlayRenderer")
            ?.obj("content")
            ?.obj("musicPlayButtonRenderer")
            ?.obj("playNavigationEndpoint")
            ?.obj("watchEndpoint")

        val videoId = multiRow.obj("onTap")?.obj("watchEndpoint")?.str("videoId")
            ?: multiRow.obj("navigationEndpoint")?.obj("watchEndpoint")?.str("videoId")
            ?: multiRow.obj("playbackEndpoint")?.obj("watchEndpoint")?.str("videoId")
            ?: multiRow.obj("playNavigationEndpoint")?.obj("watchEndpoint")?.str("videoId")
            ?: multiRow.obj("playlistItemData")?.str("videoId")
            ?: playEndpoint?.str("videoId")
            ?: return null

        val title = multiRow.obj("title")?.runsText().orEmpty()
        if (title.isBlank()) return null

        val subtitle = multiRow.obj("subtitle")?.runsText().orEmpty()
        val secondSubtitle = multiRow.obj("secondSubtitle")?.runsText().orEmpty()
        val description = multiRow.obj("description")?.runsText().orEmpty()

        val thumb = multiRow.obj("thumbnail")
            ?.obj("musicThumbnailRenderer")
            ?.obj("thumbnail")
            ?.bestThumbnailUrl()
            ?: multiRow.obj("thumbnail")?.bestThumbnailUrl()

        val parts = "$subtitle • $secondSubtitle".split(" • ").filter { it.isNotBlank() }
        val duration = parts.firstOrNull { it.contains("min", ignoreCase = true) || it.contains("hr", ignoreCase = true) || it.matches(Regex("""\d+:\d+(?::\d+)?""")) }

        return PodcastEpisode(
            id = videoId,
            videoId = videoId,
            title = title,
            author = subtitle,
            description = description.ifBlank { subtitle },
            durationText = duration,
            publishedTimeText = subtitle,
            thumbnailUrl = thumb,
            isLive = false,
            hasVideo = false,
        )
    }

    /**
     * Parses the show detail page containing podcast series metadata and episodes.
     */
    private fun parsePodcastShowResponse(browseId: String, root: JsonObject): PodcastShow {
        var showTitle = "Podcast Show"
        var author = ""
        var description = ""
        var thumbnailUrl: String? = null
        var bannerUrl: String? = null
        var episodeCountText: String? = null

        // Header parser: check root "header" OR inside twoColumnBrowseResultsRenderer tabs
        val twoCol = root.obj("contents")?.obj("twoColumnBrowseResultsRenderer")
        val tabHeader = twoCol?.arr("tabs")?.firstOrNull()?.obj("tabRenderer")
            ?.obj("content")?.obj("sectionListRenderer")?.arr("contents")
            ?.firstOrNull()?.obj("musicResponsiveHeaderRenderer")

        val header = root.obj("header")?.obj("musicDetailHeaderRenderer")
            ?: root.obj("header")?.obj("musicEditablePlaylistDetailHeaderRenderer")?.obj("header")?.obj("musicDetailHeaderRenderer")
            ?: root.obj("header")?.obj("musicResponsiveHeaderRenderer")
            ?: tabHeader

        if (header != null) {
            showTitle = header.obj("title")?.runsText()?.takeIf { it.isNotBlank() } ?: showTitle
            author = header.obj("subtitle")?.runsText()?.takeIf { it.isNotBlank() } ?: author
            description = header.obj("description")?.obj("musicDescriptionShelfRenderer")
                ?.obj("description")?.runsText().orEmpty().ifBlank {
                    header.obj("description")?.runsText().orEmpty()
                }
            thumbnailUrl = header.obj("thumbnail")
                ?.obj("croppedSquareThumbnailRenderer")
                ?.obj("thumbnail")
                ?.bestThumbnailUrl()
                ?: header.obj("thumbnail")?.obj("musicThumbnailRenderer")?.obj("thumbnail")?.bestThumbnailUrl()
                ?: header.obj("thumbnail")?.bestThumbnailUrl()
            bannerUrl = thumbnailUrl
            episodeCountText = header.obj("secondSubtitle")?.runsText()
        }

        val episodes = mutableListOf<PodcastEpisode>()

        fun walkForEpisodes(element: JsonElement) {
            when (element) {
                is JsonObject -> {
                    element.obj("musicResponsiveListItemRenderer")?.let { row ->
                        parseResponsiveEpisode(row)?.let { ep ->
                            episodes.add(ep.copy(showBrowseId = browseId, showTitle = showTitle))
                        }
                    }
                    element.obj("musicMultiRowListItemRenderer")?.let { row ->
                        parseMultiRowEpisode(row)?.let { ep ->
                            episodes.add(ep.copy(showBrowseId = browseId, showTitle = showTitle))
                        }
                    }
                    element.values.forEach { walkForEpisodes(it) }
                }
                is JsonArray -> {
                    element.forEach { walkForEpisodes(it) }
                }
                else -> Unit
            }
        }

        // Walk contents, tabs, and secondary contents
        root.obj("contents")?.let { walkForEpisodes(it) }

        val distinctEpisodes = episodes.distinctBy { it.videoId }

        return PodcastShow(
            browseId = browseId,
            title = showTitle,
            author = author,
            description = description,
            thumbnailUrl = thumbnailUrl,
            bannerUrl = bannerUrl,
            episodeCountText = episodeCountText ?: "${distinctEpisodes.size} episodes",
            episodes = distinctEpisodes,
        )
    }

    // Helper JSON navigators
    private fun JsonElement?.obj(key: String): JsonObject? = (this as? JsonObject)?.get(key) as? JsonObject
    private fun JsonElement?.arr(key: String): JsonArray? = (this as? JsonObject)?.get(key) as? JsonArray
    private fun JsonElement?.str(key: String): String? = ((this as? JsonObject)?.get(key) as? kotlinx.serialization.json.JsonPrimitive)?.content

    private fun JsonElement?.runsText(): String {
        val runs = this.arr("runs") ?: return this.str("simpleText").orEmpty()
        return runs.mapNotNull { (it as? JsonObject)?.str("text") }.joinToString("")
    }

    private fun JsonElement?.bestThumbnailUrl(): String? {
        val list = this.arr("thumbnails") ?: return null
        val best = list.mapNotNull { it as? JsonObject }.maxByOrNull {
            it.str("width")?.toIntOrNull() ?: 0
        }
        return best?.str("url")
    }
}
