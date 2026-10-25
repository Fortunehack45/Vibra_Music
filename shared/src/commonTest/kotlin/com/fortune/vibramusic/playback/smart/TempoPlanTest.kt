package com.fortune.vibramusic.playback.smart

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TempoPlanTest {

    @Test
    fun withinEightPercentMeetsInMiddle() {
        val knots = TempoPlan.create(
            outgoingBpm = 120.0,
            incomingBpm = 126.0, // 5% divergence
            overlapBeats = 16,
            style = TransitionStyleV2.BLEND
        )
        assertTrue(knots.isNotEmpty())
        // Pivot tempo should be average: 123.0 BPM
        val overlapKnot = knots.first { it.masterBeat >= 16.0 }
        assertEquals(123.0, overlapKnot.bpm, 1e-4)
    }

    @Test
    fun withinSixteenPercentLocksToOutgoing() {
        val knots = TempoPlan.create(
            outgoingBpm = 120.0,
            incomingBpm = 135.0, // 12.5% divergence
            overlapBeats = 16,
            style = TransitionStyleV2.BLEND
        )
        assertTrue(knots.isNotEmpty())
        // Pivot tempo locks to outgoing: 120.0 BPM
        val overlapKnot = knots.first { it.masterBeat >= 16.0 }
        assertEquals(120.0, overlapKnot.bpm, 1e-4)
    }

    @Test
    fun riseAndCutKeepOutgoingNativeTempoUntilDrop() {
        val riseKnots = TempoPlan.create(
            outgoingBpm = 128.0,
            incomingBpm = 174.0, // Huge gap
            overlapBeats = 16,
            style = TransitionStyleV2.RISE
        )
        // Outgoing stays at native 128.0 BPM throughout riser
        assertTrue(riseKnots.all { it.bpm == 128.0 })

        val cutKnots = TempoPlan.create(
            outgoingBpm = 100.0,
            incomingBpm = 140.0,
            overlapBeats = 8,
            style = TransitionStyleV2.CUT
        )
        assertTrue(cutKnots.all { it.bpm == 100.0 })
    }
}
