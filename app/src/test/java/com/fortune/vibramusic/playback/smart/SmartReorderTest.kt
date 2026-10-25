package com.fortune.vibramusic.playback.smart

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SmartReorderTest {

    data class SimpleTrack(val id: String, val bpm: Double, val key: String)

    private fun analysisFor(track: SimpleTrack) = TrackAnalysis(
        status = TrackAnalysis.STATUS_READY,
        trackId = track.id,
        bpm = track.bpm,
        beatConfidence = 0.9,
        key = track.key,
        keyConfidence = 0.9,
        mixOutTime = 100.0,
        mixInTime = 5.0,
    )

    @Test
    fun preservesPinnedTracksAtExactIndices() {
        // Track sequence where track at index 1 is pinned
        val tracks = listOf(
            SimpleTrack("1", bpm = 120.0, key = "8A"),
            SimpleTrack("PINNED", bpm = 90.0, key = "1A"),
            SimpleTrack("3", bpm = 122.0, key = "8A"),
            SimpleTrack("4", bpm = 124.0, key = "8B"),
        )

        val pinned = setOf(1)
        val result = SmartReorder.reorder(tracks, pinned) { analysisFor(it) }

        assertEquals("PINNED track must remain at index 1", "PINNED", result.items[1].id)
        assertEquals("Total item count must remain unchanged", 4, result.items.size)
        assertEquals("All track IDs must be preserved", setOf("1", "PINNED", "3", "4"), result.items.map { it.id }.toSet())
    }

    @Test
    fun optimizesHarmonicSequenceFlow() {
        // Scrambled tracks that have compatible Camelot keys and BPMs
        val trackA = SimpleTrack("A", bpm = 120.0, key = "8A") // 8A
        val trackB = SimpleTrack("B", bpm = 122.0, key = "9A") // 9A (adjacent to 8A)
        val trackC = SimpleTrack("C", bpm = 124.0, key = "10A") // 10A (adjacent to 9A)
        val trackClash = SimpleTrack("Clash", bpm = 85.0, key = "3B") // Clashing key and tempo

        // Put clash right in the middle between A and B
        val scrambled = listOf(trackA, trackClash, trackB, trackC)

        val result = SmartReorder.reorder(scrambled) { analysisFor(it) }

        assertEquals("Total track count must match", scrambled.size, result.items.size)
        assertEquals("All IDs must be present", scrambled.map { it.id }.toSet(), result.items.map { it.id }.toSet())
        assertTrue("Reordered sequence score should be greater than or equal to original", result.reorderedScore >= result.originalScore)
    }

    @Test
    fun smallPlaylistsRemainUnchanged() {
        val single = listOf(SimpleTrack("1", 120.0, "8A"))
        val resultSingle = SmartReorder.reorder(single) { analysisFor(it) }
        assertEquals(single, resultSingle.items)
        assertEquals(0, resultSingle.movedCount)

        val pair = listOf(
            SimpleTrack("1", 120.0, "8A"),
            SimpleTrack("2", 124.0, "8A"),
        )
        val resultPair = SmartReorder.reorder(pair) { analysisFor(it) }
        assertEquals(pair, resultPair.items)
    }
}
