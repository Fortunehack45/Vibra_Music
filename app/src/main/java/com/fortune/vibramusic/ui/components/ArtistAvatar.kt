package com.fortune.vibramusic.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage

/**
 * Premium artist avatar with smooth image loading and a vibrant
 * dual-color gradient monogram fallback matching Vibra's liquid-glass design.
 */
@Composable
fun ArtistAvatar(
    name: String = "",
    artistName: String = name,
    artworkUrl: String? = null,
    size: Dp = 48.dp,
    modifier: Modifier = Modifier,
    shape: Shape = CircleShape,
) {
    val finalName = if (artistName.isNotBlank()) artistName else name
    ArtistAvatar(
        imageUrl = artworkUrl,
        name = finalName,
        modifier = modifier.size(size),
        shape = shape,
    )
}

@Composable
fun ArtistAvatar(
    imageUrl: String?,
    name: String,
    modifier: Modifier = Modifier,
    shape: Shape = CircleShape,
) {
    var isError by remember(imageUrl) { mutableStateOf(false) }
    val initial = name.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "A"

    val gradientColors = remember(name) {
        getArtistPalette(name)
    }

    Box(
        modifier = modifier
            .clip(shape)
            .border(1.dp, Color.White.copy(alpha = 0.15f), shape),
        contentAlignment = Alignment.Center,
    ) {
        if (!imageUrl.isNullOrBlank() && !isError) {
            AsyncImage(
                model = imageUrl,
                contentDescription = name,
                contentScale = ContentScale.Crop,
                onError = { isError = true },
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            // Radiant dual-color gradient monogram fallback
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.linearGradient(gradientColors)
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = initial,
                    color = Color.White,
                    fontWeight = FontWeight.ExtraBold,
                    fontSize = 18.sp,
                    letterSpacing = 0.5.sp,
                )
            }
        }
    }
}

/**
 * Deterministically generates a vibrant liquid-glass gradient palette
 * based on the artist's name hash.
 */
private fun getArtistPalette(name: String): List<Color> {
    val palettes = listOf(
        listOf(Color(0xFF8A2387), Color(0xFFE94057), Color(0xFFF27121)), // Sunset Crimson
        listOf(Color(0xFF654EA3), Color(0xFFEAAFC8)), // Velvet Pink
        listOf(Color(0xFF0052D4), Color(0xFF4364F7), Color(0xFF6FB1FC)), // Electric Ocean
        listOf(Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)), // Deep Cyber
        listOf(Color(0xFF11998E), Color(0xFF38EF7D)), // Emerald Aqua
        listOf(Color(0xFFFC466B), Color(0xFF3F5EFB)), // Neon Twilight
        listOf(Color(0xFF833AB4), Color(0xFFFD1D1D), Color(0xFFFCB045)), // Warm Prism
        listOf(Color(0xFF1F1C2C), Color(0xFF928DAB)), // Midnight Amethyst
        listOf(Color(0xFF00b4db), Color(0xFF0083b0)), // Cerulean Wave
        listOf(Color(0xFFd53369), Color(0xFFcbad6d)), // Golden Rose
    )
    val hash = kotlin.math.abs(name.hashCode())
    return palettes[hash % palettes.size]
}
