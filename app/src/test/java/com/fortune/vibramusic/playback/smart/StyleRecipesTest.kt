package com.fortune.vibramusic.playback.smart

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

class StyleRecipesTest {

    @Test
    fun blendLanesCreateBassSwapAndGainCrossfade() {
        val lanes = StyleRecipes.createBlendLanes(
            totalBeats = 16.0,
            swapBeat = 12.0,
            vocalClash = true
        )

        val outGain = lanes.first { it.deck == Deck.OUTGOING && it.param == Param.GAIN }
        val inGain = lanes.first { it.deck == Deck.INCOMING && it.param == Param.GAIN }
        val outLow = lanes.first { it.deck == Deck.OUTGOING && it.param == Param.EQ_LOW }
        val inLow = lanes.first { it.deck == Deck.INCOMING && it.param == Param.EQ_LOW }

        // Start: outGain full, inGain silent
        assertEquals(1.0f, outGain.points.first().value, 1e-3f)
        assertEquals(0.0f, inGain.points.first().value, 1e-3f)

        // End: outGain silent, inGain full
        assertEquals(0.0f, outGain.points.last().value, 1e-3f)
        assertEquals(1.0f, inGain.points.last().value, 1e-3f)

        // Bass swap: outgoing low drops to -24 dB, incoming low rises from -24 dB to 0 dB
        assertEquals(-24f, outLow.points.last().value, 1e-4f)
        assertEquals(0f, inLow.points.last().value, 1e-4f)

        // Midrange vocal separation dip exists when vocalClash is true
        assertTrue(lanes.any { it.deck == Deck.OUTGOING && it.param == Param.EQ_MID })
    }

    @Test
    fun riseLanesBuildResonantSweepAndDropOnDownbeat() {
        val dropBeat = 16.0
        val lanes = StyleRecipes.createRiseLanes(totalBeats = 16.0, dropBeat = dropBeat)

        val outHp = lanes.first { it.deck == Deck.OUTGOING && it.param == Param.HP_HZ }
        val outQ = lanes.first { it.deck == Deck.OUTGOING && it.param == Param.HP_Q }
        val outGain = lanes.first { it.deck == Deck.OUTGOING && it.param == Param.GAIN }
        val inGain = lanes.first { it.deck == Deck.INCOMING && it.param == Param.GAIN }

        // High-pass sweeps to 2500 Hz
        assertEquals(2500f, outHp.points.last().value, 1e-4f)

        // Resonant peak rises to 2.5
        assertEquals(2.5f, outQ.points.last().value, 1e-4f)

        // On dropBeat, outgoing cuts to 0 and incoming enters at 1.0
        val outDropPoint = outGain.points.first { it.masterBeat == dropBeat }
        val inDropPoint = inGain.points.first { it.masterBeat == dropBeat }
        assertEquals(0.0f, outDropPoint.value, 1e-4f)
        assertEquals(1.0f, inDropPoint.value, 1e-4f)
    }

    @Test
    fun echoOutLanesApplyOneBeatSendTrail() {
        val cutBeat = 8.0
        val lanes = StyleRecipes.createEchoOutLanes(totalBeats = 8.0, cutBeat = cutBeat)

        val outGain = lanes.first { it.deck == Deck.OUTGOING && it.param == Param.GAIN }
        val inGain = lanes.first { it.deck == Deck.INCOMING && it.param == Param.GAIN }
        val echoSend = lanes.first { it.deck == Deck.OUTGOING && it.param == Param.ECHO_SEND }

        assertEquals(0.0f, outGain.points.first { it.masterBeat == cutBeat }.value, 1e-4f)
        assertEquals(1.0f, inGain.points.first { it.masterBeat == cutBeat }.value, 1e-4f)
        assertTrue("echo send must reach peak level during send", echoSend.points.any { it.value > 0.8f })
        assertEquals(0.0f, echoSend.points.last().value, 1e-4f)
    }
}
