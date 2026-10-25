package com.fortune.vibramusic.playback.smart

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MasterClockTest {

    @Test
    fun constantTempoClockEvaluatesTauAndRatesAccurately() {
        val clock = MasterClock(listOf(TempoKnot(0.0, 120.0), TempoKnot(32.0, 120.0)))

        assertEquals(120.0, clock.tempoAt(0.0))
        assertEquals(120.0, clock.tempoAt(16.0))
        assertEquals(120.0, clock.tempoAt(32.0))

        // 120 BPM = 0.5s per beat
        assertEquals(0.0, clock.tau(0.0))
        assertEquals(2.0, clock.tau(4.0), 1e-4)
        assertEquals(8.0, clock.tau(16.0), 1e-4)
        assertEquals(16.0, clock.tau(32.0), 1e-4)

        // Deck rate
        assertEquals(1.0, clock.playbackRate(120.0, 16.0), 1e-4)
        assertEquals(120.0 / 110.0, clock.playbackRate(110.0, 16.0), 1e-4)
    }

    @Test
    fun rampingTempoClockPreservesTauMonotonicity() {
        val clock = MasterClock(listOf(
            TempoKnot(0.0, 100.0),
            TempoKnot(16.0, 130.0),
            TempoKnot(32.0, 130.0)
        ))

        var prevTau = 0.0
        for (b in 1..32) {
            val tau = clock.tau(b.toDouble())
            assertTrue(tau > prevTau, "tau must be strictly monotonic: beat $b tau $tau <= $prevTau")
            prevTau = tau
        }

        // At start (100 BPM), beat duration is ~0.60s
        val tau4 = clock.tau(4.0)
        assertTrue(tau4 > 2.0 && tau4 < 2.5)

        // At end (130 BPM), rate is faster
        val tau32 = clock.tau(32.0)
        assertTrue(tau32 > 12.0 && tau32 < 18.0)
    }
}
