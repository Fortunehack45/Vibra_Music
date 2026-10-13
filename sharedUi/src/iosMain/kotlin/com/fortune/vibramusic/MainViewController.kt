package com.fortune.vibramusic

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Explore
import androidx.compose.material.icons.rounded.Group
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Lyrics
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.ComposeUIViewController
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.ios.IosPlaybackEngine
import platform.UIKit.UIViewController

private val VibraDarkColors = darkColorScheme(
    primary = Color(0xFFFFFFFF),
    onPrimary = Color(0xFF0B0B0E),
    background = Color(0xFF0A0A0E),
    onBackground = Color(0xFFFFFFFF),
    surface = Color(0xFF14151C),
    onSurface = Color(0xFFFFFFFF),
    surfaceVariant = Color(0xFF1E202B),
    onSurfaceVariant = Color(0xFFB8BCC8),
)

private enum class IosTab(val label: String) {
    HOME("Home"),
    EXPLORE("Explore"),
    SEARCH("Search"),
    LIBRARY("Library"),
}

fun MainViewController(): UIViewController = ComposeUIViewController {
    VibraMusicIosApp()
}

@Composable
fun VibraMusicIosApp() {
    val defaultQueue = remember {
        listOf(
            Song(
                videoId = "vibra_1",
                title = "Midnight Horizon",
                artist = "Vibra Studio",
                albumName = "Nightfall Sessions",
                durationSeconds = 214,
            ),
            Song(
                videoId = "vibra_2",
                title = "Velvet Echoes",
                artist = "Siren Collective",
                albumName = "Liquid Glass",
                durationSeconds = 198,
            ),
            Song(
                videoId = "vibra_3",
                title = "Golden Hour Drift",
                artist = "Aether & Pulse",
                albumName = "Solaris",
                durationSeconds = 242,
            ),
        )
    }

    val queue by IosPlaybackEngine.queue.collectAsState()
    val currentIndex by IosPlaybackEngine.currentIndex.collectAsState()
    val isPlaying by IosPlaybackEngine.isPlaying.collectAsState()
    val positionMs by IosPlaybackEngine.positionMs.collectAsState()
    val durationMs by IosPlaybackEngine.durationMs.collectAsState()
    val partyState by IosPlaybackEngine.partyState.collectAsState()

    val activeQueue = if (queue.isEmpty()) defaultQueue else queue
    val currentSong = activeQueue.getOrElse(currentIndex.coerceIn(0, activeQueue.lastIndex)) { defaultQueue.first() }

    var selectedTab by remember { mutableStateOf(IosTab.HOME) }
    var playerExpanded by remember { mutableStateOf(false) }
    var showLyricsShareCard by remember { mutableStateOf(false) }
    var useCoverBackground by remember { mutableStateOf(false) }
    var showListenTogetherSheet by remember { mutableStateOf(false) }

    MaterialTheme(colorScheme = VibraDarkColors) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(VibraDarkColors.background),
        ) {
            Scaffold(
                containerColor = Color.Transparent,
                bottomBar = {
                    Column {
                        // Floating Liquid Glass MiniPlayer bar matching Android UI
                        MiniPlayerBar(
                            song = currentSong,
                            isPlaying = isPlaying,
                            onTogglePlay = { IosPlaybackEngine.togglePlayPause() },
                            onSkipNext = { IosPlaybackEngine.skipNext() },
                            onClick = { playerExpanded = true },
                        )
                        NavigationBar(
                            containerColor = Color(0xFF0E0F14).copy(alpha = 0.94f),
                            contentColor = Color.White,
                        ) {
                            IosTab.entries.forEach { tab ->
                                val selected = selectedTab == tab
                                NavigationBarItem(
                                    selected = selected,
                                    onClick = { selectedTab = tab },
                                    icon = {
                                        Icon(
                                            imageVector = when (tab) {
                                                IosTab.HOME -> Icons.Rounded.Home
                                                IosTab.EXPLORE -> Icons.Rounded.Explore
                                                IosTab.SEARCH -> Icons.Rounded.Search
                                                IosTab.LIBRARY -> Icons.Rounded.LibraryMusic
                                            },
                                            contentDescription = tab.label,
                                        )
                                    },
                                    label = {
                                        Text(
                                            text = tab.label,
                                            fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                                        )
                                    },
                                    colors = NavigationBarItemDefaults.colors(
                                        selectedIconColor = Color.White,
                                        selectedTextColor = Color.White,
                                        unselectedIconColor = Color.White.copy(alpha = 0.55f),
                                        unselectedTextColor = Color.White.copy(alpha = 0.55f),
                                        indicatorColor = Color.White.copy(alpha = 0.14f),
                                    ),
                                )
                            }
                        }
                    }
                },
            ) { innerPadding ->
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(innerPadding),
                    contentPadding = PaddingValues(horizontal = 20.dp, vertical = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    item {
                        Text(
                            text = selectedTab.label,
                            style = MaterialTheme.typography.headlineLarge,
                            fontWeight = FontWeight.Bold,
                            color = Color.White,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = "Vibra Music for iOS — Identical UI & UX",
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color.White.copy(alpha = 0.65f),
                        )
                    }

                    itemsIndexed(activeQueue) { index, track ->
                        val isCurrent = track.videoId == currentSong.videoId
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(
                                    if (isCurrent) Color.White.copy(alpha = 0.12f)
                                    else Color.White.copy(alpha = 0.05f),
                                )
                                .clickable {
                                    IosPlaybackEngine.setQueue(activeQueue, index, 0L, autoPlay = true)
                                    playerExpanded = true
                                }
                                .padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(52.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(
                                        Brush.linearGradient(
                                            listOf(Color(0xFF344868), Color(0xFF171E2E)),
                                        ),
                                    ),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    text = track.title.take(1).uppercase(),
                                    color = Color.White,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 20.sp,
                                )
                            }
                            Spacer(Modifier.width(14.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = track.title,
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    color = Color.White,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    text = track.artist,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = Color.White.copy(alpha = 0.68f),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            IconButton(
                                onClick = {
                                    IosPlaybackEngine.setQueue(activeQueue, index, 0L, autoPlay = true)
                                },
                            ) {
                                Icon(
                                    imageVector = if (isCurrent && isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                    contentDescription = null,
                                    tint = Color.White,
                                )
                            }
                        }
                    }
                }
            }

            // Full-Screen Now Playing Sheet with Eased Theme Gradient, Listen Together & Spotify-Style Lyrics Share
            AnimatedVisibility(
                visible = playerExpanded,
                enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
                exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(
                            Brush.verticalGradient(
                                0.00f to Color(0xFF28344A),
                                0.35f to Color(0xFF1E2738),
                                0.68f to Color(0xFF131824),
                                1.00f to Color(0xFF0B0D14),
                            ),
                        )
                        .padding(horizontal = 24.dp, vertical = 32.dp),
                ) {
                    Column(
                        modifier = Modifier.fillMaxSize(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Close",
                                color = Color.White.copy(alpha = 0.8f),
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(10.dp))
                                    .clickable { playerExpanded = false }
                                    .padding(horizontal = 10.dp, vertical = 6.dp),
                            )
                            Text(
                                text = if (partyState != null) "Listen Together Active" else "Now Playing",
                                style = MaterialTheme.typography.labelLarge,
                                color = Color.White.copy(alpha = 0.75f),
                            )
                            IconButton(onClick = { showLyricsShareCard = !showLyricsShareCard }) {
                                Icon(
                                    imageVector = Icons.Rounded.Share,
                                    contentDescription = "Share Lyrics",
                                    tint = Color.White,
                                )
                            }
                        }

                        Spacer(Modifier.height(20.dp))

                        if (showLyricsShareCard) {
                            // Full-bleed Spotify-style Lyrics Card with tight vertical spacing
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(0.86f)
                                    .clip(RoundedCornerShape(24.dp))
                                    .background(
                                        if (useCoverBackground) {
                                            Brush.verticalGradient(
                                                0.0f to Color(0xFF090A0F).copy(alpha = 0.78f),
                                                0.5f to Color(0xFF10131C).copy(alpha = 0.62f),
                                                1.0f to Color(0xFF07080C).copy(alpha = 0.84f),
                                            )
                                        } else {
                                            Brush.verticalGradient(
                                                0.0f to Color(0xFF324766),
                                                0.58f to Color(0xFF212F45),
                                                1.0f to Color(0xFF121926),
                                            )
                                        },
                                    )
                                    .border(1.dp, Color.White.copy(alpha = 0.22f), RoundedCornerShape(24.dp))
                                    .padding(24.dp),
                            ) {
                                Column(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalArrangement = Arrangement.spacedBy(16.dp),
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Box(
                                            modifier = Modifier
                                                .size(44.dp)
                                                .clip(RoundedCornerShape(10.dp))
                                                .background(Color.White.copy(alpha = 0.18f)),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Text(
                                                text = currentSong.title.take(1),
                                                color = Color.White,
                                                fontWeight = FontWeight.Bold,
                                            )
                                        }
                                        Spacer(Modifier.width(12.dp))
                                        Column {
                                            Text(
                                                text = currentSong.title,
                                                color = Color.White,
                                                fontWeight = FontWeight.Bold,
                                                fontSize = 16.sp,
                                            )
                                            Text(
                                                text = currentSong.artist,
                                                color = Color.White.copy(alpha = 0.78f),
                                                fontSize = 13.sp,
                                            )
                                        }
                                    }

                                    Text(
                                        text = "We drift across the midnight horizon\nEvery beat aligned in crystal sound",
                                        color = Color.White,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 23.sp,
                                        lineHeight = 29.sp,
                                    )

                                    Text(
                                        text = "Vibra Music",
                                        color = Color.White.copy(alpha = 0.90f),
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 13.sp,
                                    )
                                }
                            }

                            Spacer(Modifier.height(12.dp))
                            Row(
                                modifier = Modifier.fillMaxWidth(0.86f),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "Darkened cover background",
                                    color = Color.White,
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                                Switch(
                                    checked = useCoverBackground,
                                    onCheckedChange = { useCoverBackground = it },
                                    colors = SwitchDefaults.colors(
                                        checkedThumbColor = Color.Black,
                                        checkedTrackColor = Color.White,
                                    ),
                                )
                            }
                        } else {
                            // Album Sleeve with smooth multi-stop bottom dissolve
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(0.86f)
                                    .aspectRatio(1f)
                                    .clip(RoundedCornerShape(24.dp))
                                    .background(
                                        Brush.linearGradient(
                                            listOf(Color(0xFF395075), Color(0xFF182233)),
                                        ),
                                    ),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    text = currentSong.title.take(1),
                                    color = Color.White,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 72.sp,
                                )
                                Canvas(modifier = Modifier.fillMaxSize()) {
                                    drawRect(
                                        brush = Brush.verticalGradient(
                                            0.45f to Color.Transparent,
                                            0.68f to Color(0xFF131824).copy(alpha = 0.35f),
                                            0.86f to Color(0xFF131824).copy(alpha = 0.75f),
                                            1.00f to Color(0xFF131824),
                                        ),
                                    )
                                }
                            }
                        }

                        Spacer(Modifier.weight(1f))

                        Column(modifier = Modifier.fillMaxWidth()) {
                            Text(
                                text = currentSong.title,
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.Bold,
                                color = Color.White,
                            )
                            Text(
                                text = currentSong.artist,
                                style = MaterialTheme.typography.titleMedium,
                                color = Color.White.copy(alpha = 0.68f),
                            )
                        }

                        Spacer(Modifier.height(16.dp))

                        val safeDuration = durationMs.coerceAtLeast(1L)
                        Slider(
                            value = (positionMs.toFloat() / safeDuration.toFloat()).coerceIn(0f, 1f),
                            onValueChange = { frac ->
                                IosPlaybackEngine.seekTo((frac * safeDuration).toLong())
                            },
                            colors = SliderDefaults.colors(
                                thumbColor = Color.White,
                                activeTrackColor = Color.White,
                                inactiveTrackColor = Color.White.copy(alpha = 0.24f),
                            ),
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceEvenly,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconButton(onClick = { IosPlaybackEngine.skipPrevious() }) {
                                Icon(
                                    imageVector = Icons.Rounded.SkipPrevious,
                                    contentDescription = "Previous",
                                    tint = Color.White,
                                    modifier = Modifier.size(36.dp),
                                )
                            }
                            IconButton(
                                onClick = { IosPlaybackEngine.togglePlayPause() },
                                modifier = Modifier
                                    .size(68.dp)
                                    .clip(CircleShape)
                                    .background(Color.White),
                            ) {
                                Icon(
                                    imageVector = if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                    contentDescription = "Play/Pause",
                                    tint = Color.Black,
                                    modifier = Modifier.size(36.dp),
                                )
                            }
                            IconButton(onClick = { IosPlaybackEngine.skipNext() }) {
                                Icon(
                                    imageVector = Icons.Rounded.SkipNext,
                                    contentDescription = "Next",
                                    tint = Color.White,
                                    modifier = Modifier.size(36.dp),
                                )
                            }
                        }

                        Spacer(Modifier.height(18.dp))

                        // Bottom action row matching Android PlayerActionRow
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceEvenly,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            IconButton(onClick = { showLyricsShareCard = !showLyricsShareCard }) {
                                Icon(
                                    imageVector = Icons.Rounded.Lyrics,
                                    contentDescription = "Lyrics",
                                    tint = if (showLyricsShareCard) Color.White else Color.White.copy(alpha = 0.65f),
                                )
                            }
                            IconButton(onClick = { showListenTogetherSheet = !showListenTogetherSheet }) {
                                Icon(
                                    imageVector = Icons.Rounded.Group,
                                    contentDescription = "Listen Together",
                                    tint = if (partyState != null) Color.White else Color.White.copy(alpha = 0.65f),
                                )
                            }
                            IconButton(onClick = { playerExpanded = false }) {
                                Icon(
                                    imageVector = Icons.Rounded.QueueMusic,
                                    contentDescription = "Queue",
                                    tint = Color.White.copy(alpha = 0.65f),
                                )
                            }
                        }

                        if (showListenTogetherSheet) {
                            Spacer(Modifier.height(12.dp))
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(Color.White.copy(alpha = 0.10f))
                                    .padding(14.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "Disconnect keeps current song playing",
                                    color = Color.White,
                                    style = MaterialTheme.typography.bodySmall,
                                    modifier = Modifier.weight(1f),
                                )
                                Spacer(Modifier.width(12.dp))
                                Button(
                                    onClick = {
                                        IosPlaybackEngine.leavePartyContinuingCurrentTrack()
                                        showListenTogetherSheet = false
                                    },
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color.White,
                                        contentColor = Color.Black,
                                    ),
                                ) {
                                    Text("Leave", fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MiniPlayerBar(
    song: Song,
    isPlaying: Boolean,
    onTogglePlay: () -> Unit,
    onSkipNext: () -> Unit,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0xFF1A1C26).copy(alpha = 0.95f))
            .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(18.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(42.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Brush.linearGradient(listOf(Color(0xFF395075), Color(0xFF182233)))),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = song.title.take(1).uppercase(),
                color = Color.White,
                fontWeight = FontWeight.Bold,
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = song.title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = song.artist,
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.68f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        IconButton(onClick = onTogglePlay) {
            Icon(
                imageVector = if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                contentDescription = "Play/Pause",
                tint = Color.White,
            )
        }
        IconButton(onClick = onSkipNext) {
            Icon(
                imageVector = Icons.Rounded.SkipNext,
                contentDescription = "Next",
                tint = Color.White,
            )
        }
    }
}
