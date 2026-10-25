package com.fortune.vibramusic.playback.smart

import kotlin.math.abs
import kotlin.math.ln

/**
 * Shared Master Beat Clock timeline for transition planning and execution.
 *
 * All transition progress, ramps, and lanes are calculated in master beats [B].
 * Wall-clock time tau(B) is the exact integral of 60 / T(b) db, ensuring that
 * musical bar lines and downbeats remain locked even as tempo changes.
 */
class MasterClock(
    val knots: List<TempoKnot>,
) {
    init {
        require(knots.isNotEmpty()) { "MasterClock requires at least one TempoKnot" }
    }

    /**
     * Evaluates the master tempo T(B) in BPM at master beat [b].
     */
    fun tempoAt(b: Double): Double {
        if (knots.size == 1) return knots.first().bpm
        if (b <= knots.first().masterBeat) return knots.first().bpm
        if (b >= knots.last().masterBeat) return knots.last().bpm

        for (i in 0 until knots.size - 1) {
            val k0 = knots[i]
            val k1 = knots[i + 1]
            if (b in k0.masterBeat..k1.masterBeat) {
                val span = k1.masterBeat - k0.masterBeat
                if (span <= 1e-6) return k0.bpm
                // Smoothstep interpolation (Hermite ease-in ease-out)
                val t = ((b - k0.masterBeat) / span).coerceIn(0.0, 1.0)
                val smoothT = t * t * (3.0 - 2.0 * t)
                return k0.bpm + smoothT * (k1.bpm - k0.bpm)
            }
        }
        return knots.last().bpm
    }

    /**
     * Evaluates the wall-clock time tau(B) in seconds elapsed from master beat 0 to [targetBeat].
     */
    fun tau(targetBeat: Double): Double {
        if (targetBeat <= 0.0) return 0.0
        var totalSec = 0.0
        val evalBeat = targetBeat.coerceAtLeast(0.0)

        // Numerically integrate or sum knot intervals
        for (i in 0 until knots.size - 1) {
            val k0 = knots[i]
            val k1 = knots[i + 1]
            if (evalBeat <= k0.masterBeat) break

            val segmentEnd = minOf(evalBeat, k1.masterBeat)
            val b0 = k0.masterBeat
            val b1 = segmentEnd
            val t0 = k0.bpm
            val t1 = tempoAt(b1)

            totalSec += segmentDuration(b0, b1, t0, t1)
        }

        // If targetBeat extends past last knot, integrate at final constant tempo
        val lastKnot = knots.last()
        if (evalBeat > lastKnot.masterBeat) {
            val extraBeats = evalBeat - lastKnot.masterBeat
            totalSec += extraBeats * (60.0 / lastKnot.bpm)
        }

        return totalSec
    }

    /**
     * Evaluates the instantaneous playback rate for a deck at [masterBeat].
     */
    fun playbackRate(deckBpm: Double, masterBeat: Double): Double {
        if (deckBpm <= 0.0) return 1.0
        val currentMasterBpm = tempoAt(masterBeat)
        return (currentMasterBpm / deckBpm).coerceIn(0.75, 1.35)
    }

    private fun segmentDuration(b0: Double, b1: Double, t0: Double, t1: Double): Double {
        val beats = b1 - b0
        if (beats <= 1e-6) return 0.0
        if (abs(t1 - t0) < 1e-4) {
            return beats * (60.0 / t0)
        }
        // Analytical integral of 60 / (T0 + m * x): (60 * beats / (T1 - T0)) * ln(T1 / T0)
        return (60.0 * beats / (t1 - t0)) * ln(t1 / t0)
    }
}
