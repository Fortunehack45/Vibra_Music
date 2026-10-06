package com.fortune.vibramusic.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

class BlendHeadroomTest {

    @Test
    fun returnsUnityGainWhenSumIsLessThanOrEqualToOne() {
        assertEquals(1f, blendHeadroom(0f, 0f), 0.0001f)
        assertEquals(1f, blendHeadroom(0f, 1f), 0.0001f)
        assertEquals(1f, blendHeadroom(1f, 0f), 0.0001f)
        assertEquals(1f, blendHeadroom(0.5f, 0.5f), 0.0001f)
        assertEquals(1f, blendHeadroom(0.3f, 0.4f), 0.0001f)
    }

    @Test
    fun scalesDownWhenSumExceedsOne() {
        // Equal power midpoint: sin(pi/4) + cos(pi/4) ~= 0.7071 + 0.7071 = 1.4142
        val inGain = 0.7071f
        val outGain = 0.7071f
        val headroom = blendHeadroom(inGain, outGain)
        val expected = 1f / sqrt(inGain + outGain)
        assertEquals(expected, headroom, 0.0001f)
        assertTrue(headroom < 1f)

        // Peak overlap when both faders held at 1.0 (Automix hold)
        val maxOverlapHeadroom = blendHeadroom(1f, 1f)
        assertEquals(1f / sqrt(2f), maxOverlapHeadroom, 0.0001f)
    }

    @Test
    fun scaledMidpointLevelNeverExceedsSingleTrackFullScalePower() {
        val inGain = 0.70710677f
        val outGain = 0.70710677f
        val headroom = blendHeadroom(inGain, outGain)
        val scaledIn = inGain * headroom
        val scaledOut = outGain * headroom

        // Summed power (P = v1^2 + v2^2)
        val summedPower = scaledIn * scaledIn + scaledOut * scaledOut
        assertTrue("Summed power should not exceed 1.0", summedPower <= 1.0001f)
    }
}
