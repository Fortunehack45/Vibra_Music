package com.fortune.vibramusic.desktop.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.desktop.glass.liquidGlass
import com.fortune.vibramusic.desktop.model.DesktopLyricLine
import com.fortune.vibramusic.desktop.model.DesktopMoodGenre
import com.fortune.vibramusic.desktop.model.DesktopShelf
import com.fortune.vibramusic.desktop.model.DesktopSong
import com.fortune.vibramusic.desktop.model.DesktopTab
import com.fortune.vibramusic.desktop.ui.icons.VibraMusicIcons

private val GlassSpring = spring<Float>(dampingRatio = 0.72f, stiffness = 320f)

/**
 * Frosted Top Bar matching the mobile FrostedTopBar 1:1.
 */
@Composable
fun DesktopTopBar(
    updateAvailable: Boolean,
    onOpenUpdate: () -> Unit,
    onOpenParty: () -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(54.dp)
            .padding(horizontal = 24.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        // App Logo & Wordmark
        Row(verticalAlignment = Alignment.CenterVertically) {
            Image(
                painter = painterResource("icon.png"),
                contentDescription = "Vibra Music Logo",
                modifier = Modifier
                    .size(34.dp)
                    .clip(RoundedCornerShape(8.dp)),
            )
            Spacer(modifier = Modifier.width(12.dp))
            Text(
                text = "Vibra Music",
                color = Color.White,
                fontSize = 20.sp,
                fontWeight = FontWeight.ExtraBold,
                letterSpacing = (-0.5).sp,
            )
        }

        // Action Buttons
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (updateAvailable) {
                IconButton(
                    onClick = onOpenUpdate,
                    modifier = Modifier.size(38.dp),
                ) {
                    Box(contentAlignment = Alignment.TopEnd) {
                        Icon(
                            imageVector = Icons.Rounded.SystemUpdate,
                            contentDescription = "Update Available",
                            tint = Color(0xFFFA2D48),
                            modifier = Modifier.size(22.dp),
                        )
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .clip(CircleShape)
                                .background(Color(0xFFFA2D48))
                        )
                    }
                }
                Spacer(modifier = Modifier.width(8.dp))
            }

            IconButton(
                onClick = onOpenParty,
                modifier = Modifier.size(38.dp),
            ) {
                Icon(
                    imageVector = Icons.Rounded.Groups,
                    contentDescription = "Listen Together",
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(22.dp),
                )
            }

            Spacer(modifier = Modifier.width(8.dp))

            IconButton(
                onClick = onOpenSettings,
                modifier = Modifier.size(38.dp),
            ) {
                Icon(
                    imageVector = Icons.Rounded.Settings,
                    contentDescription = "Settings",
                    tint = Color.White.copy(alpha = 0.85f),
                    modifier = Modifier.size(22.dp),
                )
            }
        }
    }
}

/**
 * Mobile-Matched Floating Liquid Glass Bottom Navigation Bar.
 */
@Composable
fun DesktopFloatingNavBar(
    selectedTab: DesktopTab,
    onTabSelected: (DesktopTab) -> Unit,
    modifier: Modifier = Modifier,
) {
    val pillShape = remember { RoundedCornerShape(percent = 50) }
    val tabs = remember {
        listOf(
            DesktopTab.Home to VibraMusicIcons.Home,
            DesktopTab.Explore to VibraMusicIcons.Explore,
            DesktopTab.Library to VibraMusicIcons.Library,
            DesktopTab.Search to VibraMusicIcons.Search,
        )
    }

    Box(
        modifier = modifier
            .liquidGlass(shape = pillShape, elevation = 14.dp)
            .background(Color(0xFF14151B).copy(alpha = 0.88f), pillShape)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            tabs.forEach { (tab, icon) ->
                val isSelected = selectedTab == tab
                DesktopNavTabItem(
                    title = tab.title,
                    icon = icon,
                    isSelected = isSelected,
                    onClick = { onTabSelected(tab) },
                )
            }
        }
    }
}

@Composable
private fun DesktopNavTabItem(
    title: String,
    icon: ImageVector,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val pillShape = remember { RoundedCornerShape(percent = 50) }
    val interactionSource = remember { MutableInteractionSource() }

    val bgModifier = if (isSelected) {
        Modifier
            .clip(pillShape)
            .background(Color.White.copy(alpha = 0.16f))
    } else {
        Modifier
    }

    Row(
        modifier = Modifier
            .then(bgModifier)
            .clickable(interactionSource = interactionSource, indication = null) { onClick() }
            .padding(horizontal = 18.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = title,
            tint = if (isSelected) Color.White else Color.White.copy(alpha = 0.55f),
            modifier = Modifier.size(20.dp),
        )
        if (isSelected) {
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = title,
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

/**
 * Mobile-Matched Floating MiniPlayer with Liquid Glass styling.
 */
@Composable
fun DesktopMiniPlayer(
    song: DesktopSong,
    isPlaying: Boolean,
    isBuffering: Boolean,
    onPlayPause: () -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    onExpand: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pillShape = remember { RoundedCornerShape(percent = 50) }

    Box(
        modifier = modifier
            .height(58.dp)
            .liquidGlass(shape = pillShape, elevation = 14.dp)
            .background(Color(0xFF181A22).copy(alpha = 0.90f), pillShape)
            .clickable { onExpand() }
            .padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Row(
            modifier = Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Album Art
            AsyncImage(
                model = song.thumbnailUrl,
                contentDescription = song.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(8.dp)),
            )

            Spacer(modifier = Modifier.width(12.dp))

            // Title & Artist
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    text = song.title,
                    color = Color.White,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = song.artist,
                    color = Color(0xFF8E8E93),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Spacer(modifier = Modifier.width(8.dp))

            // Transport Controls
            IconButton(
                onClick = onPrevious,
                modifier = Modifier.size(36.dp),
            ) {
                Icon(
                    imageVector = Icons.Rounded.SkipPrevious,
                    contentDescription = "Previous",
                    tint = Color.White,
                    modifier = Modifier.size(24.dp),
                )
            }

            IconButton(
                onClick = onPlayPause,
                modifier = Modifier.size(40.dp),
            ) {
                if (isBuffering) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        color = Color.White,
                        strokeWidth = 2.dp,
                    )
                } else {
                    Icon(
                        imageVector = if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                        contentDescription = if (isPlaying) "Pause" else "Play",
                        tint = Color.White,
                        modifier = Modifier.size(28.dp),
                    )
                }
            }

            IconButton(
                onClick = onNext,
                modifier = Modifier.size(36.dp),
            ) {
                Icon(
                    imageVector = Icons.Rounded.SkipNext,
                    contentDescription = "Next",
                    tint = Color.White,
                    modifier = Modifier.size(24.dp),
                )
            }
        }
    }
}

/**
 * Mobile-Matched Quick Picks track row (used in Home feed).
 */
@Composable
fun DesktopQuickPickItem(
    song: DesktopSong,
    isPlaying: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable { onClick() }
            .padding(horizontal = 8.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(48.dp)
                .clip(RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            AsyncImage(
                model = song.thumbnailUrl,
                contentDescription = song.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            if (isPlaying) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.5f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Rounded.PlayArrow,
                        contentDescription = "Playing",
                        tint = Color(0xFFFA2D48),
                        modifier = Modifier.size(24.dp),
                    )
                }
            }
        }

        Spacer(modifier = Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = song.title,
                color = if (isPlaying) Color(0xFFFA2D48) else Color.White,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = "${song.artist} • ${song.album}",
                color = Color(0xFF8E8E93),
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * Horizontal Carousel Shelf Card (Trending, New Releases, etc.).
 */
@Composable
fun DesktopShelfCard(
    song: DesktopSong,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .width(154.dp)
            .clickable { onClick() }
            .padding(end = 16.dp),
    ) {
        Box(
            modifier = Modifier
                .size(154.dp)
                .shadow(8.dp, RoundedCornerShape(12.dp))
                .clip(RoundedCornerShape(12.dp)),
        ) {
            AsyncImage(
                model = song.thumbnailUrl,
                contentDescription = song.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = song.title,
            color = Color.White,
            fontSize = 14.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )

        Spacer(modifier = Modifier.height(2.dp))

        Text(
            text = song.artist,
            color = Color(0xFF8E8E93),
            fontSize = 12.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * Mood & Genre Card matching ExploreScreen.
 */
@Composable
fun DesktopMoodGenreCard(
    mood: DesktopMoodGenre,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .height(72.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Brush.linearGradient(mood.colors))
            .clickable { onClick() }
            .padding(16.dp),
        contentAlignment = Alignment.BottomStart,
    ) {
        Text(
            text = mood.title,
            color = Color.White,
            fontSize = 18.sp,
            fontWeight = FontWeight.ExtraBold,
            letterSpacing = (-0.4).sp,
        )
    }
}

/**
 * Search Bar styled with Liquid Glass capsule.
 */
@Composable
fun DesktopSearchBar(
    query: String,
    onQueryChange: (String) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pillShape = remember { RoundedCornerShape(percent = 50) }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(50.dp)
            .liquidGlass(shape = pillShape, elevation = 8.dp)
            .background(Color(0xFF1E2029).copy(alpha = 0.85f), pillShape)
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Row(
            modifier = Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = VibraMusicIcons.Search,
                contentDescription = "Search",
                tint = Color(0xFF8E8E93),
                modifier = Modifier.size(20.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
            TextField(
                value = query,
                onValueChange = onQueryChange,
                placeholder = {
                    Text(
                        text = "Artists, Songs, Lyrics and More...",
                        color = Color(0xFF8E8E93),
                        fontSize = 14.sp,
                    )
                },
                colors = TextFieldDefaults.colors(
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            if (query.isNotEmpty()) {
                IconButton(onClick = onClear, modifier = Modifier.size(28.dp)) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Clear",
                        tint = Color.White.copy(alpha = 0.6f),
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/**
 * Song List item row displayed in search results and playlists.
 */
@Composable
fun DesktopSongListItem(
    song: DesktopSong,
    isPlaying: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AsyncImage(
            model = song.thumbnailUrl,
            contentDescription = song.title,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(52.dp)
                .clip(RoundedCornerShape(8.dp)),
        )

        Spacer(modifier = Modifier.width(16.dp))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = song.title,
                color = if (isPlaying) Color(0xFFFA2D48) else Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = "${song.artist} • ${song.album}",
                color = Color(0xFF8E8E93),
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        Spacer(modifier = Modifier.width(16.dp))

        Text(
            text = formatTime(song.durationSeconds * 1000L),
            color = Color(0xFF8E8E93),
            fontSize = 13.sp,
        )
    }
}

/**
 * 2-Column Fullscreen Landscape Now Playing Screen matching mobile LandscapePlayerLayout.
 */
@Composable
fun DesktopNowPlayingScreen(
    song: DesktopSong,
    isPlaying: Boolean,
    isBuffering: Boolean,
    currentPositionMs: Long,
    durationMs: Long,
    volume: Float,
    isLiked: Boolean,
    onToggleLike: () -> Unit,
    onClose: () -> Unit,
    onPlayPause: () -> Unit,
    onSeekTo: (Long) -> Unit,
    onSkipNext: () -> Unit,
    onSkipPrevious: () -> Unit,
    onVolumeChange: (Float) -> Unit,
    queue: List<DesktopSong>,
    onSelectQueueItem: (DesktopSong) -> Unit,
    modifier: Modifier = Modifier,
) {
    var activePane by remember { mutableStateOf(PlayerPane.Main) }

    Box(modifier = modifier.fillMaxSize()) {
        // Dynamic Animated Mesh Gradient Backdrop
        DesktopMeshGradient(modifier = Modifier.fillMaxSize())

        BoxWithConstraints(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.TopCenter,
        ) {
            val maxColWidth = 1100.dp

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(top = 16.dp, bottom = 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                // Top drag handle indicator + Close Button
                Box(
                    modifier = Modifier
                        .widthIn(max = maxColWidth)
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        modifier = Modifier
                            .size(width = 40.dp, height = 5.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(Color.White.copy(alpha = 0.65f))
                    )

                    IconButton(
                        onClick = onClose,
                        modifier = Modifier
                            .align(Alignment.CenterEnd)
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.12f)),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "Close",
                            tint = Color.White,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }

                Spacer(modifier = Modifier.height(16.dp))

                // 2-Column Landscape Split Layout
                Row(
                    modifier = Modifier
                        .widthIn(max = maxColWidth)
                        .weight(1f)
                        .padding(horizontal = 24.dp),
                    horizontalArrangement = Arrangement.spacedBy(36.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // LEFT COLUMN: Large Album Artwork Sleeve + Action Bar
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .aspectRatio(1f)
                                .shadow(24.dp, RoundedCornerShape(18.dp))
                                .clip(RoundedCornerShape(18.dp)),
                            contentAlignment = Alignment.Center,
                        ) {
                            AsyncImage(
                                model = song.thumbnailUrl,
                                contentDescription = song.title,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }

                        Spacer(modifier = Modifier.height(20.dp))

                        // Action Buttons Bar under sleeve
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(20.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconButton(
                                onClick = onToggleLike,
                                modifier = Modifier
                                    .size(44.dp)
                                    .clip(CircleShape)
                                    .background(if (isLiked) Color(0xFFFA2D48).copy(alpha = 0.2f) else Color.White.copy(alpha = 0.1f)),
                            ) {
                                Icon(
                                    imageVector = if (isLiked) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                                    contentDescription = "Like",
                                    tint = if (isLiked) Color(0xFFFA2D48) else Color.White,
                                    modifier = Modifier.size(22.dp),
                                )
                            }

                            IconButton(
                                onClick = {
                                    activePane = if (activePane == PlayerPane.Lyrics) PlayerPane.Main else PlayerPane.Lyrics
                                },
                                modifier = Modifier
                                    .size(44.dp)
                                    .clip(CircleShape)
                                    .background(if (activePane == PlayerPane.Lyrics) Color.White.copy(alpha = 0.25f) else Color.White.copy(alpha = 0.1f)),
                            ) {
                                Icon(
                                    imageVector = VibraMusicIcons.LyricsQuote,
                                    contentDescription = "Lyrics",
                                    tint = Color.White,
                                    modifier = Modifier.size(22.dp),
                                )
                            }

                            IconButton(
                                onClick = {
                                    activePane = if (activePane == PlayerPane.Queue) PlayerPane.Main else PlayerPane.Queue
                                },
                                modifier = Modifier
                                    .size(44.dp)
                                    .clip(CircleShape)
                                    .background(if (activePane == PlayerPane.Queue) Color.White.copy(alpha = 0.25f) else Color.White.copy(alpha = 0.1f)),
                            ) {
                                Icon(
                                    imageVector = VibraMusicIcons.Queue,
                                    contentDescription = "Queue",
                                    tint = Color.White,
                                    modifier = Modifier.size(22.dp),
                                )
                            }
                        }
                    }

                    // RIGHT COLUMN: Main Controls / Lyrics / Queue
                    AnimatedContent(
                        targetState = activePane,
                        transitionSpec = { fadeIn(tween(250)) togetherWith fadeOut(tween(200)) },
                        modifier = Modifier
                            .weight(1.1f)
                            .fillMaxHeight(),
                        label = "LandscapeRightPane",
                    ) { pane ->
                        when (pane) {
                            PlayerPane.Main -> {
                                Column(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .padding(horizontal = 16.dp),
                                    verticalArrangement = Arrangement.Center,
                                ) {
                                    Text(
                                        text = song.title,
                                        color = Color.White,
                                        fontSize = 28.sp,
                                        fontWeight = FontWeight.ExtraBold,
                                        letterSpacing = (-0.6).sp,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    Spacer(modifier = Modifier.height(4.dp))
                                    Text(
                                        text = song.artist,
                                        color = Color.White.copy(alpha = 0.8f),
                                        fontSize = 18.sp,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                    Text(
                                        text = song.album,
                                        color = Color(0xFF8E8E93),
                                        fontSize = 14.sp,
                                    )

                                    Spacer(modifier = Modifier.height(28.dp))

                                    // Scrubber Progress Slider
                                    Column {
                                        val totalDuration = if (durationMs > 0) durationMs else (song.durationSeconds * 1000L).coerceAtLeast(1L)
                                        val progress = (currentPositionMs.toFloat() / totalDuration.toFloat()).coerceIn(0f, 1f)

                                        Slider(
                                            value = progress,
                                            onValueChange = { frac ->
                                                onSeekTo((frac * totalDuration).toLong())
                                            },
                                            colors = SliderDefaults.colors(
                                                thumbColor = Color.White,
                                                activeTrackColor = Color.White,
                                                inactiveTrackColor = Color.White.copy(alpha = 0.2f),
                                            ),
                                            modifier = Modifier.fillMaxWidth(),
                                        )

                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                        ) {
                                            Text(
                                                text = formatTime(currentPositionMs),
                                                color = Color.White.copy(alpha = 0.7f),
                                                fontSize = 12.sp,
                                            )
                                            Text(
                                                text = "-" + formatTime((totalDuration - currentPositionMs).coerceAtLeast(0L)),
                                                color = Color.White.copy(alpha = 0.7f),
                                                fontSize = 12.sp,
                                            )
                                        }
                                    }

                                    Spacer(modifier = Modifier.height(24.dp))

                                    // Transport Row
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.SpaceEvenly,
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        IconButton(
                                            onClick = onSkipPrevious,
                                            modifier = Modifier.size(48.dp),
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.SkipPrevious,
                                                contentDescription = "Previous",
                                                tint = Color.White,
                                                modifier = Modifier.size(36.dp),
                                            )
                                        }

                                        Box(
                                            modifier = Modifier
                                                .size(72.dp)
                                                .shadow(16.dp, CircleShape)
                                                .clip(CircleShape)
                                                .background(Color.White)
                                                .clickable { onPlayPause() },
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            if (isBuffering) {
                                                CircularProgressIndicator(
                                                    modifier = Modifier.size(32.dp),
                                                    color = Color.Black,
                                                    strokeWidth = 3.dp,
                                                )
                                            } else {
                                                Icon(
                                                    imageVector = if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                                    contentDescription = "Play/Pause",
                                                    tint = Color.Black,
                                                    modifier = Modifier.size(40.dp),
                                                )
                                            }
                                        }

                                        IconButton(
                                            onClick = onSkipNext,
                                            modifier = Modifier.size(48.dp),
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.SkipNext,
                                                contentDescription = "Next",
                                                tint = Color.White,
                                                modifier = Modifier.size(36.dp),
                                            )
                                        }
                                    }

                                    Spacer(modifier = Modifier.height(28.dp))

                                    // Volume Bar
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Icon(
                                            imageVector = Icons.AutoMirrored.Rounded.VolumeUp,
                                            contentDescription = "Volume",
                                            tint = Color.White.copy(alpha = 0.7f),
                                            modifier = Modifier.size(20.dp),
                                        )
                                        Spacer(modifier = Modifier.width(12.dp))
                                        Slider(
                                            value = volume,
                                            onValueChange = onVolumeChange,
                                            colors = SliderDefaults.colors(
                                                thumbColor = Color.White,
                                                activeTrackColor = Color.White,
                                                inactiveTrackColor = Color.White.copy(alpha = 0.2f),
                                            ),
                                            modifier = Modifier.weight(1f),
                                        )
                                    }
                                }
                            }

                            PlayerPane.Lyrics -> {
                                Column(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .padding(horizontal = 16.dp),
                                ) {
                                    Text(
                                        text = "Lyrics",
                                        color = Color.White,
                                        fontSize = 24.sp,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.padding(bottom = 16.dp),
                                    )

                                    if (song.lyrics.isEmpty()) {
                                        Box(
                                            modifier = Modifier.fillMaxSize(),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Text(
                                                text = "No synchronized lyrics available",
                                                color = Color.White.copy(alpha = 0.5f),
                                                fontSize = 16.sp,
                                            )
                                        }
                                    } else {
                                        LazyColumn(
                                            modifier = Modifier.fillMaxSize(),
                                            verticalArrangement = Arrangement.spacedBy(16.dp),
                                        ) {
                                            itemsIndexed(song.lyrics) { index, line ->
                                                val nextTime = song.lyrics.getOrNull(index + 1)?.timeMs ?: Long.MAX_VALUE
                                                val isCurrent = currentPositionMs in line.timeMs until nextTime

                                                Text(
                                                    text = line.words,
                                                    color = if (isCurrent) Color.White else Color.White.copy(alpha = 0.35f),
                                                    fontSize = if (isCurrent) 24.sp else 20.sp,
                                                    fontWeight = if (isCurrent) FontWeight.ExtraBold else FontWeight.Medium,
                                                    modifier = Modifier
                                                        .clickable { onSeekTo(line.timeMs) }
                                                        .padding(vertical = 4.dp),
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            PlayerPane.Queue -> {
                                Column(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .padding(horizontal = 16.dp),
                                ) {
                                    Text(
                                        text = "Up Next (${queue.size})",
                                        color = Color.White,
                                        fontSize = 24.sp,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.padding(bottom = 16.dp),
                                    )

                                    LazyColumn(
                                        modifier = Modifier.fillMaxSize(),
                                        verticalArrangement = Arrangement.spacedBy(8.dp),
                                    ) {
                                        items(queue) { queueSong ->
                                            DesktopSongListItem(
                                                song = queueSong,
                                                isPlaying = queueSong.id == song.id && isPlaying,
                                                onClick = { onSelectQueueItem(queueSong) },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

enum class PlayerPane { Main, Lyrics, Queue }

private fun formatTime(ms: Long): String {
    val totalSec = (ms / 1000).coerceAtLeast(0)
    val min = totalSec / 60
    val sec = totalSec % 60
    return "%02d:%02d".format(min, sec)
}
