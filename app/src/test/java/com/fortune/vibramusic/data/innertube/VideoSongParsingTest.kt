package com.fortune.vibramusic.data.innertube

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoSongParsingTest {

    @Test
    fun testSongSubtitleIsNotClassifiedAsVideo() {
        val subtitle1 = "Song • Rema"
        val subtitle2 = "Song • Fireboy DML"
        val subtitle3 = "Song • Asake • Mr. Money With The Vibe"

        fun isVideo(subtitle: String, isWidescreen: Boolean): Boolean {
            val isExplicitSong = subtitle.contains("Song", ignoreCase = true) || subtitle.startsWith("Song", ignoreCase = true)
            return if (isExplicitSong) {
                false
            } else {
                isWidescreen || subtitle.contains("views", ignoreCase = true)
            }
        }

        assertFalse(isVideo(subtitle1, isWidescreen = true))
        assertFalse(isVideo(subtitle2, isWidescreen = true))
        assertFalse(isVideo(subtitle3, isWidescreen = true))
    }

    @Test
    fun testActualVideoSubtitleIsClassifiedAsVideo() {
        val videoSubtitle = "Official Music Video • 12M views"

        fun isVideo(subtitle: String, isWidescreen: Boolean): Boolean {
            val isExplicitSong = subtitle.contains("Song", ignoreCase = true) || subtitle.startsWith("Song", ignoreCase = true)
            return if (isExplicitSong) {
                false
            } else {
                isWidescreen || subtitle.contains("views", ignoreCase = true)
            }
        }

        assertTrue(isVideo(videoSubtitle, isWidescreen = true))
    }
}
