package com.fortune.vibramusic.desktop.model

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
)

@Serializable
data class DesktopLyricLine(
    val timeMs: Long,
    val words: String,
    val translation: String? = null,
)

enum class DesktopTab(val title: String) {
    Home("Home"),
    Explore("Explore"),
    Library("Library"),
    Party("Party"),
    Settings("Settings"),
}
