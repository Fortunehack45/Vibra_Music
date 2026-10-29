package com.fortune.vibramusic.playback.mix

import com.fortune.vibramusic.playback.smart.EnergySample
import com.fortune.vibramusic.playback.smart.MeterHypothesis
import com.fortune.vibramusic.playback.smart.TrackAnalysis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
    fun testOctaveTempoRelationshipEnablesBeatmatching() {
        // 70 BPM to 140 BPM (1:2 ratio)
        val a = TrackAnalysis(trackId = "a", bpm = 70.0, beatConfidence = 0.9, key = "10A")
        val b = TrackAnalysis(trackId = "b", bpm = 140.0, beatConfidence = 0.9, key = "10A")

        val plan = MixAutoPlanner.autoPlan(a, b, "e1", "e2")
        assertTrue("Octave harmonic BPMs (70 and 140) must support beatmatching", plan.beatmatching)
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

    @Test
    fun testOutroCutSnapsToPhraseOrDownbeat() {
        val downbeatsA = listOf(140.0, 144.0, 148.0, 152.0, 156.0, 160.0, 164.0, 168.0, 172.0)
        val phrasesA = listOf(144.0, 160.0)

        val a = TrackAnalysis(
            trackId = "a",
            duration = 180.0,
            bpm = 120.0,
            beatConfidence = 0.9,
            key = "8A",
            downbeats = downbeatsA,
            phraseBoundaries = phrasesA,
        )
        val b = TrackAnalysis(
            trackId = "b",
            duration = 180.0,
            bpm = 120.0,
            beatConfidence = 0.9,
            key = "8A",
            downbeats = listOf(0.0, 2.0, 4.0, 6.0, 8.0),
        )

        val plan = MixAutoPlanner.autoPlan(a, b, "e1", "e2", fromDurationSec = 180.0, toDurationSec = 180.0)
        assertNotNull(plan.startCutSeconds)

        val snapped = plan.startCutSeconds!!
        val matchesDownbeat = downbeatsA.any { kotlin.math.abs(it - snapped) < 0.05 }
        val matchesPhrase = phrasesA.any { kotlin.math.abs(it - snapped) < 0.05 }

        assertTrue(
            "startCutSeconds ($snapped) must snap to a downbeat or phrase boundary",
            matchesDownbeat || matchesPhrase,
        )
    }

    @Test
    fun testMeterMismatchDisablesBeatmatching() {
        val a = TrackAnalysis(
            trackId = "a",
            bpm = 120.0,
            beatConfidence = 0.9,
            key = "10A",
            meter = MeterHypothesis(beatsPerBar = 4, confidence = 0.9),
        )
        val b = TrackAnalysis(
            trackId = "b",
            bpm = 120.0,
            beatConfidence = 0.9,
            key = "10A",
            meter = MeterHypothesis(beatsPerBar = 3, confidence = 0.9), // Waltz / triple meter
        )

        val plan = MixAutoPlanner.autoPlan(a, b, "e1", "e2")
        assertFalse("Meter mismatch (4/4 vs 3/4) must disable beatmatching", plan.beatmatching)
    }

    @Test
    fun testVocalCollisionEnforcesVocalSeparation() {
        // Build energy curves and vocal activity masks with simultaneous lead singing
        val curveA = (0..200).map { EnergySample(time = it.toDouble(), energy = 0.8) }
        val curveB = (0..200).map { EnergySample(time = it.toDouble(), energy = 0.8) }

        // Vocals active (1.0) on both sides in the transition region (140s to 180s)
        val maskA = (0..200).map { if (it >= 140) 1.0 else 0.0 }
        val maskB = (0..200).map { if (it <= 40) 1.0 else 0.0 }

        val a = TrackAnalysis(
            trackId = "a",
            duration = 180.0,
            bpm = 120.0,
            beatConfidence = 0.95,
            key = "10A",
            energyCurve = curveA,
            vocalActivityMask = maskA,
        )
        val b = TrackAnalysis(
            trackId = "b",
            duration = 180.0,
            bpm = 120.0,
            beatConfidence = 0.95,
            key = "10A",
            energyCurve = curveB,
            vocalActivityMask = maskB,
        )

        val plan = MixAutoPlanner.autoPlan(a, b, "e1", "e2", fromDurationSec = 180.0, toDurationSec = 180.0)
        assertEquals(
            "Vocal collision must activate complementary vocal isolation filter",
            "lpf-in-hpf-out",
            plan.filter.option,
        )
    }

    @Test
    fun testShortTrackHandlingNeverThrowsAndScalesGracefully() {
        val shortA = TrackAnalysis(
            trackId = "short_a",
            duration = 27.0, // 27s Intro
            bpm = 115.0,
            beatConfidence = 0.85,
            key = "8A",
            downbeats = listOf(0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0),
        )
        val normalB = TrackAnalysis(
            trackId = "normal_b",
            duration = 180.0,
            bpm = 115.0,
            beatConfidence = 0.90,
            key = "8A",
            downbeats = listOf(0.0, 2.0, 4.0, 6.0, 8.0),
        )

        val plan = MixAutoPlanner.autoPlan(shortA, normalB, "short_a", "normal_b", fromDurationSec = 27.0, toDurationSec = 180.0)
        assertNotNull(plan)
        assertTrue("Start cut must not exceed track duration", plan.startCutSeconds!! < 27.0)
        assertTrue("Start cut must be greater than zero", plan.startCutSeconds!! > 0.0)
        assertTrue("Mix in must be non-negative", plan.mixInSeconds >= 0.0)
    }

    @Test
    fun testAutoPlanningSubMillisecondBenchmark() {
        val a = TrackAnalysis(trackId = "a", bpm = 120.0, beatConfidence = 0.9, key = "10A", duration = 200.0)
        val b = TrackAnalysis(trackId = "b", bpm = 124.0, beatConfidence = 0.88, key = "10B", duration = 190.0)

        // Warmup
        for (i in 0 until 50) {
            MixAutoPlanner.autoPlan(a, b, "a", "b")
        }

        val startNs = System.nanoTime()
        val iterations = 1000
        for (i in 0 until iterations) {
            MixAutoPlanner.autoPlan(a, b, "a", "b")
        }
        val elapsedMs = (System.nanoTime() - startNs) / 1_000_000.0
        val avgMicros = (elapsedMs * 1000.0) / iterations

        // Must run in under 1 millisecond per plan (1000 microseconds), far exceeding the 500ms target
        assertTrue("Pair planning must average < 1000us (was ${avgMicros}us)", avgMicros < 1000.0)
    }
}
