package com.fortune.vibramusic.data.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SongTransitionsTest {

    @Test
    fun defaultSettingsAreDisabledWithSixSecondsCrossfade() {
        val transitions = SongTransitions()
        assertFalse(transitions.enabled)
        assertEquals(SongTransitionStyle.CROSSFADE, transitions.style)
        assertEquals(6, transitions.crossfadeSeconds)
        assertFalse(transitions.automix)
        assertEquals(0, transitions.playbackCrossfadeSeconds)
    }

    @Test
    fun automixStyleEnablesAutomixProperty() {
        val transitions = SongTransitions(enabled = true, style = SongTransitionStyle.AUTOMIX, crossfadeSeconds = 8)
        assertTrue(transitions.automix)
        assertEquals(8, transitions.playbackCrossfadeSeconds)
    }

    @Test
    fun crossfadeStyleExposesPlaybackSeconds() {
        val transitions = SongTransitions(enabled = true, style = SongTransitionStyle.CROSSFADE, crossfadeSeconds = 5)
        assertFalse(transitions.automix)
        assertEquals(5, transitions.playbackCrossfadeSeconds)
    }

    @Test
    fun coerceRangeClampsCrossfadeSeconds() {
        val transitions = SongTransitions()
        assertEquals(SongTransitions.MIN_CROSSFADE_SECONDS, transitions.withCrossfadeSeconds(0).crossfadeSeconds)
        assertEquals(SongTransitions.MAX_CROSSFADE_SECONDS, transitions.withCrossfadeSeconds(25).crossfadeSeconds)
        assertEquals(7, transitions.withCrossfadeSeconds(7).crossfadeSeconds)
    }

    @Test
    fun fromLegacyMigrationPreservesPreviousStates() {
        // Both off
        val off = SongTransitions.fromLegacy(crossfadeSeconds = 0, automix = false)
        assertFalse(off.enabled)
        assertEquals(SongTransitionStyle.CROSSFADE, off.style)

        // Legacy crossfade at 5s
        val crossfade = SongTransitions.fromLegacy(crossfadeSeconds = 5, automix = false)
        assertTrue(crossfade.enabled)
        assertEquals(SongTransitionStyle.CROSSFADE, crossfade.style)
        assertEquals(5, crossfade.crossfadeSeconds)

        // Legacy automix on with 0s crossfade (defaults to 6s)
        val automix = SongTransitions.fromLegacy(crossfadeSeconds = 0, automix = true)
        assertTrue(automix.enabled)
        assertEquals(SongTransitionStyle.AUTOMIX, automix.style)
        assertEquals(SongTransitions.DEFAULT_CROSSFADE_SECONDS, automix.crossfadeSeconds)

        // Legacy automix on with 8s crossfade
        val automixWithCustom = SongTransitions.fromLegacy(crossfadeSeconds = 8, automix = true)
        assertTrue(automixWithCustom.enabled)
        assertEquals(SongTransitionStyle.AUTOMIX, automixWithCustom.style)
        assertEquals(8, automixWithCustom.crossfadeSeconds)
    }
}
