package com.fortune.vibramusic.ui.screens

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.settings.AppSettings
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.model.PodcastEpisode
import com.fortune.vibramusic.data.model.PodcastFeed
import com.fortune.vibramusic.data.model.PodcastShow
import com.fortune.vibramusic.data.model.UiState
import com.fortune.vibramusic.ui.components.MessageState
import com.fortune.vibramusic.ui.components.PAGE_GUTTER
import com.fortune.vibramusic.ui.components.PodcastEpisodeCard
import com.fortune.vibramusic.ui.components.PullToRefresh
import com.fortune.vibramusic.ui.components.feedSkeleton
import com.fortune.vibramusic.ui.components.trackColumnWidth
import com.fortune.vibramusic.ui.graphics.edgeRefraction
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import com.fortune.vibramusic.ui.icons.VibraMusicIcons
import com.fortune.vibramusic.ui.theme.VibraPurple

private val TOP_FILTERS = listOf(
    "All",
    "Live Stations",
    "Top Shows",
    "Hits & Pop",
    "Chill & Lo-Fi",
    "Hip-Hop & R&B",
    "Electronic & Dance",
    "News & Talk",
)

private data class RadioGenreTile(
    val title: String,
    val filterKey: String,
    val gradientColors: List<Color>,
)

private val RADIO_GENRE_TILES = listOf(
    RadioGenreTile("Hits & Top 40", "Hits & Pop", listOf(Color(0xFFFF1744), Color(0xFFFF8A65))),
    RadioGenreTile("Chill & Lo-Fi", "Chill & Lo-Fi", listOf(Color(0xFF00E676), Color(0xFF00B0FF))),
    RadioGenreTile("Hip-Hop & R&B", "Hip-Hop & R&B", listOf(Color(0xFF3D5AFE), Color(0xFF7C4DFF))),
    RadioGenreTile("Dance & Electronic", "Electronic & Dance", listOf(Color(0xFF00E5FF), Color(0xFF2979FF))),
    RadioGenreTile("Pop & Mood", "Hits & Pop", listOf(Color(0xFFF50057), Color(0xFFFF6E40))),
    RadioGenreTile("Jazz & Soul", "Chill & Lo-Fi", listOf(Color(0xFFFFAB00), Color(0xFFFF3D00))),
    RadioGenreTile("Rock & Alternative", "Top Shows", listOf(Color(0xFF6200EA), Color(0xFF304FFE))),
    RadioGenreTile("News & Global Talk", "News & Talk", listOf(Color(0xFF455A64), Color(0xFF263238))),
)

/**
 * Apple Music Mobile Radio Page
 *
 * Implements Apple Music's iOS Radio architecture:
 * - Editorial Live Marquee Stage ("Apple Music 1" style) with animated equalizer and pulsing LIVE indicator
 * - "Listen Live Now" horizontal broadcast stations carousel
 * - "Browse by Genre & Mood" 2-column vibrant gradient cards
 * - Top Shows and Archive Broadcasts shelf
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RadioScreen(
    state: UiState<PodcastFeed>,
    listState: LazyListState,
    onEpisodeClick: (PodcastEpisode) -> Unit,
    onShowClick: (PodcastShow) -> Unit,
    onAddToQueue: ((PodcastEpisode) -> Unit)? = null,
    onRetry: () -> Unit,
    refreshing: Boolean,
    onRefresh: () -> Unit,
    pullState: PullToRefreshState,
    currentVideoId: String?,
    isPlaying: Boolean,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues,
) {
    var selectedFilter by remember { mutableStateOf("All") }
    val haptics = rememberHaptics()

    val feed = (state as? UiState.Success)?.data
    val tokens = remember(selectedFilter) {
        if (selectedFilter in listOf("All", "Top Shows", "Live Stations")) emptyList()
        else selectedFilter.lowercase().split("&", " ", ",").filter { it.isNotBlank() && it != "and" }
    }

    val showsToDisplay = remember(feed, selectedFilter, tokens) {
        if (feed == null) emptyList()
        else when (selectedFilter) {
            "All", "Top Shows" -> feed.topShows
            "Live Stations" -> emptyList()
            else -> feed.topShows.filter { show ->
                tokens.any { token ->
                    show.title.contains(token, ignoreCase = true) ||
                    show.author.contains(token, ignoreCase = true) ||
                    show.description?.contains(token, ignoreCase = true) == true
                }
            }
        }
    }

    val liveBroadcasts = remember(feed, selectedFilter, tokens) {
        if (feed == null) emptyList()
        else when (selectedFilter) {
            "All", "Live Stations" -> feed.liveBroadcasts
            "Top Shows" -> emptyList()
            else -> feed.liveBroadcasts.filter { ep ->
                tokens.any { token ->
                    ep.title.contains(token, ignoreCase = true) ||
                    ep.author.contains(token, ignoreCase = true) ||
                    ep.description?.contains(token, ignoreCase = true) == true
                }
            }.ifEmpty { feed.liveBroadcasts }
        }
    }

    val episodesToDisplay = remember(feed, selectedFilter, tokens) {
        if (feed == null) emptyList()
        else when (selectedFilter) {
            "All" -> feed.latestEpisodes.ifEmpty { feed.liveBroadcasts }
            "Live Stations" -> feed.liveBroadcasts
            "Top Shows" -> emptyList()
            else -> feed.latestEpisodes.filter { ep ->
                tokens.any { token ->
                    ep.title.contains(token, ignoreCase = true) ||
                    ep.author.contains(token, ignoreCase = true) ||
                    ep.description?.contains(token, ignoreCase = true) == true
                }
            }
        }
    }

    PullToRefresh(
        refreshing = refreshing,
        onRefresh = onRefresh,
        state = pullState,
        modifier = modifier,
    ) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = contentPadding,
        ) {
            // Apple Music Radio Header
            item {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = PAGE_GUTTER)
                        .padding(top = 10.dp, bottom = 6.dp),
                ) {
                    Text(
                        text = stringResource(R.string.radio),
                        style = MaterialTheme.typography.displayMedium.copy(
                            fontWeight = FontWeight.ExtraBold,
                            letterSpacing = (-0.5).sp,
                        ),
                        color = MaterialTheme.colorScheme.onBackground,
                    )
                }
            }

            // Category Topic Filter Chips (Apple Music Style Capsule Pills)
            item {
                val chipsRowState = rememberLazyListState()
                LazyRow(
                    state = chipsRowState,
                    modifier = Modifier
                        .fillMaxWidth()
                        .edgeRefraction(chipsRowState)
                        .padding(bottom = 14.dp),
                    contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(TOP_FILTERS) { filter ->
                        val isSelected = filter == selectedFilter
                        val bg = if (isSelected) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
                        val textColor = if (isSelected) MaterialTheme.colorScheme.onPrimary
                        else MaterialTheme.colorScheme.onSurface

                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(20.dp))
                                .background(bg)
                                .border(
                                    width = 1.dp,
                                    color = if (isSelected) MaterialTheme.colorScheme.primary.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.08f),
                                    shape = RoundedCornerShape(20.dp),
                                )
                                .clickable {
                                    haptics.play(Haptic.Select)
                                    selectedFilter = filter
                                }
                                .padding(horizontal = 14.dp, vertical = 7.dp),
                        ) {
                            Text(
                                text = filter,
                                style = MaterialTheme.typography.labelMedium.copy(
                                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium,
                                ),
                                color = textColor,
                            )
                        }
                    }
                }
            }

            when (state) {
                is UiState.Loading -> {
                    feedSkeleton(firstIsHero = true)
                }

                is UiState.Error -> {
                    item {
                        MessageState(
                            message = state.message,
                            actionLabel = stringResource(R.string.retry),
                            onAction = onRetry,
                        )
                    }
                }

                is UiState.Success -> {
                    // 1. Apple Music 1 / Featured Live Station Stage
                    if (liveBroadcasts.isNotEmpty() && (selectedFilter == "All" || selectedFilter == "Live Stations")) {
                        val featuredLive = liveBroadcasts.first()
                        item {
                            AppleRadioHeroStage(
                                episode = featuredLive,
                                isPlaying = isPlaying && currentVideoId == featuredLive.videoId,
                                onPlay = { onEpisodeClick(featuredLive) },
                                modifier = Modifier
                                    .padding(horizontal = PAGE_GUTTER, vertical = 6.dp),
                            )
                        }
                    }

                    // 2. "Listen Live Now" Stations Carousel (Apple Music Live Stations Bar)
                    if (liveBroadcasts.size > 1 && (selectedFilter == "All" || selectedFilter == "Live Stations")) {
                        item {
                            SectionHeader(
                                title = "Listen Live Now",
                                subtitle = "Global radio stations, lo-fi channels & live broadcasts",
                            )
                        }

                        item {
                            val liveRowState = rememberLazyListState()
                            LazyRow(
                                state = liveRowState,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .edgeRefraction(liveRowState),
                                contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
                                horizontalArrangement = Arrangement.spacedBy(14.dp),
                            ) {
                                items(liveBroadcasts.drop(1), key = { it.videoId }) { episode ->
                                    val isCurrent = episode.videoId == currentVideoId
                                    AppleRadioStationCard(
                                        episode = episode,
                                        isCurrent = isCurrent,
                                        isPlaying = isCurrent && isPlaying,
                                        onPlay = { onEpisodeClick(episode) },
                                    )
                                }
                            }
                        }
                    }

                    // 3. Apple Music 2-Column "Browse by Genre & Mood" Gradient Cards
                    if (selectedFilter == "All") {
                        item {
                            SectionHeader(
                                title = "Browse by Genre & Mood",
                                subtitle = "Explore curated radio stations by style",
                            )
                        }

                        items(RADIO_GENRE_TILES.chunked(2)) { pair ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = PAGE_GUTTER, vertical = 4.dp),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                pair.forEach { tile ->
                                    AppleRadioGenreTileCard(
                                        tile = tile,
                                        onClick = {
                                            haptics.play(Haptic.Select)
                                            selectedFilter = tile.filterKey
                                        },
                                        modifier = Modifier.weight(1f),
                                    )
                                }
                                if (pair.size == 1) {
                                    Spacer(modifier = Modifier.weight(1f))
                                }
                            }
                        }
                    }

                    // 4. Top Shows & Interviews Carousel
                    if (showsToDisplay.isNotEmpty()) {
                        item {
                            SectionHeader(
                                title = if (selectedFilter == "Top Shows" || selectedFilter == "All") stringResource(R.string.top_podcast_shows) else "$selectedFilter shows",
                                subtitle = "Full seasons, weekly series and artist conversations",
                            )
                        }

                        item {
                            val showsRowState = rememberLazyListState()
                            LazyRow(
                                state = showsRowState,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .edgeRefraction(showsRowState),
                                contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
                                horizontalArrangement = Arrangement.spacedBy(14.dp),
                            ) {
                                items(showsToDisplay, key = { it.browseId }) { show ->
                                    PodcastShowCard(
                                        show = show,
                                        onClick = { onShowClick(show) },
                                    )
                                }
                            }
                        }
                    }

                    // 5. Quick Listens Shelf
                    if (episodesToDisplay.isNotEmpty() && episodesToDisplay.size >= 3 && selectedFilter == "All") {
                        item {
                            SectionHeader(
                                title = "Quick Listens",
                                subtitle = "Bite-sized episodes and trending segments",
                            )
                        }

                        item {
                            BoxWithConstraints {
                                val columnWidth = trackColumnWidth(maxWidth)
                                val quickRowState = rememberLazyListState()
                                LazyRow(
                                    state = quickRowState,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .edgeRefraction(quickRowState),
                                    contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
                                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                                ) {
                                    items(episodesToDisplay.take(9).chunked(3)) { column ->
                                        Column(Modifier.width(columnWidth)) {
                                            column.forEach { episode ->
                                                val isCurrent = episode.videoId == currentVideoId
                                                PodcastQuickEpisodeRow(
                                                    episode = episode,
                                                    isCurrent = isCurrent,
                                                    isPlaying = isCurrent && isPlaying,
                                                    onClick = { onEpisodeClick(episode) },
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 6. Latest Episodes & Past Broadcasts List
                    if (episodesToDisplay.isNotEmpty()) {
                        item {
                            SectionHeader(
                                title = when (selectedFilter) {
                                    "Live Stations" -> stringResource(R.string.live_podcasts)
                                    "All" -> stringResource(R.string.latest_episodes)
                                    else -> "$selectedFilter episodes"
                                },
                                subtitle = "Recently aired and on-demand episodes",
                            )
                        }

                        items(episodesToDisplay, key = { it.videoId }) { episode ->
                            val isCurrent = episode.videoId == currentVideoId
                            PodcastEpisodeCard(
                                episode = episode,
                                isPlaying = isPlaying,
                                isCurrent = isCurrent,
                                onPlay = { onEpisodeClick(episode) },
                                onAddToQueue = onAddToQueue?.let { { it(episode) } },
                                modifier = Modifier
                                    .padding(horizontal = PAGE_GUTTER, vertical = 6.dp),
                            )
                        }
                    } else if (showsToDisplay.isEmpty() && liveBroadcasts.isEmpty()) {
                        item {
                            MessageState(
                                message = if (selectedFilter == "Live Stations") stringResource(R.string.no_podcasts_found) else "No radio content found for \"$selectedFilter\"",
                                actionLabel = "Reset to All",
                                onAction = { selectedFilter = "All" },
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Backward compatibility alias for [RadioScreen].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PodcastScreen(
    state: UiState<PodcastFeed>,
    listState: LazyListState,
    onEpisodeClick: (PodcastEpisode) -> Unit,
    onShowClick: (PodcastShow) -> Unit,
    onAddToQueue: ((PodcastEpisode) -> Unit)? = null,
    onRetry: () -> Unit,
    refreshing: Boolean,
    onRefresh: () -> Unit,
    pullState: PullToRefreshState,
    currentVideoId: String?,
    isPlaying: Boolean,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues,
) {
    RadioScreen(
        state = state,
        listState = listState,
        onEpisodeClick = onEpisodeClick,
        onShowClick = onShowClick,
        onAddToQueue = onAddToQueue,
        onRetry = onRetry,
        refreshing = refreshing,
        onRefresh = onRefresh,
        pullState = pullState,
        currentVideoId = currentVideoId,
        isPlaying = isPlaying,
        modifier = modifier,
        contentPadding = contentPadding,
    )
}

/**
 * Apple Music Live Stage Card (Apple Music 1 Editorial Showcase).
 *
 * Features:
 * - Wide editorial card layout
 * - Pulsing Red LIVE indicator with animated 3-bar audio equalizer
 * - Full-bleed thumbnail with dark scrim
 * - Station branding ("VIBRA 1 LIVE")
 * - Frosted pill "Tune In" button
 */
@Composable
private fun AppleRadioHeroStage(
    episode: PodcastEpisode,
    isPlaying: Boolean,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .clickable(onClick = onPlay),
        shape = RoundedCornerShape(22.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        ),
    ) {
        Box(modifier = Modifier.fillMaxWidth()) {
            if (!episode.thumbnailUrl.isNullOrBlank()) {
                AsyncImage(
                    model = episode.thumbnailUrl,
                    contentDescription = episode.title,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                    contentScale = ContentScale.Crop,
                )
            }

            // Dark gradient scrim
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(200.dp)
                    .background(
                        Brush.verticalGradient(
                            colors = listOf(
                                Color.Black.copy(alpha = 0.35f),
                                Color.Black.copy(alpha = 0.88f),
                            ),
                        ),
                    ),
            )

            // Content
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                // Header with Pulsing Live Dot + Animated Equalizer + Badge
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .background(Color(0xFFE53935))
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                ) {
                    LiveEqualizerBars(
                        modifier = Modifier.size(width = 12.dp, height = 12.dp),
                        color = Color.White,
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = stringResource(R.string.live_badge),
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontWeight = FontWeight.Bold,
                            color = Color.White,
                            fontSize = 11.sp,
                        ),
                    )
                }

                Spacer(modifier = Modifier.height(30.dp))

                Text(
                    text = "VIBRA 1 · LIVE BROADCAST",
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontWeight = FontWeight.Bold,
                        color = Color.White.copy(alpha = 0.75f),
                        letterSpacing = 1.sp,
                    ),
                )

                Spacer(modifier = Modifier.height(4.dp))

                Text(
                    text = episode.title,
                    style = MaterialTheme.typography.titleLarge.copy(
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                    ),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )

                Spacer(modifier = Modifier.height(6.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        text = episode.author,
                        style = MaterialTheme.typography.bodyMedium.copy(
                            color = Color.White.copy(alpha = 0.85f),
                        ),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(Color.White)
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.PlayArrow,
                            contentDescription = "Tune In",
                            tint = Color.Black,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = if (isPlaying) "Playing" else "Tune In",
                            style = MaterialTheme.typography.labelSmall.copy(
                                fontWeight = FontWeight.Bold,
                                color = Color.Black,
                            ),
                        )
                    }
                }
            }
        }
    }
}

/**
 * Apple Music Live Station Card for horizontal "Listen Live Now" shelf.
 */
@Composable
private fun AppleRadioStationCard(
    episode: PodcastEpisode,
    isCurrent: Boolean,
    isPlaying: Boolean,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .width(152.dp)
            .clickable(onClick = onPlay),
    ) {
        Box(
            modifier = Modifier
                .size(152.dp)
                .clip(RoundedCornerShape(16.dp))
                .border(
                    width = if (isCurrent) 2.dp else 1.dp,
                    color = if (isCurrent) VibraPurple else Color.White.copy(alpha = 0.08f),
                    shape = RoundedCornerShape(16.dp),
                )
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
        ) {
            if (!episode.thumbnailUrl.isNullOrBlank()) {
                AsyncImage(
                    model = episode.thumbnailUrl,
                    contentDescription = episode.title,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            }

            // Dark subtle bottom gradient
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.65f)),
                        ),
                    ),
            )

            // Red LIVE pill overlay
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .padding(8.dp)
                    .align(Alignment.TopStart)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFFE53935))
                    .padding(horizontal = 7.dp, vertical = 3.dp),
            ) {
                LiveEqualizerBars(
                    modifier = Modifier.size(width = 10.dp, height = 10.dp),
                    color = Color.White,
                )
                Spacer(modifier = Modifier.width(4.dp))
                Text(
                    text = "LIVE",
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        fontSize = 9.sp,
                    ),
                )
            }

            // Quick Play Floating Icon
            Box(
                modifier = Modifier
                    .padding(8.dp)
                    .align(Alignment.BottomEnd)
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(if (isCurrent && isPlaying) VibraPurple else Color.White.copy(alpha = 0.9f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Rounded.PlayArrow,
                    contentDescription = "Play",
                    tint = if (isCurrent && isPlaying) Color.White else Color.Black,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = episode.title,
            style = MaterialTheme.typography.bodyMedium.copy(
                fontWeight = FontWeight.SemiBold,
                color = if (isCurrent) VibraPurple else MaterialTheme.colorScheme.onBackground,
            ),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        Text(
            text = episode.author,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * Apple Music 2-Column Vibrant Gradient Genre Tile.
 */
@Composable
private fun AppleRadioGenreTileCard(
    tile: RadioGenreTile,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .height(78.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Brush.linearGradient(tile.gradientColors))
            .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(14.dp),
    ) {
        // Glossy subtle reflection
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(Color.White.copy(alpha = 0.25f)),
        )

        Text(
            text = tile.title,
            style = MaterialTheme.typography.titleMedium.copy(
                fontWeight = FontWeight.Bold,
                color = Color.White,
            ),
            modifier = Modifier.align(Alignment.BottomStart),
        )
    }
}

/**
 * Animated Equalizer Bars for the pulsing LIVE indicator rendered strictly
 * in the draw phase using Canvas to avoid layout invalidations and frame drops.
 */
@Composable
private fun LiveEqualizerBars(
    modifier: Modifier = Modifier,
    color: Color = Color.White,
) {
    val reduceAnimation by AppSettings.reduceAnimation.collectAsStateWithLifecycle()
    val infiniteTransition = rememberInfiniteTransition(label = "equalizerTransition")
    val p1 by infiniteTransition.animateFloat(
        initialValue = 0.25f,
        targetValue = 0.9f,
        animationSpec = infiniteRepeatable(tween(420), RepeatMode.Reverse),
        label = "barFraction1",
    )
    val p2 by infiniteTransition.animateFloat(
        initialValue = 0.75f,
        targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(350), RepeatMode.Reverse),
        label = "barFraction2",
    )
    val p3 by infiniteTransition.animateFloat(
        initialValue = 0.4f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(tween(490), RepeatMode.Reverse),
        label = "barFraction3",
    )

    val f1 = if (reduceAnimation) 0.6f else p1
    val f2 = if (reduceAnimation) 0.8f else p2
    val f3 = if (reduceAnimation) 0.5f else p3

    Canvas(modifier = modifier) {
        val totalWidth = size.width
        val totalHeight = size.height
        val barCount = 3
        val spacing = 2.dp.toPx()
        val barWidth = ((totalWidth - spacing * (barCount - 1)) / barCount).coerceAtLeast(1f)
        val corner = CornerRadius(barWidth / 2f, barWidth / 2f)

        val heights = floatArrayOf(f1, f2, f3)
        for (i in 0 until barCount) {
            val barH = (totalHeight * heights[i]).coerceIn(barWidth, totalHeight)
            val left = i * (barWidth + spacing)
            val top = totalHeight - barH
            drawRoundRect(
                color = color,
                topLeft = Offset(left, top),
                size = Size(barWidth, barH),
                cornerRadius = corner,
            )
        }
    }
}

/**
 * Show Card for the Top Shows carousel.
 */
@Composable
private fun PodcastShowCard(
    show: PodcastShow,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .width(140.dp)
            .clickable(onClick = onClick),
    ) {
        Box(
            modifier = Modifier
                .size(140.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
        ) {
            if (!show.thumbnailUrl.isNullOrBlank()) {
                AsyncImage(
                    model = show.thumbnailUrl,
                    contentDescription = show.title,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = show.title,
            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        Text(
            text = show.author,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun PodcastQuickEpisodeRow(
    episode: PodcastEpisode,
    isCurrent: Boolean,
    isPlaying: Boolean,
    onClick: () -> Unit,
) {
    val titleColor by animateColorAsState(
        targetValue = if (isCurrent) VibraPurple else MaterialTheme.colorScheme.onBackground,
        label = "podcast episode title",
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            if (!episode.thumbnailUrl.isNullOrBlank()) {
                AsyncImage(
                    model = episode.thumbnailUrl,
                    contentDescription = episode.title,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            }
        }
        Spacer(modifier = Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = episode.title,
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                color = titleColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val sub = listOfNotNull(episode.author.takeIf { it.isNotBlank() }, episode.durationText?.takeIf { it.isNotBlank() }).joinToString(" · ")
            if (sub.isNotBlank()) {
                Text(
                    text = sub,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (isCurrent && isPlaying) {
            Icon(
                imageVector = Icons.Rounded.PlayArrow,
                contentDescription = null,
                tint = VibraPurple,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun SectionHeader(
    title: String,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = PAGE_GUTTER, vertical = 10.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge.copy(
                fontWeight = FontWeight.Bold,
            ),
            color = MaterialTheme.colorScheme.onBackground,
        )
        if (!subtitle.isNullOrBlank()) {
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
