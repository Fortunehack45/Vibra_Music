package com.fortune.vibramusic.ui.social

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.data.social.FavoriteArtist
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass
import com.fortune.vibramusic.ui.components.liquidGlassButton
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.theme.VibraPurple
import dev.chrisbanes.haze.HazeState

data class MusicMatchCandidate(
    val profile: SocialProfile,
    val similarityPercent: Int,
    val sharedArtists: List<FavoriteArtist> = emptyList(),
    val satelliteArtists: List<FavoriteArtist> = emptyList(),
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
    val infiniteTransition = rememberInfiniteTransition(label = "pulseTransition")
    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 0.94f,
        targetValue = 1.06f,
        animationSpec = infiniteRepeatable(
            animation = tween(2200, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "pulseScale",
    )
    val glowAlpha by infiniteTransition.animateFloat(
        initialValue = 0.25f,
        targetValue = 0.55f,
        animationSpec = infiniteRepeatable(
            animation = tween(2200, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "glowAlpha",
    )

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
                .padding(
                    top = topPadding,
                    bottom = contentPadding.calculateBottomPadding() + 16.dp,
                    start = 16.dp,
                    end = 16.dp,
                ),
        ) {
            // Optional Top Bar with Back Button when opened as detail
            if (onBack != null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(42.dp)
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
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = "Music Twin",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                    )
                }
            } else {
                Spacer(Modifier.height(12.dp))
            }

            // Centered Hero Card for "Coming Soon"
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .clip(RoundedCornerShape(32.dp))
                    .lightweightLiquidGlass(
                        shape = RoundedCornerShape(32.dp),
                        fallbackColor = Color(0xEE12141F),
                    )
                    .border(1.2.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(32.dp))
                    .padding(horizontal = 24.dp, vertical = 32.dp),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    // Pulsing Glow & Center Icon
                    Box(
                        modifier = Modifier
                            .size(140.dp)
                            .scale(pulseScale),
                        contentAlignment = Alignment.Center,
                    ) {
                        // Outer ambient glow ring
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .clip(CircleShape)
                                .background(
                                    Brush.radialGradient(
                                        listOf(
                                            VibraPurple.copy(alpha = glowAlpha),
                                            Color(0xFF3B82F6).copy(alpha = glowAlpha * 0.5f),
                                            Color.Transparent,
                                        ),
                                    ),
                                ),
                        )

                        // Inner icon orb
                        Box(
                            modifier = Modifier
                                .size(96.dp)
                                .clip(CircleShape)
                                .background(
                                    Brush.linearGradient(
                                        listOf(Color(0xFF2563EB), Color(0xFF8B5CF6)),
                                    ),
                                )
                                .border(2.dp, Color.White.copy(alpha = 0.35f), CircleShape)
                                .shadow(18.dp, CircleShape, spotColor = VibraPurple),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.GraphicEq,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(46.dp),
                            )
                        }
                    }

                    Spacer(Modifier.height(28.dp))

                    // Pill Badge: "Coming Soon"
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .lightweightLiquidGlass(
                                shape = RoundedCornerShape(20.dp),
                                fallbackColor = VibraPurple.copy(alpha = 0.25f),
                            )
                            .border(1.dp, VibraPurple.copy(alpha = 0.55f), RoundedCornerShape(20.dp))
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.AutoAwesome,
                                contentDescription = null,
                                tint = VibraPurple,
                                modifier = Modifier.size(14.dp),
                            )
                            Text(
                                text = "Coming Soon",
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontWeight = FontWeight.ExtraBold,
                                    letterSpacing = 0.8.sp,
                                ),
                                color = Color.White,
                            )
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    // Title
                    Text(
                        text = "Music Soulmate",
                        style = MaterialTheme.typography.headlineMedium.copy(
                            fontWeight = FontWeight.ExtraBold,
                            fontSize = 28.sp,
                            letterSpacing = (-0.5).sp,
                        ),
                        color = Color.White,
                        textAlign = TextAlign.Center,
                    )

                    Spacer(Modifier.height(10.dp))

                    // Description
                    Text(
                        text = "We are currently redesigning the music twin discovery experience from the ground up to bring you seamless musical taste matching, shared artist affinities, and an all-new discovery flow.",
                        style = MaterialTheme.typography.bodyMedium.copy(
                            lineHeight = 22.sp,
                        ),
                        color = Color.White.copy(alpha = 0.68f),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 12.dp),
                    )

                    Spacer(Modifier.height(28.dp))

                    // Feature Preview Pills
                    Column(
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        listOf(
                            "Real-Time Taste Frequency",
                            "Mutual Artists & Sonic Anthems",
                            "New Immersive Visual Experience",
                        ).forEach { feature ->
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(Color.White.copy(alpha = 0.08f))
                                    .border(0.8.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(16.dp))
                                    .padding(horizontal = 14.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.MusicNote,
                                    contentDescription = null,
                                    tint = VibraPurple,
                                    modifier = Modifier.size(15.dp),
                                )
                                Text(
                                    text = feature,
                                    style = MaterialTheme.typography.bodySmall.copy(
                                        fontWeight = FontWeight.SemiBold,
                                    ),
                                    color = Color.White.copy(alpha = 0.88f),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
