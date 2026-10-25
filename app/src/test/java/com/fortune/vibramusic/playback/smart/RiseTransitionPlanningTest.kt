package com.fortune.vibramusic.playback.smart

import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue

class RiseTransitionPlanningTest {

    private fun sampleTrack(id: String, bpm: Double, key: String): TrackAnalysis {
        val beat = 60.0 / bpm
        val downbeats = generateSequence(1.0) { it + 4 * beat }.take(50).toList()
        return TrackAnalysis(
            status = TrackAnalysis.STATUS_READY,
            trackId = id,
            duration = 180.0,
            bpm = bpm,
            beatInterval = beat,
            beatConfidence = 0.9,
            downbeats = downbeats,
            phraseBoundaries = downbeats.filterIndexed { idx, _ -> idx % 8 == 0 },
            key = key,
            keyConfidence = 0.9,
            audibleStartTime = 0.5,
            contentEndTime = 175.0,
            mixInTime = downbeats[4],
            vocalProbability = 0.2,
        )
    }

    @Test
    fun explicitlyRequestedRiseReturnsDjRiseWithMixPlan() {
        val outTrack = sampleTrack("track-a", 124.0, "8A")
        val inTrack = sampleTrack("track-b", 126.0, "8A")

        val plan = planTransition(
            analysis = outTrack,
            nextAnalysis = inTrack,
            currentTrack = TransitionTrackInfo("track-a", 180_000),
            nextTrack = TransitionTrackInfo("track-b", 180_000),
            duration = 180.0,
            mode = CrossfadeMode.SMART,
            requestedStyle = "RISE",
        )

        assertEquals(TransitionStyle.DJ_RISE, plan.transitionStyle)
        assertEquals(1.0, plan.filterSweep, 1e-4)
        assertNotNull(plan.mixPlan)
        assertEquals(TransitionStyleV2.RISE, plan.mixPlan?.style)
        assertTrue(plan.fadeSeconds in 4.0..12.0)
    }

    @Test
    fun largeTempoGapWithHarmonicKeysSelectsRiseOverBlend() {
        // 100 BPM to 140 BPM (40% gap, harmonically matched 8A -> 8A)
        val outTrack = sampleTrack("hiphop", 100.0, "8A")
        val inTrack = sampleTrack("dubstep", 140.0, "8A")

        val plan = planTransition(
            analysis = outTrack,
            nextAnalysis = inTrack,
            currentTrack = TransitionTrackInfo("hiphop", 180_000),
            nextTrack = TransitionTrackInfo("dubstep", 180_000),
            duration = 180.0,
            mode = CrossfadeMode.SMART,
            advanced = true,
        )

        // As specified in Blueprint: large BPM gap must use RISE or ECHO_OUT, never a flat blend
        assertEquals(TransitionStyle.DJ_RISE, plan.transitionStyle)
        assertNotNull(plan.mixPlan)
        assertEquals(TransitionStyleV2.RISE, plan.mixPlan?.style)
    }
}
