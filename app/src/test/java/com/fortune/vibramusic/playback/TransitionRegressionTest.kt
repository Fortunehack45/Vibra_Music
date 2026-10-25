package com.fortune.vibramusic.playback

import com.fortune.vibramusic.playback.audio.AutomationCurve
import com.fortune.vibramusic.playback.audio.TransitionProfile
import com.fortune.vibramusic.playback.smart.CamelotKey
import com.fortune.vibramusic.playback.smart.SmartReorder
import com.fortune.vibramusic.playback.smart.TrackAnalysis
import com.fortune.vibramusic.playback.smart.TransitionCompatibility
import com.fortune.vibramusic.playback.smart.TransitionStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

class TransitionRegressionTest {

    @Test
    fun crossfadeMaintainsConstantPowerAndHeadroomLimits() {
        val steps = 11
        for (i in 0 until steps) {
            val progress = i.toFloat() / (steps - 1)
            val rise = sin(progress * PI.toFloat() / 2f)
            val fall = cos(progress * PI.toFloat() / 2f)

            // Equal power sum of squares equals 1.0
            assertEquals(1.0f, rise * rise + fall * fall, 0.001f)

            // Headroom scaling prevents clipping when signals sum constructively
            val headroom = blendHeadroom(rise, fall)
            val trim = headroom * headroom
            val trimmedRise = rise * trim
            val trimmedFall = fall * trim
            assertTrue(
                "Trimmed gain sum must not exceed 1.0",
                trimmedRise + trimmedFall <= 1.0001f,
            )
        }
    }

    @Test
    fun risePresetPreservesVibraHighPassSweepBehavior() {
        val swapFraction = 0.70f
        val profile = TransitionProfile.rise(swapFraction)

        assertNotNull(profile.outgoingHighPass)
        assertNotNull(profile.outgoingLowPass)
        assertNotNull(profile.incomingHighPass)

        val outHp = profile.outgoingHighPass!!
        val inHp = profile.incomingHighPass!!

        // At progress 0.0, outgoing high-pass is at OFF_HZ (20Hz)
        assertEquals(TransitionFilterProcessor.OFF_HZ, outHp.evaluate(0.0f), 1.0f)

        // At swapFraction (0.70), outgoing high-pass reaches tension peak at 2000Hz
        assertEquals(2000.0f, outHp.evaluate(swapFraction), 5.0f)

        // Incoming high-pass starts at 1200Hz and descends to OFF_HZ by swapFraction
        assertEquals(1200.0f, inHp.evaluate(0.0f), 5.0f)
        assertEquals(TransitionFilterProcessor.OFF_HZ, inHp.evaluate(swapFraction), 1.0f)
    }

    @Test
    fun camelotHarmonicDistanceCalculatesAccurately() {
        val key8A = CamelotKey.parse("8A")!!
        val key9A = CamelotKey.parse("9A")!!
        val key8B = CamelotKey.parse("8B")!!
        val key2B = CamelotKey.parse("2B")!!

        // Same key
        assertEquals(1.0f, key8A.compatibilityScore(key8A), 0.0001f)
        // Adjacent hour (+1 fifth)
        assertEquals(0.90f, key8A.compatibilityScore(key9A), 0.0001f)
        // Relative major (modal modulation)
        assertEquals(0.85f, key8A.compatibilityScore(key8B), 0.0001f)
        // Incompatible key (>3 steps)
        assertTrue(key8A.compatibilityScore(key2B) <= 0.25f)
    }

    @Test
    fun trackPairCompatibilityAccountsForOctaveTempos() {
        // 70 BPM to 140 BPM (1:2 ratio)
        val octaveScore = TransitionCompatibility.calculateTempoScore(70.0, 140.0)
        assertTrue("Octave tempo relationship should score compatible (>=0.80)", octaveScore >= 0.80f)

        // 120 to 122 BPM (direct match)
        val directScore = TransitionCompatibility.calculateTempoScore(120.0, 122.0)
        assertTrue("Direct tempo match should score >=0.90", directScore >= 0.90f)
    }

    @Test
    fun automixFallsBackGracefullyOnMissingData() {
        val unanalyzedA = TrackAnalysis(trackId = "empty_a")
        val unanalyzedB = TrackAnalysis(trackId = "empty_b")

        val result = TransitionCompatibility.evaluate(unanalyzedA, unanalyzedB)

        // Should recommend equal-power crossfade when data is absent
        assertEquals(TransitionStyle.EQUAL_POWER, result.recommendedStyle)
        assertTrue("Confidence must be low for unmeasured tracks", result.confidence < 0.35f)
        assertTrue("Total score must be bounded", result.totalScore in 0f..1f)
    }

    @Test
    fun smartReorderMaintainsStrictPlaylistIntegrity() {
        data class SongItem(val id: String, val bpm: Double, val key: String)

        val playlist = listOf(
            SongItem("track_1", 120.0, "8A"),
            SongItem("track_2", 80.0, "2B"),
            SongItem("track_3", 122.0, "8A"),
            SongItem("track_4", 124.0, "9A"),
        )

        val pinnedIndices = setOf(0) // Lock track_1 in position
        val reordered = SmartReorder.reorder(playlist, pinnedIndices) { item ->
            TrackAnalysis(
                status = TrackAnalysis.STATUS_READY,
                trackId = item.id,
                bpm = item.bpm,
                beatConfidence = 0.9,
                key = item.key,
                keyConfidence = 0.9,
                mixOutTime = 120.0,
                mixInTime = 5.0,
            )
        }

        // Integrity verification
        assertEquals("Pinned item must remain at index 0", "track_1", reordered.items[0].id)
        assertEquals("Playlist size must remain constant", playlist.size, reordered.items.size)
        assertEquals(
            "Every track ID must be preserved without loss or duplication",
            playlist.map { it.id }.toSet(),
            reordered.items.map { it.id }.toSet(),
        )
    }
}
