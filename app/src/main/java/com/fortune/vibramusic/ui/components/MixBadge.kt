package com.fortune.vibramusic.ui.components

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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.playback.smart.CamelotKey
import kotlin.math.roundToInt

/**
 * Renders the BPM and harmonic Camelot key badge pill on a song row.
 * Follows the dynamic harmonic compatibility color coding:
 * - Distance 0 or 1: Blue or Emerald
 * - Distance 2: Amber
 * - Distance 3+: Coral
 */
@Composable
fun MixBadge(
    bpm: Double?,
    camelotKey: String?,
    relativeToKey: String? = null,
    modifier: Modifier = Modifier,
) {
    val parsedKey = CamelotKey.parse(camelotKey)
    val parsedRelKey = CamelotKey.parse(relativeToKey)

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
        }

        if (parsedKey != null) {
            val badgeColor = Color(parsedKey.badgeColor(parsedRelKey))
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(4.dp))
                    .background(badgeColor)
                    .padding(horizontal = 5.dp, vertical = 1.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = parsedKey.code,
                    style = MaterialTheme.typography.labelSmall.copy(
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                    ),
                    color = Color.White,
                    maxLines = 1,
                )
            }
        }
    }
}
