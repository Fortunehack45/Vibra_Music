package com.fortune.vibramusic.desktop.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin

val DefaultMeshColors = listOf(
    Color(0xFF381561),
    Color(0xFF7A1C50),
    Color(0xFF1B3B6F),
    Color(0xFF8B4513),
)

@Composable
fun DesktopMeshGradient(
    colors: List<Color> = DefaultMeshColors,
    modifier: Modifier = Modifier,
) {
    val color1 by animateColorAsState(colors.getOrElse(0) { DefaultMeshColors[0] }, tween(1200))
    val color2 by animateColorAsState(colors.getOrElse(1) { DefaultMeshColors[1] }, tween(1200))
    val color3 by animateColorAsState(colors.getOrElse(2) { DefaultMeshColors[2] }, tween(1200))
    val color4 by animateColorAsState(colors.getOrElse(3) { DefaultMeshColors[3] }, tween(1200))

    val infiniteTransition = rememberInfiniteTransition()
    val progress by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * Math.PI).toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(22000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        )
    )

    Canvas(
        modifier = modifier
            .fillMaxSize()
            .blur(80.dp)
    ) {
        val w = size.width
        val h = size.height
        val radius = maxOf(w, h) * 0.75f

        // Center 1
        val c1 = Offset(
            x = w * 0.35f + w * 0.20f * cos(progress),
            y = h * 0.30f + h * 0.18f * sin(progress),
        )
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(color1.copy(alpha = 0.85f), Color.Transparent),
                center = c1,
                radius = radius,
            ),
            center = c1,
            radius = radius,
        )

        // Center 2
        val c2 = Offset(
            x = w * 0.70f + w * 0.18f * sin(progress + 1.2f),
            y = h * 0.65f + h * 0.22f * cos(progress + 1.2f),
        )
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(color2.copy(alpha = 0.80f), Color.Transparent),
                center = c2,
                radius = radius,
            ),
            center = c2,
            radius = radius,
        )

        // Center 3
        val c3 = Offset(
            x = w * 0.45f + w * 0.22f * cos(progress + 2.5f),
            y = h * 0.80f + h * 0.15f * sin(progress + 2.5f),
        )
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(color3.copy(alpha = 0.75f), Color.Transparent),
                center = c3,
                radius = radius,
            ),
            center = c3,
            radius = radius,
        )

        // Center 4
        val c4 = Offset(
            x = w * 0.80f + w * 0.15f * sin(progress + 4.0f),
            y = h * 0.25f + h * 0.20f * cos(progress + 4.0f),
        )
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(color4.copy(alpha = 0.70f), Color.Transparent),
                center = c4,
                radius = radius,
            ),
            center = c4,
            radius = radius,
        )
    }
}
