package com.fortune.vibramusic.ui.components

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.playback.smart.CamelotKey
import com.fortune.vibramusic.playback.smart.DisplayTempo
import com.fortune.vibramusic.playback.smart.TrackMeta
import com.fortune.vibramusic.playback.smart.TrackMetaRepository
import kotlinx.coroutines.flow.filter

/**
 * Synchronous first value from memory, then live updates. No disk or network I/O, safe in lists.
 */
@Composable
fun rememberTrackMeta(trackId: String): State<TrackMeta?> =
    produceState(initialValue = TrackMetaRepository.peek(trackId), key1 = trackId) {
        value = TrackMetaRepository.peek(trackId)
        TrackMetaRepository.updates
            .filter { it == trackId }
            .collect { value = TrackMetaRepository.peek(trackId) }
    }

/**
 * Fixed-size footprint pill that displays accurate BPM and Camelot Key without layout shifts.
 * Renders a fixed shimmer placeholder while background computation is in flight.
 */
@Composable
fun MixMetaPill(
    meta: TrackMeta?,
    modifier: Modifier = Modifier,
    relativeToKey: CamelotKey? = null,
    failed: Boolean = false,
    onClick: () -> Unit = {},
) {
    val bpm = meta?.bpm
    val key = meta?.key

    Box(
        modifier = modifier
            .height(24.dp)
            .widthIn(min = 84.dp)
            .clip(RoundedCornerShape(6.dp))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.CenterEnd,
    ) {
        Crossfade(
            targetState = meta?.complete == true,
            animationSpec = tween(durationMillis = 200),
            label = "mixMetaCrossfade",
        ) { complete ->
            if (complete && bpm != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    val bpmText = "${DisplayTempo.label(bpm.value)} bpm"
                    Text(
                        text = bpmText,
                        style = MaterialTheme.typography.labelSmall.copy(
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f),
                    )

                    if (key != null) {
                        val keyBg = keyColor(key.value, relativeToKey)
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(4.dp))
                                .background(keyBg)
                                .padding(horizontal = 4.dp, vertical = 1.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = key.value.code,
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                ),
                                color = Color.White,
                            )
                        }
                    }
                }
            } else if (failed) {
                Text(
                    text = "-- bpm",
                    style = MaterialTheme.typography.labelSmall.copy(fontSize = 11.sp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                )
            } else {
                // Fixed-size subtle shimmer placeholder while analyzing (no layout shift)
                ShimmerPlaceholder()
            }
        }
    }
}

@Composable
private fun ShimmerPlaceholder() {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val translateAnim by transition.animateFloat(
        initialValue = 0f,
        targetValue = 200f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "shimmerTranslate",
    )

    val shimmerColors = listOf(
        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.16f),
        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
    )

    val brush = Brush.linearGradient(
        colors = shimmerColors,
        start = Offset(translateAnim - 100f, 0f),
        end = Offset(translateAnim, 0f),
    )

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            modifier = Modifier
                .width(44.dp)
                .height(12.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(brush),
        )
        Box(
            modifier = Modifier
                .width(22.dp)
                .height(14.dp)
                .clip(RoundedCornerShape(4.dp))
                .background(brush),
        )
    }
}

private fun keyColor(key: CamelotKey, relativeTo: CamelotKey?): Color {
    if (relativeTo == null) {
        return if (key.isMajor) Color(0xFFD97706) else Color(0xFF2563EB)
    }
    // Compatible key coloring
    val d = kotlin.math.min(
        kotlin.math.abs(key.number - relativeTo.number),
        12 - kotlin.math.abs(key.number - relativeTo.number)
    )
    return when {
        key == relativeTo -> Color(0xFF16A34A) // Exact match: Green
        key.isMajor == relativeTo.isMajor && d == 1 -> Color(0xFF059669) // Energy shift: Emerald
        key.isMajor != relativeTo.isMajor && d == 0 -> Color(0xFF2563EB) // Relative key: Blue
        key.isMajor != relativeTo.isMajor && d == 3 -> Color(0xFF7C3AED) // Parallel key: Violet
        else -> Color(0xFF4B5563) // Distant key: Charcoal
    }
}
