package com.fortune.vibramusic.ui.social

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.TextFields
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ElevatedButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.social.StoryMediaType
import com.fortune.vibramusic.data.social.UserStory
import com.fortune.vibramusic.data.social.UserStoryGroup
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.data.social.formatRelativeTime
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass
import com.fortune.vibramusic.ui.components.liquidGlassButton
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.theme.VibraPurple
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * Purple gradient story ring brush.
 */
val StoryRingGradient = Brush.sweepGradient(
    listOf(
        Color(0xFF8B5CF6),
        Color(0xFFA855F7),
        Color(0xFFC084FC),
        Color(0xFF8B5CF6),
    ),
)

/**
 * Modifier to wrap an avatar in the Instagram/Airbuds purple story ring.
 */
fun Modifier.purpleStoryRing(hasStory: Boolean): Modifier = if (hasStory) {
    this
        .border(2.5.dp, StoryRingGradient, CircleShape)
        .padding(3.dp)
} else {
    this
}

/**
 * Horizontal story card row rendered at the top of the Social Feed (matching user reference image 2).
 */
@Composable
fun StoriesFeedHorizontalBar(
    storyGroups: List<UserStoryGroup>,
    currentProfile: SocialProfile?,
    onOpenStoryGroup: (UserStoryGroup) -> Unit,
    onCreateStory: () -> Unit,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyRow(
        modifier = modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = 20.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // First Tile: "Your Story" / Add Story
        item(key = "add_story_tile") {
            val ownGroup = storyGroups.firstOrNull { it.user.id == currentProfile?.id }
            Box(
                modifier = Modifier
                    .width(108.dp)
                    .height(162.dp)
                    .clip(RoundedCornerShape(22.dp))
                    .background(Color(0xFF1B1C27))
                    .border(1.2.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(22.dp))
                    .clickable {
                        if (ownGroup != null && ownGroup.stories.isNotEmpty()) {
                            onOpenStoryGroup(ownGroup)
                        } else {
                            onCreateStory()
                        }
                    },
            ) {
                if (ownGroup != null && ownGroup.stories.isNotEmpty()) {
                    val firstStory = ownGroup.stories.first()
                    if (!firstStory.mediaUrl.isNullOrBlank()) {
                        AsyncImage(
                            model = firstStory.mediaUrl,
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .background(
                                    Brush.verticalGradient(
                                        listOf(VibraPurple.copy(alpha = 0.8f), Color(0xFF141520)),
                                    ),
                                ),
                        )
                    }
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(
                                Brush.verticalGradient(
                                    listOf(Color.Black.copy(alpha = 0.3f), Color.Black.copy(alpha = 0.65f)),
                                ),
                            ),
                    )
                }

                // Add / Your Story Avatar and Label
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(10.dp),
                    verticalArrangement = Arrangement.SpaceBetween,
                    horizontalAlignment = Alignment.Start,
                ) {
                    Box(
                        modifier = Modifier
                            .size(38.dp)
                            .purpleStoryRing(ownGroup != null && ownGroup.stories.isNotEmpty())
                            .clip(CircleShape)
                            .background(Color(0xFF2A2B3D)),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (!currentProfile?.avatarUrl.isNullOrBlank() && currentProfile?.avatarUrl != "null") {
                            AsyncImage(
                                model = currentProfile?.avatarUrl,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Add,
                                contentDescription = "Add Story",
                                tint = VibraPurple,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }

                    Column {
                        Box(
                            modifier = Modifier
                                .size(24.dp)
                                .clip(CircleShape)
                                .background(VibraPurple)
                                .clickable { onCreateStory() },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Add,
                                contentDescription = "New Story",
                                tint = Color.White,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = if (ownGroup != null && ownGroup.stories.isNotEmpty()) "Your Story" else "Add Story",
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                            color = Color.White,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }

        // Friends' Stories Tiles
        items(
            items = storyGroups.filter { it.user.id != currentProfile?.id },
            key = { it.user.id },
        ) { group ->
            val topStory = group.stories.firstOrNull() ?: return@items
            val user = group.user

            Box(
                modifier = Modifier
                    .width(108.dp)
                    .height(162.dp)
                    .clip(RoundedCornerShape(22.dp))
                    .background(Color(0xFF1B1C27))
                    .border(1.2.dp, VibraPurple.copy(alpha = 0.45f), RoundedCornerShape(22.dp))
                    .clickable { onOpenStoryGroup(group) },
            ) {
                // Background Preview (Media or Gradient)
                if (!topStory.mediaUrl.isNullOrBlank()) {
                    AsyncImage(
                        model = topStory.mediaUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(
                                Brush.verticalGradient(
                                    listOf(
                                        Color(0xFF2E1065),
                                        Color(0xFF1E1B4B),
                                        Color(0xFF0F172A),
                                    ),
                                ),
                            )
                            .padding(8.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = topStory.textContent,
                            style = MaterialTheme.typography.bodySmall.copy(
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 11.sp,
                            ),
                            color = Color.White,
                            maxLines = 4,
                            overflow = TextOverflow.Ellipsis,
                            textAlign = TextAlign.Center,
                        )
                    }
                }

                // Scrim
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(
                            Brush.verticalGradient(
                                listOf(
                                    Color.Black.copy(alpha = 0.45f),
                                    Color.Transparent,
                                    Color.Black.copy(alpha = 0.85f),
                                ),
                            ),
                        ),
                )

                // Top: User Avatar with Story Ring + Name
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(30.dp)
                            .purpleStoryRing(true)
                            .clip(CircleShape)
                            .background(Color(0xFF2A2B3D)),
                        contentAlignment = Alignment.Center,
                    ) {
                        AsyncImage(
                            model = user.avatarUrl,
                            contentDescription = user.displayName,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                    Text(
                        text = user.displayName.ifBlank { formatHandle(user.handle) },
                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // Bottom: Music Pill if attached (matching reference image 2)
                if (topStory.musicAttachment != null) {
                    val track = topStory.musicAttachment
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .padding(6.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.Black.copy(alpha = 0.65f))
                            .border(0.8.dp, Color.White.copy(alpha = 0.2f), RoundedCornerShape(12.dp))
                            .padding(horizontal = 6.dp, vertical = 4.dp),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.GraphicEq,
                                contentDescription = null,
                                tint = VibraPurple,
                                modifier = Modifier.size(12.dp),
                            )
                            Text(
                                text = track.title,
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 9.sp,
                                ),
                                color = Color.White,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Fullscreen segmented Instagram/Airbuds style Story Viewer Dialog.
 */
@Composable
fun StoryViewerDialog(
    storyGroup: UserStoryGroup,
    allGroups: List<UserStoryGroup>,
    currentUserId: String?,
    onDismiss: () -> Unit,
    onDeleteStory: (String) -> Unit,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
) {
    var activeGroupIndex by remember(storyGroup) {
        mutableIntStateOf(allGroups.indexOfFirst { it.user.id == storyGroup.user.id }.coerceAtLeast(0))
    }
    val currentGroup = allGroups.getOrNull(activeGroupIndex) ?: storyGroup
    val stories = currentGroup.stories
    var currentStoryIndex by remember(currentGroup) { mutableIntStateOf(0) }

    var isPaused by remember { mutableStateOf(false) }
    val progress = remember { Animatable(0f) }
    val activeStory = stories.getOrNull(currentStoryIndex) ?: stories.firstOrNull()

    // Timer: advances progress from 0f to 1f over 5 seconds
    LaunchedEffect(currentGroup, currentStoryIndex, isPaused) {
        if (!isPaused && activeStory != null) {
            progress.snapTo(0f)
            progress.animateTo(
                targetValue = 1f,
                animationSpec = tween(durationMillis = 5000, easing = LinearEasing),
            )
            // Advance to next story
            if (currentStoryIndex < stories.lastIndex) {
                currentStoryIndex++
            } else if (activeGroupIndex < allGroups.lastIndex) {
                activeGroupIndex++
                currentStoryIndex = 0
            } else {
                onDismiss()
            }
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black),
        ) {
            if (activeStory != null) {
                // Background Story Content
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .pointerInput(Unit) {
                            detectTapGestures(
                                onPress = {
                                    isPaused = true
                                    tryAwaitRelease()
                                    isPaused = false
                                },
                                onTap = { offset ->
                                    val screenWidth = size.width
                                    if (offset.x < screenWidth * 0.35f) {
                                        // Navigate left
                                        if (currentStoryIndex > 0) {
                                            currentStoryIndex--
                                        } else if (activeGroupIndex > 0) {
                                            activeGroupIndex--
                                            currentStoryIndex = 0
                                        }
                                    } else {
                                        // Navigate right
                                        if (currentStoryIndex < stories.lastIndex) {
                                            currentStoryIndex++
                                        } else if (activeGroupIndex < allGroups.lastIndex) {
                                            activeGroupIndex++
                                            currentStoryIndex = 0
                                        } else {
                                            onDismiss()
                                        }
                                    }
                                },
                            )
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    when (activeStory.mediaType) {
                        StoryMediaType.IMAGE -> {
                            AsyncImage(
                                model = activeStory.mediaUrl,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                        StoryMediaType.VIDEO -> {
                            val context = LocalContext.current
                            val exoPlayer = remember(activeStory.mediaUrl) {
                                ExoPlayer.Builder(context.applicationContext).build().apply {
                                    repeatMode = Player.REPEAT_MODE_ALL
                                    activeStory.mediaUrl?.let { setMediaItem(MediaItem.fromUri(it)) }
                                    prepare()
                                    playWhenReady = true
                                }
                            }
                            DisposableEffect(exoPlayer) {
                                onDispose { exoPlayer.release() }
                            }
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
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                        StoryMediaType.TEXT -> {
                            Box(
                                modifier = Modifier
                                    .fillMaxSize()
                                    .background(
                                        Brush.verticalGradient(
                                            listOf(
                                                Color(0xFF3B0764),
                                                Color(0xFF1E1B4B),
                                                Color(0xFF090A0F),
                                            ),
                                        ),
                                    )
                                    .padding(32.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    text = activeStory.textContent,
                                    style = MaterialTheme.typography.headlineMedium.copy(
                                        fontWeight = FontWeight.Bold,
                                        color = Color.White,
                                        textAlign = TextAlign.Center,
                                        lineHeight = 34.sp,
                                    ),
                                )
                            }
                        }
                    }

                    // Scrim for readability
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(
                                Brush.verticalGradient(
                                    listOf(
                                        Color.Black.copy(alpha = 0.6f),
                                        Color.Transparent,
                                        Color.Black.copy(alpha = 0.5f),
                                    ),
                                ),
                            ),
                    )
                }

                // Top Controls: Segmented Dashes + Author Header
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                ) {
                    // Segmented Progress Bars
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(3.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        stories.forEachIndexed { idx, _ ->
                            val fill = when {
                                idx < currentStoryIndex -> 1f
                                idx == currentStoryIndex -> progress.value
                                else -> 0f
                            }
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .height(3.dp)
                                    .clip(RoundedCornerShape(2.dp))
                                    .background(Color.White.copy(alpha = 0.35f)),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth(fill)
                                        .height(3.dp)
                                        .background(Color.White),
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(10.dp))

                    // Author Header Row
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(36.dp)
                                    .purpleStoryRing(true)
                                    .clip(CircleShape)
                                    .background(Color(0xFF222432)),
                            ) {
                                AsyncImage(
                                    model = currentGroup.user.avatarUrl,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }

                            Column {
                                Text(
                                    text = currentGroup.user.displayName.ifBlank { formatHandle(currentGroup.user.handle) },
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                    color = Color.White,
                                )
                                Text(
                                    text = formatRelativeTime(activeStory.createdAt),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color.White.copy(alpha = 0.7f),
                                )
                            }
                        }

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (currentUserId == currentGroup.user.id) {
                                IconButton(
                                    onClick = {
                                        onDeleteStory(activeStory.id)
                                        if (stories.size <= 1) onDismiss()
                                    },
                                    modifier = Modifier.size(36.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.DeleteOutline,
                                        contentDescription = "Delete Story",
                                        tint = Color.White,
                                        modifier = Modifier.size(20.dp),
                                    )
                                }
                            }
                            IconButton(
                                onClick = onDismiss,
                                modifier = Modifier.size(36.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Close",
                                    tint = Color.White,
                                    modifier = Modifier.size(22.dp),
                                )
                            }
                        }
                    }
                }

                // Bottom: Music Pill if attached
                if (activeStory.musicAttachment != null) {
                    val track = activeStory.musicAttachment
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .navigationBarsPadding()
                            .padding(bottom = 24.dp)
                            .clip(RoundedCornerShape(24.dp))
                            .background(Color(0xCC1A1C24))
                            .border(1.dp, VibraPurple.copy(alpha = 0.6f), RoundedCornerShape(24.dp))
                            .clickable { onPlayTrack(track) }
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(32.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(VibraPurple),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.MusicNote,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                            Column {
                                Text(
                                    text = track.title,
                                    style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold),
                                    color = Color.White,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    text = track.artist,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color.White.copy(alpha = 0.75f),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            Icon(
                                imageVector = Icons.Rounded.PlayArrow,
                                contentDescription = "Play",
                                tint = VibraPurple,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Creator sheet to post image, video, or text story lasting 24 hours.
 */
@Composable
fun CreateStorySheet(
    currentlyPlayingSong: Song?,
    onDismiss: () -> Unit,
    onSubmitStory: (mediaUrl: String?, mediaType: StoryMediaType, textContent: String, track: MusicTrackAttachment?) -> Unit,
) {
    var selectedType by remember { mutableStateOf(StoryMediaType.TEXT) }
    var textContent by remember { mutableStateOf("") }
    var mediaUrlInput by remember { mutableStateOf("") }
    var attachCurrentSong by remember { mutableStateOf(currentlyPlayingSong != null) }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0xFF0F1016)),
            color = Color(0xFF0F1016),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(20.dp),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                // Header
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "Close",
                            tint = Color.White,
                        )
                    }

                    Text(
                        text = "Add to 24h Story",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                    )

                    ElevatedButton(
                        onClick = {
                            val track = if (attachCurrentSong && currentlyPlayingSong != null) {
                                MusicTrackAttachment(
                                    videoId = currentlyPlayingSong.videoId,
                                    title = currentlyPlayingSong.title,
                                    artist = currentlyPlayingSong.artist,
                                    thumbnailUrl = currentlyPlayingSong.thumbnailUrl,
                                )
                            } else null

                            onSubmitStory(
                                mediaUrlInput.trim().ifBlank { null },
                                selectedType,
                                textContent.trim(),
                                track,
                            )
                        },
                        colors = ButtonDefaults.elevatedButtonColors(
                            containerColor = VibraPurple,
                            contentColor = Color.White,
                        ),
                        shape = RoundedCornerShape(18.dp),
                        enabled = textContent.isNotBlank() || mediaUrlInput.isNotBlank(),
                    ) {
                        Text("Post", fontWeight = FontWeight.Bold)
                    }
                }

                // Type Switcher (Text, Image, Video)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Center,
                ) {
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .background(Color(0xFF1E202E))
                            .padding(4.dp),
                    ) {
                        listOf(
                            StoryMediaType.TEXT to "Text",
                            StoryMediaType.IMAGE to "Photo",
                            StoryMediaType.VIDEO to "Video",
                        ).forEach { (type, label) ->
                            val isSel = selectedType == type
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(if (isSel) VibraPurple else Color.Transparent)
                                    .clickable { selectedType = type }
                                    .padding(horizontal = 16.dp, vertical = 8.dp),
                            ) {
                                Text(
                                    text = label,
                                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                    color = if (isSel) Color.White else Color.White.copy(alpha = 0.6f),
                                )
                            }
                        }
                    }
                }

                // Middle: Canvas Editor
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(380.dp)
                        .clip(RoundedCornerShape(24.dp))
                        .background(
                            Brush.verticalGradient(
                                listOf(Color(0xFF2E1065), Color(0xFF1E1B4B), Color(0xFF0F172A)),
                            ),
                        )
                        .border(1.dp, VibraPurple.copy(alpha = 0.4f), RoundedCornerShape(24.dp))
                        .padding(20.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (selectedType == StoryMediaType.TEXT) {
                            OutlinedTextField(
                                value = textContent,
                                onValueChange = { if (it.length <= 250) textContent = it },
                                placeholder = {
                                    Text(
                                        "Type your vibe or daily track thought...",
                                        color = Color.White.copy(alpha = 0.5f),
                                        textAlign = TextAlign.Center,
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                },
                                textStyle = MaterialTheme.typography.headlineSmall.copy(
                                    color = Color.White,
                                    fontWeight = FontWeight.Bold,
                                    textAlign = TextAlign.Center,
                                ),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = Color.Transparent,
                                    unfocusedBorderColor = Color.Transparent,
                                ),
                                modifier = Modifier.fillMaxWidth(),
                            )
                        } else {
                            OutlinedTextField(
                                value = mediaUrlInput,
                                onValueChange = { mediaUrlInput = it },
                                placeholder = {
                                    Text(
                                        "Paste ${if (selectedType == StoryMediaType.IMAGE) "Image" else "Video"} URL...",
                                        color = Color.White.copy(alpha = 0.5f),
                                    )
                                },
                                textStyle = MaterialTheme.typography.bodyMedium.copy(color = Color.White),
                                colors = OutlinedTextFieldDefaults.colors(
                                    focusedBorderColor = VibraPurple,
                                    unfocusedBorderColor = Color.White.copy(alpha = 0.2f),
                                ),
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(16.dp),
                            )

                            if (mediaUrlInput.isNotBlank() && selectedType == StoryMediaType.IMAGE) {
                                Spacer(Modifier.height(14.dp))
                                AsyncImage(
                                    model = mediaUrlInput,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier
                                        .size(160.dp)
                                        .clip(RoundedCornerShape(16.dp)),
                                )
                            }
                        }
                    }
                }

                // Bottom: Music Track Toggle
                if (currentlyPlayingSong != null) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(Color(0xFF1E202E))
                            .clickable { attachCurrentSong = !attachCurrentSong }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.MusicNote,
                                contentDescription = null,
                                tint = VibraPurple,
                                modifier = Modifier.size(20.dp),
                            )
                            Column {
                                Text(
                                    text = "Attach: ${currentlyPlayingSong.title}",
                                    style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold),
                                    color = Color.White,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    text = currentlyPlayingSong.artist,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = Color.White.copy(alpha = 0.6f),
                                )
                            }
                        }

                        Text(
                            text = if (attachCurrentSong) "Attached" else "Tap to add",
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                            color = if (attachCurrentSong) VibraPurple else Color.White.copy(alpha = 0.5f),
                        )
                    }
                } else {
                    Spacer(Modifier.height(20.dp))
                }
            }
        }
    }
}
