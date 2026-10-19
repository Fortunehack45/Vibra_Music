package com.fortune.vibramusic.ui.social

import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.LocationOn
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ElevatedButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.quiz.VERIFIED_CURATED_ARTISTS
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PostMediaItem
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.ui.components.ArtistAvatar
import dev.chrisbanes.haze.HazeState
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.ui.components.SocialTab
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.fortune.vibramusic.data.social.isWithinEditWindow
import com.fortune.vibramusic.ui.theme.rememberArtworkPalette
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import androidx.compose.ui.viewinterop.AndroidView
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.runtime.DisposableEffect
import androidx.compose.foundation.Image
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.graphics.ColorFilter
import com.fortune.vibramusic.R
import com.fortune.vibramusic.ui.realm.AppRealm
import com.fortune.vibramusic.ui.components.RealmSwitcher
import com.fortune.vibramusic.ui.components.LocalLiquidGlassEnabled
import com.fortune.vibramusic.ui.components.isGlassSupported
import com.fortune.vibramusic.ui.components.liquidGlass
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass
import com.fortune.vibramusic.ui.components.liquidGlassButton
import com.fortune.vibramusic.ui.components.glassContentColor
import com.fortune.vibramusic.ui.haptics.Haptic
import androidx.compose.ui.draw.shadow
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.materials.HazeMaterials

@Composable
fun UserProfileScreen(
    profile: SocialProfile,
    viewModel: SocialViewModel,
    isSelf: Boolean,
    onBack: (() -> Unit)?,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
    onArtistQuizClick: (QuizArtist) -> Unit,
    onOpenArtistDetail: ((id: String, name: String, artworkUrl: String?) -> Unit)? = null,
    onOpenPlaylist: ((id: String, title: String, coverUrl: String?) -> Unit)? = null,
    activeRealm: AppRealm = AppRealm.SOCIAL,
    onRealmSelected: ((AppRealm) -> Unit)? = null,
    contentPadding: PaddingValues,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val coroutineScope = rememberCoroutineScope()
    val currentProfile by viewModel.currentProfile.collectAsStateWithLifecycle()
    val viewingProfile by viewModel.viewingProfile.collectAsStateWithLifecycle()
    val activeProfile = if (isSelf) (currentProfile ?: profile) else (viewingProfile?.takeIf { it.id == profile.id } ?: profile)

    val selectedPostForComments by viewModel.selectedPostForComments.collectAsStateWithLifecycle()
    val comments by viewModel.comments.collectAsStateWithLifecycle()

    val isDark = MaterialTheme.colorScheme.surface.let {
        (it.red * 0.299f + it.green * 0.587f + it.blue * 0.114f) < 0.5f
    }

    val posts by viewModel.viewingProfilePosts.collectAsStateWithLifecycle()
    val favoriteArtists by viewModel.favoriteArtists.collectAsStateWithLifecycle()
    val followingList by viewModel.followingList.collectAsStateWithLifecycle()
    val followersList by viewModel.followersList.collectAsStateWithLifecycle()
    val friendsList by viewModel.friendsList.collectAsStateWithLifecycle()
    val suggestedUsers by viewModel.suggestedUsersList.collectAsStateWithLifecycle()

    val context = LocalContext.current
    var selectedSubTab by remember { mutableStateOf("Posts") }
    var showEditProfile by remember { mutableStateOf(false) }
    var showAddArtistScreen by remember { mutableStateOf(false) }
    var showEditStatusDialog by remember { mutableStateOf(false) }
    var showSuggestedCarousel by remember { mutableStateOf(false) }
    var activeConnectionsTab by remember { mutableStateOf<ConnectionsTab?>(null) }
    var postToDelete by remember { mutableStateOf<SocialPost?>(null) }
    var editingPost by remember { mutableStateOf<SocialPost?>(null) }
    var editPostContent by remember { mutableStateOf("") }
    var inspectedQuotedPost by remember { mutableStateOf<SocialPost?>(null) }
    var activeMediaViewer by remember { mutableStateOf<Pair<List<PostMediaItem>, Int>?>(null) }

    LaunchedEffect(activeProfile.id) {
        if (activeProfile.id.isNotBlank() && activeProfile.id != "me") {
            viewModel.loadProfileData(activeProfile.id)
            viewModel.loadConnections(activeProfile.id)
        } else {
            viewModel.currentProfile.value?.id?.let {
                viewModel.loadConnections(it)
            }
        }
    }

    Box(
        modifier = modifier.fillMaxSize(),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                top = 0.dp,
                bottom = contentPadding.calculateBottomPadding() + 80.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // 1. Wide Header Banner with Overlaid Navigation (reference image 2 & 5)
            item(key = "profile_banner_header") {
                val localBanner = remember(activeProfile.id) {
                    val fJpg = java.io.File(context.filesDir, "custom_banner_${activeProfile.id}.jpg")
                    if (fJpg.exists()) return@remember fJpg.toURI().toString()
                    val fMp4 = java.io.File(context.filesDir, "custom_banner_${activeProfile.id}.mp4")
                    if (fMp4.exists()) return@remember fMp4.toURI().toString()
                    null
                }
                val bannerUrl = activeProfile.bannerUrl?.takeIf { it.isNotBlank() }
                    ?: localBanner
                    ?: activeProfile.bannerPlaylists.firstOrNull()?.split("|")?.lastOrNull()?.takeIf { it.startsWith("http") }

                val isBannerVideo = bannerUrl?.endsWith(".mp4", ignoreCase = true) == true || bannerUrl?.contains("video", ignoreCase = true) == true
                val paletteImage = if (isBannerVideo) activeProfile.avatarUrl else (bannerUrl ?: activeProfile.avatarUrl)
                val palette = rememberArtworkPalette(paletteImage)
                val ambientColor = palette.background

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(185.dp)
                        .clipToBounds()
                        .background(
                            Brush.verticalGradient(
                                colors = listOf(
                                    ambientColor.copy(alpha = 0.95f),
                                    ambientColor.copy(alpha = 0.6f),
                                    MaterialTheme.colorScheme.background,
                                ),
                            ),
                        ),
                ) {
                    if (!bannerUrl.isNullOrBlank()) {
                        val isVideo = bannerUrl.endsWith(".mp4", ignoreCase = true) || bannerUrl.contains("video", ignoreCase = true)
                        if (isVideo) {
                            ProfileBannerVideo(
                                videoUrl = bannerUrl,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            AsyncImage(
                                model = bannerUrl,
                                contentDescription = "Profile Banner",
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                    }

                    // Bottom gradient fade into page background
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(70.dp)
                            .align(Alignment.BottomCenter)
                            .background(
                                Brush.verticalGradient(
                                    colors = listOf(Color.Transparent, MaterialTheme.colorScheme.background),
                                ),
                            ),
                    )

                    // Overlaid Floating Liquid Glass Navigation Chrome
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .statusBarsPadding()
                            .padding(horizontal = 16.dp, vertical = 6.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // Left: Back button or Vibra app mark
                        if (onBack != null) {
                            Box(
                                modifier = Modifier
                                    .size(44.dp)
                                    .shadow(
                                        elevation = 6.dp,
                                        shape = CircleShape,
                                        spotColor = Color.Black.copy(alpha = 0.35f),
                                    )
                                    .clip(CircleShape)
                                    .lightweightLiquidGlass(
                                        shape = CircleShape,
                                        fallbackColor = if (isDark) Color(0xCC181A22) else Color.White.copy(alpha = 0.92f),
                                    )
                                    .background(
                                        if (isDark) Color(0xCC181A22) else Color.White.copy(alpha = 0.92f),
                                        CircleShape,
                                    )
                                    .border(
                                        width = 1.dp,
                                        brush = Brush.verticalGradient(
                                            colors = listOf(
                                                Color.White.copy(alpha = 0.6f),
                                                Color.White.copy(alpha = 0.15f),
                                            )
                                        ),
                                        shape = CircleShape,
                                    )
                                    .liquidGlassButton(
                                        onClick = onBack,
                                        haptic = Haptic.Tap,
                                        expandScale = 1.14f,
                                        pressScale = 0.91f,
                                    ),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                                    contentDescription = "Back",
                                    tint = if (isDark) Color.White else Color(0xFF111318),
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        } else {
                            Box(
                                modifier = Modifier
                                    .size(44.dp)
                                    .shadow(
                                        elevation = 6.dp,
                                        shape = CircleShape,
                                        spotColor = Color.Black.copy(alpha = 0.35f),
                                    )
                                    .clip(CircleShape)
                                    .lightweightLiquidGlass(
                                        shape = CircleShape,
                                        fallbackColor = if (isDark) Color(0xCC181A22) else Color.White.copy(alpha = 0.92f),
                                    )
                                    .background(
                                        if (isDark) Color(0xCC181A22) else Color.White.copy(alpha = 0.92f),
                                        CircleShape,
                                    )
                                    .border(
                                        width = 1.dp,
                                        brush = Brush.verticalGradient(
                                            colors = listOf(
                                                Color.White.copy(alpha = 0.6f),
                                                Color.White.copy(alpha = 0.15f),
                                            )
                                        ),
                                        shape = CircleShape,
                                    ),
                                contentAlignment = Alignment.Center,
                            ) {
                                Image(
                                    painter = painterResource(R.drawable.ic_logo),
                                    contentDescription = null,
                                    colorFilter = ColorFilter.tint(if (isDark) Color.White else Color(0xFF111318)),
                                    modifier = Modifier.size(24.dp),
                                )
                            }
                        }

                        // Right: Realm Switcher for own profile, or Share button for other users
                        if (isSelf) {
                            RealmSwitcher(
                                activeRealm = activeRealm,
                                onRealmSelected = { onRealmSelected?.invoke(it) },
                                hazeState = hazeState,
                            )
                        } else {
                            Box(
                                modifier = Modifier
                                    .size(44.dp)
                                    .shadow(
                                        elevation = 6.dp,
                                        shape = CircleShape,
                                        spotColor = Color.Black.copy(alpha = 0.35f),
                                    )
                                    .clip(CircleShape)
                                    .lightweightLiquidGlass(
                                        shape = CircleShape,
                                        fallbackColor = if (isDark) Color(0xCC181A22) else Color.White.copy(alpha = 0.92f),
                                    )
                                    .background(
                                        if (isDark) Color(0xCC181A22) else Color.White.copy(alpha = 0.92f),
                                        CircleShape,
                                    )
                                    .border(
                                        width = 1.dp,
                                        brush = Brush.verticalGradient(
                                            colors = listOf(
                                                Color.White.copy(alpha = 0.6f),
                                                Color.White.copy(alpha = 0.15f),
                                            )
                                        ),
                                        shape = CircleShape,
                                    )
                                    .liquidGlassButton(
                                        onClick = {
                                            val shareText = "Check out ${formatHandle(activeProfile.handle)}'s music profile on Vibra:\nhttps://vibramusic.app/u/${activeProfile.handle.removePrefix("@")}"
                                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                                putExtra(Intent.EXTRA_TEXT, shareText)
                                                type = "text/plain"
                                            }
                                            context.startActivity(Intent.createChooser(sendIntent, "Share Profile"))
                                        },
                                        haptic = Haptic.Tap,
                                        expandScale = 1.14f,
                                        pressScale = 0.91f,
                                    ),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Share,
                                    contentDescription = "Share",
                                    tint = if (isDark) Color.White else Color(0xFF111318),
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                    }
                }
            }

            // 2. Profile Details & Stats Row (reference image 2 & 5)
            item(key = "profile_identity_and_stats") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // Left Column: Name, Handle, Country/Age badges, Stacked Stats
                    Column(modifier = Modifier.weight(1f)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                text = activeProfile.displayName,
                                style = MaterialTheme.typography.titleLarge.copy(
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 22.sp,
                                ),
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (activeProfile.verifiedBadge) {
                                Icon(
                                    imageVector = Icons.Rounded.CheckCircle,
                                    contentDescription = "Verified",
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }

                        Text(
                            text = formatHandle(activeProfile.handle),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )

                        if (activeProfile.country.isNotBlank() || activeProfile.age != null) {
                            Spacer(Modifier.height(4.dp))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                if (activeProfile.country.isNotBlank()) {
                                    Box(
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(8.dp))
                                            .background(MaterialTheme.colorScheme.surfaceVariant)
                                            .padding(horizontal = 7.dp, vertical = 2.dp),
                                    ) {
                                        Text(
                                            text = activeProfile.country,
                                            style = MaterialTheme.typography.labelSmall.copy(
                                                fontWeight = FontWeight.SemiBold,
                                                fontSize = 10.sp,
                                            ),
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                                if (activeProfile.age != null) {
                                    Box(
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(8.dp))
                                            .background(MaterialTheme.colorScheme.surfaceVariant)
                                            .padding(horizontal = 7.dp, vertical = 2.dp),
                                    ) {
                                        Text(
                                            text = "${activeProfile.age} yrs",
                                            style = MaterialTheme.typography.labelSmall.copy(
                                                fontWeight = FontWeight.SemiBold,
                                                fontSize = 10.sp,
                                            ),
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }

                        Spacer(Modifier.height(14.dp))

                        // Stacked Stats Row (Following, Followers, Friends) - Clickable to open ConnectionsScreen
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(20.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            ProfileStatStacked(
                                count = activeProfile.followingCount,
                                label = "Following",
                                onClick = { activeConnectionsTab = ConnectionsTab.FOLLOWING },
                            )
                            ProfileStatStacked(
                                count = activeProfile.followersCount,
                                label = "Followers",
                                onClick = { activeConnectionsTab = ConnectionsTab.FOLLOWERS },
                            )
                            ProfileStatStacked(
                                count = activeProfile.friendsCount,
                                label = "Friends",
                                onClick = { activeConnectionsTab = ConnectionsTab.FRIENDS },
                            )
                        }
                    }

                    Spacer(Modifier.width(14.dp))

                    // Right Column: Comic Thought Bubble and Avatar (reference image 5)
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.width(104.dp),
                    ) {
                        ComicThoughtBubble(
                            status = activeProfile.statusBubble,
                            onClick = if (isSelf) { { showEditStatusDialog = true } } else null,
                        )

                        Box(
                            modifier = Modifier
                                .size(86.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                                .border(2.dp, MaterialTheme.colorScheme.surfaceVariant, CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            if (!activeProfile.avatarUrl.isNullOrBlank() && activeProfile.avatarUrl != "null") {
                                AsyncImage(
                                    model = activeProfile.avatarUrl,
                                    contentDescription = activeProfile.displayName,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            } else {
                                Icon(
                                    imageVector = Icons.Rounded.Person,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(44.dp),
                                )
                            }
                        }
                    }
                }
            }

            // 3. Action Buttons Row (reference image 2 & 3)
            item(key = "profile_action_buttons") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (!isSelf) {
                        val followButtonText = when {
                            activeProfile.isFriend -> "Friends"
                            activeProfile.isFollowing -> "Following"
                            else -> "Follow"
                        }
                        Button(
                            onClick = { viewModel.toggleFollowUser(activeProfile.id) },
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (activeProfile.isFollowing || activeProfile.isFriend) {
                                    MaterialTheme.colorScheme.surfaceVariant
                                } else {
                                    MaterialTheme.colorScheme.primary
                                },
                                contentColor = if (activeProfile.isFollowing || activeProfile.isFriend) {
                                    MaterialTheme.colorScheme.onSurface
                                } else {
                                    MaterialTheme.colorScheme.onPrimary
                                },
                            ),
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(vertical = 11.dp),
                        ) {
                            Text(
                                text = followButtonText,
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                            )
                        }

                        Button(
                            onClick = {
                                viewModel.openChat(activeProfile)
                                viewModel.setNavTab(SocialTab.MESSAGES)
                                onBack?.invoke()
                            },
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                                contentColor = MaterialTheme.colorScheme.onSurface,
                            ),
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(vertical = 11.dp),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.Send,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "Message",
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                            )
                        }

                        IconButton(
                            onClick = { showSuggestedCarousel = !showSuggestedCarousel },
                            modifier = Modifier
                                .size(44.dp)
                                .clip(RoundedCornerShape(14.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)),
                        ) {
                            Icon(
                                imageVector = if (showSuggestedCarousel) Icons.Rounded.KeyboardArrowUp else Icons.Rounded.KeyboardArrowDown,
                                contentDescription = "Suggested",
                                tint = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    } else {
                        Button(
                            onClick = { showEditProfile = true },
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                                contentColor = MaterialTheme.colorScheme.onSurface,
                            ),
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(vertical = 11.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Edit,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "Edit Profile",
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                            )
                        }

                        Button(
                            onClick = {
                                val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                    putExtra(
                                        Intent.EXTRA_TEXT,
                                        "Check out ${formatHandle(activeProfile.handle)}'s music profile on Vibra:\nhttps://vibramusic.app/u/${activeProfile.handle.removePrefix("@")}",
                                    )
                                    type = "text/plain"
                                }
                                context.startActivity(Intent.createChooser(sendIntent, "Share Profile"))
                            },
                            shape = RoundedCornerShape(14.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                                contentColor = MaterialTheme.colorScheme.onSurface,
                            ),
                            modifier = Modifier.weight(1f),
                            contentPadding = PaddingValues(vertical = 11.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Share,
                                contentDescription = null,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "Share",
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                            )
                        }
                    }
                }
            }

            // 4. Expandable Suggested Accounts Carousel (reference image 3)
            if (showSuggestedCarousel && suggestedUsers.isNotEmpty()) {
                item(key = "suggested_accounts_section") {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Suggested accounts",
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            Text(
                                text = "View all >",
                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier
                                    .clickable { activeConnectionsTab = ConnectionsTab.SUGGESTED }
                                    .padding(vertical = 4.dp),
                            )
                        }

                        Spacer(Modifier.height(8.dp))

                        LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                            contentPadding = PaddingValues(vertical = 4.dp),
                        ) {
                            items(suggestedUsers, key = { it.id }) { suggested ->
                                SuggestedAccountCard(
                                    profile = suggested,
                                    onOpen = { viewModel.openUserProfile(suggested) },
                                    onFollow = { viewModel.toggleFollowUser(suggested.id, suggested) },
                                )
                            }
                        }
                    }
                }
            }

            // 5. Bio Description
            if (!activeProfile.bio.isNullOrBlank()) {
                item(key = "profile_bio") {
                    Text(
                        text = activeProfile.bio,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(horizontal = 20.dp),
                        maxLines = 4,
                    )
                }
            }

            // Favorite Artists Section
            item(key = "favorite_artists_header") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "Favorite Artists",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    Spacer(Modifier.height(10.dp))

                    val effectiveFavoriteArtists = if (favoriteArtists.isNotEmpty()) {
                        favoriteArtists
                    } else if (!isSelf) {
                        VERIFIED_CURATED_ARTISTS.take(4)
                    } else {
                        emptyList()
                    }

                    if (effectiveFavoriteArtists.isEmpty() && !isSelf) {
                        Text(
                            text = "No favorite artists chosen yet.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(14.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            itemsIndexed(
                                items = effectiveFavoriteArtists.distinctBy { it.id },
                                key = { index, artist -> "fav_artist_${artist.id.ifBlank { index.toString() }}_$index" },
                            ) { _, artist ->
                                val resolvedId = if (artist.name.equals("Drake", ignoreCase = true) && (artist.id == "UC0C-w0YjGpqDXGB8Tr0GGyA" || artist.id.isBlank())) {
                                    "UCU6cE7pdJPc6DU2jSrKEsdQ"
                                } else {
                                    artist.id
                                }
                                FavoriteArtistCard(
                                    artist = artist.copy(id = resolvedId),
                                    onClick = {
                                        if (onOpenArtistDetail != null) {
                                            onOpenArtistDetail(resolvedId, artist.name, artist.artworkUrl)
                                        } else {
                                            onArtistQuizClick(artist.copy(id = resolvedId))
                                        }
                                    },
                                )
                            }

                            if (isSelf) {
                                item(key = "add_artist_button") {
                                    Column(
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        modifier = Modifier
                                            .width(84.dp)
                                            .clip(RoundedCornerShape(14.dp))
                                            .clickable { showAddArtistScreen = true }
                                            .padding(6.dp),
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(68.dp)
                                                .clip(CircleShape)
                                                .background(MaterialTheme.colorScheme.surfaceVariant),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.Add,
                                                contentDescription = "Add Artist",
                                                tint = MaterialTheme.colorScheme.primary,
                                                modifier = Modifier.size(32.dp),
                                            )
                                        }
                                        Spacer(Modifier.height(6.dp))
                                        Text(
                                            text = "Add Artist",
                                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                            color = MaterialTheme.colorScheme.primary,
                                            maxLines = 1,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Sub-tabs: Posts / Reposts / Quiz Records
            item(key = "profile_subtabs") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    listOf("Posts", "Reposts", "Quiz Records").forEach { tab ->
                        val selected = selectedSubTab == tab
                        Text(
                            text = tab,
                            style = MaterialTheme.typography.titleSmall.copy(
                                fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                            ),
                            color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { selectedSubTab = tab }
                                .padding(vertical = 4.dp, horizontal = 8.dp),
                        )
                    }
                }
            }

            // Content based on sub-tab
            val filteredPosts = when (selectedSubTab) {
                "Reposts" -> posts.filter { it.repostOfId != null || it.repostOf != null }
                "Posts" -> posts.filter { it.repostOfId == null && it.repostOf == null }
                else -> emptyList()
            }

            if (selectedSubTab == "Posts" || selectedSubTab == "Reposts") {
                if (filteredPosts.isEmpty()) {
                    item(key = "empty_user_posts_$selectedSubTab") {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 24.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = if (selectedSubTab == "Reposts") "No reposts yet." else "No posts yet.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                } else {
                    itemsIndexed(
                        items = filteredPosts.distinctBy { it.id },
                        key = { index, post -> "user_post_${post.id.ifBlank { index.toString() }}_$index" },
                    ) { _, post ->
                        val targetPost = post.repostOf?.takeIf { post.content.isBlank() } ?: post
                        SocialPostCard(
                            post = post,
                            onLikeClick = { viewModel.toggleLike(targetPost) },
                            onCommentClick = { viewModel.openComments(targetPost) },
                            onRepostClick = { viewModel.repost(targetPost) },
                            onMediaClick = { list, idx -> activeMediaViewer = Pair(list, idx) },
                            onShareClick = {
                                val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                    putExtra(
                                        Intent.EXTRA_TEXT,
                                        "Check out @${targetPost.authorHandle}'s music post on Vibra:\n\n${targetPost.content}",
                                    )
                                    type = "text/plain"
                                }
                                context.startActivity(Intent.createChooser(sendIntent, "Share Post"))
                            },
                            onPlayTrack = onPlayTrack,
                            onVotePoll = { viewModel.votePoll(targetPost, it) },
                            onAuthorClick = {
                                val target = post.author ?: SocialProfile(
                                    id = post.authorId,
                                    handle = post.authorHandle,
                                    displayName = post.authorName,
                                    avatarUrl = post.authorAvatar,
                                    verifiedBadge = post.authorVerified,
                                )
                                if (target.id != activeProfile.id) {
                                    viewModel.openUserProfile(target)
                                }
                            },
                            onOpenProfile = { profile ->
                                if (profile.id != activeProfile.id) {
                                    viewModel.openUserProfile(profile)
                                }
                            },
                            onTaggedArtistClick = { artistName ->
                                coroutineScope.launch {
                                    val resolved = YtMusicRepository.resolveArtist(artistName)
                                    val browseId = resolved?.first ?: artistName
                                    val artwork = resolved?.second
                                    onOpenArtistDetail?.invoke(browseId, artistName, artwork)
                                }
                            },
                            onEditClick = if (isSelf && isWithinEditWindow(post.createdAt, 10L)) {
                                {
                                    editingPost = post
                                    editPostContent = post.content
                                }
                            } else null,
                            onDeleteClick = if (isSelf) {
                                { postToDelete = post }
                            } else null,
                            onQuoteClick = { quoted ->
                                val target = quoted.author ?: SocialProfile(
                                    id = quoted.authorId,
                                    handle = quoted.authorHandle,
                                    displayName = quoted.authorName,
                                    avatarUrl = quoted.authorAvatar,
                                    verifiedBadge = quoted.authorVerified,
                                )
                                viewModel.openUserProfile(target)
                            },
                            onMentionClick = { handle ->
                                viewModel.openUserProfileByHandle(handle)
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp),
                        )
                    }
                }
            } else {
                // Quiz Records Tab
                item(key = "quiz_records") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(20.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Rounded.Star,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(36.dp),
                            )
                            Spacer(Modifier.height(8.dp))
                            Text(
                                text = "Music Quiz Master",
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Play artist song quizzes to earn badges and claim the top of the leaderboards!",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }

        if (showEditProfile) {
            EditProfileSheet(
                profile = activeProfile,
                onDismiss = { showEditProfile = false },
                onSaveProfile = { name, handle, bio, avatar, country, age, statusBubble, bannerPlaylists, bannerUrl ->
                    viewModel.updateUserProfile(
                        displayName = name,
                        handle = handle,
                        bio = bio,
                        avatarUrl = avatar,
                        country = country,
                        age = age,
                        statusBubble = statusBubble,
                        bannerPlaylists = bannerPlaylists,
                        bannerUrl = bannerUrl,
                    )
                },
            )
        }

        editingPost?.let { targetPost ->
            AlertDialog(
                onDismissRequest = { editingPost = null },
                title = { Text("Edit Post", fontWeight = FontWeight.Bold) },
                text = {
                    OutlinedTextField(
                        value = editPostContent,
                        onValueChange = { editPostContent = it },
                        label = { Text("Content") },
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                    )
                },
                confirmButton = {
                    Button(
                        onClick = {
                            val trimmed = editPostContent.trim()
                            if (trimmed.isNotBlank()) {
                                viewModel.editPost(targetPost.id, trimmed) {
                                    editingPost = null
                                }
                            }
                        },
                    ) {
                        Text("Save")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { editingPost = null }) {
                        Text("Cancel")
                    }
                },
            )
        }

        if (showAddArtistScreen) {
            AddFavoriteArtistScreen(
                onDismiss = { showAddArtistScreen = false },
                onAddArtist = { newArtist ->
                    viewModel.addFavoriteArtist(newArtist)
                },
                existingArtistIds = favoriteArtists.map { it.id }.toSet(),
            )
        }

        activeConnectionsTab?.let { tab ->
            ConnectionsScreen(
                userHandle = activeProfile.handle,
                initialTab = tab,
                followingList = followingList,
                followersList = followersList,
                friendsList = friendsList,
                suggestedList = suggestedUsers,
                currentUserId = currentProfile?.id ?: "",
                onBack = { activeConnectionsTab = null },
                onOpenProfile = { clickedProfile ->
                    activeConnectionsTab = null
                    viewModel.openUserProfile(clickedProfile)
                },
                onToggleFollow = { targetUser ->
                    viewModel.toggleFollowUser(targetUser.id, targetUser)
                },
            )
        }

        if (showEditStatusDialog) {
            var newStatus by remember { mutableStateOf(activeProfile.statusBubble ?: "") }
            AlertDialog(
                onDismissRequest = { showEditStatusDialog = false },
                containerColor = MaterialTheme.colorScheme.surface,
                title = {
                    Text(
                        text = "Update Status",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                },
                text = {
                    OutlinedTextField(
                        value = newStatus,
                        onValueChange = { if (it.length <= 40) newStatus = it },
                        placeholder = { Text("What's on your mind? (max 40 chars)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                    )
                },
                confirmButton = {
                    Button(
                        onClick = {
                            viewModel.updateStatusBubble(newStatus.trim())
                            showEditStatusDialog = false
                        },
                        shape = RoundedCornerShape(10.dp),
                    ) {
                        Text("Save")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showEditStatusDialog = false }) {
                        Text("Cancel")
                    }
                },
            )
        }

        // Delete Post Confirmation Dialog
        postToDelete?.let { target ->
            AlertDialog(
                onDismissRequest = { postToDelete = null },
                containerColor = MaterialTheme.colorScheme.surface,
                title = {
                    Text(
                        text = "Delete post",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                },
                text = {
                    Text(
                        text = "Are you sure you want to delete this post? This action cannot be undone.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                },
                confirmButton = {
                    ElevatedButton(
                        onClick = {
                            viewModel.deletePost(target)
                            postToDelete = null
                        },
                        colors = ButtonDefaults.elevatedButtonColors(
                            containerColor = MaterialTheme.colorScheme.error,
                            contentColor = MaterialTheme.colorScheme.onError,
                        ),
                        shape = RoundedCornerShape(12.dp),
                    ) {
                        Text("Delete", fontWeight = FontWeight.Bold)
                    }
                },
                dismissButton = {
                    ElevatedButton(
                        onClick = { postToDelete = null },
                        colors = ButtonDefaults.elevatedButtonColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant,
                            contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                        ),
                        shape = RoundedCornerShape(12.dp),
                    ) {
                        Text("Cancel")
                    }
                },
            )
        }

        // Fullscreen Multi-Media Viewer Dialog
        activeMediaViewer?.let { (mediaList, idx) ->
            FullScreenMediaViewerDialog(
                mediaList = mediaList,
                initialIndex = idx,
                onDismiss = { activeMediaViewer = null },
            )
        }

        // Inspected Quoted Post Modal Dialog
        inspectedQuotedPost?.let { quoted ->
            Dialog(
                onDismissRequest = { inspectedQuotedPost = null },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(MaterialTheme.colorScheme.surface)
                        .systemBarsPadding(),
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(bottom = 12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Quoted Post",
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            IconButton(onClick = { inspectedQuotedPost = null }) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Close",
                                    tint = MaterialTheme.colorScheme.onSurface,
                                )
                            }
                        }

                        SocialPostCard(
                            post = quoted,
                            onLikeClick = { viewModel.toggleLike(quoted) },
                            onCommentClick = {
                                inspectedQuotedPost = null
                                viewModel.openComments(quoted)
                            },
                            onRepostClick = {
                                inspectedQuotedPost = null
                                viewModel.repost(quoted)
                            },
                            onShareClick = {
                                val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                    putExtra(
                                        Intent.EXTRA_TEXT,
                                        "Check out @${quoted.authorHandle}'s post on Vibra:\n\n${quoted.content}",
                                    )
                                    type = "text/plain"
                                }
                                context.startActivity(Intent.createChooser(sendIntent, "Share Post"))
                            },
                            onPlayTrack = onPlayTrack,
                            onVotePoll = { viewModel.votePoll(quoted, it) },
                            onAuthorClick = {},
                            onTaggedArtistClick = { artistName ->
                                inspectedQuotedPost = null
                                coroutineScope.launch {
                                    val resolved = YtMusicRepository.resolveArtist(artistName)
                                    val browseId = resolved?.first ?: artistName
                                    val artwork = resolved?.second
                                    onOpenArtistDetail?.invoke(browseId, artistName, artwork)
                                }
                            },
                            onMentionClick = { handle ->
                                inspectedQuotedPost = null
                                viewModel.openUserProfileByHandle(handle)
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }

        // Dedicated Twitter (X) style Post Thread Screen when user expands a post
        selectedPostForComments?.let { post ->
            PostThreadScreen(
                post = post,
                comments = comments,
                currentProfile = currentProfile,
                onBack = { viewModel.closeComments() },
                onLikePost = { viewModel.toggleLike(it) },
                onRepostPost = {
                    if (it.isRepostedByMe) {
                        viewModel.toggleRepost(it)
                    } else {
                        viewModel.repost(it)
                    }
                },
                onEditPost = { postId, newContent ->
                    viewModel.editPost(postId, newContent)
                },
                onDeletePost = { targetPost ->
                    viewModel.deletePost(targetPost)
                    viewModel.closeComments()
                },
                onAddComment = { content, parentId, imageUrl, videoUrl, gifUrl ->
                    viewModel.addComment(post.id, content, parentId, imageUrl, videoUrl, gifUrl)
                },
                onToggleLikeComment = { viewModel.toggleLikeComment(it) },
                onEditComment = { commentId, newContent ->
                    viewModel.editComment(commentId, newContent)
                },
                onDeleteComment = { commentId, postId ->
                    viewModel.deleteComment(commentId, postId)
                },
                onOpenProfile = { clickedProfile ->
                    viewModel.closeComments()
                    if (clickedProfile.id != activeProfile.id) {
                        viewModel.openUserProfile(clickedProfile)
                    }
                },
                onPlayTrack = onPlayTrack,
                onMediaClick = { list, idx ->
                    activeMediaViewer = Pair(list, idx)
                },
                onMentionClick = { handle ->
                    viewModel.closeComments()
                    viewModel.openUserProfileByHandle(handle)
                },
                onVotePoll = { optionIdx ->
                    viewModel.votePoll(post, optionIdx)
                },
                onQuoteClick = { quoted ->
                    viewModel.openComments(quoted)
                },
            )
        }
    }
}

@Composable
private fun ProfileStatItem(
    count: Int,
    label: String,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = count.toString(),
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun FavoriteArtistCard(
    artist: QuizArtist,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .width(88.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(6.dp),
    ) {
        ArtistAvatar(
            artistName = artist.name,
            artworkUrl = artist.artworkUrl,
            size = 68.dp,
        )

        Spacer(Modifier.height(6.dp))

        Text(
            text = artist.name,
            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Medium),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ProfileStatStacked(
    count: Int,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 2.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        Text(
            text = count.toString(),
            style = MaterialTheme.typography.titleMedium.copy(
                fontWeight = FontWeight.Bold,
                fontSize = 16.sp,
            ),
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall.copy(
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ComicThoughtBubble(
    status: String?,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val bubbleText = status?.takeIf { it.isNotBlank() } ?: if (onClick != null) "+ Status" else null

    if (bubbleText != null) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = modifier
                .padding(bottom = 4.dp)
                .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        ) {
            // Main Cloud/Bubble Body
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.85f))
                    .border(
                        1.dp,
                        MaterialTheme.colorScheme.primary.copy(alpha = 0.35f),
                        RoundedCornerShape(16.dp),
                    )
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = bubbleText,
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontWeight = FontWeight.Medium,
                        fontSize = 11.sp,
                    ),
                    color = if (status.isNullOrBlank()) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                    maxLines = 2,
                    textAlign = TextAlign.Center,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Spacer(Modifier.height(2.dp))

            // Comic thought bubble trailing dots (graduating descending dots towards avatar)
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.padding(top = 2.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(5.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                )
                Box(
                    modifier = Modifier
                        .size(3.5.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.8f)),
                )
                Box(
                    modifier = Modifier
                        .size(2.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)),
                )
            }
        }
    } else {
        Spacer(Modifier.height(18.dp))
    }
}

@Composable
private fun SuggestedAccountCard(
    profile: SocialProfile,
    onOpen: () -> Unit,
    onFollow: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .width(130.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
            .border(
                1.dp,
                MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                RoundedCornerShape(16.dp),
            )
            .clickable(onClick = onOpen)
            .padding(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier
                .size(52.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
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
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(28.dp),
                )
            }
        }

        Spacer(Modifier.height(8.dp))

        Text(
            text = profile.displayName,
            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )

        Text(
            text = formatHandle(profile.handle),
            style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(10.dp))

        Button(
            onClick = onFollow,
            shape = RoundedCornerShape(10.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (profile.isFollowing) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.primary,
                contentColor = if (profile.isFollowing) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onPrimary,
            ),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
            modifier = Modifier
                .fillMaxWidth()
                .height(32.dp),
        ) {
            Text(
                text = if (profile.isFollowing) "Following" else "Follow",
                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
            )
        }
    }
}

private data class VideoBannerTransform(
    val rotation: Float = 0f,
    val scale: Float = 1f,
    val panX: Float = 0f,
    val panY: Float = 0f,
)

private fun extractVideoBannerTransforms(videoUrl: String): VideoBannerTransform {
    val uri = runCatching { android.net.Uri.parse(videoUrl) }.getOrNull()
    val rot = uri?.getQueryParameter("rot")?.toFloatOrNull() ?: 0f
    val scale = uri?.getQueryParameter("scale")?.toFloatOrNull() ?: 1f
    val panX = uri?.getQueryParameter("panX")?.toFloatOrNull() ?: 0f
    val panY = uri?.getQueryParameter("panY")?.toFloatOrNull() ?: 0f
    return VideoBannerTransform(rot, scale, panX, panY)
}

@Composable
private fun ProfileBannerVideo(videoUrl: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val transforms = remember(videoUrl) { extractVideoBannerTransforms(videoUrl) }
    val exoPlayer = remember(videoUrl) {
        ExoPlayer.Builder(context.applicationContext).build().apply {
            repeatMode = Player.REPEAT_MODE_ALL
            volume = 0f
            setMediaItem(MediaItem.fromUri(videoUrl))
            prepare()
            playWhenReady = true
        }
    }
    DisposableEffect(exoPlayer) {
        onDispose {
            exoPlayer.release()
        }
    }
    Box(
        modifier = modifier
            .fillMaxSize()
            .clipToBounds(),
        contentAlignment = Alignment.Center,
    ) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    player = exoPlayer
                    useController = false
                    resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                    layoutParams = FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                }
            },
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    rotationZ = transforms.rotation
                    scaleX = transforms.scale
                    scaleY = transforms.scale
                    translationX = transforms.panX
                    translationY = transforms.panY
                },
        )
    }
}

