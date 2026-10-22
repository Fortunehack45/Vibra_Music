package com.fortune.vibramusic.ui.social

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ElevatedButton
import androidx.compose.material3.Icon
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.social.FavoriteArtist
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass
import com.fortune.vibramusic.ui.components.liquidGlassButton
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.theme.VibraPurple
import dev.chrisbanes.haze.HazeState
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

data class MusicMatchCandidate(
    val profile: SocialProfile,
    val similarityPercent: Int,
    val sharedArtists: List<FavoriteArtist>,
    val satelliteArtists: List<FavoriteArtist>,
)

enum class TwinViewMode {
    RADAR,
    TOP_LIST,
}

@Composable
fun FriendsDiscoveryScreen(
    currentProfile: SocialProfile?,
    suggestedProfiles: List<SocialProfile>,
    onBack: (() -> Unit)? = null,
    onSendFriendRequest: (SocialProfile) -> Unit,
    onOpenProfile: (SocialProfile) -> Unit,
    onRefreshSuggestions: () -> Unit,
    hazeState: HazeState,
    contentPadding: PaddingValues = PaddingValues(),
    modifier: Modifier = Modifier,
) {
    val coroutineScope = rememberCoroutineScope()
    var viewMode by remember { mutableStateOf(TwinViewMode.RADAR) }
    val myFavoriteArtistNames = remember(currentProfile) {
        currentProfile?.favoriteArtists?.map { it.name.trim().lowercase() }?.toSet().orEmpty()
    }

    // Build match candidates with dynamic similarity %
    val candidatesList = remember(suggestedProfiles, currentProfile) {
        suggestedProfiles
            .filter { it.id != currentProfile?.id }
            .map { candidate ->
                val candArtists = candidate.favoriteArtists
                val shared = candArtists.filter { myFavoriteArtistNames.contains(it.name.trim().lowercase()) }
                val score = if (myFavoriteArtistNames.isEmpty() || candArtists.isEmpty()) {
                    (45..85).random() // baseline music affinity
                } else {
                    val ratio = (shared.size.toFloat() / candArtists.size.coerceAtLeast(1).toFloat())
                    (ratio * 65f + 30f).toInt().coerceIn(35, 99)
                }
                MusicMatchCandidate(
                    profile = candidate,
                    similarityPercent = score,
                    sharedArtists = shared,
                    satelliteArtists = candArtists.take(5),
                )
            }
            .sortedByDescending { it.similarityPercent }
    }

    val activeDeck = remember { mutableStateListOf<MusicMatchCandidate>() }
    val historyStack = remember { mutableStateListOf<MusicMatchCandidate>() }

    LaunchedEffect(candidatesList) {
        activeDeck.clear()
        activeDeck.addAll(candidatesList)
        historyStack.clear()
    }

    val topCandidate = activeDeck.firstOrNull()

    val topPadding = if (onBack != null) 0.dp else contentPadding.calculateTopPadding()
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color(0xFF090A0F))
            .then(if (onBack != null) Modifier.statusBarsPadding() else Modifier),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = topPadding),
        ) {
            // Clean Top Bar matching reference: Search, Filter toggle, Refresh, User profile
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (onBack != null) {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .lightweightLiquidGlass(
                                    shape = CircleShape,
                                    fallbackColor = Color(0xCC1A1C28),
                                )
                                .border(1.dp, Color.White.copy(alpha = 0.20f), CircleShape)
                                .liquidGlassButton(
                                    onClick = onBack,
                                    haptic = Haptic.Tap,
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                                contentDescription = "Back",
                                tint = Color.White,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    } else {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .lightweightLiquidGlass(
                                    shape = CircleShape,
                                    fallbackColor = Color(0xCC1A1C28),
                                )
                                .border(1.dp, Color.White.copy(alpha = 0.20f), CircleShape)
                                .liquidGlassButton(
                                    onClick = { onRefreshSuggestions() },
                                    haptic = Haptic.Tap,
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Search,
                                contentDescription = "Search",
                                tint = Color.White.copy(alpha = 0.85f),
                                modifier = Modifier.size(19.dp),
                            )
                        }
                    }

                    // Mode Switch / Filter icon
                    Box(
                        modifier = Modifier
                            .size(40.dp)
                            .clip(CircleShape)
                            .lightweightLiquidGlass(
                                shape = CircleShape,
                                fallbackColor = if (viewMode == TwinViewMode.TOP_LIST) VibraPurple.copy(alpha = 0.35f) else Color(0xCC1A1C28),
                            )
                            .border(
                                1.dp,
                                if (viewMode == TwinViewMode.TOP_LIST) VibraPurple else Color.White.copy(alpha = 0.20f),
                                CircleShape,
                            )
                            .liquidGlassButton(
                                onClick = {
                                    viewMode = if (viewMode == TwinViewMode.RADAR) TwinViewMode.TOP_LIST else TwinViewMode.RADAR
                                },
                                haptic = Haptic.Tap,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Tune,
                            contentDescription = "Toggle Grid",
                            tint = if (viewMode == TwinViewMode.TOP_LIST) VibraPurple else Color.White.copy(alpha = 0.85f),
                            modifier = Modifier.size(19.dp),
                        )
                    }
                }

                // Center Title / Badge
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(
                        imageVector = Icons.Rounded.GraphicEq,
                        contentDescription = null,
                        tint = VibraPurple,
                        modifier = Modifier.size(17.dp),
                    )
                    Text(
                        text = if (viewMode == TwinViewMode.RADAR) "Music Soulmate" else "Top Matches",
                        style = MaterialTheme.typography.titleMedium.copy(
                            fontWeight = FontWeight.ExtraBold,
                            letterSpacing = (-0.3).sp,
                        ),
                        color = Color.White,
                    )
                }

                // Right Profile Avatar / Quick Action
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF222436))
                        .border(1.5.dp, VibraPurple.copy(alpha = 0.60f), CircleShape)
                        .clickable {
                            if (currentProfile != null) onOpenProfile(currentProfile)
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    if (currentProfile != null && !currentProfile.avatarUrl.isNullOrBlank() && currentProfile.avatarUrl != "null") {
                        AsyncImage(
                            model = currentProfile.avatarUrl,
                            contentDescription = currentProfile.displayName,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Rounded.Person,
                            contentDescription = null,
                            tint = Color.White.copy(alpha = 0.85f),
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }

            // Body Content
            if (viewMode == TwinViewMode.RADAR) {
                // Full Screen Hero Card Deck
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .padding(
                            start = 12.dp,
                            end = 12.dp,
                            top = 4.dp,
                            bottom = contentPadding.calculateBottomPadding() + 8.dp,
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    if (topCandidate != null) {
                        // Background stack card for 3D depth
                        if (activeDeck.size > 1) {
                            val nextCandidate = activeDeck[1]
                            MusicSoulmateCard(
                                candidate = nextCandidate,
                                isTopCard = false,
                                canRewind = historyStack.isNotEmpty(),
                                onSkip = {},
                                onAddFriend = {},
                                onRewind = null,
                                onOpenProfile = {},
                                modifier = Modifier
                                    .fillMaxSize()
                                    .graphicsLayer {
                                        scaleX = 0.94f
                                        scaleY = 0.94f
                                        translationY = 16.dp.toPx()
                                        alpha = 0.50f
                                    },
                            )
                        }

                        // Top Active Card
                        MusicSoulmateCard(
                            candidate = topCandidate,
                            isTopCard = true,
                            canRewind = historyStack.isNotEmpty(),
                            onSkip = {
                                historyStack.add(topCandidate)
                                activeDeck.removeFirstOrNull()
                            },
                            onAddFriend = {
                                onSendFriendRequest(topCandidate.profile)
                                historyStack.add(topCandidate)
                                activeDeck.removeFirstOrNull()
                            },
                            onRewind = {
                                if (historyStack.isNotEmpty()) {
                                    val last = historyStack.removeLast()
                                    activeDeck.add(0, last)
                                }
                            },
                            onOpenProfile = { onOpenProfile(topCandidate.profile) },
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        // Empty state when all candidates have been viewed
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .clip(RoundedCornerShape(30.dp))
                                .lightweightLiquidGlass(
                                    shape = RoundedCornerShape(30.dp),
                                    fallbackColor = Color(0xEE12141F),
                                )
                                .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(30.dp))
                                .padding(24.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(16.dp),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(76.dp)
                                        .clip(CircleShape)
                                        .background(Color(0xFF1E202E))
                                        .border(1.dp, VibraPurple.copy(alpha = 0.4f), CircleShape),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.AutoAwesome,
                                        contentDescription = null,
                                        tint = VibraPurple,
                                        modifier = Modifier.size(36.dp),
                                    )
                                }
                                Text(
                                    text = "All Soulmates Explored",
                                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.ExtraBold),
                                    color = Color.White,
                                )
                                Text(
                                    text = "You have explored all nearby listeners! Tap refresh to scan for newly joined music twins or rewind to revisit previous profiles.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = Color.White.copy(alpha = 0.65f),
                                    textAlign = TextAlign.Center,
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                )

                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    if (historyStack.isNotEmpty()) {
                                        ElevatedButton(
                                            onClick = {
                                                val last = historyStack.removeLast()
                                                activeDeck.add(0, last)
                                            },
                                            shape = RoundedCornerShape(18.dp),
                                            colors = ButtonDefaults.elevatedButtonColors(
                                                containerColor = Color(0xFF262838),
                                                contentColor = Color.White,
                                            ),
                                        ) {
                                            Icon(
                                                imageVector = Icons.AutoMirrored.Rounded.Undo,
                                                contentDescription = null,
                                                modifier = Modifier.size(16.dp),
                                            )
                                            Spacer(Modifier.width(6.dp))
                                            Text("Rewind")
                                        }
                                    }

                                    ElevatedButton(
                                        onClick = {
                                            activeDeck.clear()
                                            activeDeck.addAll(candidatesList)
                                            onRefreshSuggestions()
                                        },
                                        shape = RoundedCornerShape(18.dp),
                                        colors = ButtonDefaults.elevatedButtonColors(
                                            containerColor = VibraPurple,
                                            contentColor = Color.White,
                                        ),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Rounded.Refresh,
                                            contentDescription = null,
                                            modifier = Modifier.size(16.dp),
                                        )
                                        Spacer(Modifier.width(6.dp))
                                        Text("Scan Again")
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                // Top Twins List Mode
                LazyColumn(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    contentPadding = PaddingValues(
                        top = 10.dp,
                        bottom = contentPadding.calculateBottomPadding() + 24.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(candidatesList) { candidate ->
                        DiscoveryFriendCard(
                            profile = candidate.profile,
                            similarityScore = candidate.similarityPercent,
                            sharedArtists = candidate.sharedArtists,
                            onSendFriendRequest = { onSendFriendRequest(candidate.profile) },
                            onOpenProfile = { onOpenProfile(candidate.profile) },
                        )
                    }
                }
            }
        }
    }
}

/**
 * Full-Screen Music Soulmate Hero Card matching the reference aesthetic.
 * Features:
 * - Full-height liquid glass card
 * - Display name, verified checkmark, age & location
 * - Large central avatar + 5 orbital satellite artist badges
 * - Similarity percentage metric
 * - Artist pills + functional Rewind button
 * - Side-by-side Add Friend and Skip action buttons
 */
@Composable
private fun MusicSoulmateCard(
    candidate: MusicMatchCandidate,
    isTopCard: Boolean,
    canRewind: Boolean,
    onSkip: () -> Unit,
    onAddFriend: () -> Unit,
    onRewind: (() -> Unit)? = null,
    onOpenProfile: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val coroutineScope = rememberCoroutineScope()
    val offsetX = remember { Animatable(0f) }
    val profile = candidate.profile

    val cardDragModifier = if (isTopCard) {
        Modifier.pointerInput(candidate.profile.id) {
            detectDragGestures(
                onDragEnd = {
                    if (offsetX.value > 300f) {
                        coroutineScope.launch {
                            offsetX.animateTo(1000f, spring(stiffness = Spring.StiffnessMedium))
                            onAddFriend()
                        }
                    } else if (offsetX.value < -300f) {
                        coroutineScope.launch {
                            offsetX.animateTo(-1000f, spring(stiffness = Spring.StiffnessMedium))
                            onSkip()
                        }
                    } else {
                        coroutineScope.launch {
                            offsetX.animateTo(0f, spring(dampingRatio = Spring.DampingRatioMediumBouncy))
                        }
                    }
                },
                onDragCancel = {
                    coroutineScope.launch {
                        offsetX.animateTo(0f, spring())
                    }
                },
                onDrag = { change, dragAmount ->
                    change.consume()
                    coroutineScope.launch {
                        offsetX.snapTo(offsetX.value + dragAmount.x)
                    }
                },
            )
        }
    } else {
        Modifier
    }

    Box(
        modifier = modifier
            .offset { IntOffset(offsetX.value.roundToInt(), 0) }
            .graphicsLayer {
                rotationZ = (offsetX.value / 35f).coerceIn(-12f, 12f)
            }
            .then(cardDragModifier)
            .clip(RoundedCornerShape(32.dp))
            .lightweightLiquidGlass(
                shape = RoundedCornerShape(32.dp),
                fallbackColor = Color(0xEE131522),
            )
            .border(1.2.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(32.dp))
            .padding(horizontal = 20.dp, vertical = 20.dp),
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            // 1. Card Top: Display Name, Verified Checkmark, Age & City/Country
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onOpenProfile),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = profile.displayName.ifBlank { profile.handle.ifBlank { "Vibra Listener" } },
                        style = MaterialTheme.typography.titleLarge.copy(
                            fontWeight = FontWeight.ExtraBold,
                            fontSize = 24.sp,
                            letterSpacing = (-0.4).sp,
                        ),
                        color = Color.White,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    // Verified blue checkmark
                    Icon(
                        imageVector = Icons.Rounded.CheckCircle,
                        contentDescription = "Verified",
                        tint = Color(0xFF3B82F6),
                        modifier = Modifier.size(19.dp),
                    )
                }

                Spacer(Modifier.height(2.dp))

                val locationParts = mutableListOf<String>()
                if (profile.age != null) locationParts.add("${profile.age}")
                if (profile.country.isNotBlank()) locationParts.add(profile.country)
                val subtitleText = if (locationParts.isNotEmpty()) {
                    locationParts.joinToString(", ")
                } else {
                    formatHandle(profile.handle).ifBlank { "Music Explorer" }
                }

                Text(
                    text = subtitleText,
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                    color = Color.White.copy(alpha = 0.65f),
                )
            }

            // 2. Card Center: Large Avatar (155dp) + 5 Orbiting Artist Satellites
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentAlignment = Alignment.Center,
            ) {
                val satellites = candidate.satelliteArtists

                // Orbit 5 satellites at trigonometric angles mirroring the reference image
                val satellitePositions = listOf(
                    Triple(0.dp, (-102).dp, 52.dp),      // Top (12 o'clock)
                    Triple((-96).dp, (-18).dp, 48.dp),    // Mid-left (9 o'clock)
                    Triple((-72).dp, 78.dp, 52.dp),      // Bottom-left (7 o'clock)
                    Triple(18.dp, 88.dp, 46.dp),         // Bottom-center (5 o'clock)
                    Triple(92.dp, 22.dp, 50.dp),         // Mid-right (4 o'clock)
                )

                satellitePositions.forEachIndexed { idx, (xOff, yOff, satSize) ->
                    val artist = satellites.getOrNull(idx)
                    Box(
                        modifier = Modifier
                            .offset(x = xOff, y = yOff)
                            .size(satSize)
                            .clip(CircleShape)
                            .background(Color(0xFF1E202E))
                            .border(1.5.dp, Color.White.copy(alpha = 0.35f), CircleShape)
                            .shadow(8.dp, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (artist != null && !artist.artworkUrl.isNullOrBlank()) {
                            AsyncImage(
                                model = artist.artworkUrl,
                                contentDescription = artist.name,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else if (artist != null) {
                            Text(
                                text = artist.name.take(1).uppercase(),
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = Color.White,
                            )
                        } else {
                            // Aesthetic musical fallback when artist count < 5
                            val fallbackIcon = when (idx) {
                                0 -> Icons.Rounded.MusicNote
                                1 -> Icons.Rounded.GraphicEq
                                2 -> Icons.Rounded.AutoAwesome
                                3 -> Icons.Rounded.Person
                                else -> Icons.Rounded.MusicNote
                            }
                            Icon(
                                imageVector = fallbackIcon,
                                contentDescription = null,
                                tint = VibraPurple.copy(alpha = 0.75f),
                                modifier = Modifier.size((satSize.value * 0.42f).dp),
                            )
                        }
                    }
                }

                // Center Main Circular Avatar
                Box(
                    modifier = Modifier
                        .size(152.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF222436))
                        .border(3.dp, Color.White.copy(alpha = 0.30f), CircleShape)
                        .shadow(16.dp, CircleShape, spotColor = VibraPurple)
                        .clickable(onClick = onOpenProfile),
                    contentAlignment = Alignment.Center,
                ) {
                    if (!profile.avatarUrl.isNullOrBlank() && profile.avatarUrl != "null") {
                        AsyncImage(
                            model = profile.avatarUrl,
                            contentDescription = profile.displayName,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .background(
                                    Brush.linearGradient(
                                        listOf(Color(0xFF6366F1), Color(0xFF8B5CF6)),
                                    ),
                                ),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = profile.displayName.take(1).uppercase().ifBlank { "V" },
                                style = MaterialTheme.typography.headlineLarge.copy(
                                    fontWeight = FontWeight.ExtraBold,
                                    fontSize = 52.sp,
                                ),
                                color = Color.White,
                            )
                        }
                    }
                }

                // Status Speech Bubble over Avatar if present
                if (profile.statusBubble.isNotBlank()) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .offset(x = 4.dp, y = 28.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .lightweightLiquidGlass(
                                shape = RoundedCornerShape(16.dp),
                                fallbackColor = Color(0xEE2A2C3C),
                            )
                            .border(1.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(16.dp))
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    ) {
                        Text(
                            text = profile.statusBubble,
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                            color = Color.White,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            // 3. Below Orbit: Similarity Metric, Artist Badges, and Rewind Button
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 14.dp),
            ) {
                // Similarity percentage in large bold typography
                Text(
                    text = "${candidate.similarityPercent}% similar",
                    style = MaterialTheme.typography.headlineSmall.copy(
                        fontWeight = FontWeight.ExtraBold,
                        fontSize = 24.sp,
                        letterSpacing = (-0.5).sp,
                    ),
                    color = Color.White,
                )

                Spacer(Modifier.height(8.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    // Left: Artist Pill Badges
                    LazyRow(
                        modifier = Modifier.weight(1f),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        val artistsToDisplay = candidate.sharedArtists.ifEmpty { candidate.satelliteArtists }
                        if (artistsToDisplay.isNotEmpty()) {
                            items(artistsToDisplay.take(3)) { artist ->
                                Row(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(16.dp))
                                        .background(Color.White.copy(alpha = 0.12f))
                                        .border(0.8.dp, Color.White.copy(alpha = 0.22f), RoundedCornerShape(16.dp))
                                        .padding(horizontal = 10.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    if (!artist.artworkUrl.isNullOrBlank()) {
                                        AsyncImage(
                                            model = artist.artworkUrl,
                                            contentDescription = null,
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier
                                                .size(20.dp)
                                                .clip(CircleShape),
                                        )
                                    } else {
                                        Icon(
                                            imageVector = Icons.Rounded.MusicNote,
                                            contentDescription = null,
                                            tint = VibraPurple,
                                            modifier = Modifier.size(14.dp),
                                        )
                                    }
                                    Text(
                                        text = artist.name,
                                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                                        color = Color.White,
                                        maxLines = 1,
                                    )
                                }
                            }
                        } else {
                            item {
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(16.dp))
                                        .background(Color.White.copy(alpha = 0.10f))
                                        .border(0.8.dp, Color.White.copy(alpha = 0.20f), RoundedCornerShape(16.dp))
                                        .padding(horizontal = 12.dp, vertical = 6.dp),
                                ) {
                                    Text(
                                        text = "Eclectic Soundscape",
                                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                        color = Color.White.copy(alpha = 0.85f),
                                    )
                                }
                            }
                        }
                    }

                    // Right: Rewind Action Button
                    if (onRewind != null) {
                        Spacer(Modifier.width(10.dp))
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier
                                .alpha(if (canRewind) 1f else 0.40f)
                                .clickable(enabled = canRewind) { onRewind() }
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.Undo,
                                contentDescription = "Rewind",
                                tint = Color.White,
                                modifier = Modifier.size(22.dp),
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                text = "Rewind",
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold,
                                ),
                                color = Color.White.copy(alpha = 0.85f),
                            )
                        }
                    }
                }
            }

            // 4. Bottom Action Pair: + Add Friend & Skip
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                // Add Friend / Connect Button (Blue / Purple vibrant gradient)
                Box(
                    modifier = Modifier
                        .weight(1.3f)
                        .height(54.dp)
                        .clip(RoundedCornerShape(22.dp))
                        .background(
                            Brush.horizontalGradient(
                                listOf(Color(0xFF2563EB), Color(0xFF6366F1), Color(0xFF8B5CF6)),
                            ),
                        )
                        .border(1.dp, Color.White.copy(alpha = 0.35f), RoundedCornerShape(22.dp))
                        .shadow(elevation = 10.dp, shape = RoundedCornerShape(22.dp), spotColor = Color(0xFF6366F1))
                        .liquidGlassButton(
                            onClick = {
                                coroutineScope.launch {
                                    offsetX.animateTo(900f, spring(stiffness = Spring.StiffnessMedium))
                                    onAddFriend()
                                }
                            },
                            haptic = Haptic.Tap,
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.PersonAdd,
                            contentDescription = "Add Friend",
                            tint = Color.White,
                            modifier = Modifier.size(20.dp),
                        )
                        Text(
                            text = "Add Friend",
                            style = MaterialTheme.typography.labelLarge.copy(
                                fontWeight = FontWeight.ExtraBold,
                                fontSize = 16.sp,
                            ),
                            color = Color.White,
                        )
                    }
                }

                // Skip / Pass Button (Liquid Glass)
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(54.dp)
                        .clip(RoundedCornerShape(22.dp))
                        .lightweightLiquidGlass(
                            shape = RoundedCornerShape(22.dp),
                            fallbackColor = Color(0xCC202230),
                        )
                        .border(1.dp, Color.White.copy(alpha = 0.20f), RoundedCornerShape(22.dp))
                        .liquidGlassButton(
                            onClick = {
                                coroutineScope.launch {
                                    offsetX.animateTo(-900f, spring(stiffness = Spring.StiffnessMedium))
                                    onSkip()
                                }
                            },
                            haptic = Haptic.Tap,
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.SkipNext,
                            contentDescription = "Skip",
                            tint = Color.White.copy(alpha = 0.85f),
                            modifier = Modifier.size(20.dp),
                        )
                        Text(
                            text = "Skip",
                            style = MaterialTheme.typography.labelLarge.copy(
                                fontWeight = FontWeight.Bold,
                                fontSize = 16.sp,
                            ),
                            color = Color.White.copy(alpha = 0.85f),
                        )
                    }
                }
            }
        }
    }
}

/**
 * Secondary discovery friend card for list / grid mode.
 */
@Composable
private fun DiscoveryFriendCard(
    profile: SocialProfile,
    similarityScore: Int,
    sharedArtists: List<FavoriteArtist>,
    onSendFriendRequest: () -> Unit,
    onOpenProfile: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var requestSent by remember { mutableStateOf(false) }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .lightweightLiquidGlass(
                shape = RoundedCornerShape(22.dp),
                fallbackColor = Color(0xEE161824),
            )
            .border(1.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(22.dp))
            .clickable(onClick = onOpenProfile)
            .padding(14.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Profile Avatar
            Box(
                modifier = Modifier
                    .size(54.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF222436))
                    .border(2.dp, VibraPurple.copy(alpha = 0.5f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                if (!profile.avatarUrl.isNullOrBlank() && profile.avatarUrl != "null") {
                    AsyncImage(
                        model = profile.avatarUrl,
                        contentDescription = profile.displayName,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Rounded.Person,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.85f),
                        modifier = Modifier.size(26.dp),
                    )
                }
            }

            Spacer(Modifier.width(12.dp))

            // Text Info
            Column(modifier = Modifier.weight(1f)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = profile.displayName.ifBlank { profile.handle.ifBlank { "Vibra Listener" } },
                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Icon(
                        imageVector = Icons.Rounded.CheckCircle,
                        contentDescription = null,
                        tint = Color(0xFF3B82F6),
                        modifier = Modifier.size(15.dp),
                    )
                }

                Spacer(Modifier.height(2.dp))

                val locationParts = mutableListOf<String>()
                if (profile.age != null) locationParts.add("${profile.age}")
                if (profile.country.isNotBlank()) locationParts.add(profile.country)
                val sub = if (locationParts.isNotEmpty()) locationParts.joinToString(", ") else formatHandle(profile.handle)

                Text(
                    text = "$similarityScore% match · $sub",
                    style = MaterialTheme.typography.bodySmall.copy(
                        fontWeight = FontWeight.SemiBold,
                        color = VibraPurple,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Spacer(Modifier.width(10.dp))

            // Connect button
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(16.dp))
                    .then(
                        if (requestSent) {
                            Modifier.background(Color(0xFF222432))
                        } else {
                            Modifier.background(Brush.horizontalGradient(listOf(Color(0xFF2563EB), VibraPurple)))
                        }
                    )
                    .border(1.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(16.dp))
                    .clickable(enabled = !requestSent) {
                        requestSent = true
                        onSendFriendRequest()
                    }
                    .padding(horizontal = 14.dp, vertical = 9.dp),
                contentAlignment = Alignment.Center,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(
                        imageVector = if (requestSent) Icons.Rounded.Check else Icons.Rounded.PersonAdd,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(14.dp),
                    )
                    Text(
                        text = if (requestSent) "Sent" else "Connect",
                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                    )
                }
            }
        }
    }
}

private fun formatHandle(handle: String): String {
    val clean = handle.trim().removePrefix("@")
    return if (clean.isNotBlank()) "@$clean" else ""
}
