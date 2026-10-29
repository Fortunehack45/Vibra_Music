package com.fortune.vibramusic.playback.smart

import kotlin.math.abs
import org.junit.Test
import org.junit.Assert.assertTrue

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
            "Phase-servo must converge 40ms startup jitter to under 4ms before fade starts, actual: ${finalDrift}ms",
            finalDrift < 4.0
        )
    }

    @Test
    fun phaseServoMaintainsPhaseLockDuringActiveBlend() {
        val fadeMs = 8000.0 // 8s transition
        val tickIntervalMs = 30.0
        val incomingCueTimeMs = 20000.0
        val playbackRate = 1.0
        val baseSpeed = 1.0f

        var incomingPosition = incomingCueTimeMs
        var outgoingPosition = 172000.0 // 8s before 180s track end
        val transitionStartMs = outgoingPosition
        var currentSpeed = baseSpeed

        // Clock drift bias (+1.5ms per second of hardware timer mismatch)
        val clockDriftFactorPerTick = 0.05

        var elapsedMs = 0.0
        var maxObservedDrift = 0.0

        while (elapsedMs < fadeMs) {
            val dt = tickIntervalMs
            outgoingPosition += dt
            incomingPosition += (dt * currentSpeed) + clockDriftFactorPerTick
            elapsedMs += dt

            val outElapsedMs = outgoingPosition - transitionStartMs
            val expectedIncomingPos = incomingCueTimeMs + (outElapsedMs * playbackRate)
            val driftMs = incomingPosition - expectedIncomingPos

            maxObservedDrift = maxOf(maxObservedDrift, abs(driftMs))

            // Active blend phase-servo law from CrossfadeController
            if (abs(driftMs) in 2.0..150.0) {
                val nudgedSpeed = (baseSpeed * (1.0f - (driftMs.toFloat() / 1500f))).coerceIn(baseSpeed * 0.98f, baseSpeed * 1.02f)
                if (abs(currentSpeed - nudgedSpeed) >= 0.0005f) {
                    currentSpeed = nudgedSpeed
                }
            } else if (abs(driftMs) < 1.0) {
                if (abs(currentSpeed - baseSpeed) >= 0.0005f) {
                    currentSpeed = baseSpeed
                }
            }
        }

        val outElapsedMs = outgoingPosition - transitionStartMs
        val finalExpectedPos = incomingCueTimeMs + (outElapsedMs * playbackRate)
        val finalDrift = abs(incomingPosition - finalExpectedPos)

        assertTrue(
            "Active blend phase lock must bound accumulated drift to under 4ms (measured $finalDrift ms, max $maxObservedDrift ms)",
            finalDrift < 4.0
        )
    }
}
