package com.fortune.vibramusic.playback.mix

import com.fortune.vibramusic.playback.smart.TrackAnalysis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MixAutoPlannerTest {

    @Test
    fun testAutoPlanIsDeterministic() {
        val a = TrackAnalysis(trackId = "a", bpm = 120.0, beatConfidence = 0.9, key = "10A")
        val b = TrackAnalysis(trackId = "b", bpm = 122.0, beatConfidence = 0.88, key = "10B")

        val plan1 = MixAutoPlanner.autoPlan(a, b, "e1", "e2")
        val plan2 = MixAutoPlanner.autoPlan(a, b, "e1", "e2")

        assertEquals(plan1.lengthBars, plan2.lengthBars)
        assertEquals(plan1.volume.option, plan2.volume.option)
        assertEquals(plan1.eq.option, plan2.eq.option)
        assertEquals(plan1.beatmatching, plan2.beatmatching)
    }

    @Test
    fun testBpmDisablingBeatmatching() {
        // Gap > 8% (e.g. 100 to 130 bpm is 30%)
        val a = TrackAnalysis(trackId = "a", bpm = 100.0, beatConfidence = 0.9, key = "10A")
        val b = TrackAnalysis(trackId = "b", bpm = 130.0, beatConfidence = 0.9, key = "10A")

        val plan = MixAutoPlanner.autoPlan(a, b, "e1", "e2")
        assertFalse(plan.beatmatching)
    }

    @Test
    fun testFallbackWithoutAnalysis() {
        val b = TrackAnalysis(trackId = "b", bpm = 120.0, beatConfidence = 0.9, key = "10A")
        val plan = MixAutoPlanner.autoPlan(null, b, "e1", "e2")

        assertEquals(2, plan.lengthBars)
        assertFalse(plan.beatmatching)
        assertEquals("smooth-crossfade", plan.volume.option)
    }

    @Test
    fun testHighCompatibilityReceivesLongBlend() {
        // Same BPM and relative keys (10A and 10B)
        val a = TrackAnalysis(trackId = "a", bpm = 115.0, beatConfidence = 0.95, key = "10A")
        val b = TrackAnalysis(trackId = "b", bpm = 115.0, beatConfidence = 0.95, key = "10B")

        val plan = MixAutoPlanner.autoPlan(a, b, "e1", "e2")
        assertTrue(plan.lengthBars >= 8)
        assertTrue(plan.beatmatching)
    }
}
