package com.fortune.vibramusic.ui.social

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Poll
import androidx.compose.material.icons.rounded.Send
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PollData
import com.fortune.vibramusic.data.social.PollOption
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CreatePostSheet(
    currentlyPlayingSong: Song?,
    isPosting: Boolean,
    onDismiss: () -> Unit,
    onSubmitPost: (content: String, track: MusicTrackAttachment?, poll: PollData?) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var textContent by remember { mutableStateOf("") }
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

    var showPollBuilder by remember { mutableStateOf(false) }
    var pollQuestion by remember { mutableStateOf("") }
    val pollOptions = remember { mutableStateListOf("Option 1", "Option 2") }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
        dragHandle = null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp)
                .navigationBarsPadding(),
        ) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onDismiss) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Cancel",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                Text(
                    text = "New Post",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurface,
                )

                ElevatedButton(
                    onClick = {
                        val finalPoll = if (showPollBuilder && pollQuestion.isNotBlank() && pollOptions.size >= 2) {
                            PollData(
                                question = pollQuestion.trim(),
                                options = pollOptions.filter { it.isNotBlank() }.map { PollOption(text = it.trim()) },
                            )
                        } else null

                        onSubmitPost(textContent.trim(), attachedTrack, finalPoll)
                    },
                    enabled = !isPosting && (textContent.isNotBlank() || attachedTrack != null || showPollBuilder),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.elevatedButtonColors(
                        containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = MaterialTheme.colorScheme.onPrimary,
                        disabledContainerColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.3f),
                    ),
                ) {
                    if (isPosting) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            color = MaterialTheme.colorScheme.onPrimary,
                            strokeWidth = 2.dp,
                        )
                    } else {
                        Text(
                            text = "Post",
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }

            Spacer(Modifier.height(14.dp))

            // Text Input
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(120.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                    .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                    .padding(14.dp),
            ) {
                if (textContent.isEmpty()) {
                    Text(
                        text = "Share what you're listening to, ask for music recs, or drop your thoughts...",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    )
                }
                BasicTextField(
                    value = textContent,
                    onValueChange = { textContent = it },
                    textStyle = TextStyle(
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 15.sp,
                    ),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(Modifier.height(12.dp))

            // Attached Track Preview Card (Liquid Glass)
            attachedTrack?.let { track ->
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                        .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
                        .padding(10.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(44.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant),
                        ) {
                            if (track.artworkUrl != null) {
                                AsyncImage(
                                    model = track.artworkUrl,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            } else {
                                Icon(
                                    imageVector = Icons.Rounded.MusicNote,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.align(Alignment.Center),
                                )
                            }
                        }

                        Spacer(Modifier.width(12.dp))

                        Column(Modifier.weight(1f)) {
                            Text(
                                text = track.title,
                                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
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
                                contentDescription = "Remove Track",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }

            // Poll Builder Section
            AnimatedVisibility(visible = showPollBuilder) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                        .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                        .padding(14.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "Poll Question",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.primary,
                        )
                        IconButton(
                            onClick = { showPollBuilder = false },
                            modifier = Modifier.size(24.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Close Poll",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }

                    Spacer(Modifier.height(6.dp))

                    BasicTextField(
                        value = pollQuestion,
                        onValueChange = { pollQuestion = it },
                        textStyle = TextStyle(
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.7f))
                            .padding(10.dp),
                        decorationBox = { innerTextField ->
                            if (pollQuestion.isEmpty()) {
                                Text(
                                    text = "Ask a music question...",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                )
                            }
                            innerTextField()
                        },
                    )

                    Spacer(Modifier.height(10.dp))

                    pollOptions.forEachIndexed { index, option ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp),
                        ) {
                            BasicTextField(
                                value = option,
                                onValueChange = { pollOptions[index] = it },
                                textStyle = TextStyle(
                                    color = MaterialTheme.colorScheme.onSurface,
                                    fontSize = 13.sp,
                                ),
                                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.7f))
                                    .padding(8.dp),
                            )

                            if (pollOptions.size > 2) {
                                IconButton(
                                    onClick = { pollOptions.removeAt(index) },
                                    modifier = Modifier.size(28.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Close,
                                        contentDescription = "Remove Option",
                                        tint = MaterialTheme.colorScheme.error.copy(alpha = 0.8f),
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            }
                        }
                    }

                    if (pollOptions.size < 4) {
                        Spacer(Modifier.height(6.dp))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { pollOptions.add("Option ${pollOptions.size + 1}") }
                                .padding(horizontal = 8.dp, vertical = 6.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Add,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "Add Option",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(12.dp))
            }

            // Bottom Toolbar Controls
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Attach Playing Song Button
                if (currentlyPlayingSong != null && attachedTrack == null) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f))
                            .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.25f), RoundedCornerShape(20.dp))
                            .clickable {
                                attachedTrack = MusicTrackAttachment(
                                    videoId = currentlyPlayingSong.videoId,
                                    title = currentlyPlayingSong.title,
                                    artist = currentlyPlayingSong.artist,
                                    artworkUrl = currentlyPlayingSong.thumbnailUrl,
                                    durationText = currentlyPlayingSong.durationText,
                                )
                            }
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.GraphicEq,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "Attach Playing Song",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Medium),
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                }

                // Poll Toggle Button
                if (!showPollBuilder) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                            .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(20.dp))
                            .clickable { showPollBuilder = true }
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Poll,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "Create Poll",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Medium),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}
