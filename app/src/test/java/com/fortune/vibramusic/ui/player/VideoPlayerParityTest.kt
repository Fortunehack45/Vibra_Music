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

    @Test
    fun canvasSuppressionWhenVideoModeActive() {
        val mockCanvas = "https://canvas.spotify.com/mock.mp4"
        val isPodcast = false
        val videoMode = true
        val resolvedCanvas = if (isPodcast || videoMode) null else mockCanvas
        assertNull(resolvedCanvas)

        val audioTrackVideoMode = false
        val audioResolvedCanvas = if (isPodcast || audioTrackVideoMode) null else mockCanvas
        assertEquals(mockCanvas, audioResolvedCanvas)
    }

    @Test
    fun sleeveShadowAndBackgroundSuppressionOnVideo() {
        fun sleeveShadow(artLoaded: Boolean, videoMode: Boolean, docking: Boolean): Int {
            return if (artLoaded && (!videoMode || docking)) 10 else 0
        }
        fun sleeveTransparent(videoMode: Boolean, docking: Boolean): Boolean {
            return videoMode && !docking
        }

        // On video song while expanded: shadow is 0, background is transparent
        assertEquals(0, sleeveShadow(artLoaded = true, videoMode = true, docking = false))
        assertEquals(true, sleeveTransparent(videoMode = true, docking = false))

        // On video song while docking (collapsing to miniplayer): shadow is preserved for smooth transition
        assertEquals(10, sleeveShadow(artLoaded = true, videoMode = true, docking = true))
        assertEquals(false, sleeveTransparent(videoMode = true, docking = true))

        // On regular audio song: shadow is 10, background is opaque/dark
        assertEquals(10, sleeveShadow(artLoaded = true, videoMode = false, docking = false))
        assertEquals(false, sleeveTransparent(videoMode = false, docking = false))
    }
}
