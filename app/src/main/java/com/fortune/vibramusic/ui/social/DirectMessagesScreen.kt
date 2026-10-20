package com.fortune.vibramusic.ui.social

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Reply
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Gif
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.data.model.Song
import androidx.compose.runtime.mutableIntStateOf
import com.fortune.vibramusic.data.social.ConversationSummary
import com.fortune.vibramusic.data.social.DirectMessage
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PostMediaItem
import com.fortune.vibramusic.data.social.PostMediaType
import com.fortune.vibramusic.data.social.SharedPlaylistAttachment
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.data.social.formatMessageTime
import com.fortune.vibramusic.data.social.formatRelativeTime
import com.fortune.vibramusic.data.social.isUserOnline
import com.fortune.vibramusic.data.social.isWithinEditWindow
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.ui.components.ArtistAvatar
import com.fortune.vibramusic.ui.components.MentionSuggestionPopup
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DirectMessagesScreen(
    viewModel: SocialViewModel,
    currentlyPlayingSong: Song?,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
    contentPadding: PaddingValues,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val activeChatFriend by viewModel.activeChatFriend.collectAsStateWithLifecycle()
    val conversations by viewModel.conversations.collectAsStateWithLifecycle()
    val messages by viewModel.chatMessages.collectAsStateWithLifecycle()
    val myProfile by viewModel.currentProfile.collectAsStateWithLifecycle()

    var messageText by remember { mutableStateOf("") }
    var attachedTrack by remember { mutableStateOf<MusicTrackAttachment?>(null) }
    var attachedPlaylist by remember { mutableStateOf<SharedPlaylistAttachment?>(null) }
    var stagedImageUri by remember { mutableStateOf<Uri?>(null) }
    var stagedVideoUri by remember { mutableStateOf<Uri?>(null) }
    var stagedGifUrl by remember { mutableStateOf<String?>(null) }

    var showAttachmentPicker by remember { mutableStateOf(false) }
    var showGifPicker by remember { mutableStateOf(false) }
    var showMediaMenu by remember { mutableStateOf(false) }
    var isUploadingMedia by remember { mutableStateOf(false) }

    var replyingToMessage by remember { mutableStateOf<DirectMessage?>(null) }
    var actionTargetMessage by remember { mutableStateOf<DirectMessage?>(null) }
    var editingMessage by remember { mutableStateOf<DirectMessage?>(null) }
    var editedMessageText by remember { mutableStateOf("") }
    var messageToDelete by remember { mutableStateOf<DirectMessage?>(null) }
    var selectedReceiptMessageId by remember { mutableStateOf<String?>(null) }

    var fullScreenMediaList by remember { mutableStateOf<List<PostMediaItem>?>(null) }
    var fullScreenMediaIndex by remember { mutableIntStateOf(0) }

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

    // Audio recording & playback manager
    val voiceRecorderManager = remember { VoiceRecorderManager(context) }
    DisposableEffect(Unit) {
        onDispose {
            voiceRecorderManager.release()
        }
    }

    val isRecording by voiceRecorderManager.isRecording.collectAsStateWithLifecycle()
    val recordDuration by voiceRecorderManager.recordingDurationSeconds.collectAsStateWithLifecycle()
    val currentlyPlayingAudioUrl by voiceRecorderManager.currentlyPlayingUrl.collectAsStateWithLifecycle()
    val isAudioPlaying by voiceRecorderManager.isPlaying.collectAsStateWithLifecycle()

    // Activity Result Launchers for Photo and Video
    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            stagedImageUri = uri
            stagedVideoUri = null
            stagedGifUrl = null
        }
    }

    val videoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            stagedVideoUri = uri
            stagedImageUri = null
            stagedGifUrl = null
        }
    }

    // Audio Permission Launcher
    val audioPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { isGranted ->
        if (isGranted) {
            voiceRecorderManager.startRecording()
        }
    }

    Box(
        modifier = modifier.fillMaxSize(),
    ) {
        if (activeChatFriend == null) {
            // Conversations List View
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(top = contentPadding.calculateTopPadding()),
            ) {
                Text(
                    text = "Direct Messages",
                    style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
                )

                if (conversations.isEmpty()) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(bottom = 100.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(
                                imageVector = Icons.Rounded.Person,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(52.dp),
                            )
                            Spacer(Modifier.height(14.dp))
                            Text(
                                text = "No conversations yet",
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Connect with friends to start chatting and sharing tracks",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(
                            bottom = contentPadding.calculateBottomPadding() + 80.dp,
                        ),
                    ) {
                        itemsIndexed(
                            items = conversations.distinctBy { it.friend.id },
                            key = { index, summary -> "conv_${summary.friend.id.ifBlank { index.toString() }}_$index" },
                        ) { _, summary ->
                            ConversationRow(
                                summary = summary,
                                onClick = { viewModel.openChat(summary.friend) },
                            )
                        }
                    }
                }
            }
        } else {
            // Full Screen Dedicated Active Chat Thread View
            val friend = activeChatFriend!!

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.background)
                    .windowInsetsPadding(WindowInsets.statusBars)
                    .windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime)),
            ) {
                // Top Bar with Back Arrow and Friend Profile Header
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = { viewModel.closeChat() },
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

                    Spacer(Modifier.width(10.dp))

                    Row(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(12.dp))
                            .clickable { viewModel.openUserProfile(friend) }
                            .padding(4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        ArtistAvatar(
                            artistName = friend.displayName,
                            artworkUrl = friend.avatarUrl?.takeIf { it.isNotBlank() && it != "null" },
                            size = 40.dp,
                        )

                        Spacer(Modifier.width(10.dp))

                        Column {
                            Text(
                                text = friend.displayName,
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                text = formatHandle(friend.handle),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }

                val lastMessageId = messages.lastOrNull()?.id
                val isFriendOnline = remember(friend, messages) { isUserOnline(friend, messages) }

                LaunchedEffect(friend.id) {
                    myProfile?.id?.let { myId ->
                        SupabaseService.updatePresence(myId)
                    }
                    while (true) {
                        kotlinx.coroutines.delay(4000)
                        myProfile?.id?.let { myId ->
                            SupabaseService.updatePresence(myId)
                        }
                        viewModel.refreshDirectMessages()
                    }
                }

                // Messages List
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                    reverseLayout = true,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    contentPadding = PaddingValues(vertical = 12.dp),
                ) {
                    itemsIndexed(
                        items = messages.reversed().distinctBy { it.id },
                        key = { index, msg -> "msg_${msg.id.ifBlank { index.toString() }}_$index" },
                    ) { _, msg ->
                        val isMine = msg.senderId == myProfile?.id
                        val isLastMessage = msg.id == lastMessageId
                        val showReceipt = if (selectedReceiptMessageId == null) {
                            isLastMessage
                        } else if (selectedReceiptMessageId == "NONE") {
                            false
                        } else {
                            msg.id == selectedReceiptMessageId
                        }

                        MessageBubble(
                            message = msg,
                            isMine = isMine,
                            friendDisplayName = friend.displayName,
                            isFriendOnline = isFriendOnline,
                            showReceipt = showReceipt,
                            onToggleReceipt = {
                                if (selectedReceiptMessageId == null) {
                                    if (msg.id == lastMessageId) {
                                        selectedReceiptMessageId = "NONE"
                                    } else {
                                        selectedReceiptMessageId = msg.id
                                    }
                                } else if (selectedReceiptMessageId == "NONE") {
                                    selectedReceiptMessageId = msg.id
                                } else if (selectedReceiptMessageId == msg.id) {
                                    selectedReceiptMessageId = null
                                } else if (msg.id == lastMessageId) {
                                    selectedReceiptMessageId = null
                                } else {
                                    selectedReceiptMessageId = msg.id
                                }
                            },
                            onPlayTrack = onPlayTrack,
                            voiceRecorderManager = voiceRecorderManager,
                            currentlyPlayingAudioUrl = currentlyPlayingAudioUrl,
                            isAudioPlaying = isAudioPlaying,
                            onReply = { replyingToMessage = it },
                            onLongClick = { actionTargetMessage = it },
                            onMediaClick = { list, idx ->
                                fullScreenMediaList = list
                                fullScreenMediaIndex = idx
                            },
                        )
                    }
                }

                // Staged Media Previews (Image, Video, GIF, Track, Playlist)
                if (stagedImageUri != null || stagedVideoUri != null || stagedGifUrl != null || attachedTrack != null || attachedPlaylist != null) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        stagedImageUri?.let { uri ->
                            Box(
                                modifier = Modifier
                                    .size(68.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                AsyncImage(
                                    model = uri,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                                IconButton(
                                    onClick = { stagedImageUri = null },
                                    modifier = Modifier
                                        .size(22.dp)
                                        .align(Alignment.TopEnd)
                                        .clip(CircleShape)
                                        .background(Color.Black),
                                ) {
                                    Icon(Icons.Rounded.Close, null, tint = Color.White, modifier = Modifier.size(14.dp))
                                }
                            }
                        }

                        stagedVideoUri?.let { uri ->
                            Box(
                                modifier = Modifier
                                    .size(68.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Color.Black),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(Icons.Rounded.Videocam, null, tint = Color.White, modifier = Modifier.size(24.dp))
                                IconButton(
                                    onClick = { stagedVideoUri = null },
                                    modifier = Modifier
                                        .size(22.dp)
                                        .align(Alignment.TopEnd)
                                        .clip(CircleShape)
                                        .background(Color.Black),
                                ) {
                                    Icon(Icons.Rounded.Close, null, tint = Color.White, modifier = Modifier.size(14.dp))
                                }
                            }
                        }

                        stagedGifUrl?.let { url ->
                            Box(
                                modifier = Modifier
                                    .size(68.dp)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                AsyncImage(
                                    model = url,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                                IconButton(
                                    onClick = { stagedGifUrl = null },
                                    modifier = Modifier
                                        .size(22.dp)
                                        .align(Alignment.TopEnd)
                                        .clip(CircleShape)
                                        .background(Color.Black),
                                ) {
                                    Icon(Icons.Rounded.Close, null, tint = Color.White, modifier = Modifier.size(14.dp))
                                }
                            }
                        }

                        attachedTrack?.let { track ->
                            Row(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(Icons.Rounded.MusicNote, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(track.title, style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold), color = MaterialTheme.colorScheme.onSurface, maxLines = 1)
                                    Text(track.artist, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                                }
                                IconButton(onClick = { attachedTrack = null }, modifier = Modifier.size(24.dp)) {
                                    Icon(Icons.Rounded.Close, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                                }
                            }
                        }

                        attachedPlaylist?.let { playlist ->
                            Row(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(Icons.Rounded.QueueMusic, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(playlist.title, style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold), color = MaterialTheme.colorScheme.onSurface, maxLines = 1)
                                    Text("Playlist • ${playlist.author ?: "Vibra"}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                                }
                                IconButton(onClick = { attachedPlaylist = null }, modifier = Modifier.size(24.dp)) {
                                    Icon(Icons.Rounded.Close, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                                }
                            }
                        }
                    }
                }

                // Replying Preview Banner (docked directly above the chat controls)
                if (replyingToMessage != null) {
                    val rep = replyingToMessage!!
                    val isRepMine = rep.senderId == myProfile?.id
                    val repAuthor = if (isRepMine) "yourself" else friend.displayName
                    val repSnippet = rep.content.ifBlank {
                        when {
                            rep.sharedMusic != null -> "Song: ${rep.sharedMusic.title}"
                            rep.sharedPlaylist != null -> "Playlist: ${rep.sharedPlaylist.title}"
                            !rep.imageUrl.isNullOrBlank() -> "Photo"
                            !rep.videoUrl.isNullOrBlank() -> "Video"
                            !rep.audioUrl.isNullOrBlank() -> "Voice note"
                            !rep.gifUrl.isNullOrBlank() -> "GIF"
                            else -> "Message"
                        }
                    }

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 4.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .width(3.dp)
                                .height(32.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(MaterialTheme.colorScheme.primary),
                        )
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "Replying to $repAuthor",
                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.primary,
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                text = repSnippet,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        IconButton(
                            onClick = { replyingToMessage = null },
                            modifier = Modifier.size(24.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Dismiss reply",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }

                // Voice Recording State Banner (Active recording)
                if (isRecording) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp)
                            .clip(RoundedCornerShape(24.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // Pulsing red indicator
                        Box(
                            modifier = Modifier
                                .size(10.dp)
                                .clip(CircleShape)
                                .background(Color(0xFFEF4444)),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = "%02d:%02d".format(recordDuration / 60, recordDuration % 60),
                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Spacer(Modifier.width(12.dp))

                        // Waveform visualization
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.weight(1f),
                        ) {
                            listOf(6, 12, 18, 10, 16, 22, 14, 20, 12, 8, 14, 18, 10).forEach { h ->
                                Box(
                                    modifier = Modifier
                                        .width(3.dp)
                                        .height(h.dp)
                                        .clip(RoundedCornerShape(2.dp))
                                        .background(MaterialTheme.colorScheme.primary),
                                )
                            }
                        }

                        // Cancel button
                        IconButton(
                            onClick = { voiceRecorderManager.cancelRecording() },
                            modifier = Modifier.size(36.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Delete,
                                contentDescription = "Cancel Recording",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(20.dp),
                            )
                        }

                        // Send Voice Note button
                        IconButton(
                            onClick = {
                                val recordedFile = voiceRecorderManager.stopRecording()
                                if (recordedFile != null && recordedFile.exists()) {
                                    scope.launch {
                                        isUploadingMedia = true
                                        val bytes = withContext(Dispatchers.IO) { recordedFile.readBytes() }
                                        val uploaded = SupabaseService.uploadMedia(
                                            bytes = bytes,
                                            mimeType = "audio/mp4",
                                            fileName = "vn_${UUID.randomUUID()}.m4a",
                                        )
                                        uploaded.onSuccess { url ->
                                            viewModel.sendDirectMessage(
                                                text = "",
                                                audioUrl = url,
                                                replyTo = replyingToMessage,
                                            )
                                            replyingToMessage = null
                                        }
                                        recordedFile.delete()
                                        isUploadingMedia = false
                                    }
                                }
                            },
                            modifier = Modifier
                                .size(38.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.Send,
                                contentDescription = "Send Voice Note",
                                tint = MaterialTheme.colorScheme.onPrimary,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                } else {
                    // Mention Suggestions Popup above Input Bar
                    if (mentionQuery != null && (mentionSuggestions.isNotEmpty() || isSearchingMentions)) {
                        MentionSuggestionPopup(
                            suggestions = mentionSuggestions,
                            isLoading = isSearchingMentions,
                            onSelectUser = { user ->
                                val lastAt = messageText.lastIndexOf('@')
                                if (lastAt >= 0) {
                                    val prefix = messageText.substring(0, lastAt)
                                    val cleanHandle = user.handle.removePrefix("@")
                                    messageText = "$prefix@$cleanHandle "
                                }
                                mentionQuery = null
                                mentionSuggestions = emptyList()
                            },
                            onDismiss = {
                                mentionQuery = null
                                mentionSuggestions = emptyList()
                            },
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                        )
                    }

                    // Chat Input Bar (Docked directly above keyboard via imePadding)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // Media Attach Button (+)
                        Box {
                            IconButton(
                                onClick = { showMediaMenu = true },
                                modifier = Modifier
                                    .size(40.dp)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Add,
                                    contentDescription = "Attach media",
                                    tint = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.size(22.dp),
                                )
                            }

                            DropdownMenu(
                                expanded = showMediaMenu,
                                onDismissRequest = { showMediaMenu = false },
                            ) {
                                DropdownMenuItem(
                                    text = { Text("Share Music") },
                                    leadingIcon = { Icon(Icons.Rounded.MusicNote, null) },
                                    onClick = {
                                        showMediaMenu = false
                                        showAttachmentPicker = true
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Photo") },
                                    leadingIcon = { Icon(Icons.Rounded.Image, null) },
                                    onClick = {
                                        showMediaMenu = false
                                        photoPickerLauncher.launch(
                                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                                        )
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text("Video") },
                                    leadingIcon = { Icon(Icons.Rounded.Videocam, null) },
                                    onClick = {
                                        showMediaMenu = false
                                        videoPickerLauncher.launch(
                                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)
                                        )
                                    },
                                )
                            }
                        }

                        Spacer(Modifier.width(8.dp))

                        // GIF Button
                        IconButton(
                            onClick = { showGifPicker = true },
                            modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.surfaceVariant),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Gif,
                                contentDescription = "Add GIF",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(24.dp),
                            )
                        }

                        Spacer(Modifier.width(8.dp))

                        // Text Input
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(24.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                                .padding(horizontal = 16.dp, vertical = 11.dp),
                        ) {
                            if (messageText.isEmpty()) {
                                val recipientLabel = friend.displayName.ifBlank { formatHandle(friend.handle) }
                                Text(
                                    text = "Message $recipientLabel...",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            BasicTextField(
                                value = messageText,
                                onValueChange = { newText ->
                                    messageText = newText
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
                                    fontSize = 14.sp,
                                ),
                                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }

                        Spacer(Modifier.width(8.dp))

                        // Send or Mic Action Button
                        val hasDraft = messageText.isNotBlank() || stagedImageUri != null || stagedVideoUri != null || stagedGifUrl != null || attachedTrack != null || attachedPlaylist != null

                        if (hasDraft || isUploadingMedia) {
                            IconButton(
                                onClick = {
                                    val trimmed = messageText.trim()
                                    scope.launch {
                                        isUploadingMedia = true
                                        var finalImageUrl: String? = null
                                        var finalVideoUrl: String? = null

                                        stagedImageUri?.let { uri ->
                                            val bytes = withContext(Dispatchers.IO) {
                                                context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                            }
                                            if (bytes != null) {
                                                SupabaseService.uploadMedia(bytes, "image/jpeg", "dm_img_${UUID.randomUUID()}.jpg")
                                                    .onSuccess { finalImageUrl = it }
                                            }
                                        }

                                        stagedVideoUri?.let { uri ->
                                            val bytes = withContext(Dispatchers.IO) {
                                                context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                            }
                                            if (bytes != null) {
                                                SupabaseService.uploadMedia(bytes, "video/mp4", "dm_vid_${UUID.randomUUID()}.mp4")
                                                    .onSuccess { finalVideoUrl = it }
                                            }
                                        }

                                        viewModel.sendDirectMessage(
                                            text = trimmed,
                                            musicAttachment = attachedTrack,
                                            playlistAttachment = attachedPlaylist,
                                            imageUrl = finalImageUrl,
                                            videoUrl = finalVideoUrl,
                                            gifUrl = stagedGifUrl,
                                            replyTo = replyingToMessage,
                                        )

                                        messageText = ""
                                        attachedTrack = null
                                        attachedPlaylist = null
                                        stagedImageUri = null
                                        stagedVideoUri = null
                                        stagedGifUrl = null
                                        replyingToMessage = null
                                        isUploadingMedia = false
                                    }
                                },
                                enabled = !isUploadingMedia,
                                modifier = Modifier
                                    .size(40.dp)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.primary),
                            ) {
                                if (isUploadingMedia) {
                                    CircularProgressIndicator(
                                        color = MaterialTheme.colorScheme.onPrimary,
                                        strokeWidth = 2.dp,
                                        modifier = Modifier.size(18.dp),
                                    )
                                } else {
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Rounded.Send,
                                        contentDescription = "Send",
                                        tint = MaterialTheme.colorScheme.onPrimary,
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            }
                        } else {
                            // Mic Button
                            IconButton(
                                onClick = {
                                    val hasPermission = ContextCompat.checkSelfPermission(
                                        context,
                                        android.Manifest.permission.RECORD_AUDIO,
                                    ) == PackageManager.PERMISSION_GRANTED

                                    if (hasPermission) {
                                        voiceRecorderManager.startRecording()
                                    } else {
                                        audioPermissionLauncher.launch(android.Manifest.permission.RECORD_AUDIO)
                                    }
                                },
                                modifier = Modifier
                                    .size(40.dp)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Mic,
                                    contentDescription = "Record Voice Note",
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // Modal Attachment Picker Sheet for Sharing Songs & Playlists
    if (showAttachmentPicker) {
        ChatAttachmentPickerSheet(
            currentlyPlayingSong = currentlyPlayingSong,
            onSelectTrack = { track ->
                attachedTrack = track
                attachedPlaylist = null
                showAttachmentPicker = false
            },
            onSelectPlaylist = { playlist ->
                attachedPlaylist = playlist
                attachedTrack = null
                showAttachmentPicker = false
            },
            onDismiss = { showAttachmentPicker = false },
        )
    }

    // Tenor GIF Picker Sheet
    if (showGifPicker) {
        GifPickerSheet(
            onDismiss = { showGifPicker = false },
            onSelectGif = { gifUrl ->
                stagedGifUrl = gifUrl
                showGifPicker = false
            },
        )
    }

    // Message Actions Bottom Sheet (Long Press)
    if (actionTargetMessage != null) {
        val targetMsg = actionTargetMessage!!
        val isMine = targetMsg.senderId == myProfile?.id
        val clipboardManager = LocalClipboardManager.current

        ModalBottomSheet(
            onDismissRequest = { actionTargetMessage = null },
            containerColor = MaterialTheme.colorScheme.surface,
            contentColor = MaterialTheme.colorScheme.onSurface,
            shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .navigationBarsPadding(),
            ) {
                // Reply Option
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .clickable {
                            replyingToMessage = targetMsg
                            actionTargetMessage = null
                        }
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.Reply,
                        contentDescription = "Reply",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(22.dp),
                    )
                    Spacer(Modifier.width(16.dp))
                    Text(
                        text = "Reply",
                        style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }

                // Copy Text Option
                if (targetMsg.content.isNotBlank()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable {
                                clipboardManager.setText(AnnotatedString(targetMsg.content))
                                actionTargetMessage = null
                            }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.ContentCopy,
                            contentDescription = "Copy text",
                            tint = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.size(22.dp),
                        )
                        Spacer(Modifier.width(16.dp))
                        Text(
                            text = "Copy text",
                            style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }

                // Edit Message Option (only for messages authored by the current user within 10 minutes)
                if (isMine && targetMsg.content.isNotBlank() && isWithinEditWindow(targetMsg.createdAt, 10L)) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable {
                                editedMessageText = targetMsg.content
                                editingMessage = targetMsg
                                actionTargetMessage = null
                            }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Edit,
                            contentDescription = "Edit message",
                            tint = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.size(22.dp),
                        )
                        Spacer(Modifier.width(16.dp))
                        Text(
                            text = "Edit message",
                            style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }

                // Share Option
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .clickable {
                            val shareText = targetMsg.content.ifBlank {
                                targetMsg.imageUrl ?: targetMsg.videoUrl ?: targetMsg.audioUrl ?: "Shared from Vibra Music"
                            }
                            val sendIntent = Intent().apply {
                                action = Intent.ACTION_SEND
                                putExtra(Intent.EXTRA_TEXT, shareText)
                                type = "text/plain"
                            }
                            context.startActivity(Intent.createChooser(sendIntent, null))
                            actionTargetMessage = null
                        }
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Share,
                        contentDescription = "Share",
                        tint = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.size(22.dp),
                    )
                    Spacer(Modifier.width(16.dp))
                    Text(
                        text = "Share",
                        style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }

                // Delete Message Option (only for messages authored by the current user)
                if (isMine) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable {
                                messageToDelete = targetMsg
                                actionTargetMessage = null
                            }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Delete,
                            contentDescription = "Delete message",
                            tint = MaterialTheme.colorScheme.error,
                            modifier = Modifier.size(22.dp),
                        )
                        Spacer(Modifier.width(16.dp))
                        Text(
                            text = "Delete message",
                            style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }

                Spacer(Modifier.height(12.dp))
            }
        }
    }

    // Edit Message Dialog
    if (editingMessage != null) {
        val msgToEdit = editingMessage!!
        AlertDialog(
            onDismissRequest = { editingMessage = null },
            title = {
                Text(
                    text = "Edit message",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
            },
            text = {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .padding(12.dp),
                ) {
                    BasicTextField(
                        value = editedMessageText,
                        onValueChange = { editedMessageText = it },
                        textStyle = TextStyle(
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 15.sp,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val trimmed = editedMessageText.trim()
                        if (trimmed.isNotBlank()) {
                            viewModel.editDirectMessage(msgToEdit.id, trimmed)
                        }
                        editingMessage = null
                    },
                ) {
                    Text(
                        text = "Save",
                        color = MaterialTheme.colorScheme.primary,
                        fontWeight = FontWeight.Bold,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { editingMessage = null }) {
                    Text(
                        text = "Cancel",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            containerColor = MaterialTheme.colorScheme.surface,
            shape = RoundedCornerShape(16.dp),
        )
    }

    // Delete Message Confirmation Dialog
    if (messageToDelete != null) {
        val msgDel = messageToDelete!!
        AlertDialog(
            onDismissRequest = { messageToDelete = null },
            title = {
                Text(
                    text = "Delete message",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
            },
            text = {
                Text(
                    text = "Are you sure you want to delete this message? It will be permanently removed for everyone.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteDirectMessage(msgDel.id)
                        messageToDelete = null
                    },
                ) {
                    Text(
                        text = "Delete",
                        color = MaterialTheme.colorScheme.error,
                        fontWeight = FontWeight.Bold,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { messageToDelete = null }) {
                    Text(
                        text = "Cancel",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            containerColor = MaterialTheme.colorScheme.surface,
            shape = RoundedCornerShape(16.dp),
        )
    }

    // Fullscreen media dialog for expanding chat photos, GIFs, and videos
    fullScreenMediaList?.let { mediaList ->
        FullScreenMediaViewerDialog(
            mediaList = mediaList,
            initialIndex = fullScreenMediaIndex,
            onDismiss = { fullScreenMediaList = null },
        )
    }
}

@Composable
private fun ConversationRow(
    summary: ConversationSummary,
    onClick: () -> Unit,
) {
    val friend = summary.friend
    val hasUnread = summary.unreadCount > 0

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ArtistAvatar(
            artistName = friend.displayName,
            artworkUrl = friend.avatarUrl?.takeIf { it.isNotBlank() && it != "null" },
            size = 52.dp,
        )

        Spacer(Modifier.width(14.dp))

        Column(Modifier.weight(1f)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = friend.displayName,
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )

                val displayTime = if (summary.lastMessageTime.isNotBlank()) {
                    formatRelativeTime(summary.lastMessageTime)
                } else ""

                if (displayTime.isNotBlank()) {
                    Text(
                        text = displayTime,
                        style = MaterialTheme.typography.labelSmall,
                        color = if (hasUnread) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }

            Spacer(Modifier.height(3.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val previewText = summary.lastMessagePreview.ifBlank { formatHandle(friend.handle) }

                Text(
                    text = previewText,
                    style = MaterialTheme.typography.bodySmall.copy(
                        fontWeight = if (hasUnread) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                    color = if (hasUnread) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )

                if (hasUnread) {
                    Box(
                        modifier = Modifier
                            .padding(start = 8.dp)
                            .background(MaterialTheme.colorScheme.primary, CircleShape)
                            .padding(horizontal = 7.dp, vertical = 2.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = if (summary.unreadCount > 99) "99+" else summary.unreadCount.toString(),
                            style = MaterialTheme.typography.labelSmall.copy(
                                fontWeight = FontWeight.Bold,
                                fontSize = 11.sp,
                            ),
                            color = MaterialTheme.colorScheme.onPrimary,
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(
    message: DirectMessage,
    isMine: Boolean,
    friendDisplayName: String = "",
    isFriendOnline: Boolean = false,
    showReceipt: Boolean = false,
    onToggleReceipt: () -> Unit = {},
    onPlayTrack: (MusicTrackAttachment) -> Unit,
    voiceRecorderManager: VoiceRecorderManager,
    currentlyPlayingAudioUrl: String?,
    isAudioPlaying: Boolean,
    onReply: (DirectMessage) -> Unit,
    onLongClick: (DirectMessage) -> Unit,
    onMediaClick: ((List<PostMediaItem>, Int) -> Unit)? = null,
) {
    var dragOffset by remember { mutableFloatStateOf(0f) }
    val animatedOffset by animateFloatAsState(
        targetValue = dragOffset,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "swipeReplyOffset",
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .pointerInput(message.id) {
                detectHorizontalDragGestures(
                    onDragEnd = {
                        if (dragOffset >= 80f) {
                            onReply(message)
                        }
                        dragOffset = 0f
                    },
                    onDragCancel = {
                        dragOffset = 0f
                    },
                    onHorizontalDrag = { change, dragAmount ->
                        if (dragAmount > 0 || dragOffset > 0) {
                            change.consume()
                            dragOffset = (dragOffset + dragAmount).coerceIn(0f, 150f)
                        }
                    },
                )
            },
        contentAlignment = if (isMine) Alignment.CenterEnd else Alignment.CenterStart,
    ) {
        // Reply icon revealed on the left when dragged to the right
        if (animatedOffset > 10f) {
            Box(
                modifier = Modifier
                    .align(Alignment.CenterStart)
                    .padding(start = 6.dp)
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Rounded.Reply,
                    contentDescription = "Reply",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        Box(
            modifier = Modifier
                .offset { IntOffset(animatedOffset.roundToInt(), 0) }
                .clip(
                    RoundedCornerShape(
                        topStart = 16.dp,
                        topEnd = 16.dp,
                        bottomStart = if (isMine) 16.dp else 4.dp,
                        bottomEnd = if (isMine) 4.dp else 16.dp,
                    ),
                )
                .background(
                    if (isMine) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.surfaceVariant,
                )
                .combinedClickable(
                    onClick = { onToggleReceipt() },
                    onLongClick = { onLongClick(message) },
                )
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            Column {
                // Quoted reply snippet if this message replies to another message
                if (!message.replyToText.isNullOrBlank()) {
                    val replyBoxBg = if (isMine) MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surface
                    val replyAccent = if (isMine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.primary
                    val replyText = if (isMine) MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.85f) else MaterialTheme.colorScheme.onSurfaceVariant

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(replyBoxBg)
                            .padding(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .width(3.dp)
                                .height(28.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(replyAccent),
                        )
                        Spacer(Modifier.width(8.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            val resolvedSender = when {
                                message.replyToSender == "You" -> "You"
                                !message.replyToSender.isNullOrBlank() && message.replyToSender != "Friend" -> message.replyToSender
                                friendDisplayName.isNotBlank() -> friendDisplayName
                                else -> "Reply"
                            }
                            Text(
                                text = resolvedSender,
                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                                color = replyAccent,
                            )
                            Spacer(Modifier.height(1.dp))
                            Text(
                                text = message.replyToText,
                                style = MaterialTheme.typography.bodySmall,
                                color = replyText,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                }

                // GIF attachment
                if (!message.gifUrl.isNullOrBlank() && message.gifUrl != "null") {
                    AsyncImage(
                        model = message.gifUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 220.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .clickable {
                                onMediaClick?.invoke(
                                    listOf(PostMediaItem(url = message.gifUrl, type = PostMediaType.IMAGE)),
                                    0,
                                )
                            },
                    )
                    if (message.message.isNotBlank()) Spacer(Modifier.height(8.dp))
                }

                // Image attachment
                if (!message.imageUrl.isNullOrBlank() && message.imageUrl != "null") {
                    AsyncImage(
                        model = message.imageUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 240.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .clickable {
                                onMediaClick?.invoke(
                                    listOf(PostMediaItem(url = message.imageUrl, type = PostMediaType.IMAGE)),
                                    0,
                                )
                            },
                    )
                    if (message.message.isNotBlank()) Spacer(Modifier.height(8.dp))
                }

                // Video attachment
                if (!message.videoUrl.isNullOrBlank() && message.videoUrl != "null") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(180.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.Black)
                            .clickable {
                                onMediaClick?.invoke(
                                    listOf(PostMediaItem(url = message.videoUrl, type = PostMediaType.VIDEO)),
                                    0,
                                )
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.PlayArrow,
                            contentDescription = "Play Video",
                            tint = Color.White,
                            modifier = Modifier.size(44.dp),
                        )
                    }
                    if (message.message.isNotBlank()) Spacer(Modifier.height(8.dp))
                }

                // Voice Note audio attachment
                if (!message.audioUrl.isNullOrBlank() && message.audioUrl != "null") {
                    val isPlayingThis = currentlyPlayingAudioUrl == message.audioUrl && isAudioPlaying
                    val vnBoxBg = if (isMine) MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.12f) else MaterialTheme.colorScheme.surface
                    val vnPlayBtnBg = if (isMine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.primary
                    val vnPlayBtnTint = if (isMine) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onPrimary
                    val vnContentColor = if (isMine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface

                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .background(vnBoxBg)
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        IconButton(
                            onClick = {
                                if (isPlayingThis) voiceRecorderManager.pauseAudio()
                                else voiceRecorderManager.playAudio(message.audioUrl)
                            },
                            modifier = Modifier
                                .size(34.dp)
                                .clip(CircleShape)
                                .background(vnPlayBtnBg),
                        ) {
                            Icon(
                                imageVector = if (isPlayingThis) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                                contentDescription = if (isPlayingThis) "Pause" else "Play",
                                tint = vnPlayBtnTint,
                                modifier = Modifier.size(18.dp),
                            )
                        }

                        Spacer(Modifier.width(10.dp))

                        // Waveform bars
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            listOf(8, 14, 20, 12, 18, 24, 16, 22, 14, 10, 18, 12).forEach { h ->
                                Box(
                                    modifier = Modifier
                                        .width(3.dp)
                                        .height(h.dp)
                                        .clip(RoundedCornerShape(2.dp))
                                        .background(vnContentColor),
                                )
                            }
                        }

                        Spacer(Modifier.width(10.dp))

                        Text(
                            text = "Voice Note",
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                            color = vnContentColor,
                        )
                    }
                    if (message.message.isNotBlank()) Spacer(Modifier.height(8.dp))
                }

                // Text Content
                if (message.message.isNotBlank()) {
                    Row(
                        verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            text = message.message,
                            style = MaterialTheme.typography.bodyMedium,
                            color = if (isMine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        if (message.isEdited) {
                            Text(
                                text = "(edited)",
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Normal,
                                ),
                                color = if (isMine) MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.7f) else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                            )
                        }
                    }
                }

                // Track Attachment inside DM
                message.trackAttachment?.let { track ->
                    if (message.message.isNotBlank() || (!message.gifUrl.isNullOrBlank() && message.gifUrl != "null") || (!message.imageUrl.isNullOrBlank() && message.imageUrl != "null")) {
                        Spacer(Modifier.height(8.dp))
                    }
                    PlayableTrackCard(
                        track = track,
                        onPlay = { onPlayTrack(track) },
                    )
                }

                // Shared Playlist Attachment inside DM
                message.sharedPlaylist?.let { playlist ->
                    if (message.message.isNotBlank() || (!message.gifUrl.isNullOrBlank() && message.gifUrl != "null") || (!message.imageUrl.isNullOrBlank() && message.imageUrl != "null")) {
                        Spacer(Modifier.height(8.dp))
                    }
                    SharedPlaylistCard(playlist = playlist)
                }

                // Tiny Read Receipt & Timestamp at the bottom of the bubble
                if (showReceipt) {
                    val timeStr = formatMessageTime(message.createdAt)
                    val receiptText = if (isMine) {
                        val status = when {
                            message.isRead -> "seen"
                            isFriendOnline -> "received"
                            else -> "sent"
                        }
                        if (timeStr.isNotBlank()) "$timeStr · $status" else status
                    } else {
                        timeStr
                    }

                    if (receiptText.isNotBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = receiptText,
                            style = MaterialTheme.typography.labelSmall.copy(
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Normal,
                            ),
                            color = if (isMine) MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.75f)
                            else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f),
                            modifier = Modifier.align(if (isMine) Alignment.End else Alignment.Start),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SharedPlaylistCard(
    playlist: SharedPlaylistAttachment,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(46.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant),
                contentAlignment = Alignment.Center,
            ) {
                if (playlist.thumbnailUrl != null) {
                    AsyncImage(
                        model = playlist.thumbnailUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Rounded.QueueMusic,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(24.dp),
                    )
                }
            }

            Spacer(Modifier.width(12.dp))

            Column(Modifier.weight(1f)) {
                Text(
                    text = playlist.title,
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = "Playlist • ${playlist.author ?: "Shared"}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatAttachmentPickerSheet(
    currentlyPlayingSong: Song?,
    onSelectTrack: (MusicTrackAttachment) -> Unit,
    onSelectPlaylist: (SharedPlaylistAttachment) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var activeTab by remember { mutableStateOf("Song") }
    var searchQuery by remember { mutableStateOf("") }
    var searchSongResults by remember { mutableStateOf<List<Song>>(emptyList()) }
    var searchPlaylistResults by remember { mutableStateOf<List<SharedPlaylistAttachment>>(emptyList()) }
    var isSearching by remember { mutableStateOf(false) }

    LaunchedEffect(searchQuery, activeTab) {
        val q = searchQuery.trim()
        if (q.length >= 2) {
            isSearching = true
            scope.launch {
                if (activeTab == "Song") {
                    val items = withContext(Dispatchers.IO) {
                        YtMusicRepository.search(q, SearchFilter.SONGS).getOrNull().orEmpty()
                    }
                    val songs = items.mapNotNull { result ->
                        when (result) {
                            is SearchResult.Track -> result.song
                            is SearchResult.TopTrack -> result.song
                            else -> null
                        }
                    }
                    searchSongResults = songs
                } else {
                    val items = withContext(Dispatchers.IO) {
                        YtMusicRepository.search(q, SearchFilter.PLAYLISTS).getOrNull().orEmpty()
                    }
                    val playlists = items.mapNotNull { result ->
                        when (result) {
                            is SearchResult.Browse -> SharedPlaylistAttachment(
                                playlistId = result.item.browseId,
                                title = result.item.title,
                                author = result.item.subtitle,
                                thumbnailUrl = result.item.thumbnailUrl,
                            )
                            else -> null
                        }
                    }
                    searchPlaylistResults = playlists
                }
                isSearching = false
            }
        } else {
            searchSongResults = emptyList()
            searchPlaylistResults = emptyList()
            isSearching = false
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 12.dp)
                .navigationBarsPadding(),
        ) {
            Text(
                text = "Share Music with Friend",
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
            )

            Spacer(Modifier.height(12.dp))

            // Currently Playing Quick Option
            if (currentlyPlayingSong != null) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .clickable {
                            val thumb = currentlyPlayingSong.thumbnailUrl ?: "https://i.ytimg.com/vi/${currentlyPlayingSong.videoId}/hqdefault.jpg"
                            onSelectTrack(
                                MusicTrackAttachment(
                                    videoId = currentlyPlayingSong.videoId,
                                    title = currentlyPlayingSong.title,
                                    artist = currentlyPlayingSong.artist,
                                    thumbnailUrl = thumb,
                                    artworkUrl = thumb,
                                    durationText = currentlyPlayingSong.durationText,
                                )
                            )
                        }
                        .padding(12.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = Icons.Rounded.GraphicEq,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(24.dp),
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                text = "Currently Playing",
                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.primary,
                            )
                            Text(
                                text = currentlyPlayingSong.title,
                                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                            )
                        }
                        Icon(
                            imageVector = Icons.Rounded.PlayArrow,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                }

                Spacer(Modifier.height(14.dp))
            }

            // Tab Selector: Song | Playlist
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(4.dp),
            ) {
                listOf("Song", "Playlist").forEach { tab ->
                    val isSelected = activeTab == tab
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (isSelected) MaterialTheme.colorScheme.primary else Color.Transparent)
                            .clickable { activeTab = tab }
                            .padding(vertical = 8.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = tab,
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                            color = if (isSelected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Search Input
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Rounded.Search,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Box(Modifier.weight(1f)) {
                        if (searchQuery.isEmpty()) {
                            Text(
                                text = if (activeTab == "Song") "Search any song..." else "Search any playlist...",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        BasicTextField(
                            value = searchQuery,
                            onValueChange = { searchQuery = it },
                            textStyle = TextStyle(
                                color = MaterialTheme.colorScheme.onSurface,
                                fontSize = 14.sp,
                            ),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Search Results List
            if (isSearching) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(strokeWidth = 2.dp)
                }
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(280.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (activeTab == "Song") {
                        items(searchSongResults, key = { it.videoId }) { song ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .clickable {
                                        val thumb = song.thumbnailUrl ?: "https://i.ytimg.com/vi/${song.videoId}/hqdefault.jpg"
                                        onSelectTrack(
                                            MusicTrackAttachment(
                                                videoId = song.videoId,
                                                title = song.title,
                                                artist = song.artist,
                                                thumbnailUrl = thumb,
                                                artworkUrl = thumb,
                                                durationText = song.durationText,
                                            )
                                        )
                                    }
                                    .padding(8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(40.dp)
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
                                Spacer(Modifier.width(10.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        text = song.title,
                                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.onSurface,
                                        maxLines = 1,
                                    )
                                    Text(
                                        text = song.artist,
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1,
                                    )
                                }
                            }
                        }
                    } else {
                        items(searchPlaylistResults, key = { it.playlistId }) { playlist ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .clickable { onSelectPlaylist(playlist) },
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(40.dp)
                                        .clip(RoundedCornerShape(6.dp))
                                        .background(MaterialTheme.colorScheme.surfaceVariant),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (playlist.thumbnailUrl != null) {
                                        AsyncImage(
                                            model = playlist.thumbnailUrl,
                                            contentDescription = null,
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier.fillMaxSize(),
                                        )
                                    } else {
                                        Icon(
                                            imageVector = Icons.Rounded.QueueMusic,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(20.dp),
                                        )
                                    }
                                }
                                Spacer(Modifier.width(10.dp))
                                Column(Modifier.weight(1f)) {
                                    Text(
                                        text = playlist.title,
                                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.onSurface,
                                        maxLines = 1,
                                    )
                                    Text(
                                        text = playlist.author ?: "Playlist",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1,
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
