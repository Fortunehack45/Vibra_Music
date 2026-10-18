package com.fortune.vibramusic.ui.quiz

import android.content.Intent
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.EmojiEvents
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Share
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.artworkAt
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.quiz.LeaderboardEntry
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.ui.components.ArtistAvatar
import com.fortune.vibramusic.ui.components.ArtworkWash
import com.fortune.vibramusic.ui.theme.rememberArtworkPalette
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass
import com.fortune.vibramusic.ui.components.liquidGlassButton
import com.fortune.vibramusic.ui.components.glassContentColor
import com.fortune.vibramusic.ui.haptics.Haptic

fun formatLeaderboardTime(totalTimeMillis: Long): String {
    val minutes = (totalTimeMillis / 60000)
    val seconds = (totalTimeMillis % 60000) / 1000
    val millis = (totalTimeMillis % 1000)
    return "%02d:%02d.%03d".format(minutes, seconds, millis)
}

@Composable
fun ArtistLeaderboardScreen(
    artist: QuizArtist,
    onBack: () -> Unit,
    onChallengeArtist: () -> Unit,
    onOpenArtistDetail: ((id: String, name: String, artworkUrl: String?) -> Unit)? = null,
    onPlaySong: ((Song) -> Unit)? = null,
    onOpenProfile: ((SocialProfile) -> Unit)? = null,
    contentPadding: PaddingValues,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    var resolvedArtwork by remember(artist.name) { mutableStateOf(artist.artworkUrl) }
    var resolvedBrowseId by remember(artist.id) { mutableStateOf(artist.id) }

    val context = LocalContext.current
    val listState = rememberLazyListState()
    val highResArtwork = (resolvedArtwork ?: artist.artworkUrl)?.artworkAt(1080) ?: (resolvedArtwork ?: artist.artworkUrl)
    val palette = rememberArtworkPalette(highResArtwork)
    val artHeight = 220.dp

    var leaderboardEntries by remember { mutableStateOf<List<LeaderboardEntry>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(artist.name, artist.id) {
        if (resolvedArtwork.isNullOrBlank() || !resolvedBrowseId.startsWith("UC")) {
            runCatching {
                val thumb = YtMusicRepository.getArtistThumbnail(artist.id, artist.name)
                if (!thumb.isNullOrBlank()) {
                    resolvedArtwork = thumb
                } else {
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
    }

    LaunchedEffect(artist.id) {
        isLoading = true
        SupabaseService.fetchArtistLeaderboard(artist.id)
            .onSuccess { entries ->
                leaderboardEntries = entries
            }
        isLoading = false
    }

    val bestEntry = leaderboardEntries.firstOrNull()
    val topPercentile = if (leaderboardEntries.isNotEmpty()) "Top ${(100.0 / leaderboardEntries.size.coerceAtLeast(1)).toInt().coerceIn(1, 100)}%" else "Top Fan"

    Box(
        modifier = modifier
            .fillMaxSize()
            .clipToBounds()
            .hazeSource(hazeState),
    ) {
        // 1. Page Background: Dynamic Artwork Wash + Hero Artist Image
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

                Box(
                    Modifier
                        .matchParentSize()
                        .background(
                            Brush.verticalGradient(
                                0.35f to Color.Transparent,
                                0.55f to palette.wash.copy(alpha = 0.25f),
                                0.75f to palette.wash.copy(alpha = 0.65f),
                                0.90f to palette.wash.copy(alpha = 0.90f),
                                1.00f to palette.wash,
                            ),
                        ),
                )
            }
        }

        // 2. Foreground Content List
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                bottom = contentPadding.calculateBottomPadding() + 90.dp,
            ),
        ) {
            // Header: Top Bar with Back, "Leaderboard", Share
            item(key = "nav_top_bar") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .liquidGlassButton(
                                onClick = onBack,
                                haptic = Haptic.Tap,
                                expandScale = 1.14f,
                                pressScale = 0.91f,
                            )
                            .lightweightLiquidGlass(
                                shape = CircleShape,
                                fallbackColor = MaterialTheme.colorScheme.surfaceVariant,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                            contentDescription = "Back",
                            tint = glassContentColor(),
                            modifier = Modifier.size(20.dp),
                        )
                    }

                    Box(
                        modifier = Modifier
                            .height(38.dp)
                            .lightweightLiquidGlass(
                                shape = RoundedCornerShape(19.dp),
                                fallbackColor = MaterialTheme.colorScheme.surfaceVariant,
                            )
                            .padding(horizontal = 16.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "Leaderboard",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            color = glassContentColor(),
                        )
                    }

                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .liquidGlassButton(
                                onClick = {
                                    val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                        putExtra(
                                            Intent.EXTRA_TEXT,
                                            "Check out the Quiz Leaderboard for ${artist.name} on Vibra Music!\nCan you beat the record?",
                                        )
                                        type = "text/plain"
                                    }
                                    context.startActivity(Intent.createChooser(sendIntent, "Share Leaderboard"))
                                },
                                haptic = Haptic.Tap,
                                expandScale = 1.14f,
                                pressScale = 0.91f,
                            )
                            .lightweightLiquidGlass(
                                shape = CircleShape,
                                fallbackColor = MaterialTheme.colorScheme.surfaceVariant,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Share,
                            contentDescription = "Share",
                            tint = glassContentColor(),
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }

            // Artist Centerpiece: Large Circular Avatar + "Top Fan of [Artist]"
            item(key = "artist_header") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 10.dp, start = 20.dp, end = 20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    // Centered Circular Avatar
                    Box(
                        modifier = Modifier
                            .size(92.dp)
                            .clip(CircleShape)
                            .background(palette.elevated)
                            .clickable {
                                onOpenArtistDetail?.invoke(resolvedBrowseId, artist.name, highResArtwork)
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        ArtistAvatar(
                            name = artist.name,
                            artworkUrl = highResArtwork,
                            size = 92.dp,
                        )
                    }

                    Spacer(Modifier.height(12.dp))

                    Text(
                        text = "Top Fan of ${artist.name}",
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.ExtraBold),
                        color = palette.onBackground,
                        textAlign = TextAlign.Center,
                    )

                    Spacer(Modifier.height(16.dp))

                    // 3-Metric Summary Record Card (Matching Screenshot 1)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(18.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(horizontal = 14.dp, vertical = 14.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            // Column 1: Your best record
                            Column(
                                modifier = Modifier.weight(1.3f),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(
                                    text = "Your best record",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    text = if (bestEntry != null) {
                                        "${formatLeaderboardTime(bestEntry.totalTimeMillis)} (${bestEntry.score}/10)"
                                    } else "--",
                                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }

                            // Column 2: Global ranking
                            Column(
                                modifier = Modifier.weight(1f),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(
                                    text = "Global rank",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    text = topPercentile,
                                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                    color = palette.accent,
                                )
                            }

                            // Column 3: NO. ranking
                            Column(
                                modifier = Modifier.weight(0.9f),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(
                                    text = "NO. ranking",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    text = if (bestEntry != null) "No. 1" else "--",
                                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(20.dp))
                }
            }

            // Table Column Headers: Fans | Score | Time (Matching Screenshot 1)
            item(key = "table_header") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 30.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Fans",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = "Score",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.width(60.dp),
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text = "Time",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.width(90.dp),
                        textAlign = TextAlign.End,
                    )
                }
            }

            // Leaderboard Entries
            if (isLoading) {
                item(key = "loading") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(140.dp),
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
                            .padding(top = 30.dp, start = 24.dp, end = 24.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Rounded.EmojiEvents,
                                contentDescription = null,
                                tint = palette.accent,
                                modifier = Modifier.size(44.dp),
                            )
                            Spacer(Modifier.height(10.dp))
                            Text(
                                text = "No records yet for ${artist.name}",
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = palette.onBackground,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Be the first to challenge the quiz and top the hall of fame!",
                                style = MaterialTheme.typography.bodySmall,
                                color = palette.onBackgroundVariant,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
            } else {
                itemsIndexed(leaderboardEntries, key = { _, it -> it.id }) { index, entry ->
                    LeaderboardTableRow(
                        entry = entry,
                        rank = index + 1,
                        paletteAccent = palette.accent,
                        onClick = {
                            onOpenProfile?.invoke(
                                SocialProfile(
                                    id = entry.userId,
                                    handle = entry.userHandle,
                                    displayName = entry.userName,
                                    avatarUrl = entry.userAvatar,
                                )
                            )
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                }
            }
        }

        // 3. Sticky Bottom Action Card (Play again + Share buttons, matching Screenshot 1)
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(
                    start = 16.dp,
                    end = 16.dp,
                    bottom = contentPadding.calculateBottomPadding() + 10.dp,
                )
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Play Again / Challenge button
                ElevatedButton(
                    onClick = onChallengeArtist,
                    shape = RoundedCornerShape(14.dp),
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
                        text = "Play again",
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp,
                    )
                }

                // Share button
                ElevatedButton(
                    onClick = {
                        val sendIntent = Intent(Intent.ACTION_SEND).apply {
                            putExtra(
                                Intent.EXTRA_TEXT,
                                "I scored on the ${artist.name} quiz on Vibra Music!\nTake the challenge now!",
                            )
                            type = "text/plain"
                        }
                        context.startActivity(Intent.createChooser(sendIntent, "Share Leaderboard"))
                    },
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.elevatedButtonColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant,
                        contentColor = MaterialTheme.colorScheme.onSurface,
                    ),
                    modifier = Modifier
                        .weight(1f)
                        .height(46.dp),
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Share,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = "Share",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                    )
                }
            }
        }
    }
}

@Composable
private fun LeaderboardTableRow(
    entry: LeaderboardEntry,
    rank: Int,
    paletteAccent: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val timeFormatted = formatLeaderboardTime(entry.totalTimeMillis)

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            // Rank Number or Badge
            Box(
                modifier = Modifier.width(32.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                when (rank) {
                    1 -> Box(
                        modifier = Modifier
                            .size(24.dp)
                            .clip(CircleShape)
                            .background(Color(0xFFFFD700)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "1",
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.ExtraBold),
                            color = Color.Black,
                        )
                    }
                    2 -> Box(
                        modifier = Modifier
                            .size(24.dp)
                            .clip(CircleShape)
                            .background(Color(0xFFC0C0C0)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "2",
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.ExtraBold),
                            color = Color.Black,
                        )
                    }
                    3 -> Box(
                        modifier = Modifier
                            .size(24.dp)
                            .clip(CircleShape)
                            .background(Color(0xFFCD7F32)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "3",
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.ExtraBold),
                            color = Color.White,
                        )
                    }
                    else -> Text(
                        text = "$rank",
                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.width(8.dp))

            // User Avatar
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surface),
                contentAlignment = Alignment.Center,
            ) {
                if (!entry.userAvatar.isNullOrBlank() && entry.userAvatar != "null") {
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
                        modifier = Modifier.size(22.dp),
                    )
                }
            }

            Spacer(Modifier.width(10.dp))

            // Username and Handle
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
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            // Score
            Text(
                text = "${entry.score}/10",
                style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Black),
                color = paletteAccent,
                modifier = Modifier.width(60.dp),
                textAlign = TextAlign.Center,
            )

            // Time
            Text(
                text = timeFormatted,
                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.width(90.dp),
                textAlign = TextAlign.End,
            )
        }
    }
}
