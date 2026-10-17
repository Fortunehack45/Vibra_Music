package com.fortune.vibramusic.ui.social

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
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.LocationOn
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PersonAdd
import androidx.compose.material.icons.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ElevatedButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PostMediaItem
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.ui.components.ArtistAvatar
import androidx.compose.foundation.layout.statusBarsPadding
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
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.social.SocialPost
import kotlinx.coroutines.launch
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource

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
    contentPadding: PaddingValues,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val coroutineScope = rememberCoroutineScope()
    val currentProfile by viewModel.currentProfile.collectAsStateWithLifecycle()
    val viewingProfile by viewModel.viewingProfile.collectAsStateWithLifecycle()
    val activeProfile = if (isSelf) (currentProfile ?: profile) else (viewingProfile?.takeIf { it.id == profile.id } ?: profile)

    val posts by viewModel.viewingProfilePosts.collectAsStateWithLifecycle()
    val favoriteArtists by viewModel.favoriteArtists.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var selectedSubTab by remember { mutableStateOf("Posts") }
    var showEditProfile by remember { mutableStateOf(false) }
    var showAddArtistDialog by remember { mutableStateOf(false) }
    var postToDelete by remember { mutableStateOf<SocialPost?>(null) }
    var inspectedQuotedPost by remember { mutableStateOf<SocialPost?>(null) }
    var activeMediaViewer by remember { mutableStateOf<Pair<List<PostMediaItem>, Int>?>(null) }

    LaunchedEffect(activeProfile.id) {
        if (activeProfile.id.isNotBlank() && activeProfile.id != "me") {
            viewModel.loadProfileData(activeProfile.id)
        }
    }

    Box(
        modifier = modifier.fillMaxSize(),
    ) {
        val topPadding = if (onBack != null && !isSelf) 0.dp else (contentPadding.calculateTopPadding() + 8.dp)

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                top = topPadding,
                bottom = contentPadding.calculateBottomPadding() + 80.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Header Bar (Back button only if viewing another user's profile)
            if (onBack != null && !isSelf) {
                item(key = "back_nav") {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .statusBarsPadding()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        IconButton(
                            onClick = onBack,
                            modifier = Modifier
                                .size(38.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.surfaceVariant),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                                contentDescription = "Back",
                                tint = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(
                                text = activeProfile.displayName,
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                text = formatHandle(activeProfile.handle),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }

            // Profile Card Header (Solid Surface with Banner & Status Bubble)
            item(key = "profile_header") {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp)
                        .clip(RoundedCornerShape(24.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                ) {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        // 1. Banner Playlists Showcase (Up to 15 covers)
                        if (activeProfile.bannerPlaylists.isNotEmpty()) {
                            LazyRow(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(116.dp)
                                    .background(MaterialTheme.colorScheme.surface),
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                itemsIndexed(
                                    items = activeProfile.bannerPlaylists.take(15),
                                    key = { index, entry -> "banner_${entry.hashCode()}_$index" },
                                ) { _, entry ->
                                    val parts = entry.split("|")
                                    val pId = if (parts.size >= 3) parts[0] else ""
                                    val pTitle = if (parts.size >= 3) parts[1] else "Playlist"
                                    val pThumb = if (parts.size >= 3) parts[2] else entry

                                    Box(
                                        modifier = Modifier
                                            .width(100.dp)
                                            .fillMaxHeight()
                                            .clip(RoundedCornerShape(12.dp))
                                            .background(MaterialTheme.colorScheme.surfaceVariant)
                                            .clickable {
                                                if (pId.isNotBlank()) {
                                                    if (onOpenPlaylist != null) {
                                                        onOpenPlaylist(pId, pTitle, pThumb)
                                                    } else {
                                                        onOpenArtistDetail?.invoke(pId, pTitle, pThumb)
                                                    }
                                                }
                                            },
                                    ) {
                                        AsyncImage(
                                            model = pThumb,
                                            contentDescription = pTitle,
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier.fillMaxSize(),
                                        )
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .align(Alignment.BottomCenter)
                                                .background(
                                                    Brush.verticalGradient(
                                                        colors = listOf(Color.Transparent, Color(0xCC000000)),
                                                    ),
                                                )
                                                .padding(horizontal = 6.dp, vertical = 4.dp),
                                        ) {
                                            Row(
                                                modifier = Modifier.fillMaxWidth(),
                                                horizontalArrangement = Arrangement.SpaceBetween,
                                                verticalAlignment = Alignment.CenterVertically,
                                            ) {
                                                Text(
                                                    text = pTitle,
                                                    style = MaterialTheme.typography.labelSmall.copy(
                                                        fontWeight = FontWeight.SemiBold,
                                                        fontSize = 10.sp,
                                                    ),
                                                    color = Color.White,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis,
                                                    modifier = Modifier.weight(1f),
                                                )
                                                Spacer(Modifier.width(4.dp))
                                                Icon(
                                                    imageVector = Icons.Rounded.PlayArrow,
                                                    contentDescription = "Play",
                                                    tint = Color.White,
                                                    modifier = Modifier.size(14.dp),
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        } else if (isSelf) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(80.dp)
                                    .background(MaterialTheme.colorScheme.surface)
                                    .clickable { showEditProfile = true }
                                    .padding(horizontal = 16.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.QueueMusic,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(20.dp),
                                    )
                                    Text(
                                        text = "Tap to add up to 15 playlist covers to banner",
                                        style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }

                        // 2. Profile Details & Avatar
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp, vertical = 18.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            // Avatar & Authentic Thought Bubble Status
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                if (activeProfile.statusBubble.isNotBlank()) {
                                    Column(
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        modifier = Modifier.padding(bottom = 6.dp),
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(16.dp))
                                                .background(Color(0xFF232631))
                                                .padding(horizontal = 14.dp, vertical = 7.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Text(
                                                text = activeProfile.statusBubble,
                                                style = MaterialTheme.typography.labelSmall.copy(
                                                    fontWeight = FontWeight.SemiBold,
                                                    fontSize = 12.sp,
                                                ),
                                                color = Color.White,
                                                maxLines = 2,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                        }
                                        Spacer(Modifier.height(3.dp))
                                        Box(
                                            modifier = Modifier
                                                .size(7.dp)
                                                .clip(CircleShape)
                                                .background(Color(0xFF232631)),
                                        )
                                        Spacer(Modifier.height(2.dp))
                                        Box(
                                            modifier = Modifier
                                                .size(4.dp)
                                                .clip(CircleShape)
                                                .background(Color(0xFF232631)),
                                        )
                                    }
                                }

                                Box(
                                    modifier = Modifier
                                        .size(90.dp)
                                        .clip(CircleShape)
                                        .background(MaterialTheme.colorScheme.surface),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (!activeProfile.avatarUrl.isNullOrBlank() && activeProfile.avatarUrl != "null") {
                                        AsyncImage(
                                            model = activeProfile.avatarUrl,
                                            contentDescription = null,
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

                            Spacer(Modifier.height(12.dp))

                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Text(
                                    text = activeProfile.displayName,
                                    style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
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

                            // Country & Age Badges
                            if (activeProfile.country.isNotBlank() || activeProfile.age != null) {
                                Spacer(Modifier.height(6.dp))
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    if (activeProfile.country.isNotBlank()) {
                                        Box(
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(MaterialTheme.colorScheme.surface)
                                                .padding(horizontal = 8.dp, vertical = 3.dp),
                                        ) {
                                            Text(
                                                text = activeProfile.country,
                                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            )
                                        }
                                    }
                                    if (activeProfile.age != null) {
                                        Box(
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(MaterialTheme.colorScheme.surface)
                                                .padding(horizontal = 8.dp, vertical = 3.dp),
                                        ) {
                                            Text(
                                                text = "${activeProfile.age} yrs",
                                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            )
                                        }
                                    }
                                }
                            }

                            if (!activeProfile.bio.isNullOrBlank()) {
                                Spacer(Modifier.height(8.dp))
                                Text(
                                    text = activeProfile.bio,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    maxLines = 3,
                                )
                            }

                        Spacer(Modifier.height(16.dp))

                        // Stats Row
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceEvenly,
                        ) {
                            ProfileStatItem(count = activeProfile.followingCount, label = "Following")
                            ProfileStatItem(count = activeProfile.followersCount, label = "Followers")
                            ProfileStatItem(count = activeProfile.friendsCount, label = "Friends")
                        }

                        Spacer(Modifier.height(18.dp))

                        // Action Buttons
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            if (!isSelf) {
                                Button(
                                    onClick = { viewModel.toggleFollowUser(activeProfile.id) },
                                    shape = RoundedCornerShape(12.dp),
                                    border = null,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = if (activeProfile.isFollowing) MaterialTheme.colorScheme.surface
                                        else MaterialTheme.colorScheme.primary,
                                        contentColor = if (activeProfile.isFollowing) MaterialTheme.colorScheme.onSurface
                                        else MaterialTheme.colorScheme.onPrimary,
                                    ),
                                    modifier = Modifier.weight(1f),
                                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 10.dp),
                                ) {
                                    Text(
                                        text = if (activeProfile.isFollowing) "Following" else "Follow",
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                    )
                                }

                                val isFriend = activeProfile.isFriend || activeProfile.friendshipStatus.equals("ACCEPTED", ignoreCase = true)
                                val isRequested = activeProfile.friendshipStatus.equals("PENDING", ignoreCase = true)
                                val friendText = when {
                                    isFriend -> "Friends"
                                    isRequested -> "Requested"
                                    else -> "Add Friend"
                                }

                                Button(
                                    onClick = {
                                        if (!isFriend && !isRequested) {
                                            viewModel.sendFriendRequest(activeProfile.id)
                                        }
                                    },
                                    shape = RoundedCornerShape(12.dp),
                                    border = null,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = if (isFriend) MaterialTheme.colorScheme.surfaceVariant
                                        else MaterialTheme.colorScheme.surface,
                                        contentColor = if (isFriend) MaterialTheme.colorScheme.primary
                                        else MaterialTheme.colorScheme.onSurface,
                                    ),
                                    modifier = Modifier.weight(1f),
                                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 10.dp),
                                ) {
                                    Icon(
                                        imageVector = if (isFriend) Icons.Rounded.CheckCircle else Icons.Rounded.PersonAdd,
                                        contentDescription = null,
                                        modifier = Modifier.size(15.dp),
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Text(
                                        text = friendText,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                    )
                                }

                                Button(
                                    onClick = {
                                        viewModel.openChat(activeProfile)
                                        viewModel.setNavTab(SocialTab.MESSAGES)
                                        onBack?.invoke()
                                    },
                                    shape = RoundedCornerShape(12.dp),
                                    border = null,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = MaterialTheme.colorScheme.surface,
                                        contentColor = MaterialTheme.colorScheme.onSurface,
                                    ),
                                    modifier = Modifier.weight(1f),
                                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 10.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Rounded.Send,
                                        contentDescription = null,
                                        modifier = Modifier.size(15.dp),
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Text(
                                        text = "Message",
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                    )
                                }
                            }

                            if (isSelf) {
                                Button(
                                    onClick = { showEditProfile = true },
                                    shape = RoundedCornerShape(12.dp),
                                    border = null,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = MaterialTheme.colorScheme.surface,
                                        contentColor = MaterialTheme.colorScheme.onSurface,
                                    ),
                                    modifier = Modifier.weight(1f),
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Edit,
                                        contentDescription = null,
                                        modifier = Modifier.size(16.dp),
                                    )
                                    Spacer(Modifier.width(6.dp))
                                    Text(
                                        text = "Edit Profile",
                                        fontSize = 13.sp,
                                        maxLines = 1,
                                    )
                                }
                            }

                            // Share Profile Button
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
                                shape = RoundedCornerShape(12.dp),
                                border = null,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = MaterialTheme.colorScheme.surface,
                                    contentColor = MaterialTheme.colorScheme.onSurface,
                                ),
                                modifier = Modifier.weight(1f),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Share,
                                    contentDescription = null,
                                    modifier = Modifier.size(16.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    text = "Share",
                                    fontSize = 13.sp,
                                    maxLines = 1,
                                )
                            }
                        }
                    }
                }
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
                        if (isSelf) {
                            Text(
                                text = "+ Add",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(6.dp))
                                    .clickable { showAddArtistDialog = true }
                                    .padding(horizontal = 8.dp, vertical = 4.dp),
                            )
                        }
                    }
                    Spacer(Modifier.height(10.dp))

                    if (favoriteArtists.isEmpty() && !isSelf) {
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
                            if (isSelf) {
                                item(key = "add_artist_button") {
                                    Column(
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        modifier = Modifier
                                            .width(84.dp)
                                            .clip(RoundedCornerShape(14.dp))
                                            .clickable { showAddArtistDialog = true }
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

                            itemsIndexed(
                                items = favoriteArtists.distinctBy { it.id },
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
                onSaveProfile = { name, handle, bio, avatar, country, age, statusBubble, bannerPlaylists ->
                    viewModel.updateUserProfile(
                        displayName = name,
                        handle = handle,
                        bio = bio,
                        avatarUrl = avatar,
                        country = country,
                        age = age,
                        statusBubble = statusBubble,
                        bannerPlaylists = bannerPlaylists,
                    )
                },
            )
        }

        if (showAddArtistDialog) {
            AddFavoriteArtistDialog(
                onDismiss = { showAddArtistDialog = false },
                onAddArtist = { newArtist ->
                    viewModel.addFavoriteArtist(newArtist)
                },
                existingArtistIds = favoriteArtists.map { it.id }.toSet(),
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
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
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
private fun AddFavoriteArtistDialog(
    onDismiss: () -> Unit,
    onAddArtist: (QuizArtist) -> Unit,
    existingArtistIds: Set<String>,
) {
    var searchQuery by remember { mutableStateOf("") }
    var searchResults by remember { mutableStateOf<List<QuizArtist>>(emptyList()) }
    var isSearching by remember { mutableStateOf(false) }

    val curatedArtists = remember {
        listOf(
            QuizArtist("UCU6cE7pdJPc6DU2jSrKEsdQ", "Drake", "https://lh3.googleusercontent.com/9t5_vY2mN4sB2lqT2r9x1cQ5p3w4e5r6t7y8u9i0o1p2a3s4d5f6g7h8j9k0l=w544-h544-l90-rj"),
            QuizArtist("UCPC0L1d253x-KuMNwa05TpA", "Taylor Swift", "https://lh3.googleusercontent.com/WpP8zK1eB34vA9Bq08b3l5v9dE=w544-h544-l90-rj"),
            QuizArtist("UCr61sufuLt7_eB7ak1bXHIg", "Burna Boy", "https://lh3.googleusercontent.com/e2E4eJ3iA6f9=w544-h544-l90-rj"),
            QuizArtist("UClYV6hHlupm_S_ObS1W-DYw", "The Weeknd", "https://lh3.googleusercontent.com/d7y0n9a5=w544-h544-l90-rj"),
            QuizArtist("UCprAFmT0C6O4X0ToEXpeFTQ", "Kendrick Lamar", "https://lh3.googleusercontent.com/k9l0m1=w544-h544-l90-rj"),
            QuizArtist("UCERrDZ8oN0U_n9MphMKERcg", "Billie Eilish", "https://lh3.googleusercontent.com/b1l2i3=w544-h544-l90-rj"),
            QuizArtist("UC25DGtgYk5TwdksvtpeWYvA", "Wizkid", "https://lh3.googleusercontent.com/w1z2k3=w544-h544-l90-rj"),
            QuizArtist("UCCjfbcoH0ZYT0r1jScDHJMg", "Asake", "https://lh3.googleusercontent.com/a1s2a3=w544-h544-l90-rj"),
            QuizArtist("UCf_gP4AMRSgAfyzbkeS9k4g", "Travis Scott", "https://lh3.googleusercontent.com/t1s2=w544-h544-l90-rj"),
            QuizArtist("UCeKDV9JgivrXehVluw5bKFA", "SZA", "https://lh3.googleusercontent.com/s1z2a3=w544-h544-l90-rj"),
            QuizArtist("UCyD3XWRK9ko-izf2nBSFitw", "Post Malone", "https://lh3.googleusercontent.com/p1m2=w544-h544-l90-rj"),
            QuizArtist("UC0076UMUgEng8HORUw_MYHA", "Ariana Grande", "https://lh3.googleusercontent.com/a1g2=w544-h544-l90-rj"),
        )
    }

    LaunchedEffect(searchQuery) {
        val q = searchQuery.trim()
        if (q.length >= 2) {
            kotlinx.coroutines.delay(300)
            isSearching = true
            val results = YtMusicRepository.search(q, SearchFilter.ARTISTS).getOrNull()
            if (results != null) {
                searchResults = results.filterIsInstance<SearchResult.Browse>().map { browse ->
                    val resolvedId = if (browse.item.title.equals("Drake", ignoreCase = true) && (browse.item.browseId == "UC0C-w0YjGpqDXGB8Tr0GGyA" || browse.item.browseId.isBlank())) {
                        "UCU6cE7pdJPc6DU2jSrKEsdQ"
                    } else {
                        browse.item.browseId
                    }
                    QuizArtist(
                        id = resolvedId,
                        name = browse.item.title,
                        artworkUrl = browse.item.thumbnailUrl,
                    )
                }
            }
            isSearching = false
        } else {
            searchResults = emptyList()
            isSearching = false
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0xFF14171F))
                .systemBarsPadding(),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 20.dp, vertical = 16.dp),
            ) {
                // Header
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Add Favorite Artist",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                    )
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "Close",
                            tint = Color.White,
                        )
                    }
                }

                Spacer(Modifier.height(12.dp))

                // Search field
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    placeholder = {
                        Text("Search artist (e.g. Drake, Billie Eilish...)", color = Color(0xFF8E95A5), fontSize = 14.sp)
                    },
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Rounded.Search,
                            contentDescription = null,
                            tint = Color(0xFF8E95A5),
                        )
                    },
                    trailingIcon = {
                        if (searchQuery.isNotEmpty()) {
                            IconButton(onClick = { searchQuery = "" }) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Clear",
                                    tint = Color(0xFF8E95A5),
                                )
                            }
                        }
                    },
                    singleLine = true,
                    shape = RoundedCornerShape(14.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedContainerColor = Color(0xFF232631),
                        unfocusedContainerColor = Color(0xFF232631),
                        focusedBorderColor = MaterialTheme.colorScheme.primary,
                        unfocusedBorderColor = Color(0xFF383C4A),
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )

                Spacer(Modifier.height(16.dp))

                if (isSearching) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 32.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(32.dp),
                        )
                    }
                } else {
                    val displayList = if (searchQuery.trim().length >= 2) searchResults else curatedArtists

                    Text(
                        text = if (searchQuery.trim().length >= 2) "Search Results" else "Popular Artists",
                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                        color = Color(0xFF8E95A5),
                        modifier = Modifier.padding(bottom = 8.dp),
                    )

                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        contentPadding = PaddingValues(bottom = 32.dp),
                    ) {
                        itemsIndexed(
                            items = displayList.distinctBy { it.id },
                            key = { index, artist -> "search_artist_${artist.id.ifBlank { index.toString() }}_$index" },
                        ) { _, artist ->
                            val isAdded = existingArtistIds.contains(artist.id)

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(Color(0xFF1E212B))
                                    .clickable {
                                        if (!isAdded) {
                                            onAddArtist(artist)
                                        }
                                    }
                                    .padding(horizontal = 14.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                ArtistAvatar(
                                    artistName = artist.name,
                                    artworkUrl = artist.artworkUrl,
                                    size = 48.dp,
                                )

                                Spacer(Modifier.width(14.dp))

                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = artist.name,
                                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                                        color = Color.White,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    Text(
                                        text = "Artist",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = Color(0xFF8E95A5),
                                    )
                                }

                                if (isAdded) {
                                    Box(
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(8.dp))
                                            .background(Color(0xFF2A2E3D))
                                            .padding(horizontal = 10.dp, vertical = 6.dp),
                                    ) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.CheckCircle,
                                                contentDescription = null,
                                                tint = MaterialTheme.colorScheme.primary,
                                                modifier = Modifier.size(14.dp),
                                            )
                                            Text(
                                                text = "Added",
                                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                                                color = MaterialTheme.colorScheme.primary,
                                            )
                                        }
                                    }
                                } else {
                                    Button(
                                        onClick = { onAddArtist(artist) },
                                        shape = RoundedCornerShape(10.dp),
                                        colors = ButtonDefaults.buttonColors(
                                            containerColor = MaterialTheme.colorScheme.primary,
                                            contentColor = MaterialTheme.colorScheme.onPrimary,
                                        ),
                                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Rounded.Add,
                                            contentDescription = null,
                                            modifier = Modifier.size(16.dp),
                                        )
                                        Spacer(Modifier.width(4.dp))
                                        Text(
                                            text = "Add",
                                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
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
