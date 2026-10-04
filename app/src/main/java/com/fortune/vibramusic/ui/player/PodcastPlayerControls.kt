package com.fortune.vibramusic.ui.player

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.R
import com.fortune.vibramusic.ui.components.GLASS_EDGE_COLOR
import com.fortune.vibramusic.ui.components.GLASS_EDGE_WIDTH
import com.fortune.vibramusic.ui.components.liquidGlass
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import com.fortune.vibramusic.ui.icons.VibraMusicIcons

private val SPEED_STEPS = listOf(1.0f, 1.25f, 1.5f, 1.75f, 2.0f)


/**
 * Transport row enhanced with -15s rewind and +30s fast forward for podcast playback.
 */
@Composable
fun PodcastTransportRow(
    isPlaying: Boolean,
    isLoading: Boolean,
    onPlayPause: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onReplay15: () -> Unit,
    onForward30: () -> Unit,
    previousEnabled: Boolean = true,
    nextEnabled: Boolean = true,
    compact: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val haptics = rememberHaptics()
    val playSize = if (compact) 58.dp else 74.dp
    val playTouch = if (compact) 76.dp else 92.dp
    val secondarySize = if (compact) 32.dp else 40.dp
    val jumpSize = if (compact) 38.dp else 46.dp

    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceAround,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Replay 15 seconds
        Box(
            modifier = Modifier
                .size(jumpSize)
                .clip(CircleShape)
                .clickable {
                    haptics.play(Haptic.Tap)
                    onReplay15()
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = VibraMusicIcons.Replay15,
                contentDescription = "-15s",
                tint = Color.White.copy(alpha = 0.88f),
                modifier = Modifier.size(if (compact) 24.dp else 28.dp),
            )
        }

        // Previous
        Box(
            modifier = Modifier
                .size(secondarySize)
                .clip(CircleShape)
                .clickable(enabled = previousEnabled) {
                    haptics.play(Haptic.SkipPrevious)
                    onPrevious()
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painter = androidx.compose.ui.res.painterResource(R.drawable.ic_player_previous),
                contentDescription = stringResource(R.string.widget_previous),
                tint = if (previousEnabled) Color.White else Color.White.copy(alpha = 0.35f),
                modifier = Modifier.size(if (compact) 22.dp else 26.dp),
            )
        }

        // Play / Pause
        if (isLoading) {
            Box(Modifier.size(playTouch), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 3.dp,
                    modifier = Modifier.size(if (compact) 30.dp else 38.dp),
                )
            }
        } else {
            Box(
                modifier = Modifier
                    .size(playTouch)
                    .clip(CircleShape)
                    .clickable {
                        haptics.play(if (isPlaying) Haptic.Pause else Haptic.Resume)
                        onPlayPause()
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    painter = androidx.compose.ui.res.painterResource(
                        if (isPlaying) R.drawable.ic_player_pause else R.drawable.ic_player_play,
                    ),
                    contentDescription = stringResource(if (isPlaying) R.string.pause else R.string.play),
                    tint = Color.White,
                    modifier = Modifier.size(playSize),
                )
            }
        }

        // Next
        Box(
            modifier = Modifier
                .size(secondarySize)
                .clip(CircleShape)
                .clickable(enabled = nextEnabled) {
                    haptics.play(Haptic.SkipNext)
                    onNext()
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painter = androidx.compose.ui.res.painterResource(R.drawable.ic_player_next),
                contentDescription = stringResource(R.string.widget_next),
                tint = if (nextEnabled) Color.White else Color.White.copy(alpha = 0.35f),
                modifier = Modifier.size(if (compact) 22.dp else 26.dp),
            )
        }

        // Forward 30 seconds
        Box(
            modifier = Modifier
                .size(jumpSize)
                .clip(CircleShape)
                .clickable {
                    haptics.play(Haptic.Tap)
                    onForward30()
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = VibraMusicIcons.Forward30,
                contentDescription = "+30s",
                tint = Color.White.copy(alpha = 0.88f),
                modifier = Modifier.size(if (compact) 24.dp else 28.dp),
            )
        }
    }
}

/**
 * Compact liquid glass speed selector pill.
 */
@Composable
fun PlaybackSpeedPill(
    speed: Float,
    onSpeedChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = rememberHaptics()
    val pillShape = RoundedCornerShape(percent = 50)
    var optimisticSpeed by remember(speed) { mutableFloatStateOf(speed) }
    val displaySpeed = if (optimisticSpeed % 1f == 0f) "${optimisticSpeed.toInt()}.0x" else "${optimisticSpeed}x"

    Box(
        modifier = modifier
            .height(34.dp)
            .clip(pillShape)
            .liquidGlass(shape = pillShape)
            .border(GLASS_EDGE_WIDTH, GLASS_EDGE_COLOR, pillShape)
            .clickable {
                haptics.play(Haptic.Tick)
                val currentIndex = SPEED_STEPS.indexOfFirst { kotlin.math.abs(it - optimisticSpeed) < 0.05f }
                val nextIndex = if (currentIndex in 0 until SPEED_STEPS.lastIndex) currentIndex + 1 else 0
                val nextSpeed = SPEED_STEPS[nextIndex]
                optimisticSpeed = nextSpeed
                onSpeedChange(nextSpeed)
            }
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                imageVector = VibraMusicIcons.Speed,
                contentDescription = stringResource(R.string.speed),
                tint = Color.White.copy(alpha = 0.9f),
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = displaySpeed,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
            )
        }
    }
}

/**
 * Show Notes button pill.
 */
@Composable
fun ShowNotesPill(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = rememberHaptics()
    val pillShape = RoundedCornerShape(percent = 50)

    Box(
        modifier = modifier
            .height(34.dp)
            .clip(pillShape)
            .liquidGlass(shape = pillShape)
            .border(GLASS_EDGE_WIDTH, GLASS_EDGE_COLOR, pillShape)
            .clickable {
                haptics.play(Haptic.Tap)
                onClick()
            }
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                imageVector = VibraMusicIcons.Notes,
                contentDescription = stringResource(R.string.show_notes),
                tint = Color.White.copy(alpha = 0.9f),
                modifier = Modifier.size(14.dp),
            )
            Text(
                text = stringResource(R.string.show_notes),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.Medium,
                color = Color.White,
            )
        }
    }
}
