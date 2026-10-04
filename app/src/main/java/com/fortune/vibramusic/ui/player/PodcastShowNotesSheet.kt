package com.fortune.vibramusic.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.ClickableText
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.ui.components.GLASS_EDGE_COLOR
import com.fortune.vibramusic.ui.components.GLASS_EDGE_WIDTH
import com.fortune.vibramusic.ui.components.liquidGlass
import com.fortune.vibramusic.ui.icons.VibraMusicIcons

private val TIMESTAMP_REGEX = Regex("""\b(?:(\d{1,2}):)?([0-5]?\d):([0-5]\d)\b""")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PodcastShowNotesSheet(
    song: Song,
    onDismiss: () -> Unit,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val description = song.description.orEmpty().ifBlank {
        stringResource(R.string.no_description_available)
    }

    // Build annotated string highlighting clickable timestamps
    val annotatedDescription = remember(description) {
        buildAnnotatedString {
            var lastIndex = 0
            val matches = TIMESTAMP_REGEX.findAll(description)

            for (match in matches) {
                append(description.substring(lastIndex, match.range.first))
                val hours = match.groups[1]?.value?.toLongOrNull() ?: 0L
                val minutes = match.groups[2]?.value?.toLongOrNull() ?: 0L
                val seconds = match.groups[3]?.value?.toLongOrNull() ?: 0L
                val totalMs = (hours * 3600 + minutes * 60 + seconds) * 1000L

                val start = length
                append(match.value)
                val end = length

                addStyle(
                    style = SpanStyle(
                        color = Color(0xFF64B5F6),
                        fontWeight = FontWeight.SemiBold,
                        textDecoration = TextDecoration.Underline,
                    ),
                    start = start,
                    end = end,
                )
                addStringAnnotation(
                    tag = "TIMESTAMP",
                    annotation = totalMs.toString(),
                    start = start,
                    end = end,
                )
                lastIndex = match.range.last + 1
            }
            if (lastIndex < description.length) {
                append(description.substring(lastIndex))
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
        dragHandle = null,
        contentWindowInsets = { WindowInsets(0, 0, 0, 0) },
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 16.dp),
        ) {
            // Header: Title and Close button
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.weight(1f),
                ) {
                    Box(
                        modifier = Modifier
                            .size(36.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = VibraMusicIcons.Notes,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text(
                            text = stringResource(R.string.show_notes),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = song.artist,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                    }
                }

                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }

            Spacer(Modifier.height(16.dp))

            // Episode title card
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f))
                    .border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f), RoundedCornerShape(14.dp))
                    .padding(14.dp),
            ) {
                Column {
                    Text(
                        text = song.title,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    song.albumName?.let { showName ->
                        if (showName.isNotBlank() && showName != song.artist) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = showName,
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.primary,
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            // Scrollable Description Text with clickable timestamps
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f, fill = false)
                    .verticalScroll(rememberScrollState()),
            ) {
                ClickableText(
                    text = annotatedDescription,
                    style = MaterialTheme.typography.bodyMedium.copy(
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.88f),
                        lineHeight = 22.sp,
                    ),
                    onClick = { offset ->
                        annotatedDescription.getStringAnnotations(tag = "TIMESTAMP", start = offset, end = offset)
                            .firstOrNull()?.let { annotation ->
                                annotation.item.toLongOrNull()?.let { targetMs ->
                                    onSeek(targetMs)
                                    onDismiss()
                                }
                            }
                    },
                )
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}
