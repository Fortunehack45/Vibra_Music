package com.fortune.vibramusic.ui.lyrics

import android.graphics.Typeface
import androidx.annotation.StringRes
import androidx.compose.ui.graphics.Color
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.model.Song

enum class LyricCardStyle(@StringRes val labelRes: Int) {
    LYRICS_CARD(R.string.lyrics_card),
    SONG_CARD(R.string.song_card),
}

enum class LyricCardFont(val label: String, val typefaceStyle: Int = Typeface.NORMAL) {
    SF_PRO("SF Pro", Typeface.BOLD),
    SERIF("Serif", Typeface.BOLD),
    MONO("Mono", Typeface.BOLD),
    SANS("Sans", Typeface.BOLD),
}

enum class LyricCardPalette(
    val label: String,
    val primaryColor: Color,
    val secondaryColor: Color,
    val textColor: Color = Color.White,
) {
    ARTWORK("Artwork", Color(0xFF4A4E5A), Color(0xFF1E1E24)),
    OBSIDIAN("Obsidian", Color(0xFF232526), Color(0xFF0F0C20)),
    SUNSET("Sunset", Color(0xFFFF5E62), Color(0xFFFF9966)),
    OCEAN("Ocean", Color(0xFF00C0FF), Color(0xFF4218B8)),
    ROSE("Rosé", Color(0xFFFF0844), Color(0xFFFFB199)),
    GLASS("Glass", Color(0xFF3A3D40), Color(0xFF181719)),
}

enum class LyricCardAlignment(val label: String) {
    LEFT("Left"),
    CENTER("Center"),
    RIGHT("Right"),
}

enum class LyricCardRatio(val label: String, val width: Int, val height: Int, val ratio: Float) {
    CARD_3_4("Card (3:4)", 1080, 1440, 3f / 4f),
    STORY_9_16("Story (9:16)", 1080, 1920, 9f / 16f),
}

data class LyricShareConfig(
    val song: Song,
    val selectedLines: List<String>,
    val cardStyle: LyricCardStyle = LyricCardStyle.LYRICS_CARD,
    val palette: LyricCardPalette = LyricCardPalette.ARTWORK,
    val font: LyricCardFont = LyricCardFont.SF_PRO,
    val alignment: LyricCardAlignment = LyricCardAlignment.LEFT,
    val ratio: LyricCardRatio = LyricCardRatio.CARD_3_4,
    val showArtwork: Boolean = true,
)

