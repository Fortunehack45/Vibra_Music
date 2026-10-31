package com.fortune.vibramusic.ui.player

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Fullscreen
import androidx.compose.material.icons.rounded.FullscreenExit
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.R
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics

/**
 * State representing video quality renditions and selection.
 */
data class VideoQualityUi(
    val heights: List<Int> = listOf(1080, 720, 480, 360, 240, 144),
    val held: Int? = null,
    val activeHeight: Int? = 480,
) {
    fun selected(): Int? = if (held == null || held !in heights) activeHeight else held
}

/**
 * Marketing name for resolution heights, matching BitChord specification.
 */
fun videoQualityLabel(height: Int): String = when {
    height >= 4320 -> "8K"
    height >= 2160 -> "4K"
    height >= 1440 -> "2K"
    height >= 1080 -> "FullHD"
    height >= 720 -> "HD"
    else -> "${height}p"
}

/**
 * Corner controls overlaying the video: Quality badge button + Fullscreen toggle.
 */
@Composable
fun VideoCornerControls(
    quality: VideoQualityUi,
    fullscreen: Boolean,
    onToggleFullscreen: () -> Unit,
    onOpenQuality: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val label = quality.selected()?.let(::videoQualityLabel) ?: "Auto"
        Box(
            modifier = Modifier
                .height(30.dp)
                .widthIn(min = 44.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color.Black.copy(alpha = 0.52f))
                .clickable(onClick = onOpenQuality)
                .padding(horizontal = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            AnimatedContent(
                targetState = label,
                transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(180)) },
                label = "videoQualityBadge",
            ) { text ->
                Text(
                    text = text,
                    color = Color.White.copy(alpha = 0.95f),
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.4.sp,
                    maxLines = 1,
                )
            }
        }

        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color.Black.copy(alpha = 0.52f))
                .clickable(onClick = onToggleFullscreen),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (fullscreen) Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen,
                contentDescription = if (fullscreen) "Exit Fullscreen" else "Fullscreen",
                tint = Color.White,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

/**
 * Liquid Glass Video Quality Bottom Sheet matching BitChord design.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VideoQualitySheet(
    quality: VideoQualityUi,
    onSelectQuality: (Int?) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val selected = quality.selected()

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        dragHandle = { BottomSheetDefaults.DragHandle() },
        containerColor = MaterialTheme.colorScheme.surface,
        contentColor = MaterialTheme.colorScheme.onSurface,
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
        ) {
            Text(
                text = stringResource(R.string.video_quality),
                style = MaterialTheme.typography.titleLarge.copy(
                    fontWeight = FontWeight.Bold,
                    fontSize = 20.sp,
                ),
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(bottom = 16.dp),
            )

            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Auto Option
                QualityRowItem(
                    name = stringResource(R.string.video_quality_auto),
                    detail = if (quality.held == null) selected?.let(::videoQualityLabel) else null,
                    active = quality.held == null,
                    onSelect = {
                        onSelectQuality(null)
                        onDismiss()
                    },
                )

                // Heights available
                quality.heights.forEach { height ->
                    QualityRowItem(
                        name = videoQualityLabel(height),
                        detail = "${height}p",
                        active = quality.held != null && selected == height,
                        onSelect = {
                            onSelectQuality(height)
                            onDismiss()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun QualityRowItem(
    name: String,
    detail: String?,
    active: Boolean,
    onSelect: () -> Unit,
) {
    val haptics = rememberHaptics()
    val bg = if (active) {
        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f)
    } else {
        MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.25f)
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                enabled = !active,
            ) {
                haptics.play(Haptic.Select)
                onSelect()
            }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = name,
            style = MaterialTheme.typography.bodyLarge.copy(
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
            ),
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (active) 1f else 0.85f),
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )

        if (detail != null) {
            Text(
                text = detail,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                modifier = Modifier.padding(horizontal = 8.dp),
            )
        }

        Box(
            modifier = Modifier.size(20.dp),
            contentAlignment = Alignment.Center,
        ) {
            if (active) {
                Icon(
                    imageVector = Icons.Rounded.Check,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}
