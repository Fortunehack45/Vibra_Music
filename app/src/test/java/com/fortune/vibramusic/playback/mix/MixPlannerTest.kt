package com.fortune.vibramusic.playback.mix

import com.fortune.vibramusic.data.db.TrackAnalysis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MixPlannerTest {

    @Test
    fun testFoldBpm() {
        val (b60, amb60) = NativeAnalyzer.foldBpm(60f)
        assertEquals(120f, b60, 0.01f)
        assertFalse(amb60) // 120 is in 90..140

        val (b75, amb75) = NativeAnalyzer.foldBpm(75f)
        assertEquals(150f, b75, 0.01f)
        assertTrue(amb75) // 150 is > 140

        val (b180, amb180) = NativeAnalyzer.foldBpm(180f)
        assertEquals(90f, b180, 0.01f)
        assertFalse(amb180)

        val (b124, amb124) = NativeAnalyzer.foldBpm(124f)
        assertEquals(124f, b124, 0.01f)
        assertFalse(amb124)
    }

    @Test
    fun testCamelotDistance() {
        // Same key
        assertEquals(0, MixPlanner.camelotDistance("8A", "8A"))
        // Relative major/minor (mode swap)
        assertEquals(1, MixPlanner.camelotDistance("8A", "8B"))
        // Adjacent step (fifth)
        assertEquals(1, MixPlanner.camelotDistance("8A", "9A"))
        assertEquals(1, MixPlanner.camelotDistance("8A", "7A"))
        // Wrap around wheel
        assertEquals(1, MixPlanner.camelotDistance("12B", "1B"))
        assertEquals(1, MixPlanner.camelotDistance("1B", "12B"))
        // Two steps away
        assertEquals(2, MixPlanner.camelotDistance("8A", "10A"))
        // Relative major/minor plus 1 step away
        assertEquals(2, MixPlanner.camelotDistance("8A", "9B"))
        // Distant / tritone clash
        assertEquals(6, MixPlanner.camelotDistance("8A", "2A"))
    }

    @Test
    fun testMatchBpmSurvivesOctaveJumps() {
        // Normal small gap
        val (eff124, gap124) = MixPlanner.matchBpm(120f, 124f)
        assertEquals(124f, eff124, 0.01f)
        assertEquals(3.33f, gap124, 0.05f)

        // Half time (70 vs 140)
        val (eff140, gap140) = MixPlanner.matchBpm(140f, 70f)
        assertEquals(140f, eff140, 0.01f) // Doubled to match
        assertEquals(0f, gap140, 0.01f)

        // Double time (80 vs 160)
        val (eff80, gap80) = MixPlanner.matchBpm(80f, 160f)
        assertEquals(80f, eff80, 0.01f) // Halved to match
        assertEquals(0f, gap80, 0.01f)
    }

    @Test
    fun testSyntheticClickTrackPair120And124Bpm() {
        val barMsA = 4f * 60000f / 120f // 2000 ms per bar
        val barMsB = 4f * 60000f / 124f // 1935.48 ms per bar

        val downbeatsA = FloatArray(90) { i -> i * barMsA }
        val beatsA = FloatArray(360) { i -> i * (barMsA / 4f) }
        val phrasesA = FloatArray(10) { i -> i * 8 * barMsA }

        val downbeatsB = FloatArray(100) { i -> i * barMsB }
        val beatsB = FloatArray(400) { i -> i * (barMsB / 4f) }
        val phrasesB = FloatArray(12) { i -> i * 8 * barMsB }

        val trackA = TrackAnalysis(
            trackId = "track_120_bpm",
            fingerprint = "fp_120",
            analysisVersion = 1,
            durationMs = 180000L,
            startMs = 0L,
            bpm = 120f,
            bpmConfidence = 0.95f,
            bpmAmbiguous = false,
            beatsMs = beatsA,
            downbeatsMs = downbeatsA,
            camelot = "8A",
            keyConfidence = 0.9f,
            lufs = -14f,
            energyPerBar = FloatArray(90) { 0.7f },
            introEndMs = 16000L,
            outroStartMs = 140000L,
            vocalRegionsMs = longArrayOf(16000L, 120000L),
            phraseStartsMs = phrasesA
        )

        val trackB = TrackAnalysis(
            trackId = "track_124_bpm",
            fingerprint = "fp_124",
            analysisVersion = 1,
            durationMs = 200000L,
            startMs = 0L,
            bpm = 124f,
            bpmConfidence = 0.96f,
            bpmAmbiguous = false,
            beatsMs = beatsB,
            downbeatsMs = downbeatsB,
            camelot = "9A",
            keyConfidence = 0.88f,
            lufs = -14.5f,
            energyPerBar = FloatArray(100) { 0.68f },
            introEndMs = 31000L,
            outroStartMs = 160000L,
            vocalRegionsMs = longArrayOf(31000L, 140000L),
            phraseStartsMs = phrasesB
        )

        val score = MixPlanner.scorePair(trackA, trackB)
        assertTrue("Expected score >= 75 for compatible 120/124 BPM pair, got ${score.total}", score.total >= 75f)
        assertEquals(1, score.keyDist)

        val planDJ = MixPlanner.planMix(trackA, trackB, DJ)
        assertTrue(
            "Expected RAMP_BASS_SWAP or LONG_BLEND_BASS_SWAP, got ${planDJ.style}",
            planDJ.style in setOf(Style.RAMP_BASS_SWAP, Style.LONG_BLEND_BASS_SWAP)
        )
        assertTrue("Bars should be <= 16 for DJ preset, got ${planDJ.bars}", planDJ.bars in listOf(4, 8, 16))
        assertEquals(124f, planDJ.targetBpm, 0.01f)
        assertTrue("cutOutMs should be in outro region, got ${planDJ.cutOutMs}", planDJ.cutOutMs >= 140000L)
    }

    @Test
    fun testValidatorSafetyChecks() {
        val baseTrack = TrackAnalysis(
            trackId = "test1",
            fingerprint = "fp",
            analysisVersion = 1,
            durationMs = 180000L,
            startMs = 0L,
            bpm = 120f,
            bpmConfidence = 0.9f,
            bpmAmbiguous = false,
            beatsMs = floatArrayOf(0f, 500f, 1000f),
            downbeatsMs = floatArrayOf(0f, 2000f, 4000f),
            camelot = "8A",
            keyConfidence = 0.9f,
            lufs = -14f,
            energyPerBar = floatArrayOf(0.5f),
            introEndMs = 10000L,
            outroStartMs = 160000L,
            vocalRegionsMs = longArrayOf(),
            phraseStartsMs = floatArrayOf(0f)
        )

        val planOk = MixPlan(
            style = Style.RAMP_BASS_SWAP,
            bars = 8,
            score = 80f,
            outAlignDownbeat = 0,
            inAlignDownbeat = 0,
            rampBars = 2,
            targetBpm = 125f, // ~4.1% stretch, within 8%
            cutOutMs = 176000L
        )
        assertNull(MixPlanner.validate(planOk, baseTrack, baseTrack))

        // Stretch over 8%
        val planOverstretched = planOk.copy(targetBpm = 135f) // >12% stretch
        assertEquals("stretch over 8 percent", MixPlanner.validate(planOverstretched, baseTrack, baseTrack))

        // Low beat confidence
        val lowConfTrack = baseTrack.copy(bpmConfidence = 0.3f)
        assertEquals("beat grid not trusted", MixPlanner.validate(planOk, lowConfTrack, baseTrack))

        // Large loudness gap (>12 dB)
        val quietTrack = baseTrack.copy(lufs = -30f)
        assertEquals("loudness gap too large", MixPlanner.validate(planOk, baseTrack, quietTrack))
    }
}
