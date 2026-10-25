package com.fortune.vibramusic.playback.smart

import kotlin.math.abs

/**
 * Builds piecewise tempo ramps and knots for master beat clock transitions.
 */
object TempoPlan {

    const val DEFAULT_PRE_RAMP_BARS = 4
    const val DEFAULT_POST_RAMP_BARS = 4

    /**
     * Calculates pivot tempo and knots across pre-ramp, overlap, and post-ramp segments.
     */
    fun create(
        outgoingBpm: Double,
        incomingBpm: Double,
        overlapBeats: Int,
        beatsPerBar: Int = 4,
        allowPreRamp: Boolean = true,
        style: TransitionStyleV2 = TransitionStyleV2.BLEND,
    ): List<TempoKnot> {
        val outBpm = if (outgoingBpm > 0.0) outgoingBpm else 120.0
        val inBpm = if (incomingBpm > 0.0) incomingBpm else 120.0

        val ratio = inBpm / outBpm
        val pivotBpm = when {
            // For Rise, Echo-Out, or Cut, outgoing stays at native tempo up to drop
            style == TransitionStyleV2.RISE || style == TransitionStyleV2.ECHO_OUT || style == TransitionStyleV2.CUT -> outBpm
            // Within 8%: meet in the middle
            abs(ratio - 1.0) <= 0.08 -> (outBpm + inBpm) / 2.0
            // Within 16%: lock to outgoing tempo
            abs(ratio - 1.0) <= 0.16 -> outBpm
            // Larger divergence: maintain outgoing tempo through transition
            else -> outBpm
        }

        val preRampBeats = if (allowPreRamp && style == TransitionStyleV2.BLEND) {
            (DEFAULT_PRE_RAMP_BARS * beatsPerBar).toDouble()
        } else 0.0

        val postRampBeats = if (style == TransitionStyleV2.BLEND) {
            (DEFAULT_POST_RAMP_BARS * beatsPerBar).toDouble()
        } else 0.0

        val knots = mutableListOf<TempoKnot>()

        // Segment 1: Pre-ramp (if any)
        if (preRampBeats > 0.0 && abs(pivotBpm - outBpm) > 0.1) {
            knots += TempoKnot(masterBeat = 0.0, bpm = outBpm)
            knots += TempoKnot(masterBeat = preRampBeats, bpm = pivotBpm)
        } else {
            knots += TempoKnot(masterBeat = 0.0, bpm = pivotBpm)
        }

        // Segment 2: Hold through overlap
        val overlapStart = preRampBeats
        val overlapEnd = preRampBeats + overlapBeats
        if (knots.last().masterBeat < overlapStart) {
            knots += TempoKnot(masterBeat = overlapStart, bpm = pivotBpm)
        }
        knots += TempoKnot(masterBeat = overlapEnd, bpm = pivotBpm)

        // Segment 3: Post-ramp back to native incoming tempo
        if (postRampBeats > 0.0 && abs(inBpm - pivotBpm) > 0.1) {
            val totalEnd = overlapEnd + postRampBeats
            knots += TempoKnot(masterBeat = totalEnd, bpm = inBpm)
        }

        return knots
    }
}
