package com.fortune.vibramusic.ui.quiz

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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.EmojiEvents
import androidx.compose.material.icons.rounded.MilitaryTech
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.WorkspacePremium
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.artworkAt
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.quiz.LeaderboardEntry
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.ui.components.ArtistAvatar
import com.fortune.vibramusic.ui.components.ArtworkWash
import com.fortune.vibramusic.ui.theme.rememberArtworkPalette
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import kotlin.math.roundToInt

@Composable
fun ArtistLeaderboardScreen(
    artist: QuizArtist,
    onBack: () -> Unit,
    onChallengeArtist: () -> Unit,
    onOpenArtistDetail: ((id: String, name: String, artworkUrl: String?) -> Unit)? = null,
    onPlaySong: ((Song) -> Unit)? = null,
    contentPadding: PaddingValues,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    var resolvedArtwork by remember(artist.name) { mutableStateOf(artist.artworkUrl) }
    var resolvedBrowseId by remember(artist.id) { mutableStateOf(artist.id) }

    val listState = rememberLazyListState()
    val highResArtwork = (resolvedArtwork ?: artist.artworkUrl)?.artworkAt(1080) ?: (resolvedArtwork ?: artist.artworkUrl)
    val palette = rememberArtworkPalette(highResArtwork)
    val artHeight = 320.dp

    var leaderboardEntries by remember { mutableStateOf<List<LeaderboardEntry>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(artist.name) {
        if (resolvedArtwork.isNullOrBlank() || !resolvedBrowseId.startsWith("UC")) {
            runCatching {
                val resolved = YtMusicRepository.resolveArtist(artist.name)
                if (resolved != null) {
                    resolvedBrowseId = resolved.first
                    if (!resolved.second.isNullOrBlank()) {
                        resolvedArtwork = resolved.second
                    }
                }
            }
        }
    }

    LaunchedEffect(artist.id) {
        isLoading = true
        SupabaseService.fetchArtistLeaderboard(artist.id)
            .onSuccess { entries ->
                leaderboardEntries = entries
            }
        isLoading = false
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .clipToBounds()
            .hazeSource(hazeState),
    ) {
        // 1. Page Background: Dynamic Artwork Wash + Hero Artist Image (Mirroring DetailScreen)
        Box(Modifier.matchParentSize()) {
            ArtworkWash(palette = palette, modifier = Modifier.matchParentSize())

            Box(
                Modifier
                    .fillMaxWidth()
                    .height(artHeight),
            ) {
                if (highResArtwork != null) {
                    AsyncImage(
                        model = highResArtwork,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .matchParentSize()
                            .background(palette.elevated),
                    )
                }

                // Solid wash container behind artist header
                Box(
                    Modifier
                        .matchParentSize()
                        .background(palette.wash),
                )
            }
        }

        // 2. Foreground Content List
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                bottom = contentPadding.calculateBottomPadding() + 80.dp,
            ),
        ) {
            // Header Space reserving room for the artwork
            item(key = "artist_header") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = artHeight - 50.dp, start = 20.dp, end = 20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    // Circular HD Artist Profile Avatar
                    Box(
                        modifier = Modifier
                            .size(96.dp)
                            .clip(CircleShape)
                            .background(palette.elevated),
                        contentAlignment = Alignment.Center,
                    ) {
                        ArtistAvatar(
                            name = artist.name,
                            artworkUrl = highResArtwork,
                            size = 96.dp,
                        )
                    }

                    Spacer(Modifier.height(14.dp))

                    Text(
                        text = artist.name,
                        style = MaterialTheme.typography.displaySmall.copy(fontWeight = FontWeight.ExtraBold),
                        color = palette.onBackground,
                        textAlign = TextAlign.Center,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )

                    Spacer(Modifier.height(6.dp))

                    Text(
                        text = "Quiz Master Hall of Fame",
                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                        color = palette.accent,
                    )

                    Spacer(Modifier.height(16.dp))

                    // Action Buttons Row: Challenge Artist + Open Discography
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ElevatedButton(
                            onClick = onChallengeArtist,
                            shape = RoundedCornerShape(16.dp),
                            colors = ButtonDefaults.elevatedButtonColors(
                                containerColor = palette.accent,
                                contentColor = if (palette.accent.luminance() > 0.5f) Color.Black else Color.White,
                            ),
                            modifier = Modifier
                                .weight(1.2f)
                                .height(46.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.PlayArrow,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "Challenge",
                                fontWeight = FontWeight.Bold,
                                fontSize = 14.sp,
                            )
                        }

                        if (onOpenArtistDetail != null) {
                            ElevatedButton(
                                onClick = { onOpenArtistDetail(resolvedBrowseId, artist.name, highResArtwork) },
                                shape = RoundedCornerShape(16.dp),
                                colors = ButtonDefaults.elevatedButtonColors(
                                    containerColor = palette.elevated,
                                    contentColor = palette.onBackground,
                                ),
                                modifier = Modifier
                                    .weight(1f)
                                    .height(46.dp),
                            ) {
                                Text(
                                    text = "Discography",
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 13.sp,
                                )
                            }
                        }
                    }
                }
            }

            item(key = "leaderboard_header") {
                Spacer(Modifier.height(20.dp))
                Text(
                    text = "Quiz Master Leaderboard",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = palette.onBackground,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 6.dp),
                )
            }

            // Top 3 Podium (if we have entries)
            if (leaderboardEntries.isNotEmpty()) {
                item(key = "podium") {
                    Spacer(Modifier.height(24.dp))
                    Top3Podium(
                        entries = leaderboardEntries.take(3),
                        paletteAccent = palette.accent,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp),
                    )
                    Spacer(Modifier.height(16.dp))
                }
            }

            // Leaderboard Entries (Ranks 4+)
            if (isLoading) {
                item(key = "loading") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(160.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(color = palette.accent, strokeWidth = 2.dp)
                    }
                }
            } else if (leaderboardEntries.isEmpty()) {
                item(key = "empty_leaderboard") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 40.dp, start = 24.dp, end = 24.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Rounded.EmojiEvents,
                                contentDescription = null,
                                tint = palette.accent,
                                modifier = Modifier.size(44.dp),
                            )
                            Spacer(Modifier.height(12.dp))
                            Text(
                                text = "No records yet for ${artist.name}",
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = palette.onBackground,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Take the quiz and be the first crowned master on the podium!",
                                style = MaterialTheme.typography.bodySmall,
                                color = palette.onBackgroundVariant,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
            } else {
                val remainingEntries = leaderboardEntries.drop(3)
                if (remainingEntries.isNotEmpty()) {
                    item(key = "rankings_title") {
                        Text(
                            text = "Rankings",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            color = palette.onBackground,
                            modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                        )
                    }

                    itemsIndexed(remainingEntries, key = { _, it -> it.id }) { index, entry ->
                        LeaderboardRow(
                            entry = entry,
                            rank = index + 4,
                            paletteAccent = palette.accent,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp, vertical = 4.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun Top3Podium(
    entries: List<LeaderboardEntry>,
    paletteAccent: Color,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        // 2nd Place (Silver)
        entries.getOrNull(1)?.let { silver ->
            PodiumPillar(
                entry = silver,
                rank = 2,
                color = Color(0xFFC0C0C0), // Silver
                height = 120.dp,
                modifier = Modifier.weight(1f),
            )
        }

        // 1st Place (Gold)
        entries.getOrNull(0)?.let { gold ->
            PodiumPillar(
                entry = gold,
                rank = 1,
                color = Color(0xFFFFD700), // Gold
                height = 150.dp,
                modifier = Modifier.weight(1.15f),
            )
        }

        // 3rd Place (Bronze)
        entries.getOrNull(2)?.let { bronze ->
            PodiumPillar(
                entry = bronze,
                rank = 3,
                color = Color(0xFFCD7F32), // Bronze
                height = 100.dp,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun PodiumPillar(
    entry: LeaderboardEntry,
    rank: Int,
    color: Color,
    height: androidx.compose.ui.unit.Dp,
    modifier: Modifier = Modifier,
) {
    val seconds = (entry.totalTimeMillis % 60000) / 1000
    val millis = (entry.totalTimeMillis % 1000)
    val timeFormatted = "%d.%02ds".format(seconds, millis / 10)

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // Avatar
        Box(
            modifier = Modifier
                .size(if (rank == 1) 58.dp else 48.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            if (entry.userAvatar != null) {
                AsyncImage(
                    model = entry.userAvatar,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Icon(
                    imageVector = Icons.Rounded.Person,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(24.dp),
                )
            }
        }

        Spacer(Modifier.height(6.dp))

        Text(
            text = entry.userName,
            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        Text(
            text = "${entry.score}/10 in $timeFormatted",
            style = MaterialTheme.typography.labelSmall,
            color = color,
            fontWeight = FontWeight.Bold,
        )

        Spacer(Modifier.height(6.dp))

        // Pedestal (Solid color, no gradient, no border)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(height)
                .clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
                .background(color),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = when (rank) {
                    1 -> Icons.Rounded.EmojiEvents
                    2 -> Icons.Rounded.WorkspacePremium
                    else -> Icons.Rounded.MilitaryTech
                },
                contentDescription = "Rank #$rank",
                tint = Color.White,
                modifier = Modifier.size(32.dp),
            )
        }
    }
}

@Composable
private fun LeaderboardRow(
    entry: LeaderboardEntry,
    rank: Int,
    paletteAccent: Color,
    modifier: Modifier = Modifier,
) {
    val seconds = (entry.totalTimeMillis % 60000) / 1000
    val millis = (entry.totalTimeMillis % 1000)
    val timeFormatted = "%d.%02ds".format(seconds, millis / 10)

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                text = "#$rank",
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.ExtraBold),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.width(36.dp),
            )

            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant),
            ) {
                if (entry.userAvatar != null) {
                    AsyncImage(
                        model = entry.userAvatar,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            Spacer(Modifier.width(12.dp))

            Column(Modifier.weight(1f)) {
                Text(
                    text = entry.userName,
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = formatHandle(entry.userHandle),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Column(horizontalAlignment = Alignment.End) {
                Text(
                    text = "${entry.score}/10",
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Black),
                    color = paletteAccent,
                )
                Text(
                    text = timeFormatted,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
