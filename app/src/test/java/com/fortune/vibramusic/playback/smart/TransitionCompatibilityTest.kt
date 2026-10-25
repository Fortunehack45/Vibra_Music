package com.fortune.vibramusic.playback.smart

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TransitionCompatibilityTest {

    @Test
    fun tempoScoreRecognizesDirectMatches() {
        val scoreDirect = TransitionCompatibility.calculateTempoScore(120.0, 122.0)
        assertTrue("Direct tempo match should score high (>0.90)", scoreDirect >= 0.90f)

        val scoreExact = TransitionCompatibility.calculateTempoScore(128.0, 128.0)
        assertEquals(1.0f, scoreExact, 0.001f)
    }

    @Test
    fun tempoScoreRecognizesOctaveHarmonicRatios() {
        // 70 BPM to 140 BPM (1:2 ratio)
        val scoreHalfDouble = TransitionCompatibility.calculateTempoScore(70.0, 140.0)
        assertTrue("Octave tempo ratio (70 vs 140) should score as compatible (>=0.80)", scoreHalfDouble >= 0.80f)

        // 80 BPM to 160 BPM
        val score80To160 = TransitionCompatibility.calculateTempoScore(160.0, 80.0)
        assertTrue("Octave tempo ratio (160 vs 80) should score as compatible (>=0.80)", score80To160 >= 0.80f)
    }

    @Test
    fun tempoScorePenalizesClashingTempos() {
        // 75 BPM to 118 BPM (no harmonic relationship)
        val scoreClash = TransitionCompatibility.calculateTempoScore(75.0, 118.0)
        assertTrue("Clashing tempos should score lower (<=0.60)", scoreClash <= 0.60f)
    }

    @Test
    fun evaluateComputesWeightedScoresAccurately() {
        val trackA = TrackAnalysis(
            status = TrackAnalysis.STATUS_READY,
            trackId = "track_a",
            bpm = 124.0,
            beatConfidence = 0.95,
            key = "8A",
            keyConfidence = 0.90,
            mixOutTime = 180.0,
        )

        val trackB = TrackAnalysis(
            status = TrackAnalysis.STATUS_READY,
            trackId = "track_b",
            bpm = 125.0,
            beatConfidence = 0.92,
            key = "8A",
            keyConfidence = 0.88,
            mixInTime = 8.0,
        )

        val result = TransitionCompatibility.evaluate(trackA, trackB)
        assertTrue("Harmonically matched tracks should have high compatibility (>0.85)", result.totalScore > 0.85f)
        assertTrue("High confidence analyses should yield high overall confidence (>0.70)", result.confidence > 0.70f)
        assertEquals(TransitionStyle.DJ_BLEND, result.recommendedStyle)
    }

    @Test
    fun handlesMissingAnalysisSafelyWithoutCrash() {
        val emptyA = TrackAnalysis()
        val emptyB = TrackAnalysis()

        val result = TransitionCompatibility.evaluate(emptyA, emptyB)
        assertTrue("Total score should stay within [0, 1]", result.totalScore in 0f..1f)
        assertTrue("Confidence should be low for unmeasured tracks", result.confidence < 0.35f)
        assertEquals(TransitionStyle.EQUAL_POWER, result.recommendedStyle)
    }
}
