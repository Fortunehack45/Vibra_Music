package com.fortune.vibramusic.ui.social

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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.social.DirectMessage
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.SocialProfile
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource

@Composable
fun DirectMessagesScreen(
    viewModel: SocialViewModel,
    currentlyPlayingSong: Song?,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
    contentPadding: PaddingValues,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val activeChatFriend by viewModel.activeChatFriend.collectAsStateWithLifecycle()
    val conversations by viewModel.conversations.collectAsStateWithLifecycle()
    val messages by viewModel.chatMessages.collectAsStateWithLifecycle()
    val myProfile by viewModel.currentProfile.collectAsStateWithLifecycle()

    var messageText by remember { mutableStateOf("") }
    var attachedTrack by remember { mutableStateOf<MusicTrackAttachment?>(null) }

    Box(
        modifier = modifier
            .fillMaxSize()
            .hazeSource(hazeState),
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
                                tint = MaterialTheme.colorScheme.primary.copy(alpha = 0.5f),
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
                                text = "Connect with friends to start chatting and sharing tracks!",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
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
                        items(conversations, key = { it.id }) { friend ->
                            ConversationRow(
                                friend = friend,
                                onClick = { viewModel.openChat(friend) },
                            )
                        }
                    }
                }
            }
        } else {
            // Active Chat Thread View
            val friend = activeChatFriend!!

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(top = contentPadding.calculateTopPadding()),
            ) {
                // Top Bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = { viewModel.closeChat() }) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                            contentDescription = "Back",
                            tint = MaterialTheme.colorScheme.onSurface,
                        )
                    }

                    Spacer(Modifier.width(4.dp))

                    Box(
                        modifier = Modifier
                            .size(38.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (friend.avatarUrl != null) {
                            AsyncImage(
                                model = friend.avatarUrl,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Person,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }

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
                            text = "@${friend.handle}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        )
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
                ) {
                    items(messages.reversed(), key = { it.id }) { msg ->
                        val isMine = msg.senderId == myProfile?.id
                        MessageBubble(
                            message = msg,
                            isMine = isMine,
                            onPlayTrack = onPlayTrack,
                        )
                    }
                }

                // Track Attachment Preview (if staged to send)
                attachedTrack?.let { track ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 6.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
                            .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                            .padding(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.MusicNote,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(Modifier.width(8.dp))
                        Column(Modifier.weight(1f)) {
                            Text(
                                text = track.title,
                                style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                            )
                            Text(
                                text = track.artist,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                            )
                        }
                        IconButton(onClick = { attachedTrack = null }, modifier = Modifier.size(24.dp)) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                                contentDescription = "Remove",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }

                // Chat Input Bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            start = 16.dp,
                            end = 16.dp,
                            top = 6.dp,
                            bottom = contentPadding.calculateBottomPadding() + 8.dp,
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // Quick Share Playing Song Button
                    if (currentlyPlayingSong != null && attachedTrack == null) {
                        IconButton(
                            onClick = {
                                attachedTrack = MusicTrackAttachment(
                                    videoId = currentlyPlayingSong.videoId,
                                    title = currentlyPlayingSong.title,
                                    artist = currentlyPlayingSong.artist,
                                    artworkUrl = currentlyPlayingSong.thumbnailUrl,
                                    durationText = currentlyPlayingSong.durationText,
                                )
                            },
                            modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.GraphicEq,
                                contentDescription = "Share Playing Track",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                    }

                    // Text Input
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(24.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(24.dp))
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                    ) {
                        if (messageText.isEmpty()) {
                            Text(
                                text = "Message...",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                            )
                        }
                        BasicTextField(
                            value = messageText,
                            onValueChange = { messageText = it },
                            textStyle = TextStyle(
                                color = MaterialTheme.colorScheme.onSurface,
                                fontSize = 14.sp,
                            ),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }

                    Spacer(Modifier.width(8.dp))

                    // Send Button
                    IconButton(
                        onClick = {
                            val trimmed = messageText.trim()
                            if (trimmed.isNotBlank() || attachedTrack != null) {
                                viewModel.sendDirectMessage(trimmed, attachedTrack)
                                messageText = ""
                                attachedTrack = null
                            }
                        },
                        enabled = messageText.isNotBlank() || attachedTrack != null,
                        modifier = Modifier
                            .size(42.dp)
                            .clip(CircleShape)
                            .background(
                                if (messageText.isNotBlank() || attachedTrack != null) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.primary.copy(alpha = 0.3f),
                            ),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.Send,
                            contentDescription = "Send",
                            tint = MaterialTheme.colorScheme.onPrimary,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ConversationRow(
    friend: SocialProfile,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(50.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
            contentAlignment = Alignment.Center,
        ) {
            if (friend.avatarUrl != null) {
                AsyncImage(
                    model = friend.avatarUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Icon(
                    imageVector = Icons.Rounded.Person,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(26.dp),
                )
            }
        }

        Spacer(Modifier.width(14.dp))

        Column(Modifier.weight(1f)) {
            Text(
                text = friend.displayName,
                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                text = "@${friend.handle}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            )
        }
    }
}

@Composable
private fun MessageBubble(
    message: DirectMessage,
    isMine: Boolean,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (isMine) Alignment.End else Alignment.Start,
    ) {
        Box(
            modifier = Modifier
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
                    else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                )
                .border(
                    1.dp,
                    if (isMine) MaterialTheme.colorScheme.primary.copy(alpha = 0.8f)
                    else Color.White.copy(alpha = 0.08f),
                    RoundedCornerShape(16.dp),
                )
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            Column {
                if (message.message.isNotBlank()) {
                    Text(
                        text = message.message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (isMine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                    )
                }

                // Track Attachment inside DM
                message.trackAttachment?.let { track ->
                    if (message.message.isNotBlank()) Spacer(Modifier.height(8.dp))
                    PlayableTrackCard(
                        track = track,
                        onPlay = { onPlayTrack(track) },
                    )
                }
            }
        }
    }
}
