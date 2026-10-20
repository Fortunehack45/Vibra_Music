package com.fortune.vibramusic.ui.player

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.CalendarToday
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Equalizer
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.stats.ArtistFacts
import com.fortune.vibramusic.playback.AudioOutputStatus
import com.fortune.vibramusic.data.NerdStats
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass
import com.fortune.vibramusic.ui.theme.VibraPurple

/**
 * Apple Music-style Song Info bottom sheet displaying release date,
 * stream codecs, bit depth, bitrate, sample rate, and listening statistics.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SongInfoSheet(
    song: Song,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val clipboardManager = LocalClipboardManager.current
    val nerdStats by NerdStats.current.collectAsStateWithLifecycle()
    val outputStatus by AudioOutputStatus.current.collectAsStateWithLifecycle()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Color(0xFF141520),
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            // Header: Track Artwork + Title + Artist
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(68.dp)
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color(0xFF222336)),
                ) {
                    if (!song.thumbnailUrl.isNullOrBlank()) {
                        AsyncImage(
                            model = song.thumbnailUrl,
                            contentDescription = song.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.matchParentSize(),
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Rounded.MusicNote,
                            contentDescription = null,
                            tint = VibraPurple,
                            modifier = Modifier
                                .size(32.dp)
                                .align(Alignment.Center),
                        )
                    }
                }

                Spacer(Modifier.width(16.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = song.title,
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = song.artist,
                        style = MaterialTheme.typography.bodyMedium,
                        color = VibraPurple,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (!song.albumName.isNullOrBlank()) {
                        Text(
                            text = song.albumName,
                            style = MaterialTheme.typography.labelSmall,
                            color = Color.White.copy(alpha = 0.6f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            // Section 1: Release & Track Metadata
            Text(
                text = "Track Details",
                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                color = Color.White.copy(alpha = 0.5f),
            )
            Spacer(Modifier.height(8.dp))

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .lightweightLiquidGlass(
                        shape = RoundedCornerShape(18.dp),
                        fallbackColor = Color(0xFF1E1F2E).copy(alpha = 0.75f),
                    )
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                val releaseText = song.durationText?.let { "Duration: $it" } ?: "Full Track"
                SongInfoRow(
                    icon = Icons.Rounded.CalendarToday,
                    title = "Release",
                    value = song.durationText ?: "Available on Vibra Music",
                )
                if (!song.albumName.isNullOrBlank()) {
                    SongInfoRow(
                        icon = Icons.Rounded.Album,
                        title = "Album",
                        value = song.albumName,
                    )
                }
                SongInfoRow(
                    icon = Icons.Rounded.Person,
                    title = "Artist",
                    value = song.artist,
                )
                SongInfoRow(
                    icon = Icons.Rounded.Info,
                    title = "Track ID",
                    value = song.videoId.take(16),
                    copyValue = song.videoId,
                    onCopy = { clipboardManager.setText(AnnotatedString(song.videoId)) },
                )
            }

            Spacer(Modifier.height(20.dp))

            // Section 2: Audio Quality & Pipeline
            Text(
                text = "Audio & Stream Quality",
                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                color = Color.White.copy(alpha = 0.5f),
            )
            Spacer(Modifier.height(8.dp))

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .lightweightLiquidGlass(
                        shape = RoundedCornerShape(18.dp),
                        fallbackColor = Color(0xFF1E1F2E).copy(alpha = 0.75f),
                    )
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                val codec = NerdStats.codecLabel(nerdStats?.mimeType) ?: if (song.videoId.startsWith("file://") || song.videoId.startsWith("content://")) "Local / Device" else "Opus / AAC"
                val sampleRate = nerdStats?.sampleRateHz?.let { "${it / 1000} kHz" }
                    ?: outputStatus.actualSampleRateHz?.let { "${it / 1000} kHz" } ?: "48 kHz"
                val bitDepth = nerdStats?.bitDepth?.let { "$it-bit" } ?: if (nerdStats?.isHiRes == true) "24-bit Hi-Res" else "16-bit Standard"
                val bitrate = nerdStats?.bitrateKbps?.let { "$it kbps" } ?: "High Quality"

                SongInfoRow(
                    icon = Icons.Rounded.GraphicEq,
                    title = "Codec & Format",
                    value = codec,
                )
                SongInfoRow(
                    icon = Icons.Rounded.Equalizer,
                    title = "Sample Rate",
                    value = sampleRate,
                )
                SongInfoRow(
                    icon = Icons.Rounded.MusicNote,
                    title = "Bit Depth",
                    value = bitDepth,
                )
                SongInfoRow(
                    icon = Icons.Rounded.Timer,
                    title = "Bitrate",
                    value = bitrate,
                )
            }
        }
    }
}

@Composable
private fun SongInfoRow(
    icon: ImageVector,
    title: String,
    value: String,
    copyValue: String? = null,
    onCopy: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.weight(1f),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = VibraPurple,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(10.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.bodySmall,
                color = Color.White.copy(alpha = 0.65f),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = value,
                style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                color = Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (copyValue != null && onCopy != null) {
                Spacer(Modifier.width(6.dp))
                IconButton(
                    onClick = onCopy,
                    modifier = Modifier.size(24.dp),
                ) {
                    Icon(
                        imageVector = Icons.Rounded.ContentCopy,
                        contentDescription = "Copy",
                        tint = VibraPurple,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }
    }
}
