package com.fortune.vibramusic.ui.social

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.TextFields
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.StoryMediaType
import com.fortune.vibramusic.ui.theme.VibraPurple

val storyGradientPresets = listOf(
    listOf(Color(0xFF8B5CF6), Color(0xFF3B82F6)),
    listOf(Color(0xFFEC4899), Color(0xFF8B5CF6)),
    listOf(Color(0xFF06B6D4), Color(0xFF3B82F6)),
    listOf(Color(0xFF10B981), Color(0xFF06B6D4)),
    listOf(Color(0xFFF59E0B), Color(0xFFEF4444)),
    listOf(Color(0xFF1E1B4B), Color(0xFF0F172A)),
)

val storyGradientHexPresets = listOf(
    "#8B5CF6,#3B82F6",
    "#EC4899,#8B5CF6",
    "#06B6D4,#3B82F6",
    "#10B981,#06B6D4",
    "#F59E0B,#EF4444",
    "#1E1B4B,#0F172A",
)

/**
 * Dedicated fullscreen story creation screen.
 * Allows picking photos and videos directly from the device gallery via PickVisualMedia,
 * or creating a styled text story with gradient backgrounds and currently playing music attachment.
 */
@Composable
fun CreateStoryScreen(
    currentlyPlayingSong: Song?,
    onDismiss: () -> Unit,
    onSubmitStory: (mediaUrl: String?, mediaType: StoryMediaType, textContent: String, track: MusicTrackAttachment?, backgroundColorHex: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var selectedMediaUri by remember { mutableStateOf<Uri?>(null) }
    var isVideo by remember { mutableStateOf(false) }
    var textContent by remember { mutableStateOf("") }
    var selectedGradientIndex by remember { mutableIntStateOf(0) }
    var attachCurrentSong by remember { mutableStateOf(currentlyPlayingSong != null) }

    val photoVideoLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            selectedMediaUri = uri
            val mimeType = context.contentResolver.getType(uri) ?: ""
            isVideo = mimeType.startsWith("video")
        }
    }

    val activeGradient = storyGradientPresets[selectedGradientIndex]

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                if (selectedMediaUri == null) {
                    Brush.verticalGradient(activeGradient)
                } else {
                    Brush.verticalGradient(listOf(Color.Black, Color(0xFF0B0C10)))
                }
            ),
    ) {
        // Media Preview Background
        selectedMediaUri?.let { uri ->
            if (isVideo) {
                PostVideoPlayer(
                    videoUrl = uri.toString(),
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                AsyncImage(
                    model = uri,
                    contentDescription = "Selected Media",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            // Scrim overlay for readability
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.35f)),
            )
        }

        // Top Navigation & Action Chrome
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            IconButton(
                onClick = onDismiss,
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.45f)),
            ) {
                Icon(
                    imageVector = Icons.Rounded.Close,
                    contentDescription = "Close",
                    tint = Color.White,
                    modifier = Modifier.size(20.dp),
                )
            }

            Text(
                text = "New Story",
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                color = Color.White,
            )

            Button(
                onClick = {
                    val mediaUrl = selectedMediaUri?.toString()
                    val mediaType = when {
                        mediaUrl != null && isVideo -> StoryMediaType.VIDEO
                        mediaUrl != null -> StoryMediaType.IMAGE
                        else -> StoryMediaType.TEXT
                    }
                    val track = if (attachCurrentSong && currentlyPlayingSong != null) {
                        MusicTrackAttachment(
                            videoId = currentlyPlayingSong.videoId,
                            title = currentlyPlayingSong.title,
                            artist = currentlyPlayingSong.artist,
                            artworkUrl = currentlyPlayingSong.thumbnailUrl,
                        )
                    } else null

                    val bgHex = storyGradientHexPresets.getOrElse(selectedGradientIndex) { "#8B5CF6,#3B82F6" }
                    onSubmitStory(mediaUrl, mediaType, textContent.trim(), track, bgHex)
                },
                colors = ButtonDefaults.buttonColors(
                    containerColor = VibraPurple,
                    contentColor = Color.White,
                ),
                shape = CircleShape,
                enabled = selectedMediaUri != null || textContent.isNotBlank(),
            ) {
                Text(
                    text = "Share",
                    fontWeight = FontWeight.Bold,
                    fontSize = 14.sp,
                )
            }
        }

        // Center Story Text Input
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 32.dp),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                BasicTextField(
                    value = textContent,
                    onValueChange = { if (it.length <= 280) textContent = it },
                    textStyle = TextStyle(
                        color = Color.White,
                        fontSize = if (selectedMediaUri != null) 20.sp else 26.sp,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center,
                        lineHeight = 34.sp,
                    ),
                    cursorBrush = SolidColor(Color.White),
                    modifier = Modifier.fillMaxWidth(),
                    decorationBox = { inner ->
                        if (textContent.isEmpty()) {
                            Text(
                                text = if (selectedMediaUri != null) "Add a caption..." else "What's on your mind?",
                                style = TextStyle(
                                    color = Color.White.copy(alpha = 0.6f),
                                    fontSize = if (selectedMediaUri != null) 20.sp else 26.sp,
                                    fontWeight = FontWeight.Bold,
                                    textAlign = TextAlign.Center,
                                ),
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        inner()
                    },
                )

                // Currently playing music sticker
                if (attachCurrentSong && currentlyPlayingSong != null) {
                    Spacer(Modifier.height(24.dp))
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .background(Color.Black.copy(alpha = 0.65f))
                            .border(1.dp, VibraPurple.copy(alpha = 0.6f), RoundedCornerShape(20.dp))
                            .clickable { attachCurrentSong = false }
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.Rounded.GraphicEq,
                                contentDescription = null,
                                tint = VibraPurple,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = "${currentlyPlayingSong.title} · ${currentlyPlayingSong.artist}",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = Color.White,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Spacer(Modifier.width(6.dp))
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Remove music sticker",
                                tint = Color.White.copy(alpha = 0.6f),
                                modifier = Modifier.size(14.dp),
                            )
                        }
                    }
                }
            }
        }

        // Bottom Controls Shelf
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(bottom = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Gradient presets (only when text story mode)
            if (selectedMediaUri == null) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    storyGradientPresets.forEachIndexed { index, gradient ->
                        val isSelected = index == selectedGradientIndex
                        Box(
                            modifier = Modifier
                                .size(if (isSelected) 36.dp else 28.dp)
                                .clip(CircleShape)
                                .background(Brush.linearGradient(gradient))
                                .border(
                                    width = if (isSelected) 2.5.dp else 1.dp,
                                    color = if (isSelected) Color.White else Color.White.copy(alpha = 0.4f),
                                    shape = CircleShape,
                                )
                                .clickable { selectedGradientIndex = index },
                        )
                    }
                }
                Spacer(Modifier.height(16.dp))
            }

            // Media & Music Tool Bar
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(30.dp))
                    .background(Color.Black.copy(alpha = 0.6f))
                    .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(30.dp))
                    .padding(horizontal = 14.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                // Direct Gallery Picker button
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .clickable {
                            photoVideoLauncher.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
                            )
                        }
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Image,
                        contentDescription = "Upload from Gallery",
                        tint = Color.White,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = if (selectedMediaUri != null) "Change Media" else "Gallery",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                        color = Color.White,
                    )
                }

                // If media is attached, clear media button
                if (selectedMediaUri != null) {
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .clickable {
                                selectedMediaUri = null
                                isVideo = false
                            }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.TextFields,
                            contentDescription = "Switch to Text",
                            tint = Color.White.copy(alpha = 0.8f),
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }

                // Attach Currently Playing Music button
                if (currentlyPlayingSong != null && !attachCurrentSong) {
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .clickable { attachCurrentSong = true }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.GraphicEq,
                            contentDescription = "Attach Music",
                            tint = VibraPurple,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
        }
    }
}
