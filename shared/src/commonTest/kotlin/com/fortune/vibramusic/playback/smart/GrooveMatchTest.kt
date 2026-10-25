package com.fortune.vibramusic.playback.smart

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class GrooveMatchTest {

    @Test
    fun identicalGroovesProduceMaximumSimilarity() {
        val low = FloatArray(16) { if (it % 4 == 0) 1.0f else 0.1f }
        val mid = FloatArray(16) { 0.5f }
        val high = FloatArray(16) { if (it % 2 == 0) 0.8f else 0.2f }

        val grooveA = GrooveProfile(low, mid, high)
        val grooveB = GrooveProfile(low.clone(), mid.clone(), high.clone())

        val sim = GrooveMatch.similarity(grooveA, grooveB)
        assertEquals(1.0f, sim, 1e-4f)

        // Since both kick on 0, 4, 8, 12 simultaneously, kick clash is flagged
        assertTrue(GrooveMatch.detectKickClash(grooveA.lowBand16, grooveB.lowBand16))
    }

    @Test
    fun orthogonalGroovesHaveNoKickClash() {
        // Deck A kicks on 0, 4, 8, 12 (four on the floor)
        val lowA = FloatArray(16) { if (it % 4 == 0) 1.0f else 0.0f }
        // Deck B kicks on offbeats 2, 6, 10, 14
        val lowB = FloatArray(16) { if (it % 4 == 2) 1.0f else 0.0f }

        assertFalse(GrooveMatch.detectKickClash(lowA, lowB))
    }
}
