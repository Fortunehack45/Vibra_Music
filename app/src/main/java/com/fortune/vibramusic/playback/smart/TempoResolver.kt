package com.fortune.vibramusic.playback.smart

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.roundToInt

/**
 * Precise tempo calculation from measured beat times, robust to outlier or missed beats.
 */
fun bpmFromBeats(beats: List<Double>): Double? {
    if (beats.size < 12) return null
    val ioi = beats.zipWithNext { a, b -> b - a }
    val med = ioi.sorted()[ioi.size / 2]
    if (med <= 0.0) return null

    // Find the longest stretch where beats are steady (within 12% of the median gap).
    var bestStart = 0
    var bestLen = 0
    var start = 0
    for (i in ioi.indices) {
        if (abs(ioi[i] / med - 1.0) > 0.12) start = i + 1
        val len = i - start + 2
        if (len > bestLen) {
            bestLen = len
            bestStart = start
        }
    }
    if (bestLen < 8) return 60.0 / med

    // Least-squares line: time = t0 + k * period. The slope is the beat period.
    val ys = beats.subList(bestStart, bestStart + bestLen)
    val xs = DoubleArray(bestLen) { it.toDouble() }
    val mx = xs.average()
    val my = ys.average()
    val denom = xs.sumOf { (it - mx) * (it - mx) }
    if (denom <= 0.0) return 60.0 / med
    val slope = xs.indices.sumOf { (xs[it] - mx) * (ys[it] - my) } / denom
    return if (slope > 0.0) 60.0 / slope else 60.0 / med
}

/** Gentle preference for common tempos (centered at 125 BPM). Only a tie-breaker. */
private fun tempoPrior(bpm: Double): Double {
    if (bpm <= 0.0) return 0.0
    val z = ln(bpm / 125.0) / 0.45
    return exp(-0.5 * z * z)
}

/** The song's true tempo with the octave decided. */
fun resolveTempo(a: TrackAnalysis): Double? {
    val precise = bpmFromBeats(a.beats) ?: a.bpm.takeIf { it > 0.0 } ?: return null
    val candidates = listOf(precise / 2.0, precise, precise * 2.0).filter { it in 60.0..220.0 }
    if (candidates.isEmpty()) return precise
    return candidates.maxByOrNull { c ->
        val support = a.tempoHypotheses.filter { abs(it.bpm / c - 1.0) < 0.03 }.sumOf { it.weight }
        (support + 0.05) * tempoPrior(c) * (if (c == precise) 1.15 else 1.0)
    }
}

/** One place that formats tempo. Eliminates multiple folding loops. */
object DisplayTempo {
    fun label(bpm: Double): String = bpm.roundToInt().toString()
    fun detail(bpm: Double): String = "%.1f".format(bpm)
    fun needsTilde(meta: TrackMeta, tempoStability: Double?): Boolean =
        (meta.bpm?.confidence ?: 0f) < 0.5f || (tempoStability != null && tempoStability < 0.8)
}
