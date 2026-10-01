package com.fortune.vibramusic.desktop.model

import androidx.compose.ui.graphics.Color
import kotlinx.serialization.Serializable

@Serializable
data class DesktopSong(
    val id: String,
    val title: String,
    val artist: String,
    val album: String = "",
    val thumbnailUrl: String = "",
    val durationSeconds: Int = 0,
    val streamUrl: String? = null,
    val lyrics: List<DesktopLyricLine> = emptyList(),
    val isExplicit: Boolean = false,
)

@Serializable
data class DesktopLyricLine(
    val timeMs: Long,
    val words: String,
    val translation: String? = null,
)

@Serializable
data class DesktopShelf(
    val title: String,
    val subtitle: String = "",
    val items: List<DesktopSong> = emptyList(),
)

data class DesktopMoodGenre(
    val title: String,
    val colors: List<Color>,
)

enum class DesktopTab(val title: String) {
    Home("Home"),
    Explore("Explore"),
    Library("Library"),
    Search("Search"),
}
