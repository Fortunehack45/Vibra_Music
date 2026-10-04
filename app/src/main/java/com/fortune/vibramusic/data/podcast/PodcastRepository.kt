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
     * Loads the main Podcast hub feed. Tries the official podcasts browse destination first;
     * if that returns empty shelves (for unauthenticated guests) or errors, falls back to
     * curated search shelves across top categories.
     */
    suspend fun getPodcastFeed(forceRefresh: Boolean = false): Result<PodcastFeed> = withContext(Dispatchers.IO) {
        if (!forceRefresh && cachedFeed != null) {
            return@withContext Result.success(cachedFeed!!)
        }

        try {
            val response = runCatching { Innertube.browse(BROWSE_PODCASTS) }.getOrNull()
            val parsed = response?.let { parsePodcastFeedResponse(it) }

            if (parsed != null && (parsed.topShows.isNotEmpty() || parsed.latestEpisodes.isNotEmpty() || parsed.topicShelves.isNotEmpty())) {
                cachedFeed = parsed
                return@withContext Result.success(parsed)
            }

            // Fallback: build resilient categorized feed from official InnerTube podcast queries
            val fallbackFeed = buildFallbackPodcastFeed()
            cachedFeed = fallbackFeed
            Result.success(fallbackFeed)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load podcast feed: ${e.message}", e)
            cachedFeed?.let { return@withContext Result.success(it) }
            // Try fallback even if an unexpected exception occurs
            runCatching {
                val fallbackFeed = buildFallbackPodcastFeed()
                cachedFeed = fallbackFeed
                Result.success(fallbackFeed)
            }.getOrElse { Result.failure(e) }
        }
    }

    /**
     * Builds a comprehensive podcast feed by querying multiple categories concurrently.
     */
    private suspend fun buildFallbackPodcastFeed(): PodcastFeed = coroutineScope {
        val topShowsDeferred = async { fetchSearchShelf("top podcasts", FILTER_PODCASTS, "Top Shows") }
        val trendingEpisodesDeferred = async { fetchSearchShelf("popular podcast episodes", FILTER_EPISODES, "Trending Episodes") }
        val techShowsDeferred = async { fetchSearchShelf("technology podcast", FILTER_PODCASTS, "Technology & Science") }
        val cultureShowsDeferred = async { fetchSearchShelf("society culture podcast", FILTER_PODCASTS, "Society & Culture") }
        val comedyShowsDeferred = async { fetchSearchShelf("comedy podcast", FILTER_PODCASTS, "Comedy & Entertainment") }
        val newsShowsDeferred = async { fetchSearchShelf("news podcast", FILTER_PODCASTS, "News & Politics") }

        val topShowsShelf = topShowsDeferred.await()
        val trendingEpisodesShelf = trendingEpisodesDeferred.await()
        val techShelf = techShowsDeferred.await()
        val cultureShelf = cultureShowsDeferred.await()
        val comedyShelf = comedyShowsDeferred.await()
        val newsShelf = newsShowsDeferred.await()

        val allShows = mutableListOf<PodcastShow>()
        val allEpisodes = mutableListOf<PodcastEpisode>()
        val shelves = mutableListOf<HomeShelf>()

        fun processShelf(result: Pair<HomeShelf, List<Any>>, isTopShows: Boolean = false, isTrendingEpisodes: Boolean = false) {
            val (shelf, items) = result
            if (shelf.items.isNotEmpty()) {
                shelves.add(shelf)
                items.forEach { item ->
                    when (item) {
                        is PodcastShow -> allShows.add(item)
                        is PodcastEpisode -> allEpisodes.add(item)
                    }
                }
            }
        }

        processShelf(topShowsShelf, isTopShows = true)
        processShelf(trendingEpisodesShelf, isTrendingEpisodes = true)
        processShelf(techShelf)
        processShelf(cultureShelf)
        processShelf(comedyShelf)
        processShelf(newsShelf)

        PodcastFeed(
            liveBroadcasts = emptyList(),
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
        params: String,
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
                domainItems.add(show)
                shelfItems.add(ShelfItem(title = title, subtitle = subtitle, thumbnailUrl = thumb, videoId = null, browseId = browseId))
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
                    isLive = false,
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
