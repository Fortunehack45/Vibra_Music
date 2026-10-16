package com.fortune.vibramusic.ui.quiz

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Leaderboard
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.ui.components.ArtistAvatar
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Premium Liquid-Glass Music Quiz Hub.
 * Features glowing vinyl artist cards, real-time artist thumbnail auto-resolution,
 * frosted lives pills, and elegant step cards.
 */
@Composable
fun QuizHubScreen(
    viewModel: QuizViewModel,
    onArtistSelect: (QuizArtist) -> Unit,
    onViewArtistLeaderboard: (QuizArtist) -> Unit,
    contentPadding: PaddingValues,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val livesState by viewModel.livesState.collectAsStateWithLifecycle()
    val isPreparingQuiz by viewModel.isPreparingQuiz.collectAsStateWithLifecycle()
    var showLivesDialog by remember { mutableStateOf(false) }

    var searchQuery by remember { mutableStateOf("") }
    var searchResults by remember { mutableStateOf<List<QuizArtist>>(emptyList()) }
    var isSearching by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // Default Popular / Trending Quiz Artists with automatic thumbnail resolution
    val trendingArtists = remember {
        mutableStateListOf(
            QuizArtist("UC0C-w0YjGpqDXGB8Tr0GGyA", "Drake", null),
            QuizArtist("UCqECaJ8Gagnn7YCbPEzWH6g", "Taylor Swift", "https://yt3.googleusercontent.com/ZpWD37EEQE_LVuQ_O03cRmz5mZA7jG0gKGLt-49uHNDX6DycysijGGSOX9woU-OfQR5jyahz3aEdmBmm3A=w540-h540-l90-rj"),
            QuizArtist("UCOmHUn--16B90oW2L6FRR3A", "Burna Boy", "https://yt3.googleusercontent.com/9h5EMc3LktccxFy-3bznozFCwYSU1YnU0agJZssvGqDj3UDrtFC7FgPHjDrtUG3dGAP45uEPBxDYLBg=w540-h540-l90-rj"),
            QuizArtist("UC0WP5P-ufpRfjbNrmOWwLBQ", "The Weeknd", "https://yt3.googleusercontent.com/mxqDOrw4zbfDBdd4kOnD2qBUtMklnAucEfrQUbr30pRLie0P3JIhJhBJ9wJq3NEeg2yVrT9lgrYid-w=w540-h540-l90-rj"),
            QuizArtist("UCiGm_E4DwYcU-gEyZv29eJA", "Billie Eilish", null),
            QuizArtist("UCCgsKDzkjI6kHjG22r7Lq2w", "Kendrick Lamar", null),
        )
    }

    // Auto-resolve any missing artist thumbnails in the background
    LaunchedEffect(Unit) {
        trendingArtists.forEachIndexed { index, artist ->
            if (artist.artworkUrl.isNullOrBlank()) {
                launch {
                    val thumb = YtMusicRepository.getArtistThumbnail(artist.id, artist.name)
                    if (!thumb.isNullOrBlank() && index < trendingArtists.size) {
                        trendingArtists[index] = trendingArtists[index].copy(artworkUrl = thumb)
                    }
                }
            }
        }
    }

    LaunchedEffect(searchQuery) {
        val query = searchQuery.trim()
        if (query.length >= 2) {
            isSearching = true
            scope.launch {
                runCatching {
                    val searchItems = withContext(Dispatchers.IO) {
                        YtMusicRepository.search(query, SearchFilter.ARTISTS).getOrNull().orEmpty()
                    }
                    val artists = searchItems.mapNotNull { result ->
                        when (result) {
                            is SearchResult.Browse -> QuizArtist(
                                id = result.item.browseId,
                                name = result.item.title,
                                avatarUrl = result.item.thumbnailUrl,
                            )
                            else -> null
                        }
                    }
                    searchResults = artists
                }.onFailure {
                    searchResults = emptyList()
                }
                isSearching = false
            }
        } else {
            searchResults = emptyList()
            isSearching = false
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .hazeSource(hazeState),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                top = contentPadding.calculateTopPadding() + 8.dp,
                bottom = contentPadding.calculateBottomPadding() + 80.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            // Header Bar with Lives Indicator
            item(key = "hub_header") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column {
                        Text(
                            text = "Music Quiz",
                            style = MaterialTheme.typography.titleLarge.copy(
                                fontWeight = FontWeight.ExtraBold,
                                letterSpacing = (-0.5).sp,
                            ),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            text = "Do You Know The Song?",
                            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                        )
                    }

                    // Lives Pill (Liquid Glass)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(percent = 50))
                            .background(
                                Brush.verticalGradient(
                                    listOf(
                                        Color.White.copy(alpha = 0.12f),
                                        Color.White.copy(alpha = 0.04f),
                                    )
                                )
                            )
                            .border(
                                width = 1.dp,
                                brush = Brush.verticalGradient(
                                    listOf(
                                        Color.White.copy(alpha = 0.30f),
                                        Color.White.copy(alpha = 0.08f),
                                    )
                                ),
                                shape = RoundedCornerShape(percent = 50),
                            )
                            .clickable { showLivesDialog = true }
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Favorite,
                            contentDescription = "Lives",
                            tint = Color(0xFFFF453A),
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "${livesState.livesRemaining} / ${livesState.maxLives}",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }

            // Search Bar (Search Any Artist in the world)
            item(key = "search_bar") {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp)
                        .clip(RoundedCornerShape(22.dp))
                        .background(
                            Brush.verticalGradient(
                                listOf(
                                    Color.White.copy(alpha = 0.08f),
                                    Color.White.copy(alpha = 0.03f),
                                )
                            )
                        )
                        .border(
                            1.dp,
                            Brush.verticalGradient(
                                listOf(
                                    Color.White.copy(alpha = 0.18f),
                                    Color.White.copy(alpha = 0.04f),
                                )
                            ),
                            RoundedCornerShape(22.dp),
                        )
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = Icons.Rounded.Search,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        Box(Modifier.weight(1f)) {
                            if (searchQuery.isEmpty()) {
                                Text(
                                    text = "Search any artist in the world...",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                )
                            }
                            BasicTextField(
                                value = searchQuery,
                                onValueChange = { searchQuery = it },
                                textStyle = TextStyle(
                                    color = MaterialTheme.colorScheme.onSurface,
                                    fontSize = 15.sp,
                                ),
                                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        if (searchQuery.isNotEmpty()) {
                            IconButton(onClick = { searchQuery = "" }, modifier = Modifier.size(24.dp)) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Clear",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        }
                    }
                }
            }

            // Search Results Section
            if (searchQuery.isNotEmpty()) {
                if (isSearching) {
                    item(key = "searching_indicator") {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(120.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator(
                                color = MaterialTheme.colorScheme.primary,
                                strokeWidth = 2.5.dp,
                            )
                        }
                    }
                } else if (searchResults.isNotEmpty()) {
                    item(key = "search_results_header") {
                        Text(
                            text = "Search Results",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.padding(horizontal = 20.dp),
                        )
                    }
                    items(searchResults, key = { it.id }) { artist ->
                        ArtistQuizRow(
                            artist = artist,
                            onPlay = {
                                viewModel.startQuizForArtist(
                                    artist = artist,
                                    onInsufficientLives = { showLivesDialog = true },
                                )
                            },
                            onLeaderboard = { onViewArtistLeaderboard(artist) },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp),
                        )
                    }
                }
            } else {
                // Trending Challenges Section
                item(key = "trending_artists_title") {
                    Text(
                        text = "Trending Challenges",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                }

                item(key = "trending_artists_row") {
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 20.dp),
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        items(trendingArtists, key = { it.id }) { artist ->
                            TrendingArtistCard(
                                artist = artist,
                                onPlay = {
                                    viewModel.startQuizForArtist(
                                        artist = artist,
                                        onInsufficientLives = { showLivesDialog = true },
                                    )
                                },
                                onLeaderboard = { onViewArtistLeaderboard(artist) },
                            )
                        }
                    }
                }

                // How to Play Banner (Liquid Glass Step Cards)
                item(key = "how_to_play") {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp)
                            .clip(RoundedCornerShape(22.dp))
                            .background(
                                Brush.verticalGradient(
                                    listOf(
                                        Color.White.copy(alpha = 0.06f),
                                        Color.White.copy(alpha = 0.02f),
                                    )
                                )
                            )
                            .border(
                                1.dp,
                                Brush.verticalGradient(
                                    listOf(
                                        Color.White.copy(alpha = 0.18f),
                                        Color.White.copy(alpha = 0.04f),
                                    )
                                ),
                                RoundedCornerShape(22.dp),
                            )
                            .padding(18.dp),
                    ) {
                        Text(
                            text = "HOW TO PLAY",
                            style = MaterialTheme.typography.labelMedium.copy(
                                fontWeight = FontWeight.ExtraBold,
                                letterSpacing = 1.sp,
                            ),
                            color = MaterialTheme.colorScheme.primary,
                        )

                        Spacer(Modifier.height(14.dp))

                        QuizStepRow(
                            stepNumber = "1",
                            title = "Select Any Artist",
                            description = "Choose from trending icons or search any artist in the world.",
                        )

                        Spacer(Modifier.height(12.dp))

                        QuizStepRow(
                            stepNumber = "2",
                            title = "Hear Mystery Snippets",
                            description = "15-second mystery audio snippets play instantly with 0ms delay.",
                        )

                        Spacer(Modifier.height(12.dp))

                        QuizStepRow(
                            stepNumber = "3",
                            title = "Climb The Leaderboard",
                            description = "Answer all 10 questions fast to claim the top global rank.",
                        )
                    }
                }
            }
        }

        // Preparing Quiz Overlay
        if (isPreparingQuiz) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.72f)),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(
                        color = MaterialTheme.colorScheme.primary,
                        strokeWidth = 3.dp,
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = "Preparing 10 Questions...",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                    )
                }
            }
        }
    }

    // Lives Dialog
    if (showLivesDialog) {
        QuizLivesDialog(
            livesState = livesState,
            referralCode = "vibra_quiz",
            onDismiss = { showLivesDialog = false },
        )
    }
}

@Composable
private fun TrendingArtistCard(
    artist: QuizArtist,
    onPlay: () -> Unit,
    onLeaderboard: () -> Unit,
) {
    Box(
        modifier = Modifier
            .width(168.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(
                Brush.verticalGradient(
                    listOf(
                        Color.White.copy(alpha = 0.09f),
                        Color.White.copy(alpha = 0.02f),
                    )
                )
            )
            .border(
                1.dp,
                Brush.verticalGradient(
                    listOf(
                        Color.White.copy(alpha = 0.28f),
                        Color.White.copy(alpha = 0.06f),
                    )
                ),
                RoundedCornerShape(24.dp),
            )
            .padding(14.dp),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.fillMaxWidth(),
        ) {
            // Vinyl Record Ring Motif framing the artist portrait
            Box(
                modifier = Modifier
                    .size(92.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.45f))
                    .border(2.dp, Color.White.copy(alpha = 0.14f), CircleShape)
                    .padding(4.dp),
                contentAlignment = Alignment.Center,
            ) {
                ArtistAvatar(
                    artistName = artist.name,
                    artworkUrl = artist.artworkUrl,
                    size = 84.dp,
                )
            }

            Spacer(Modifier.height(10.dp))

            Text(
                text = artist.name,
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )

            Text(
                text = "10 Audio Snippets",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                maxLines = 1,
            )

            Spacer(Modifier.height(12.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Play Button
                Row(
                    modifier = Modifier
                        .weight(1f)
                        .height(36.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.primary)
                        .clickable(onClick = onPlay),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                ) {
                    Icon(
                        imageVector = Icons.Rounded.PlayArrow,
                        contentDescription = "Play",
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = "Play",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                }

                // Leaderboard Button
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.White.copy(alpha = 0.08f))
                        .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                        .clickable(onClick = onLeaderboard),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Leaderboard,
                        contentDescription = "Leaderboard",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun QuizStepRow(
    stepNumber: String,
    title: String,
    description: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.18f))
                .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.4f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = stepNumber,
                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.primary,
            )
        }

        Spacer(Modifier.width(12.dp))

        Column(Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f),
                lineHeight = 16.sp,
            )
        }
    }
}

@Composable
private fun ArtistQuizRow(
    artist: QuizArtist,
    onPlay: () -> Unit,
    onLeaderboard: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(18.dp))
            .background(
                Brush.verticalGradient(
                    listOf(
                        Color.White.copy(alpha = 0.08f),
                        Color.White.copy(alpha = 0.02f),
                    )
                )
            )
            .border(
                1.dp,
                Brush.verticalGradient(
                    listOf(
                        Color.White.copy(alpha = 0.18f),
                        Color.White.copy(alpha = 0.04f),
                    )
                ),
                RoundedCornerShape(18.dp),
            )
            .padding(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            ArtistAvatar(
                artistName = artist.name,
                artworkUrl = artist.artworkUrl,
                size = 48.dp,
            )

            Spacer(Modifier.width(14.dp))

            Column(Modifier.weight(1f)) {
                Text(
                    text = artist.name,
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = "10 Audio Snippets Challenge",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f),
                )
            }

            IconButton(onClick = onLeaderboard) {
                Icon(
                    imageVector = Icons.Rounded.Leaderboard,
                    contentDescription = "Leaderboard",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }

            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary)
                    .clickable(onClick = onPlay),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Rounded.PlayArrow,
                    contentDescription = "Play",
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}
