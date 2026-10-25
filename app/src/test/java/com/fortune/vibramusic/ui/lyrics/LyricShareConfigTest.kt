package com.fortune.vibramusic.ui.lyrics

import com.fortune.vibramusic.data.model.Song
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LyricShareConfigTest {

    @Test
    fun squareRatio_hasSquareDimensionsAndAspect() {
        val square = LyricCardRatio.SQUARE_1_1
        assertEquals("Square (1:1)", square.label)
        assertEquals(1080, square.width)
        assertEquals(1080, square.height)
        assertEquals(1f, square.ratio, 0.0001f)
    }

    @Test
    fun storyRatio_hasNineSixteenDimensions() {
        val story = LyricCardRatio.STORY_9_16
        assertEquals("Story (9:16)", story.label)
        assertEquals(1080, story.width)
        assertEquals(1920, story.height)
        assertEquals(9f / 16f, story.ratio, 0.0001f)
    }

    @Test
    fun ratioEntries_containsOnlySquareAndStory() {
        val names = LyricCardRatio.entries.map { it.name }
        assertEquals(listOf("SQUARE_1_1", "STORY_9_16"), names)
    }

    @Test
    fun lyricShareConfig_defaultsToSquareRatio() {
        val dummySong = Song(
            videoId = "test-id",
            title = "Test Song",
            artist = "Test Artist",
            thumbnailUrl = null,
        )
        val config = LyricShareConfig(
            song = dummySong,
            selectedLines = listOf("Line 1", "Line 2"),
        )
        assertEquals(LyricCardRatio.SQUARE_1_1, config.ratio)
        assertEquals(LyricCardStyle.LYRICS_CARD, config.cardStyle)
        assertTrue(config.showArtwork)
    }
}
