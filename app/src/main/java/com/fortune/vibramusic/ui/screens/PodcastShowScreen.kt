package com.fortune.vibramusic.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.NotificationsNone
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Sort
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.model.PodcastEpisode
import com.fortune.vibramusic.data.model.PodcastShow
import com.fortune.vibramusic.data.model.UiState
import com.fortune.vibramusic.ui.components.MessageState
import com.fortune.vibramusic.ui.components.PAGE_GUTTER
import com.fortune.vibramusic.ui.components.PodcastEpisodeCard

@Composable
fun PodcastShowScreen(
    showState: UiState<PodcastShow>?,
    onBack: () -> Unit,
    onEpisodeClick: (PodcastEpisode) -> Unit,
    onAddToQueue: ((PodcastEpisode) -> Unit)? = null,
    onRetry: () -> Unit,
    currentVideoId: String?,
    isPlaying: Boolean,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues,
) {
    BackHandler(onBack = onBack)

    var isFollowing by remember { mutableStateOf(false) }
    var sortNewestFirst by remember { mutableStateOf(true) }
    var expandedShowDesc by remember { mutableStateOf(false) }

    val listState = rememberLazyListState()

    Box(modifier = modifier.fillMaxSize()) {
        when (showState) {
            null, is UiState.Loading -> {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
                }
            }

            is UiState.Error -> {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .statusBarsPadding(),
                    contentAlignment = Alignment.Center,
                ) {
                    MessageState(
                        message = showState.message,
                        actionLabel = stringResource(R.string.retry),
                        onAction = onRetry,
                    )
                }
            }

            is UiState.Success -> {
                val show = showState.data
                val displayedEpisodes = remember(show.episodes, sortNewestFirst) {
                    if (sortNewestFirst) show.episodes else show.episodes.reversed()
                }

                // Blurred Ambient Backdrop Header
                if (!show.thumbnailUrl.isNullOrBlank()) {
                    AsyncImage(
                        model = show.thumbnailUrl,
                        contentDescription = null,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(340.dp)
                            .blur(48.dp),
                        contentScale = ContentScale.Crop,
                    )

                    // Scrim gradient
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(340.dp)
                            .background(
                                Brush.verticalGradient(
                                    colors = listOf(
                                        Color.Black.copy(alpha = 0.45f),
                                        MaterialTheme.colorScheme.background.copy(alpha = 0.95f),
                                        MaterialTheme.colorScheme.background,
                                    ),
                                ),
                            ),
                    )
                }

                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = contentPadding,
                ) {
                    // Header Artwork + Show Info
                    item {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .statusBarsPadding()
                                .padding(top = 16.dp, bottom = 20.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            // Cover Artwork (160dp x 160dp rounded)
                            Box(
                                modifier = Modifier
                                    .size(164.dp)
                                    .clip(RoundedCornerShape(20.dp))
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

                            Spacer(modifier = Modifier.height(16.dp))

                            // Show Title
                            Text(
                                text = show.title,
                                style = MaterialTheme.typography.headlineMedium.copy(
                                    fontWeight = FontWeight.Bold,
                                ),
                                color = MaterialTheme.colorScheme.onBackground,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.padding(horizontal = PAGE_GUTTER),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )

                            Spacer(modifier = Modifier.height(6.dp))

                            // Host / Publisher
                            Text(
                                text = show.author,
                                style = MaterialTheme.typography.titleMedium,
                                color = MaterialTheme.colorScheme.primary,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.padding(horizontal = PAGE_GUTTER),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )

                            // Episode Count
                            show.episodeCountText?.let { countText ->
                                Spacer(modifier = Modifier.height(4.dp))
                                Text(
                                    text = countText,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }

                            Spacer(modifier = Modifier.height(18.dp))

                            // Action Pills Row: Play Latest + Follow
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.Center,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                // Play Latest Button
                                if (displayedEpisodes.isNotEmpty()) {
                                    val latestEp = displayedEpisodes.first()
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(50))
                                            .background(MaterialTheme.colorScheme.primary)
                                            .clickable { onEpisodeClick(latestEp) }
                                            .padding(horizontal = 22.dp, vertical = 10.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Rounded.PlayArrow,
                                            contentDescription = "Play Latest",
                                            tint = MaterialTheme.colorScheme.onPrimary,
                                            modifier = Modifier.size(18.dp),
                                        )
                                        Spacer(modifier = Modifier.width(6.dp))
                                        Text(
                                            text = stringResource(R.string.latest_episodes),
                                            style = MaterialTheme.typography.labelLarge.copy(
                                                fontWeight = FontWeight.Bold,
                                            ),
                                            color = MaterialTheme.colorScheme.onPrimary,
                                        )
                                    }

                                    Spacer(modifier = Modifier.width(12.dp))
                                }

                                // Follow Toggle Button
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(50))
                                        .background(
                                            if (isFollowing) MaterialTheme.colorScheme.surfaceVariant
                                            else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                                        )
                                        .clickable { isFollowing = !isFollowing }
                                        .padding(horizontal = 18.dp, vertical = 10.dp),
                                ) {
                                    Icon(
                                        imageVector = if (isFollowing) Icons.Rounded.Check else Icons.Rounded.NotificationsNone,
                                        contentDescription = if (isFollowing) "Following" else "Follow",
                                        tint = if (isFollowing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                                        modifier = Modifier.size(16.dp),
                                    )
                                    Spacer(modifier = Modifier.width(6.dp))
                                    Text(
                                        text = if (isFollowing) stringResource(R.string.following_show) else stringResource(R.string.follow_show),
                                        style = MaterialTheme.typography.labelLarge.copy(
                                            fontWeight = FontWeight.SemiBold,
                                        ),
                                        color = if (isFollowing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                                    )
                                }
                            }

                            // Expandable Show Overview
                            if (show.description.isNotBlank()) {
                                Spacer(modifier = Modifier.height(16.dp))
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = PAGE_GUTTER)
                                        .clip(RoundedCornerShape(14.dp))
                                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
                                        .clickable { expandedShowDesc = !expandedShowDesc }
                                        .padding(14.dp)
                                        .animateContentSize(),
                                ) {
                                    Text(
                                        text = "About this show",
                                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.padding(bottom = 4.dp),
                                    )
                                    Text(
                                        text = show.description,
                                        style = MaterialTheme.typography.bodySmall.copy(lineHeight = 18.sp),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = if (expandedShowDesc) Int.MAX_VALUE else 3,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }

                    // Section Header: Episodes List & Sort Pill
                    item {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = PAGE_GUTTER, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text(
                                text = "Episodes (${displayedEpisodes.size})",
                                style = MaterialTheme.typography.titleLarge.copy(
                                    fontWeight = FontWeight.Bold,
                                ),
                                color = MaterialTheme.colorScheme.onBackground,
                            )

                            // Sort Order Pill
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(20.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                                    .clickable { sortNewestFirst = !sortNewestFirst }
                                    .padding(horizontal = 10.dp, vertical = 6.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Sort,
                                    contentDescription = "Sort order",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(modifier = Modifier.width(4.dp))
                                Text(
                                    text = if (sortNewestFirst) stringResource(R.string.sort_newest) else stringResource(R.string.sort_oldest),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }

                    // Episode Rows
                    if (displayedEpisodes.isEmpty()) {
                        item {
                            Text(
                                text = stringResource(R.string.no_episodes_found),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(horizontal = PAGE_GUTTER, vertical = 16.dp),
                            )
                        }
                    } else {
                        items(displayedEpisodes, key = { it.videoId }) { episode ->
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
            }
        }

        // Floating Back Button on Top Left
        IconButton(
            onClick = onBack,
            modifier = Modifier
                .statusBarsPadding()
                .padding(start = 12.dp, top = 8.dp)
                .size(40.dp)
                .clip(CircleShape)
                .background(Color.Black.copy(alpha = 0.45f)),
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                contentDescription = "Back",
                tint = Color.White,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
