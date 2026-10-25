package com.fortune.vibramusic.playback.smart

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * 3-band 16-step groove comparison and rhythmic compatibility scoring.
 */
object GrooveMatch {

    /**
     * Calculates rhythmic similarity [0..1] between two groove profiles.
     */
    fun similarity(a: GrooveProfile?, b: GrooveProfile?): Float {
        if (a == null || b == null) return 0.5f // Neutral baseline

        val lowSim = cosineSimilarity(a.lowBand16, b.lowBand16)
        val midSim = cosineSimilarity(a.midBand16, b.midBand16)
        val highSim = cosineSimilarity(a.highBand16, b.highBand16)

        // Swing difference penalty
        val swingDelta = abs(a.swing - b.swing)
        val swingPenalty = (swingDelta * 0.2f).coerceIn(0f, 0.2f)

        // Low and mid bands dominate perceived rhythmic compatibility
        val raw = lowSim * 0.45f + midSim * 0.35f + highSim * 0.20f
        return (raw - swingPenalty).coerceIn(0f, 1f)
    }

    /**
     * Checks whether simultaneous kicks/bass transients occur on identical 16th steps.
     * When true, two unmanaged low ends turn to mud unless cleanly separated by bass swap.
     */
    fun detectKickClash(lowA: FloatArray, lowB: FloatArray, threshold: Float = 0.15f): Boolean {
        if (lowA.size != 16 || lowB.size != 16) return false
        // Primary kick positions: 0, 4, 8, 12 in 4/4
        for (step in 0 until 16 step 4) {
            if (lowA[step] > threshold && lowB[step] > threshold) {
                return true
            }
        }
        return false
    }

    private fun cosineSimilarity(v1: FloatArray, v2: FloatArray): Float {
        if (v1.isEmpty() || v2.isEmpty() || v1.size != v2.size) return 0f
        var dot = 0f
        var norm1 = 0f
        var norm2 = 0f
        for (i in v1.indices) {
            dot += v1[i] * v2[i]
            norm1 += v1[i] * v1[i]
            norm2 += v2[i] * v2[i]
        }
        val denom = sqrt(norm1) * sqrt(norm2)
        return if (denom > 1e-6f) (dot / denom).coerceIn(0f, 1f) else 0f
    }
}
