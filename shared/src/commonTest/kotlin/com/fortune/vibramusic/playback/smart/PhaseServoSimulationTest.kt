package com.fortune.vibramusic.playback.smart

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertTrue

class PhaseServoSimulationTest {

    @Test
    fun phaseServoConvergesFortyMillisecondStartupJitterToUnderFourMilliseconds() {
        val preRollMs = 1200L
        val tickIntervalMs = 35L
        val initialStartupDelayMs = 40.0 // 40ms ExoPlayer startup latency

        var remainingToFade = preRollMs.toDouble()
        val incomingCueTimeMs = 30000.0 // 30s mix-in point
        val playbackRate = 1.0
        val baseSpeed = 1.0f

        // Initial state when player starts with 40ms lag behind intended cue
        var incomingPosition = incomingCueTimeMs - preRollMs - initialStartupDelayMs
        var currentSpeed = baseSpeed

        while (remainingToFade > 0) {
            val dt = tickIntervalMs.toDouble()
            // Player advances by dt * speed
            incomingPosition += dt * currentSpeed
            remainingToFade -= dt

            if (remainingToFade > 0) {
                val expectedPos = incomingCueTimeMs - (remainingToFade * playbackRate)
                val driftMs = incomingPosition - expectedPos

                // Rate nudge servo formula
                val nudgedSpeed = (baseSpeed * (1.0f - (driftMs.toFloat() / 4000f))).coerceIn(baseSpeed * 0.96f, baseSpeed * 1.04f)
                if (abs(currentSpeed - nudgedSpeed) > 0.003f) {
                    currentSpeed = nudgedSpeed
                }
            }
        }

        // At transition start, verify drift is locked under 4ms
        val finalExpectedPos = incomingCueTimeMs
        val finalDrift = abs(incomingPosition - finalExpectedPos)

        assertTrue(
            finalDrift < 4.0,
            "Phase-servo must converge 40ms startup jitter to under 4ms before fade starts, actual: ${finalDrift}ms"
        )
    }
}
