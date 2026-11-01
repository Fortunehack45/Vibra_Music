package com.fortune.vibramusic.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
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
import kotlin.math.roundToInt

/**
 * Renders the accurate BPM and harmonic Camelot key badge pill on a song row.
 * Displays a fixed-size shimmer placeholder during background computation.
 */
@Composable
fun MixBadge(
    bpm: Double?,
    camelotKey: String?,
    relativeToKey: String? = null,
    showPlaceholder: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val parsedKey = CamelotKey.parse(camelotKey)

    if (bpm == null && parsedKey == null && !showPlaceholder) return

    val transition = rememberInfiniteTransition(label = "mix_badge_shimmer")
    val translateAnim by transition.animateFloat(
        initialValue = 0f,
        targetValue = 180f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "mix_shimmer_translate",
    )

    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.Center,
    ) {
        if (bpm != null && bpm > 0.0) {
            Text(
                text = "${bpm.roundToInt()} bpm",
                style = MaterialTheme.typography.labelSmall.copy(
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                ),
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.85f),
                maxLines = 1,
            )
            Spacer(Modifier.height(2.dp))
        } else if (showPlaceholder) {
            val shimmerBrush = Brush.linearGradient(
                colors = listOf(
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f),
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.18f),
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f),
                ),
                start = Offset(translateAnim - 80f, 0f),
                end = Offset(translateAnim, 0f),
            )
            Box(
                modifier = Modifier
                    .width(42.dp)
                    .height(11.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(shimmerBrush),
            )
            Spacer(Modifier.height(3.dp))
        }

        if (parsedKey != null) {
            val badgeColor = Color(parsedKey.badgeColor())
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .background(badgeColor)
                    .padding(horizontal = 6.dp, vertical = 2.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = parsedKey.code,
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                    ),
                    color = Color(0xFF000000),
                    maxLines = 1,
                )
            }
        } else if (showPlaceholder) {
            val shimmerBrush = Brush.linearGradient(
                colors = listOf(
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f),
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.18f),
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f),
                ),
                start = Offset(translateAnim - 80f, 0f),
                end = Offset(translateAnim, 0f),
            )
            Box(
                modifier = Modifier
                    .width(22.dp)
                    .height(14.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(shimmerBrush),
            )
        }
    }
}
