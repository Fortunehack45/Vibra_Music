package com.fortune.vibramusic.ui.social

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.AddPhotoAlternate
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.EditNote
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Poll
import androidx.compose.material.icons.rounded.RocketLaunch
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarOutline
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.BrowseItem
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PollData
import com.fortune.vibramusic.data.social.PollOption
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.ui.components.MentionSuggestionPopup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

private enum class CreateMode {
    POST,
    REVIEW,
}

@Composable
fun CreatePostSheet(
    currentlyPlayingSong: Song?,
    quotedPost: SocialPost? = null,
    isPosting: Boolean,
    onDismiss: () -> Unit,
    onSubmitPost: (
        content: String,
        imageUrls: List<String>,
        videoUrl: String?,
        gifUrl: String?,
        audioUrl: String?,
        isReview: Boolean,
        rating: Int,
        taggedArtist: String?,
        track: MusicTrackAttachment?,
        poll: PollData?,
        quoteOfId: String?,
    ) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Mode state: If quoting a post, jump directly into composer
    var isChoiceScreenVisible by remember { mutableStateOf(quotedPost == null) }
    var selectedMode by remember { mutableStateOf(CreateMode.POST) }

    // Composer inputs
    var textContent by remember { mutableStateOf("") }
    val selectedImageUris = remember { mutableStateListOf<Uri>() }
    var selectedVideoUri by remember { mutableStateOf<Uri?>(null) }
    var selectedGifUrl by remember { mutableStateOf<String?>(null) }
    var showGifPicker by remember { mutableStateOf(false) }

    var mentionQuery by remember { mutableStateOf<String?>(null) }
    var mentionSuggestions by remember { mutableStateOf<List<SocialProfile>>(emptyList()) }
    var isSearchingMentions by remember { mutableStateOf(false) }

    LaunchedEffect(mentionQuery) {
        val query = mentionQuery
        if (query != null) {
            isSearchingMentions = true
            SupabaseService.searchUsersForMention(query).onSuccess { list ->
                mentionSuggestions = list
            }.onFailure {
                mentionSuggestions = emptyList()
            }
            isSearchingMentions = false
        } else {
            mentionSuggestions = emptyList()
            isSearchingMentions = false
        }
    }

    // Review fields
    var reviewRating by remember { mutableIntStateOf(5) }
    var taggedArtist by remember { mutableStateOf<String?>(null) }
    var showArtistPicker by remember { mutableStateOf(false) }

    // Track attachment
    var attachedTrack by remember {
        mutableStateOf(
            currentlyPlayingSong?.let {
                MusicTrackAttachment(
                    videoId = it.videoId,
                    title = it.title,
                    artist = it.artist,
                    artworkUrl = it.thumbnailUrl,
                    durationText = it.durationText,
                )
            }
        )
    }

    // Poll builder
    var showPollBuilder by remember { mutableStateOf(false) }
    var pollQuestion by remember { mutableStateOf("") }
    val pollOptions = remember { mutableStateListOf("", "") }
    val pollOptionTracks = remember { androidx.compose.runtime.mutableStateMapOf<Int, MusicTrackAttachment?>() }
    val pollOptionImages = remember { androidx.compose.runtime.mutableStateMapOf<Int, String?>() }
    var pollDurationDays by remember { mutableIntStateOf(1) }
    var pickingSongForOptionIndex by remember { mutableStateOf<Int?>(null) }
    var pickingAttachmentForOptionIndex by remember { mutableStateOf<Int?>(null) }

    // Voice note recording
    val voiceRecorder = remember { VoiceRecorderManager(context) }
    val isRecordingVoice by voiceRecorder.isRecording.collectAsState()
    val recordingDuration by voiceRecorder.recordingDurationSeconds.collectAsState()
    val isVoicePlaying by voiceRecorder.isPlaying.collectAsState()
    val voiceProgress by voiceRecorder.playbackProgress.collectAsState()
    var recordedAudioFile by remember { mutableStateOf<File?>(null) }

    DisposableEffect(Unit) {
        onDispose {
            voiceRecorder.cancelRecording()
            voiceRecorder.stopPlayback()
        }
    }

    // Music search dialog
    var showMusicSearch by remember { mutableStateOf(false) }

    // Upload state
    var isUploadingMedia by remember { mutableStateOf(false) }

    // Multi-image picker (up to 10 photos)
    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(maxItems = 10)
    ) { uris ->
        uris.forEach { uri ->
            if (selectedImageUris.size < 10 && !selectedImageUris.contains(uri)) {
                selectedImageUris.add(uri)
                selectedVideoUri = null
            }
        }
    }

    // Video picker launcher
    val videoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri != null) {
            val pfd = runCatching { context.contentResolver.openFileDescriptor(uri, "r") }.getOrNull()
            val size = pfd?.statSize ?: 0L
            pfd?.close()
            if (size > 50L * 1024 * 1024) {
                android.widget.Toast.makeText(context, "Video exceeds 50MB limit", android.widget.Toast.LENGTH_SHORT).show()
            } else {
                selectedVideoUri = uri
                selectedImageUris.clear()
            }
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface)
                .systemBarsPadding(),
        ) {
            if (isChoiceScreenVisible) {
                // Choice view: Post vs Review
                CreateChoiceScreen(
                    onDismiss = onDismiss,
                    onSelectPost = {
                        selectedMode = CreateMode.POST
                        isChoiceScreenVisible = false
                    },
                    onSelectReview = {
                        selectedMode = CreateMode.REVIEW
                        isChoiceScreenVisible = false
                    },
                )
            } else {
                // Full Screen Composer
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .imePadding(),
                ) {
                    // Top Navigation Bar
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(56.dp)
                            .padding(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        TextButton(
                            onClick = {
                                if (quotedPost == null) {
                                    isChoiceScreenVisible = true
                                } else {
                                    onDismiss()
                                }
                            },
                        ) {
                            Text(
                                text = "Back",
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Medium),
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                        }

                        Text(
                            text = when {
                                quotedPost != null -> "Quote Post"
                                selectedMode == CreateMode.REVIEW -> "Music Review"
                                else -> "New Post"
                            },
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )

                        Text(
                            text = "${9000 - textContent.length}",
                            style = MaterialTheme.typography.labelMedium,
                            color = if (textContent.length > 8500) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }

                    // Main Scrollable Content Area
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .verticalScroll(rememberScrollState())
                            .padding(horizontal = 20.dp, vertical = 8.dp),
                    ) {
                        // Artist Tag Pill (clickable to search artist)
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(RoundedCornerShape(20.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                                .clickable { showArtistPicker = true }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        ) {
                            Text(
                                text = taggedArtist?.let { "Artist: $it" } ?: "Select Artist",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            Spacer(Modifier.width(4.dp))
                            if (taggedArtist != null) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Clear Artist",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier
                                        .size(16.dp)
                                        .clickable { taggedArtist = null },
                                )
                            } else {
                                Icon(
                                    imageVector = Icons.Rounded.ArrowDropDown,
                                    contentDescription = "Select Artist",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }

                        // Music Review Rating Bar (1-5 stars)
                        if (selectedMode == CreateMode.REVIEW) {
                            Spacer(Modifier.height(14.dp))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(horizontal = 16.dp, vertical = 10.dp),
                            ) {
                                (1..5).forEach { star ->
                                    Icon(
                                        imageVector = if (star <= reviewRating) Icons.Rounded.Star else Icons.Rounded.StarOutline,
                                        contentDescription = "Rating $star",
                                        tint = if (star <= reviewRating) Color(0xFFFFB300) else MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier
                                            .size(28.dp)
                                            .clickable { reviewRating = star },
                                    )
                                }
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    text = "$reviewRating / 5 Stars",
                                    style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                            }
                        }

                        // Quoted Post Card Embed Preview
                        if (quotedPost != null) {
                            Spacer(Modifier.height(14.dp))
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(14.dp),
                            ) {
                                Column {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Box(
                                            modifier = Modifier
                                                .size(26.dp)
                                                .clip(CircleShape)
                                                .background(MaterialTheme.colorScheme.surface),
                                        ) {
                                            if (quotedPost.authorAvatar != null) {
                                                AsyncImage(
                                                    model = quotedPost.authorAvatar,
                                                    contentDescription = null,
                                                    contentScale = ContentScale.Crop,
                                                    modifier = Modifier.fillMaxSize(),
                                                )
                                            }
                                        }
                                        Spacer(Modifier.width(8.dp))
                                        Text(
                                            text = quotedPost.authorName,
                                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                            color = MaterialTheme.colorScheme.onSurface,
                                        )
                                        Spacer(Modifier.width(6.dp))
                                        Text(
                                            text = "@${quotedPost.authorHandle}",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }

                                    if (quotedPost.content.isNotBlank()) {
                                        Spacer(Modifier.height(6.dp))
                                        Text(
                                            text = quotedPost.content,
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurface,
                                            maxLines = 3,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }

                                    // Quoted media (images/GIFs)
                                    val quotedImages = quotedPost.imageUrls
                                    if (quotedImages.size == 1) {
                                        Spacer(Modifier.height(8.dp))
                                        AsyncImage(
                                            model = quotedImages.first(),
                                            contentDescription = "Quoted image",
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .heightIn(max = 180.dp)
                                                .clip(RoundedCornerShape(12.dp)),
                                        )
                                    } else if (quotedImages.size > 1) {
                                        Spacer(Modifier.height(8.dp))
                                        PostMediaCarousel(
                                            images = quotedImages,
                                            onImageClick = {},
                                            modifier = Modifier.fillMaxWidth(),
                                        )
                                    } else if (!quotedPost.gifUrl.isNullOrBlank()) {
                                        Spacer(Modifier.height(8.dp))
                                        AsyncImage(
                                            model = quotedPost.gifUrl,
                                            contentDescription = "GIF",
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .heightIn(max = 160.dp)
                                                .clip(RoundedCornerShape(12.dp)),
                                        )
                                    }

                                    // Quoted video
                                    if (!quotedPost.videoUrl.isNullOrBlank()) {
                                        Spacer(Modifier.height(8.dp))
                                        PostVideoPlayer(
                                            videoUrl = quotedPost.videoUrl,
                                            onFullScreenClick = {},
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .aspectRatio(16f / 9f)
                                                .clip(RoundedCornerShape(12.dp)),
                                        )
                                    }

                                    // Quoted poll
                                    quotedPost.poll?.let { poll ->
                                        Spacer(Modifier.height(8.dp))
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .clip(RoundedCornerShape(10.dp))
                                                .background(MaterialTheme.colorScheme.surface)
                                                .padding(10.dp),
                                        ) {
                                            Text(
                                                text = "Poll: ${poll.question}",
                                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                                color = MaterialTheme.colorScheme.onSurface,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                            Spacer(Modifier.height(4.dp))
                                            poll.options.take(2).forEach { opt ->
                                                Text(
                                                    text = "• ${opt.text}",
                                                    style = MaterialTheme.typography.bodySmall,
                                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis,
                                                )
                                            }
                                        }
                                    }

                                    quotedPost.musicTrack?.let { qTrack ->
                                        Spacer(Modifier.height(8.dp))
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(MaterialTheme.colorScheme.surface)
                                                .padding(horizontal = 10.dp, vertical = 6.dp),
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.MusicNote,
                                                contentDescription = null,
                                                tint = MaterialTheme.colorScheme.primary,
                                                modifier = Modifier.size(16.dp),
                                            )
                                            Spacer(Modifier.width(8.dp))
                                            Text(
                                                text = "${qTrack.title} • ${qTrack.artist}",
                                                style = MaterialTheme.typography.labelSmall,
                                                color = MaterialTheme.colorScheme.onSurface,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        Spacer(Modifier.height(14.dp))

                        // Mention Suggestions Popup
                        if (mentionQuery != null && (mentionSuggestions.isNotEmpty() || isSearchingMentions)) {
                            MentionSuggestionPopup(
                                suggestions = mentionSuggestions,
                                isLoading = isSearchingMentions,
                                onSelectUser = { user ->
                                    val lastAt = textContent.lastIndexOf('@')
                                    if (lastAt >= 0) {
                                        val prefix = textContent.substring(0, lastAt)
                                        val cleanHandle = user.handle.removePrefix("@")
                                        textContent = "$prefix@$cleanHandle "
                                    }
                                    mentionQuery = null
                                    mentionSuggestions = emptyList()
                                },
                                onDismiss = {
                                    mentionQuery = null
                                    mentionSuggestions = emptyList()
                                },
                                modifier = Modifier.padding(bottom = 8.dp),
                            )
                        }

                        // Text Input
                        BasicTextField(
                            value = textContent,
                            onValueChange = { newText ->
                                textContent = newText
                                val lastAt = newText.lastIndexOf('@')
                                if (lastAt >= 0 && (lastAt == 0 || newText[lastAt - 1].isWhitespace())) {
                                    val candidate = newText.substring(lastAt + 1)
                                    if (!candidate.contains(" ") && !candidate.contains("\n")) {
                                        mentionQuery = candidate
                                    } else {
                                        mentionQuery = null
                                    }
                                } else {
                                    mentionQuery = null
                                }
                            },
                            textStyle = TextStyle(
                                color = MaterialTheme.colorScheme.onSurface,
                                fontSize = 16.sp,
                                lineHeight = 22.sp,
                            ),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(130.dp),
                            decorationBox = { innerTextField ->
                                if (textContent.isEmpty()) {
                                    Text(
                                        text = when {
                                            quotedPost != null -> "Add your take on this post..."
                                            selectedMode == CreateMode.REVIEW -> "Write your song review, breakdown, or critique..."
                                            else -> "Write something..."
                                        },
                                        style = MaterialTheme.typography.bodyLarge,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                                innerTextField()
                            },
                        )

                        // Multi-Media Carousel Preview with Dynamic Dots
                        if (selectedImageUris.isNotEmpty()) {
                            Spacer(Modifier.height(14.dp))
                            val pagerState = rememberPagerState(pageCount = { selectedImageUris.size })

                            Column(modifier = Modifier.fillMaxWidth()) {
                                HorizontalPager(
                                    state = pagerState,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(240.dp)
                                        .clip(RoundedCornerShape(16.dp)),
                                ) { page ->
                                    val uri = selectedImageUris[page]
                                    Box(modifier = Modifier.fillMaxSize()) {
                                        AsyncImage(
                                            model = uri,
                                            contentDescription = "Selected media",
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier.fillMaxSize(),
                                        )

                                        // Delete media button
                                        Box(
                                            modifier = Modifier
                                                .align(Alignment.TopEnd)
                                                .padding(10.dp)
                                                .size(28.dp)
                                                .clip(CircleShape)
                                                .background(Color.Black)
                                                .clickable { selectedImageUris.removeAt(page) },
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.Close,
                                                contentDescription = "Remove",
                                                tint = Color.White,
                                                modifier = Modifier.size(16.dp),
                                            )
                                        }
                                    }
                                }

                                // Carousel Dynamic Indicator Dots
                                if (selectedImageUris.size > 1) {
                                    Spacer(Modifier.height(8.dp))
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.Center,
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        repeat(selectedImageUris.size) { index ->
                                            val isActive = pagerState.currentPage == index
                                            Box(
                                                modifier = Modifier
                                                    .padding(horizontal = 3.dp)
                                                    .height(6.dp)
                                                    .width(if (isActive) 18.dp else 6.dp)
                                                    .clip(RoundedCornerShape(3.dp))
                                                    .background(
                                                        if (isActive) MaterialTheme.colorScheme.primary
                                                        else MaterialTheme.colorScheme.onSurfaceVariant
                                                    ),
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        // Video Attachment Preview
                        selectedVideoUri?.let { uri ->
                            Spacer(Modifier.height(14.dp))
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(14.dp),
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(
                                            imageVector = Icons.Rounded.Videocam,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(24.dp),
                                        )
                                        Spacer(Modifier.width(10.dp))
                                        Text(
                                            text = "Video selected",
                                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                                            color = MaterialTheme.colorScheme.onSurface,
                                        )
                                    }
                                    IconButton(onClick = { selectedVideoUri = null }) {
                                        Icon(
                                            imageVector = Icons.Rounded.Close,
                                            contentDescription = "Remove video",
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }

                        // GIF Attachment Preview
                        selectedGifUrl?.let { gifUrl ->
                            Spacer(Modifier.height(14.dp))
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(200.dp)
                                    .clip(RoundedCornerShape(16.dp)),
                            ) {
                                AsyncImage(
                                    model = gifUrl,
                                    contentDescription = "Selected GIF",
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                                Box(
                                    modifier = Modifier
                                        .align(Alignment.TopEnd)
                                        .padding(8.dp)
                                        .size(28.dp)
                                        .clip(CircleShape)
                                        .background(Color.Black)
                                        .clickable { selectedGifUrl = null },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Close,
                                        contentDescription = "Remove GIF",
                                        tint = Color.White,
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            }
                        }

                        // Voice Note Attachment Preview
                        recordedAudioFile?.let { file ->
                            Spacer(Modifier.height(14.dp))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(horizontal = 14.dp, vertical = 10.dp),
                            ) {
                                IconButton(
                                    onClick = {
                                        if (isVoicePlaying) voiceRecorder.pauseAudio()
                                        else voiceRecorder.playAudio(file.absolutePath)
                                    },
                                    modifier = Modifier
                                        .size(36.dp)
                                        .clip(CircleShape)
                                        .background(MaterialTheme.colorScheme.primary),
                                ) {
                                    Icon(
                                        imageVector = if (isVoicePlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                        contentDescription = "Play voice note",
                                        tint = MaterialTheme.colorScheme.onPrimary,
                                        modifier = Modifier.size(20.dp),
                                    )
                                }

                                Spacer(Modifier.width(12.dp))

                                // Waveform simulation
                                Row(
                                    modifier = Modifier.weight(1f),
                                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    val barHeights = listOf(14, 24, 18, 30, 20, 16, 26, 22, 12, 28, 20, 15, 25, 18)
                                    barHeights.forEachIndexed { idx, h ->
                                        val barProgress = idx.toFloat() / barHeights.size
                                        val isPassed = barProgress <= voiceProgress
                                        Box(
                                            modifier = Modifier
                                                .width(3.dp)
                                                .height(h.dp)
                                                .clip(RoundedCornerShape(1.5.dp))
                                                .background(
                                                    if (isPassed) MaterialTheme.colorScheme.primary
                                                    else MaterialTheme.colorScheme.onSurfaceVariant
                                                ),
                                        )
                                    }
                                }

                                Spacer(Modifier.width(10.dp))

                                IconButton(
                                    onClick = {
                                        voiceRecorder.stopPlayback()
                                        file.delete()
                                        recordedAudioFile = null
                                    },
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Delete,
                                        contentDescription = "Delete voice note",
                                        tint = MaterialTheme.colorScheme.error,
                                        modifier = Modifier.size(20.dp),
                                    )
                                }
                            }
                        }

                        // Attached Track Card
                        attachedTrack?.let { track ->
                            Spacer(Modifier.height(14.dp))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(10.dp),
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(46.dp)
                                        .clip(RoundedCornerShape(8.dp))
                                        .background(MaterialTheme.colorScheme.surface),
                                ) {
                                    if (track.artworkUrl != null) {
                                        AsyncImage(
                                            model = track.artworkUrl,
                                            contentDescription = null,
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier.fillMaxSize(),
                                        )
                                    }
                                }

                                Spacer(Modifier.width(12.dp))

                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = track.title,
                                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.onSurface,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    Text(
                                        text = track.artist,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }

                                IconButton(onClick = { attachedTrack = null }) {
                                    Icon(
                                        imageVector = Icons.Rounded.Close,
                                        contentDescription = "Remove track",
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }

                        // Poll Builder Section
                        if (showPollBuilder) {
                            Spacer(Modifier.height(14.dp))
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(14.dp),
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Text(
                                        text = "Create Poll",
                                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.onSurface,
                                    )
                                    IconButton(
                                        onClick = { showPollBuilder = false },
                                        modifier = Modifier.size(24.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Rounded.Close,
                                            contentDescription = "Remove poll",
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }

                                Spacer(Modifier.height(10.dp))

                                // Poll Question
                                BasicTextField(
                                    value = pollQuestion,
                                    onValueChange = { pollQuestion = it },
                                    textStyle = TextStyle(
                                        color = MaterialTheme.colorScheme.onSurface,
                                        fontSize = 14.sp,
                                    ),
                                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(MaterialTheme.colorScheme.surface)
                                        .padding(10.dp),
                                    decorationBox = { innerTextField ->
                                        if (pollQuestion.isEmpty()) {
                                            Text(
                                                text = "Ask a question...",
                                                style = MaterialTheme.typography.bodyMedium,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            )
                                        }
                                        innerTextField()
                                    },
                                )

                                Spacer(Modifier.height(8.dp))

                                // Poll Options
                                pollOptions.forEachIndexed { index, option ->
                                    Spacer(Modifier.height(6.dp))
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.fillMaxWidth(),
                                    ) {
                                        BasicTextField(
                                            value = option,
                                            onValueChange = { pollOptions[index] = it },
                                            textStyle = TextStyle(
                                                color = MaterialTheme.colorScheme.onSurface,
                                                fontSize = 14.sp,
                                            ),
                                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                            modifier = Modifier
                                                .weight(1f)
                                                .clip(RoundedCornerShape(10.dp))
                                                .background(MaterialTheme.colorScheme.surface)
                                                .padding(10.dp),
                                            decorationBox = { innerTextField ->
                                                if (option.isEmpty()) {
                                                    Text(
                                                        text = pollOptionTracks[index]?.let { "${it.title} - ${it.artist}" } ?: "Option ${index + 1}",
                                                        style = MaterialTheme.typography.bodyMedium,
                                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                    )
                                                }
                                                innerTextField()
                                            },
                                        )

                                        Spacer(Modifier.width(6.dp))

                                        // Attachment preview / button for option (song, artist, or album)
                                        val currentTrack = pollOptionTracks[index]
                                        val currentImage = pollOptionImages[index] ?: currentTrack?.artworkUrl ?: currentTrack?.thumbnailUrl
                                        if (currentImage != null || currentTrack != null) {
                                            Box(
                                                modifier = Modifier
                                                    .size(34.dp)
                                                    .clip(RoundedCornerShape(8.dp))
                                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                                    .clickable {
                                                        pollOptionTracks.remove(index)
                                                        pollOptionImages.remove(index)
                                                    },
                                                contentAlignment = Alignment.Center,
                                            ) {
                                                if (currentImage != null) {
                                                    AsyncImage(
                                                        model = currentImage,
                                                        contentDescription = "Option media",
                                                        contentScale = ContentScale.Crop,
                                                        modifier = Modifier.fillMaxSize(),
                                                    )
                                                    Box(
                                                        modifier = Modifier
                                                            .fillMaxSize()
                                                            .background(Color.Black.copy(alpha = 0.35f)),
                                                        contentAlignment = Alignment.Center,
                                                    ) {
                                                        Icon(
                                                            imageVector = Icons.Rounded.Close,
                                                            contentDescription = "Remove attachment",
                                                            tint = Color.White,
                                                            modifier = Modifier.size(16.dp),
                                                        )
                                                    }
                                                } else {
                                                    Icon(
                                                        imageVector = Icons.Rounded.MusicNote,
                                                        contentDescription = "Remove song",
                                                        tint = MaterialTheme.colorScheme.primary,
                                                        modifier = Modifier.size(18.dp),
                                                    )
                                                }
                                            }
                                        } else {
                                            IconButton(
                                                onClick = {
                                                    pickingAttachmentForOptionIndex = index
                                                },
                                                modifier = Modifier.size(34.dp),
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Rounded.AddPhotoAlternate,
                                                    contentDescription = "Attach song, artist or album to option",
                                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                                    modifier = Modifier.size(18.dp),
                                                )
                                            }
                                        }

                                        if (pollOptions.size > 2) {
                                            Spacer(Modifier.width(4.dp))
                                            IconButton(
                                                onClick = {
                                                    pollOptions.removeAt(index)
                                                    pollOptionTracks.remove(index)
                                                    pollOptionImages.remove(index)
                                                },
                                                modifier = Modifier.size(24.dp),
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Rounded.Close,
                                                    contentDescription = "Remove option",
                                                    tint = MaterialTheme.colorScheme.error,
                                                )
                                            }
                                        }
                                    }
                                }

                                if (pollOptions.size < 4) {
                                    Spacer(Modifier.height(8.dp))
                                    TextButton(
                                        onClick = { pollOptions.add("") },
                                        contentPadding = PaddingValues(0.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Rounded.Add,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(16.dp),
                                        )
                                        Spacer(Modifier.width(4.dp))
                                        Text(
                                            text = "Add option",
                                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                            color = MaterialTheme.colorScheme.primary,
                                        )
                                    }
                                }

                                // Poll Duration Selector
                                Spacer(Modifier.height(10.dp))
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Text(
                                        text = "Duration:",
                                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    listOf(1 to "24h", 3 to "3d", 7 to "7d", 14 to "14d", 30 to "30d").forEach { (days, label) ->
                                        val isSelected = pollDurationDays == days
                                        Box(
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(8.dp))
                                                .background(if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface)
                                                .clickable { pollDurationDays = days }
                                                .padding(horizontal = 8.dp, vertical = 4.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Text(
                                                text = label,
                                                style = MaterialTheme.typography.labelSmall.copy(
                                                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                                ),
                                                color = if (isSelected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                                            )
                                        }
                                    }
                                }
                            }
                        }

                        // Live Voice Recording State Indicator
                        if (isRecordingVoice) {
                            Spacer(Modifier.height(14.dp))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.GraphicEq,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(24.dp),
                                )
                                Spacer(Modifier.width(12.dp))
                                Text(
                                    text = "Recording Voice Note... ${recordingDuration}s",
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.weight(1f),
                                )
                                IconButton(
                                    onClick = {
                                        val file = voiceRecorder.stopRecording()
                                        if (file != null && file.exists()) {
                                            recordedAudioFile = file
                                        }
                                    },
                                    modifier = Modifier
                                        .size(34.dp)
                                        .clip(CircleShape)
                                        .background(MaterialTheme.colorScheme.error),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Stop,
                                        contentDescription = "Stop recording",
                                        tint = MaterialTheme.colorScheme.onError,
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            }
                        }
                    }

                    // Bottom Docked Toolbar (above keyboard)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.surface)
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // Toolbar Action Icons
                        val isPollMode = showPollBuilder
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            // Photo
                            Icon(
                                imageVector = Icons.Rounded.AddPhotoAlternate,
                                contentDescription = "Add Photos",
                                tint = if (isPollMode) MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                                else if (selectedImageUris.isNotEmpty()) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(24.dp)
                                    .clickable {
                                        if (isPollMode) {
                                            android.widget.Toast.makeText(context, "Poll posts cannot contain media attachments", android.widget.Toast.LENGTH_SHORT).show()
                                        } else {
                                            photoPickerLauncher.launch(
                                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                                            )
                                        }
                                    },
                            )

                            // Video
                            Icon(
                                imageVector = Icons.Rounded.Videocam,
                                contentDescription = "Add Video",
                                tint = if (isPollMode) MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                                else if (selectedVideoUri != null) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(24.dp)
                                    .clickable {
                                        if (isPollMode) {
                                            android.widget.Toast.makeText(context, "Poll posts cannot contain media attachments", android.widget.Toast.LENGTH_SHORT).show()
                                        } else {
                                            videoPickerLauncher.launch(
                                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)
                                            )
                                        }
                                    },
                            )

                            // Song
                            Icon(
                                imageVector = Icons.Rounded.MusicNote,
                                contentDescription = "Attach Song",
                                tint = if (isPollMode) MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                                else if (attachedTrack != null) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(24.dp)
                                    .clickable {
                                        if (isPollMode) {
                                            android.widget.Toast.makeText(context, "Poll posts cannot contain media attachments", android.widget.Toast.LENGTH_SHORT).show()
                                        } else {
                                            showMusicSearch = true
                                        }
                                    },
                            )

                            // Poll
                            Icon(
                                imageVector = Icons.Rounded.Poll,
                                contentDescription = "Create Poll",
                                tint = if (showPollBuilder) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(24.dp)
                                    .clickable {
                                        if (!showPollBuilder) {
                                            val hadMedia = selectedImageUris.isNotEmpty() || selectedVideoUri != null ||
                                                    selectedGifUrl != null || attachedTrack != null || recordedAudioFile != null || isRecordingVoice
                                            selectedImageUris.clear()
                                            selectedVideoUri = null
                                            selectedGifUrl = null
                                            attachedTrack = null
                                            if (isRecordingVoice) {
                                                voiceRecorder.stopRecording()
                                            }
                                            recordedAudioFile = null
                                            if (hadMedia) {
                                                android.widget.Toast.makeText(context, "Cleared media attachments for poll post", android.widget.Toast.LENGTH_SHORT).show()
                                            }
                                            showPollBuilder = true
                                        } else {
                                            showPollBuilder = false
                                        }
                                    },
                            )

                            // GIF
                            Text(
                                text = "GIF",
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.ExtraBold),
                                color = if (isPollMode) MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                                else if (selectedGifUrl != null) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.clickable {
                                    if (isPollMode) {
                                        android.widget.Toast.makeText(context, "Poll posts cannot contain media attachments", android.widget.Toast.LENGTH_SHORT).show()
                                    } else {
                                        showGifPicker = true
                                    }
                                },
                            )

                            // Voice Note
                            Icon(
                                imageVector = Icons.Rounded.Mic,
                                contentDescription = "Record Voice Note",
                                tint = if (isPollMode) MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
                                else if (isRecordingVoice || recordedAudioFile != null) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(24.dp)
                                    .clickable {
                                        if (isPollMode) {
                                            android.widget.Toast.makeText(context, "Poll posts cannot contain media attachments", android.widget.Toast.LENGTH_SHORT).show()
                                        } else if (isRecordingVoice) {
                                            val file = voiceRecorder.stopRecording()
                                            if (file != null && file.exists()) {
                                                recordedAudioFile = file
                                            }
                                        } else {
                                            voiceRecorder.startRecording()
                                        }
                                    },
                            )
                        }

                        // Post Pill Button
                        val canPost = !isPosting && !isUploadingMedia && (
                            textContent.isNotBlank() || selectedImageUris.isNotEmpty() || selectedVideoUri != null ||
                                selectedGifUrl != null || attachedTrack != null || showPollBuilder || recordedAudioFile != null || quotedPost != null
                        )

                        Button(
                            onClick = {
                                scope.launch {
                                    isUploadingMedia = true
                                    // 1. Upload selected images (skip if poll post)
                                    val uploadedUrls = mutableListOf<String>()
                                    if (!showPollBuilder) {
                                        selectedImageUris.forEach { uri ->
                                            runCatching {
                                                val bytes = withContext(Dispatchers.IO) {
                                                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                                }
                                                if (bytes != null) {
                                                    val uploadResult = SupabaseService.uploadImage(
                                                        bytes = bytes,
                                                        mimeType = "image/jpeg",
                                                    )
                                                    uploadResult.getOrNull()?.let { uploadedUrls.add(it) }
                                                }
                                            }
                                        }
                                    }

                                    // 2. Upload video (skip if poll post)
                                    var uploadedVideoUrl: String? = null
                                    if (!showPollBuilder) {
                                        selectedVideoUri?.let { uri ->
                                            runCatching {
                                                val bytes = withContext(Dispatchers.IO) {
                                                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                                }
                                                if (bytes != null) {
                                                    val uploadResult = SupabaseService.uploadMedia(
                                                        bytes = bytes,
                                                        mimeType = "video/mp4",
                                                    )
                                                    uploadedVideoUrl = uploadResult.getOrNull()
                                                }
                                            }
                                        }
                                    }

                                    // 3. Upload voice note (skip if poll post)
                                    var uploadedAudioUrl: String? = null
                                    if (!showPollBuilder) {
                                        recordedAudioFile?.let { file ->
                                            runCatching {
                                                val bytes = withContext(Dispatchers.IO) { file.readBytes() }
                                                val uploadResult = SupabaseService.uploadMedia(
                                                    bytes = bytes,
                                                    mimeType = "audio/mp4",
                                                )
                                                uploadedAudioUrl = uploadResult.getOrNull()
                                            }
                                        }
                                    }

                                    isUploadingMedia = false

                                    // 4. Construct poll
                                    val finalPoll = if (showPollBuilder && pollQuestion.isNotBlank() && pollOptions.size >= 2) {
                                        val calculatedEndsAt = runCatching {
                                            java.time.Instant.now().plus(pollDurationDays.toLong(), java.time.temporal.ChronoUnit.DAYS).toString()
                                        }.getOrNull()
                                        PollData(
                                            question = pollQuestion.trim(),
                                            options = pollOptions.mapIndexedNotNull { idx, text ->
                                                val track = pollOptionTracks[idx]
                                                val img = pollOptionImages[idx] ?: track?.artworkUrl ?: track?.thumbnailUrl
                                                val effectiveText = text.trim().ifEmpty { track?.let { "${it.title} - ${it.artist}" } }
                                                if (effectiveText.isNullOrBlank() && track == null && img == null) null
                                                else PollOption(
                                                    text = effectiveText ?: "Option ${idx + 1}",
                                                    songAttachment = track,
                                                    imageUrl = img,
                                                )
                                            },
                                            endsAt = calculatedEndsAt,
                                        )
                                    } else null

                                    if (finalPoll != null) {
                                        onSubmitPost(
                                            textContent.trim(),
                                            emptyList(),
                                            null,
                                            null,
                                            null,
                                            selectedMode == CreateMode.REVIEW,
                                            if (selectedMode == CreateMode.REVIEW) reviewRating else 0,
                                            taggedArtist,
                                            null,
                                            finalPoll,
                                            quotedPost?.id,
                                        )
                                    } else {
                                        onSubmitPost(
                                            textContent.trim(),
                                            uploadedUrls,
                                            uploadedVideoUrl,
                                            selectedGifUrl,
                                            uploadedAudioUrl,
                                            selectedMode == CreateMode.REVIEW,
                                            if (selectedMode == CreateMode.REVIEW) reviewRating else 0,
                                            taggedArtist,
                                            attachedTrack,
                                            null,
                                            quotedPost?.id,
                                        )
                                    }
                                }
                            },
                            enabled = canPost,
                            shape = RoundedCornerShape(20.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.primary,
                                contentColor = MaterialTheme.colorScheme.onPrimary,
                                disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                                disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                            ),
                            contentPadding = PaddingValues(horizontal = 24.dp, vertical = 10.dp),
                        ) {
                            if (isPosting || isUploadingMedia) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    color = MaterialTheme.colorScheme.onPrimary,
                                    strokeWidth = 2.dp,
                                )
                            } else {
                                Text(
                                    text = if (quotedPost != null) "Quote" else "Post",
                                    style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // GIF Picker Modal
    if (showGifPicker) {
        GifPickerSheet(
            onDismiss = { showGifPicker = false },
            onSelectGif = { gifUrl ->
                selectedGifUrl = gifUrl
                showGifPicker = false
            },
        )
    }

    // Music Search Modal
    if (showMusicSearch) {
        SongSearchDialog(
            onDismiss = { showMusicSearch = false },
            onSongSelected = { song ->
                attachedTrack = MusicTrackAttachment(
                    videoId = song.videoId,
                    title = song.title,
                    artist = song.artist,
                    artworkUrl = song.thumbnailUrl,
                    durationText = song.durationText,
                )
                showMusicSearch = false
            },
        )
    }

    if (pickingAttachmentForOptionIndex != null) {
        val optionIdx = pickingAttachmentForOptionIndex!!
        PollOptionAttachmentDialog(
            onDismiss = { pickingAttachmentForOptionIndex = null },
            onTrackSelected = { track ->
                pollOptionTracks[optionIdx] = track
                pollOptionImages[optionIdx] = track.artworkUrl ?: track.thumbnailUrl
                if (pollOptions.getOrNull(optionIdx)?.isBlank() == true) {
                    pollOptions[optionIdx] = "${track.title} - ${track.artist}"
                }
                pickingAttachmentForOptionIndex = null
            },
            onArtistSelected = { artistName, imageUrl ->
                pollOptionTracks.remove(optionIdx)
                pollOptionImages[optionIdx] = imageUrl
                if (pollOptions.getOrNull(optionIdx)?.isBlank() == true) {
                    pollOptions[optionIdx] = artistName
                }
                pickingAttachmentForOptionIndex = null
            },
            onAlbumSelected = { albumTitle, imageUrl ->
                pollOptionTracks.remove(optionIdx)
                pollOptionImages[optionIdx] = imageUrl
                if (pollOptions.getOrNull(optionIdx)?.isBlank() == true) {
                    pollOptions[optionIdx] = albumTitle
                }
                pickingAttachmentForOptionIndex = null
            },
        )
    }

    // Artist Search Modal
    if (showArtistPicker) {
        ArtistSearchDialog(
            onDismiss = { showArtistPicker = false },
            onArtistSelected = { artistName ->
                taggedArtist = artistName
                showArtistPicker = false
            },
        )
    }
}

/**
 * Clean Choice Screen: Post vs Review.
 * 100% solid colors, zero borders, zero gradients, zero emojis.
 */
@Composable
private fun CreateChoiceScreen(
    onDismiss: () -> Unit,
    onSelectPost: () -> Unit,
    onSelectReview: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp, vertical = 16.dp),
    ) {
        // Top Header
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(
                onClick = onDismiss,
                contentPadding = PaddingValues(0.dp),
            ) {
                Text(
                    text = "Cancel",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Medium),
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }

            Text(
                text = "Create",
                style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
            )

            Spacer(Modifier.width(48.dp))
        }

        Spacer(Modifier.height(28.dp))

        Text(
            text = "What is on your mind?",
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(18.dp))

        // Card 1: Normal Post
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .clickable { onSelectPost() }
                .padding(20.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(46.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Rounded.EditNote,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(26.dp),
                )
            }

            Spacer(Modifier.width(16.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Post",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text = "Share a music moment",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        Spacer(Modifier.height(16.dp))

        // Card 2: Music Review
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .clickable { onSelectReview() }
                .padding(20.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(46.dp)
                    .clip(CircleShape)
                    .background(Color(0xFFFFB300)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Rounded.Star,
                    contentDescription = null,
                    tint = Color.Black,
                    modifier = Modifier.size(26.dp),
                )
            }

            Spacer(Modifier.width(16.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Review",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text = "Rate a song or project",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        Spacer(Modifier.weight(1f))

        // Bottom Info Card: Boost your reach
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(16.dp),
        ) {
            Icon(
                imageVector = Icons.Rounded.RocketLaunch,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(24.dp),
            )
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Boost your reach",
                    style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text = "Music content with substance gets more visibility across Vibra.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        Spacer(Modifier.height(16.dp))
    }
}

/**
 * Modal dialog for searching and picking an artist tag.
 */
@Composable
private fun ArtistSearchDialog(
    onDismiss: () -> Unit,
    onArtistSelected: (String) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<String>>(emptyList()) }
    var isSearching by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(query) {
        val q = query.trim()
        if (q.length >= 2) {
            isSearching = true
            scope.launch {
                val searchItems = withContext(Dispatchers.IO) {
                    YtMusicRepository.search(q, SearchFilter.ARTISTS).getOrNull().orEmpty()
                }
                results = searchItems.mapNotNull { item ->
                    when (item) {
                        is SearchResult.Browse -> item.item.title
                        else -> null
                    }
                }
                isSearching = false
            }
        } else {
            results = emptyList()
            isSearching = false
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(20.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Tag Artist",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            // Search Bar
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Rounded.Search,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        textStyle = TextStyle(
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 14.sp,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        decorationBox = { innerTextField ->
                            if (query.isEmpty()) {
                                Text(
                                    text = "Search artist name...",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            innerTextField()
                        },
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            if (isSearching) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        color = MaterialTheme.colorScheme.primary,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(24.dp),
                    )
                }
            } else if (results.isNotEmpty()) {
                LazyColumn(modifier = Modifier.height(200.dp)) {
                    items(results) { artistName ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .clickable { onArtistSelected(artistName) }
                                .padding(vertical = 10.dp, horizontal = 8.dp),
                        ) {
                            Text(
                                text = artistName,
                                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            } else if (query.isNotBlank()) {
                TextButton(
                    onClick = { onArtistSelected(query.trim()) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        text = "Use \"${query.trim()}\"",
                        style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }
        }
    }
}

/**
 * Modal dialog for searching and attaching a song.
 */
@Composable
private fun SongSearchDialog(
    onDismiss: () -> Unit,
    onSongSelected: (Song) -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Song>>(emptyList()) }
    var isSearching by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(query) {
        val q = query.trim()
        if (q.length >= 2) {
            isSearching = true
            scope.launch {
                val searchItems = withContext(Dispatchers.IO) {
                    YtMusicRepository.search(q, SearchFilter.SONGS).getOrNull().orEmpty()
                }
                results = searchItems.mapNotNull { item ->
                    when (item) {
                        is SearchResult.Track -> item.song
                        is SearchResult.TopTrack -> item.song
                        else -> null
                    }
                }
                isSearching = false
            }
        } else {
            results = emptyList()
            isSearching = false
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(20.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Attach Song",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            // Search Bar
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Rounded.Search,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        textStyle = TextStyle(
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 14.sp,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        decorationBox = { innerTextField ->
                            if (query.isEmpty()) {
                                Text(
                                    text = "Search song or artist...",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            innerTextField()
                        },
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            if (isSearching) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(150.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        color = MaterialTheme.colorScheme.primary,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(24.dp),
                    )
                }
            } else {
                LazyColumn(modifier = Modifier.height(240.dp)) {
                    items(results) { song ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .clickable { onSongSelected(song) }
                                .padding(vertical = 8.dp, horizontal = 4.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(42.dp)
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                if (song.thumbnailUrl != null) {
                                    AsyncImage(
                                        model = song.thumbnailUrl,
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                }
                            }

                            Spacer(Modifier.width(12.dp))

                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = song.title,
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    text = song.artist,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
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
}

private enum class PollAttachmentTab(val label: String) {
    SONG("Song"),
    ARTIST("Artist"),
    ALBUM("Album"),
}

/**
 * Modal dialog allowing attachment of a Song, Artist, or Album to a poll option.
 * 100% solid theme colors, zero emojis.
 */
@Composable
private fun PollOptionAttachmentDialog(
    onDismiss: () -> Unit,
    onTrackSelected: (MusicTrackAttachment) -> Unit,
    onArtistSelected: (name: String, imageUrl: String?) -> Unit,
    onAlbumSelected: (title: String, imageUrl: String?) -> Unit,
) {
    var activeTab by remember { mutableStateOf(PollAttachmentTab.SONG) }
    var query by remember { mutableStateOf("") }
    var songResults by remember { mutableStateOf<List<Song>>(emptyList()) }
    var browseResults by remember { mutableStateOf<List<BrowseItem>>(emptyList()) }
    var isSearching by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(query, activeTab) {
        val q = query.trim()
        if (q.length >= 2) {
            isSearching = true
            scope.launch {
                val filter = when (activeTab) {
                    PollAttachmentTab.SONG -> SearchFilter.SONGS
                    PollAttachmentTab.ARTIST -> SearchFilter.ARTISTS
                    PollAttachmentTab.ALBUM -> SearchFilter.ALBUMS
                }
                val rawResults = withContext(Dispatchers.IO) {
                    YtMusicRepository.search(q, filter).getOrNull().orEmpty()
                }
                when (activeTab) {
                    PollAttachmentTab.SONG -> {
                        songResults = rawResults.mapNotNull { item ->
                            when (item) {
                                is SearchResult.Track -> item.song
                                is SearchResult.TopTrack -> item.song
                                else -> null
                            }
                        }
                        browseResults = emptyList()
                    }
                    PollAttachmentTab.ARTIST, PollAttachmentTab.ALBUM -> {
                        browseResults = rawResults.mapNotNull { item ->
                            when (item) {
                                is SearchResult.Browse -> item.item
                                else -> null
                            }
                        }
                        songResults = emptyList()
                    }
                }
                isSearching = false
            }
        } else {
            songResults = emptyList()
            browseResults = emptyList()
            isSearching = false
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(MaterialTheme.colorScheme.surface)
                .padding(20.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Attach to Option",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            // Tab selector (Song / Artist / Album)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                PollAttachmentTab.entries.forEach { tab ->
                    val isSelected = activeTab == tab
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(8.dp))
                            .background(if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent)
                            .clickable {
                                activeTab = tab
                                songResults = emptyList()
                                browseResults = emptyList()
                            }
                            .padding(vertical = 8.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = tab.label,
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                            color = if (isSelected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Search Bar
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Rounded.Search,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        textStyle = TextStyle(
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 14.sp,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        decorationBox = { innerTextField ->
                            if (query.isEmpty()) {
                                Text(
                                    text = "Search ${activeTab.label.lowercase()}...",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            innerTextField()
                        },
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            if (isSearching) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(180.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        color = MaterialTheme.colorScheme.primary,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(24.dp),
                    )
                }
            } else if (activeTab == PollAttachmentTab.SONG && songResults.isNotEmpty()) {
                LazyColumn(modifier = Modifier.height(240.dp)) {
                    items(songResults) { song ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .clickable {
                                    val fallbackArtwork = song.thumbnailUrl ?: "https://i.ytimg.com/vi/${song.videoId}/hqdefault.jpg"
                                    onTrackSelected(
                                        MusicTrackAttachment(
                                            videoId = song.videoId,
                                            title = song.title,
                                            artist = song.artist,
                                            thumbnailUrl = fallbackArtwork,
                                            artworkUrl = fallbackArtwork,
                                            durationText = song.durationText,
                                        )
                                    )
                                }
                                .padding(vertical = 8.dp, horizontal = 4.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(42.dp)
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                val thumb = song.thumbnailUrl ?: "https://i.ytimg.com/vi/${song.videoId}/hqdefault.jpg"
                                AsyncImage(
                                    model = thumb,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }

                            Spacer(Modifier.width(12.dp))

                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = song.title,
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    text = song.artist,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                }
            } else if ((activeTab == PollAttachmentTab.ARTIST || activeTab == PollAttachmentTab.ALBUM) && browseResults.isNotEmpty()) {
                LazyColumn(modifier = Modifier.height(240.dp)) {
                    items(browseResults) { item ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .clickable {
                                    if (activeTab == PollAttachmentTab.ARTIST) {
                                        onArtistSelected(item.title, item.thumbnailUrl)
                                    } else {
                                        onAlbumSelected(item.title, item.thumbnailUrl)
                                    }
                                }
                                .padding(vertical = 8.dp, horizontal = 4.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(42.dp)
                                    .clip(if (activeTab == PollAttachmentTab.ARTIST) CircleShape else RoundedCornerShape(6.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                if (!item.thumbnailUrl.isNullOrBlank()) {
                                    AsyncImage(
                                        model = item.thumbnailUrl,
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                }
                            }

                            Spacer(Modifier.width(12.dp))

                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = item.title,
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (item.subtitle.isNotBlank()) {
                                    Text(
                                        text = item.subtitle,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }
                }
            } else if (query.isNotBlank() && !isSearching) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(100.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "No results found for \"$query\"",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

