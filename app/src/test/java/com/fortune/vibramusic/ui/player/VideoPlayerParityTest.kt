package com.fortune.vibramusic.ui.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VideoPlayerParityTest {

    @Test
    fun videoQualityLabelsMatchBitChordStandard() {
        assertEquals("8K", videoQualityLabel(4320))
        assertEquals("4K", videoQualityLabel(2160))
        assertEquals("2K", videoQualityLabel(1440))
        assertEquals("FullHD", videoQualityLabel(1080))
        assertEquals("HD", videoQualityLabel(720))
        assertEquals("480p", videoQualityLabel(480))
        assertEquals("360p", videoQualityLabel(360))
        assertEquals("240p", videoQualityLabel(240))
        assertEquals("144p", videoQualityLabel(144))
    }

    @Test
    fun musicVideoQualityUiSelectedResolution() {
        val defaultQuality = MusicVideoQualityUi(
            heights = listOf(1080, 720, 480, 360),
            held = null,
            activeHeight = 720,
        )
        // When held is null, it returns activeHeight
        assertEquals(720, defaultQuality.selected())

        // When held is set to an available height, it returns held
        val heldQuality = defaultQuality.copy(held = 1080)
        assertEquals(1080, heldQuality.selected())

        // When held is set to an unavailable height, fallback to activeHeight
        val unavailableHeld = defaultQuality.copy(held = 2160)
        assertEquals(720, unavailableHeld.selected())

        // When activeHeight is null and held is null, returns null (Auto)
        val emptyQuality = MusicVideoQualityUi(
            heights = listOf(1080, 720),
            held = null,
            activeHeight = null,
        )
        assertNull(emptyQuality.selected())
    }

    @Test
    fun videoAspectClampingEnforcesValidAspectRatios() {
        val ultraWide = 3.5f
        val vertical = 0.5f
        val standard169 = 16f / 9f

        assertEquals(2.4f, ultraWide.coerceIn(1f, 2.4f), 0.001f)
        assertEquals(1.0f, vertical.coerceIn(1f, 2.4f), 0.001f)
        assertEquals(1.777f, standard169.coerceIn(1f, 2.4f), 0.01f)
    }
}
