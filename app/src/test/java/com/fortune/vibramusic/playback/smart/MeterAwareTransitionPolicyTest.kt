package com.fortune.vibramusic.playback.smart

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MeterAwareTransitionPolicyTest {

    private fun track(
        bpm: Double = 120.0,
        beatConfidence: Double = 0.9,
        meter: MeterHypothesis = MeterHypothesis(beatsPerBar = 4, confidence = 0.9),
    ) = TrackAnalysis(
        status = TrackAnalysis.STATUS_READY,
        bpm = bpm,
        beatInterval = 60.0 / bpm,
        beatConfidence = beatConfidence,
        firstBeat = 0.5,
        meter = meter,
    )

    @Test
    fun beatTrackerInfersQuadrupleMeterFromFourBeatSpacing() {
        val interval = 0.5 // 120 BPM
        val beats = (0 until 32).map { 1.0 + it * interval }
        // Downbeats every 4 beats: 1.0, 3.0, 5.0, etc.
        val downbeats = (0 until 8).map { 1.0 + it * 4 * interval }

        val meter = BeatTracker.inferMeter(beats, downbeats)
        assertEquals("Should infer 4 beats per bar", 4, meter.beatsPerBar)
        assertFalse("Should not be ambiguous", meter.isAmbiguous)
        assertTrue("Confidence should be high", meter.confidence >= 0.8)
    }

    @Test
    fun beatTrackerInfersTripleMeterFromThreeBeatSpacing() {
        val interval = 0.4 // 150 BPM waltz
        val beats = (0 until 30).map { 1.0 + it * interval }
        // Downbeats every 3 beats: 1.0, 2.2, 3.4, etc.
        val downbeats = (0 until 10).map { 1.0 + it * 3 * interval }

        val meter = BeatTracker.inferMeter(beats, downbeats)
        assertEquals("Should infer 3 beats per bar", 3, meter.beatsPerBar)
        assertFalse("Should not be ambiguous", meter.isAmbiguous)
        assertTrue("Confidence should be high", meter.confidence >= 0.8)
    }

    @Test
    fun matchingMetersAuthorizeBeatmatchedTier() {
        val outTrack = track(bpm = 120.0, meter = MeterHypothesis(beatsPerBar = 4, confidence = 0.9))
        val inTrack = track(bpm = 122.0, meter = MeterHypothesis(beatsPerBar = 4, confidence = 0.9))

        val verdict = assessTransitionTier(outTrack, inTrack)
        assertEquals("Matching 4/4 tracks should be BEATMATCHED", TransitionTier.BEATMATCHED, verdict.tier)
        assertTrue("Reasons should be empty", verdict.reasons.isEmpty())
    }

    @Test
    fun meterMismatchDegradesToDjAssistedWithReason() {
        // 4/4 pop song transitioning into 3/4 waltz
        val outTrack = track(bpm = 120.0, meter = MeterHypothesis(beatsPerBar = 4, confidence = 0.9))
        val inTrack = track(bpm = 122.0, meter = MeterHypothesis(beatsPerBar = 3, confidence = 0.9))

        val verdict = assessTransitionTier(outTrack, inTrack)
        assertEquals("Mismatched meters must not be BEATMATCHED", TransitionTier.DJ_ASSISTED, verdict.tier)
        assertTrue("Should contain meter-mismatch reason", verdict.reasons.contains("meter-mismatch"))
    }

    @Test
    fun ambiguousMeterDegradesToDjAssistedWithReason() {
        val outTrack = track(bpm = 120.0, meter = MeterHypothesis(beatsPerBar = 4, confidence = 0.9))
        val inTrack = track(bpm = 122.0, meter = MeterHypothesis(beatsPerBar = 4, confidence = 0.8, isAmbiguous = true))

        val verdict = assessTransitionTier(outTrack, inTrack)
        assertEquals("Ambiguous meter must not be BEATMATCHED", TransitionTier.DJ_ASSISTED, verdict.tier)
        assertTrue("Should contain meter-ambiguous reason", verdict.reasons.contains("meter-ambiguous"))
    }

    @Test
    fun transitionCompatibilityRecommendsFilterForMeterMismatch() {
        val outTrack = track(bpm = 120.0, meter = MeterHypothesis(beatsPerBar = 4, confidence = 0.9))
            .copy(mixOutTime = 100.0, mixInTime = 10.0)
        val inTrack = track(bpm = 121.0, meter = MeterHypothesis(beatsPerBar = 3, confidence = 0.9))
            .copy(mixOutTime = 100.0, mixInTime = 10.0)

        val eval = TransitionCompatibility.evaluate(outTrack, inTrack)
        assertEquals(
            "Meter mismatch must recommend DJ_FILTER rather than DJ_BLEND",
            TransitionStyle.DJ_FILTER,
            eval.recommendedStyle,
        )
    }
}
