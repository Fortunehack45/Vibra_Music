package com.fortune.vibramusic.ui.screens

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PlayArrow
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
import com.fortune.vibramusic.ui.icons.VibraMusicIcons

private val TOP_FILTERS = listOf(
    "All",
    "Live Broadcasts",
    "Top Shows",
    "Technology",
    "Interviews",
    "Culture & Society",
    "News & Politics",
    "Comedy",
)

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
    var selectedFilter by remember { mutableStateOf("All") }

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
            // Screen Title
            item {
                Text(
                    text = stringResource(R.string.podcasts),
                    style = MaterialTheme.typography.displayLarge,
                    color = MaterialTheme.colorScheme.onBackground,
                    modifier = Modifier.padding(horizontal = PAGE_GUTTER, vertical = 8.dp),
                )
            }

            // Category Topic Filter Chips
            item {
                LazyRow(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 12.dp),
                    contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(TOP_FILTERS) { filter ->
                        val isSelected = filter == selectedFilter
                        val bg = if (isSelected) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                        val textColor = if (isSelected) MaterialTheme.colorScheme.onPrimary
                        else MaterialTheme.colorScheme.onSurface

                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(20.dp))
                                .background(bg)
                                .clickable { selectedFilter = filter }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
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
                    val feed = state.data

                    // 1. Live Broadcast Stage (if live stream available)
                    if (feed.liveBroadcasts.isNotEmpty() && (selectedFilter == "All" || selectedFilter == "Live Broadcasts")) {
                        val featuredLive = feed.liveBroadcasts.first()
                        item {
                            PodcastLiveStageCard(
                                episode = featuredLive,
                                onPlay = { onEpisodeClick(featuredLive) },
                                modifier = Modifier
                                    .padding(horizontal = PAGE_GUTTER, vertical = 6.dp),
                            )
                        }
                    }

                    // 2. Top Shows Carousel
                    if (feed.topShows.isNotEmpty() && (selectedFilter == "All" || selectedFilter == "Top Shows")) {
                        item {
                            Text(
                                text = stringResource(R.string.top_podcast_shows),
                                style = MaterialTheme.typography.titleLarge,
                                color = MaterialTheme.colorScheme.onBackground,
                                modifier = Modifier.padding(horizontal = PAGE_GUTTER, vertical = 12.dp),
                            )
                        }

                        item {
                            LazyRow(
                                modifier = Modifier.fillMaxWidth(),
                                contentPadding = PaddingValues(horizontal = PAGE_GUTTER),
                                horizontalArrangement = Arrangement.spacedBy(14.dp),
                            ) {
                                items(feed.topShows) { show ->
                                    PodcastShowCard(
                                        show = show,
                                        onClick = { onShowClick(show) },
                                    )
                                }
                            }
                        }
                    }

                    // 3. Latest Episodes Feed (Wide Episode Cards)
                    if (selectedFilter != "Top Shows") {
                        val episodesToDisplay = when (selectedFilter) {
                            "Live Broadcasts" -> feed.liveBroadcasts
                            else -> feed.latestEpisodes.ifEmpty { feed.liveBroadcasts }
                        }

                        if (episodesToDisplay.isNotEmpty()) {
                            item {
                                Text(
                                    text = if (selectedFilter == "Live Broadcasts") stringResource(R.string.live_podcasts)
                                    else stringResource(R.string.latest_episodes),
                                    style = MaterialTheme.typography.titleLarge,
                                    color = MaterialTheme.colorScheme.onBackground,
                                    modifier = Modifier.padding(horizontal = PAGE_GUTTER, vertical = 14.dp),
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
                        }
                    }

                    // 4. Fallback if empty
                    if (feed.latestEpisodes.isEmpty() && feed.topShows.isEmpty() && feed.liveBroadcasts.isEmpty()) {
                        item {
                            MessageState(
                                message = stringResource(R.string.no_podcasts_found),
                                actionLabel = stringResource(R.string.retry),
                                onAction = onRetry,
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Widescreen Live Broadcast Stage Card featuring real-time red canvas pulse dot and clean LIVE badge.
 */
@Composable
private fun PodcastLiveStageCard(
    episode: PodcastEpisode,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val infiniteTransition = rememberInfiniteTransition(label = "livePulse")
    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 0.8f,
        targetValue = 1.3f,
        animationSpec = infiniteRepeatable(
            animation = tween(900),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "pulseScale",
    )

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
                        .height(180.dp),
                    contentScale = ContentScale.Crop,
                )
            }

            // Dark gradient scrim
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(180.dp)
                    .background(
                        Brush.verticalGradient(
                            colors = listOf(
                                Color.Black.copy(alpha = 0.35f),
                                Color.Black.copy(alpha = 0.85f),
                            ),
                        ),
                    ),
            )

            // Content on top of banner
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            ) {
                // Header with Pulsing Live Dot + Badge
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .background(Color(0xFFE53935))
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                ) {
                    Canvas(modifier = Modifier.size(8.dp)) {
                        drawCircle(
                            color = Color.White,
                            radius = size.minDimension / 2f * pulseScale,
                        )
                    }
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

                Spacer(modifier = Modifier.height(38.dp))

                Text(
                    text = episode.title,
                    style = MaterialTheme.typography.titleLarge.copy(
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                    ),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )

                Spacer(modifier = Modifier.height(4.dp))

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
                            contentDescription = "Listen",
                            tint = Color.Black,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = stringResource(R.string.play),
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
