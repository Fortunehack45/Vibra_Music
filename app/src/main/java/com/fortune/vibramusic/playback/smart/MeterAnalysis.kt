package com.fortune.vibramusic.playback.smart

import kotlin.math.min

/**
 * Detects meter, time-signature, straight vs triplet feel, and reduces compound meters.
 */
object MeterAnalysis {

    /**
     * Determines the rhythmic feel (STRAIGHT vs TRIPLET) based on sub-beat onset ratios.
     */
    fun detectFeel(
        tripletCorrelation: Double,
        straightCorrelation: Double,
    ): Feel {
        if (tripletCorrelation <= 0.0 && straightCorrelation <= 0.0) return Feel.UNKNOWN
        return if (tripletCorrelation > 1.15 * straightCorrelation) {
            Feel.TRIPLET
        } else {
            Feel.STRAIGHT
        }
    }

    /**
     * Collapses compound meters (6/8, 12/8) to their felt tactus:
     * - 6/8 with triplet feel collapses to 2 dotted-quarter beats per bar.
     * - 12/8 with triplet feel collapses to 4 dotted-quarter beats per bar.
     */
    fun reduceCompoundMeter(
        beatsPerBar: Int,
        bpm: Double,
        feel: Feel,
    ): Pair<Int, Double> {
        return when {
            beatsPerBar == 6 && feel == Feel.TRIPLET -> Pair(2, bpm / 3.0)
            beatsPerBar == 12 && feel == Feel.TRIPLET -> Pair(4, bpm / 3.0)
            else -> Pair(beatsPerBar, bpm)
        }
    }

    /**
     * Computes meter confidence from the ratio of bars matching the dominant meter.
     */
    fun calculateMeterConfidence(
        totalBars: Int,
        matchingBars: Int,
    ): Double {
        if (totalBars < 2) return 0.0
        val matchRatio = matchingBars.toDouble() / totalBars.toDouble()
        val sampleFactor = min(1.0, totalBars / 8.0)
        return (matchRatio * sampleFactor).coerceIn(0.0, 1.0)
    }
}
