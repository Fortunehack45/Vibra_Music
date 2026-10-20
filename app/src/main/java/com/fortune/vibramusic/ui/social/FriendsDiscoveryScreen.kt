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
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.SkipNext
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
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass
import com.fortune.vibramusic.ui.components.liquidGlassButton
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.theme.VibraPurple
import dev.chrisbanes.haze.HazeState
import kotlinx.coroutines.launch
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Calculated match candidate model containing similarity score and shared favorite artists.
 */
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
                    (35..65).random() // baseline music affinity
                } else {
                    val ratio = (shared.size.toFloat() / candArtists.size.coerceAtLeast(1).toFloat())
                    (ratio * 65f + 30f).toInt().coerceIn(25, 99)
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
    }

    val topCandidate = activeDeck.firstOrNull()

    val topPadding = if (onBack != null) 0.dp else contentPadding.calculateTopPadding()
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color(0xFF0C0D12))
            .then(if (onBack != null) Modifier.statusBarsPadding() else Modifier),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = topPadding),
        ) {
            // Top Navigation Bar
            if (onBack != null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(42.dp)
                            .clip(CircleShape)
                            .lightweightLiquidGlass(
                                shape = CircleShape,
                                fallbackColor = Color(0xCC1A1C24),
                            )
                            .border(1.dp, Color.White.copy(alpha = 0.2f), CircleShape)
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

                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = "Music Twin",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            color = Color.White,
                        )
                        Text(
                            text = "Find your musical soulmates",
                            style = MaterialTheme.typography.labelSmall,
                            color = Color.White.copy(alpha = 0.65f),
                        )
                    }

                    Box(
                        modifier = Modifier
                            .size(42.dp)
                            .clip(CircleShape)
                            .lightweightLiquidGlass(
                                shape = CircleShape,
                                fallbackColor = Color(0xCC1A1C24),
                            )
                            .border(1.dp, Color.White.copy(alpha = 0.2f), CircleShape)
                            .liquidGlassButton(
                                onClick = { onRefreshSuggestions() },
                                haptic = Haptic.Tap,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Refresh,
                            contentDescription = "Refresh",
                            tint = VibraPurple,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            } else {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column {
                        Text(
                            text = "Musical Soulmates",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            color = Color.White,
                        )
                        Text(
                            text = "People sharing your music taste",
                            style = MaterialTheme.typography.labelSmall,
                            color = Color.White.copy(alpha = 0.65f),
                        )
                    }

                    Box(
                        modifier = Modifier
                            .size(38.dp)
                            .clip(CircleShape)
                            .lightweightLiquidGlass(
                                shape = CircleShape,
                                fallbackColor = Color(0xCC1A1C24),
                            )
                            .border(1.dp, Color.White.copy(alpha = 0.2f), CircleShape)
                            .liquidGlassButton(
                                onClick = { onRefreshSuggestions() },
                                haptic = Haptic.Tap,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Refresh,
                            contentDescription = "Refresh",
                            tint = VibraPurple,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }

            // Dual Mode Liquid Glass Switcher (Radar vs Top Twins)
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp, vertical = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .lightweightLiquidGlass(
                            shape = RoundedCornerShape(20.dp),
                            fallbackColor = Color(0xCC181922),
                        )
                        .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(20.dp))
                        .padding(3.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    TwinModePill(
                        label = "Radar Swipe",
                        selected = viewMode == TwinViewMode.RADAR,
                        onClick = { viewMode = TwinViewMode.RADAR },
                    )
                    TwinModePill(
                        label = "Top Twins",
                        selected = viewMode == TwinViewMode.TOP_LIST,
                        onClick = { viewMode = TwinViewMode.TOP_LIST },
                    )
                }
            }

            // Body Content
            if (viewMode == TwinViewMode.RADAR) {
                // Center: Cards Deck or Empty State
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(
                            top = 10.dp,
                            bottom = contentPadding.calculateBottomPadding() + 84.dp,
                            start = 16.dp,
                            end = 16.dp,
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    if (topCandidate != null) {
                        if (activeDeck.size > 1) {
                            val nextCandidate = activeDeck[1]
                            MusicSoulmateCard(
                                candidate = nextCandidate,
                                isTopCard = false,
                                onSkip = {},
                                onAddFriend = {},
                                onOpenProfile = {},
                                modifier = Modifier
                                    .graphicsLayer {
                                        scaleX = 0.94f
                                        scaleY = 0.94f
                                        translationY = 28.dp.toPx()
                                        alpha = 0.5f
                                    },
                            )
                        }

                        MusicSoulmateCard(
                            candidate = topCandidate,
                            isTopCard = true,
                            onSkip = {
                                historyStack.add(topCandidate)
                                activeDeck.removeAt(0)
                            },
                            onAddFriend = {
                                onSendFriendRequest(topCandidate.profile)
                                historyStack.add(topCandidate)
                                activeDeck.removeAt(0)
                            },
                            onOpenProfile = { onOpenProfile(topCandidate.profile) },
                            onRewind = {
                                if (historyStack.isNotEmpty()) {
                                    val last = historyStack.removeAt(historyStack.lastIndex)
                                    activeDeck.add(0, last)
                                }
                            },
                            canRewind = historyStack.isNotEmpty(),
                        )
                    } else {
                        // Empty State
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(32.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(80.dp)
                                    .clip(CircleShape)
                                    .background(VibraPurple.copy(alpha = 0.15f))
                                    .border(1.5.dp, VibraPurple.copy(alpha = 0.4f), CircleShape),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.GraphicEq,
                                    contentDescription = null,
                                    tint = VibraPurple,
                                    modifier = Modifier.size(40.dp),
                                )
                            }

                            Spacer(Modifier.height(18.dp))

                            Text(
                                text = "All Caught Up!",
                                style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                                color = Color.White,
                            )
                            Spacer(Modifier.height(8.dp))
                            Text(
                                text = "You've reviewed all music twins. Refresh to discover more listeners with matching tastes!",
                                style = MaterialTheme.typography.bodyMedium,
                                color = Color.White.copy(alpha = 0.65f),
                                textAlign = TextAlign.Center,
                            )

                            Spacer(Modifier.height(22.dp))

                            ElevatedButton(
                                onClick = { onRefreshSuggestions() },
                                colors = ButtonDefaults.elevatedButtonColors(
                                    containerColor = VibraPurple,
                                    contentColor = Color.White,
                                ),
                                shape = RoundedCornerShape(22.dp),
                                contentPadding = PaddingValues(horizontal = 24.dp, vertical = 12.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Refresh,
                                    contentDescription = null,
                                    modifier = Modifier.size(18.dp),
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    text = "Refresh Twins",
                                    style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                                )
                            }
                        }
                    }
                }
            } else {
                // Top Twins Curated List Mode
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = 16.dp,
                        end = 16.dp,
                        top = 12.dp,
                        bottom = contentPadding.calculateBottomPadding() + 84.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(
                        items = candidatesList,
                        key = { it.profile.id },
                    ) { candidate ->
                        TopTwinListItem(
                            candidate = candidate,
                            onOpenProfile = { onOpenProfile(candidate.profile) },
                            onAddFriend = { onSendFriendRequest(candidate.profile) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TwinModePill(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .then(
                if (selected) {
                    Modifier
                        .background(VibraPurple)
                        .border(1.dp, Color.White.copy(alpha = 0.3f), RoundedCornerShape(16.dp))
                } else {
                    Modifier.clickable(onClick = onClick)
                },
            )
            .padding(horizontal = 20.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium.copy(
                fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
            ),
            color = if (selected) Color.White else Color.White.copy(alpha = 0.7f),
        )
    }
}

@Composable
private fun TopTwinListItem(
    candidate: MusicMatchCandidate,
    onOpenProfile: () -> Unit,
    onAddFriend: () -> Unit,
) {
    val profile = candidate.profile
    var requestSent by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .lightweightLiquidGlass(
                shape = RoundedCornerShape(20.dp),
                fallbackColor = Color(0xCC181924),
            )
            .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(20.dp))
            .clickable(onClick = onOpenProfile)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Avatar
        Box(
            modifier = Modifier
                .size(54.dp)
                .clip(CircleShape)
                .background(Color(0xFF222432))
                .border(2.dp, VibraPurple, CircleShape),
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
                    tint = Color.White.copy(alpha = 0.7f),
                    modifier = Modifier.size(28.dp),
                )
            }
        }

        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = profile.displayName.ifBlank { formatHandle(profile.handle) },
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (profile.verifiedBadge) {
                    Icon(
                        imageVector = Icons.Rounded.CheckCircle,
                        contentDescription = "Verified",
                        tint = Color(0xFF38BDF8),
                        modifier = Modifier.size(16.dp),
                    )
                }
            }

            Text(
                text = "${candidate.similarityPercent}% match in music taste",
                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                color = VibraPurple,
            )

            if (candidate.sharedArtists.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "Both love " + candidate.sharedArtists.take(2).joinToString(", ") { it.name },
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.65f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Spacer(Modifier.width(8.dp))

        // Connect button
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(16.dp))
                .background(if (requestSent) Color(0xFF222432) else VibraPurple)
                .border(1.dp, Color.White.copy(alpha = 0.2f), RoundedCornerShape(16.dp))
                .clickable(enabled = !requestSent) {
                    requestSent = true
                    onAddFriend()
                }
                .padding(horizontal = 14.dp, vertical = 8.dp),
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

/**
 * Liquid glass match card displaying candidate details, orbiting artist satellites, and actions.
 */
@Composable
private fun MusicSoulmateCard(
    candidate: MusicMatchCandidate,
    isTopCard: Boolean,
    onSkip: () -> Unit,
    onAddFriend: () -> Unit,
    onOpenProfile: () -> Unit,
    onRewind: (() -> Unit)? = null,
    canRewind: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val coroutineScope = rememberCoroutineScope()
    val profile = candidate.profile

    val offsetX = remember { Animatable(0f) }
    val offsetY = remember { Animatable(0f) }

    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .offset { IntOffset(offsetX.value.roundToInt(), offsetY.value.roundToInt()) }
            .graphicsLayer {
                rotationZ = (offsetX.value / 350f) * 12f
            }
            .clip(RoundedCornerShape(32.dp))
            .background(
                Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF222430),
                        Color(0xFF161720),
                        Color(0xFF101118),
                    ),
                ),
            )
            .border(
                width = 1.2.dp,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.White.copy(alpha = 0.28f),
                        VibraPurple.copy(alpha = 0.35f),
                        Color.White.copy(alpha = 0.08f),
                    ),
                ),
                shape = RoundedCornerShape(32.dp),
            )
            .then(
                if (isTopCard) {
                    Modifier.pointerInput(Unit) {
                        detectDragGestures(
                            onDragEnd = {
                                coroutineScope.launch {
                                    if (offsetX.value > 250f) {
                                        offsetX.animateTo(1000f, spring(stiffness = Spring.StiffnessMedium))
                                        onAddFriend()
                                    } else if (offsetX.value < -250f) {
                                        offsetX.animateTo(-1000f, spring(stiffness = Spring.StiffnessMedium))
                                        onSkip()
                                    } else {
                                        offsetX.animateTo(0f, spring(stiffness = Spring.StiffnessMediumLow))
                                        offsetY.animateTo(0f, spring(stiffness = Spring.StiffnessMediumLow))
                                    }
                                }
                            },
                            onDrag = { change, dragAmount ->
                                change.consume()
                                coroutineScope.launch {
                                    offsetX.snapTo(offsetX.value + dragAmount.x)
                                    offsetY.snapTo(offsetY.value + dragAmount.y * 0.4f)
                                }
                            },
                        )
                    }
                } else Modifier,
            )
            .padding(22.dp),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            // Card Top Row: Name, Verified Badge, Age, Location
            Column(modifier = Modifier.fillMaxWidth()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = profile.displayName.ifBlank { formatHandle(profile.handle) },
                        style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.ExtraBold),
                        color = Color.White,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (profile.verifiedBadge) {
                        Icon(
                            imageVector = Icons.Rounded.CheckCircle,
                            contentDescription = "Verified",
                            tint = Color(0xFF38BDF8),
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }

                Spacer(Modifier.height(2.dp))

                val locationParts = mutableListOf<String>()
                if (profile.age != null) locationParts.add("${profile.age}")
                if (profile.country.isNotBlank()) locationParts.add(profile.country)
                if (locationParts.isNotEmpty()) {
                    Text(
                        text = locationParts.joinToString(", "),
                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                        color = Color.White.copy(alpha = 0.70f),
                    )
                }
            }

            Spacer(Modifier.height(16.dp))

            // Card Center: Main Avatar + Status Bubble + Satellite Orbiting Artists
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(240.dp),
                contentAlignment = Alignment.Center,
            ) {
                val satelliteArtists = candidate.satelliteArtists
                val orbitRadius = 96.dp

                satelliteArtists.forEachIndexed { idx, artist ->
                    val angleDeg = when (idx) {
                        0 -> 210.0
                        1 -> 330.0
                        2 -> 150.0
                        3 -> 30.0
                        else -> 90.0
                    }
                    val angleRad = Math.toRadians(angleDeg)
                    val xOffset = (cos(angleRad) * orbitRadius.value).dp
                    val yOffset = (sin(angleRad) * orbitRadius.value).dp

                    Box(
                        modifier = Modifier
                            .offset(x = xOffset, y = yOffset)
                            .size(50.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF1C1D28))
                            .border(1.5.dp, Color.White.copy(alpha = 0.35f), CircleShape)
                            .shadow(8.dp, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (!artist.artworkUrl.isNullOrBlank()) {
                            AsyncImage(
                                model = artist.artworkUrl,
                                contentDescription = artist.name,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            Text(
                                text = artist.name.take(1).uppercase(),
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = Color.White,
                            )
                        }
                    }
                }

                // Center Main Avatar
                Box(
                    modifier = Modifier
                        .size(130.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF252636))
                        .border(3.dp, VibraPurple, CircleShape)
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
                        Icon(
                            imageVector = Icons.Rounded.Person,
                            contentDescription = null,
                            tint = Color.White.copy(alpha = 0.7f),
                            modifier = Modifier.size(60.dp),
                        )
                    }
                }

                // Status Speech Bubble over Avatar
                if (profile.statusBubble.isNotBlank()) {
                    Box(
                        modifier = Modifier
                            .offset(x = 38.dp, y = (-50).dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(Color(0xEE2A2C3C))
                            .border(1.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(16.dp))
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

            Spacer(Modifier.height(14.dp))

            // Card Lower Section: Similarity Score + Shared Artists
            Column(modifier = Modifier.fillMaxWidth()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = "${candidate.similarityPercent}% match",
                        style = MaterialTheme.typography.titleMedium.copy(
                            fontWeight = FontWeight.ExtraBold,
                            color = VibraPurple,
                        ),
                    )
                    Text(
                        text = if (candidate.sharedArtists.isNotEmpty()) "shared music taste" else "sound profile",
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color.White.copy(alpha = 0.65f),
                    )
                }

                if (candidate.sharedArtists.isNotEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    LazyRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        items(candidate.sharedArtists) { artist ->
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(Color.White.copy(alpha = 0.10f))
                                    .border(0.8.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(14.dp))
                                    .padding(horizontal = 10.dp, vertical = 5.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                if (!artist.artworkUrl.isNullOrBlank()) {
                                    AsyncImage(
                                        model = artist.artworkUrl,
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier
                                            .size(18.dp)
                                            .clip(CircleShape),
                                    )
                                }
                                Text(
                                    text = artist.name,
                                    style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                    color = Color.White,
                                )
                            }
                        }
                    }
                }
            }

            Spacer(Modifier.height(18.dp))

            // Card Bottom Actions: Rewind, Skip, + Add Friend
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (onRewind != null) {
                    Box(
                        modifier = Modifier
                            .size(52.dp)
                            .clip(RoundedCornerShape(18.dp))
                            .background(Color(0xFF222432))
                            .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(18.dp))
                            .alpha(if (canRewind) 1f else 0.4f)
                            .clickable(enabled = canRewind) { onRewind() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.Undo,
                                contentDescription = "Rewind",
                                tint = Color.White,
                                modifier = Modifier.size(18.dp),
                            )
                            Text(
                                text = "Rewind",
                                style = MaterialTheme.typography.labelSmall.copy(fontSize = 9.sp),
                                color = Color.White.copy(alpha = 0.75f),
                            )
                        }
                    }
                }

                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(52.dp)
                        .clip(RoundedCornerShape(18.dp))
                        .background(Color(0xFF262736))
                        .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(18.dp))
                        .clickable {
                            coroutineScope.launch {
                                offsetX.animateTo(-800f, spring(stiffness = Spring.StiffnessMedium))
                                onSkip()
                            }
                        },
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
                            style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                            color = Color.White.copy(alpha = 0.85f),
                        )
                    }
                }

                Box(
                    modifier = Modifier
                        .weight(1.3f)
                        .height(52.dp)
                        .clip(RoundedCornerShape(18.dp))
                        .background(
                            Brush.horizontalGradient(
                                listOf(VibraPurple, Color(0xFFA855F7)),
                            ),
                        )
                        .shadow(elevation = 10.dp, shape = RoundedCornerShape(18.dp), spotColor = VibraPurple)
                        .clickable {
                            coroutineScope.launch {
                                offsetX.animateTo(800f, spring(stiffness = Spring.StiffnessMedium))
                                onAddFriend()
                            }
                        },
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
                            style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.ExtraBold),
                            color = Color.White,
                        )
                    }
                }
            }
        }
    }
}
