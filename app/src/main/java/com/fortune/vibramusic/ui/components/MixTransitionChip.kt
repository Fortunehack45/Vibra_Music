package com.fortune.vibramusic.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.Icon
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
import com.fortune.vibramusic.playback.mix.TransitionMode
import com.fortune.vibramusic.playback.mix.TransitionPlan
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics

/**
 * Vertical connector line and interactive pill chip rendered between adjacent song rows
 * in a playlist when Mix is enabled.
 */
@Composable
fun MixTransitionChip(
    plan: TransitionPlan?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = rememberHaptics()
    val lineColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.20f)

    val mode = plan?.mode ?: TransitionMode.AUTO
    val label = when (mode) {
        TransitionMode.AUTO -> "Auto"
        TransitionMode.CUSTOM -> "Custom"
        TransitionMode.PRESET -> plan?.presetId?.replaceFirstChar { it.uppercase() } ?: "Preset"
    }

    val icon = when (mode) {
        TransitionMode.AUTO -> Icons.Rounded.AutoAwesome
        TransitionMode.CUSTOM -> Icons.Rounded.GraphicEq
        TransitionMode.PRESET -> Icons.Rounded.Tune
    }

    val accentColor = when (mode) {
        TransitionMode.AUTO -> Color(0xFF10B981) // Emerald sparkle
        TransitionMode.CUSTOM -> Color(0xFF8B5CF6) // Vibra purple
        TransitionMode.PRESET -> Color(0xFFF59E0B) // Amber
    }

    Column(
        modifier = modifier.padding(vertical = 2.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        // Vertical guideline connecting to row above
        Box(
            modifier = Modifier
                .padding(start = 32.dp)
                .width(1.dp)
                .height(6.dp)
                .background(lineColor),
        )

        // Pill Chip
        Row(
            modifier = Modifier
                .padding(start = 18.dp)
                .height(28.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color.White.copy(alpha = 0.08f))
                .border(0.5.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(14.dp))
                .clickable {
                    haptics.play(Haptic.Select)
                    onClick()
                }
                .padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = accentColor,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall.copy(
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.width(2.dp))
            Icon(
                imageVector = Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                modifier = Modifier.size(16.dp),
            )
        }

        // Vertical guideline connecting to row below
        Box(
            modifier = Modifier
                .padding(start = 32.dp)
                .width(1.dp)
                .height(6.dp)
                .background(lineColor),
        )
    }
}
