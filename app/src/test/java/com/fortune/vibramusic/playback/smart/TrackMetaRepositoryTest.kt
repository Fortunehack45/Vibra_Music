package com.fortune.vibramusic.playback.smart

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackMetaRepositoryTest {

    @Test
    fun testBpmFromBeatsEquallySpaced() {
        // Beats at 0.5s intervals corresponds exactly to 120 BPM
        val beats = List(16) { it * 0.5 }
        val bpm = bpmFromBeats(beats)
        assertTrue(bpm != null)
        assertEquals(120.0, bpm!!, 0.5)
    }

    @Test
    fun testSameTempoOctavesAndTolerance() {
        // Identical tempo
        assertTrue(TrackMetaRepository.sameTempo(120.0, 120.0))

        // Within 2% tolerance
        assertTrue(TrackMetaRepository.sameTempo(120.0, 121.0))

        // Octave doubling: 60 vs 120 BPM
        assertTrue(TrackMetaRepository.sameTempo(60.0, 120.0))

        // Octave halving: 140 vs 70 BPM
        assertTrue(TrackMetaRepository.sameTempo(140.0, 70.0))

        // Different tempos
        assertFalse(TrackMetaRepository.sameTempo(120.0, 135.0))
        assertFalse(TrackMetaRepository.sameTempo(90.0, 128.0))
    }

    @Test
    fun testMetaSourceTrustHierarchy() {
        val tagField = Field(120.0, 0.9f, MetaSource.TAG)
        val sharedField = Field(120.0, 0.7f, MetaSource.SHARED)
        val userField = Field(122.0, 1.0f, MetaSource.USER)

        // When values agree, TAG (rank 90) outranks SHARED (rank 70)
        val merged1 = mergeField(tagField, sharedField) { a, b -> TrackMetaRepository.sameTempo(a, b) }
        assertEquals(MetaSource.TAG, merged1?.source)
        assertEquals(120.0, merged1?.value ?: 0.0, 0.001)

        // USER (rank 100) outranks TAG (rank 90)
        val merged2 = mergeField(tagField, userField) { a, b -> TrackMetaRepository.sameTempo(a, b) }
        assertEquals(MetaSource.USER, merged2?.source)
        assertEquals(122.0, merged2?.value ?: 0.0, 0.001)
    }

    @Test
    fun testDisplayTempoFormatting() {
        assertEquals("120", DisplayTempo.label(120.0))
        assertEquals("128", DisplayTempo.label(127.8))
        assertEquals("120.4", DisplayTempo.detail(120.4))
    }
}
