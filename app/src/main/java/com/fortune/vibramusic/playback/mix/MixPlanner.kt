package com.fortune.vibramusic.playback.mix

import com.fortune.vibramusic.data.db.TrackAnalysis
import kotlin.math.abs

enum class Style {
    LONG_BLEND_BASS_SWAP,
    RAMP_BASS_SWAP,
    FILTER_SWEEP,
    ECHO_OUT,
    CUT_ON_DOWNBEAT
}

data class MixPreset(
    val name: String,
    val maxBars: Int,
    val allowed: Set<Style>,
    val minScore: Float
)

val SMOOTH = MixPreset(
    name = "Smooth",
    maxBars = 32,
    allowed = setOf(Style.LONG_BLEND_BASS_SWAP, Style.RAMP_BASS_SWAP, Style.FILTER_SWEEP),
    minScore = 55f
)

val DJ = MixPreset(
    name = "DJ",
    maxBars = 16,
    allowed = Style.entries.toSet(),
    minScore = 40f
)

val QUICK = MixPreset(
    name = "Quick",
    maxBars = 8,
    allowed = setOf(Style.RAMP_BASS_SWAP, Style.ECHO_OUT, Style.CUT_ON_DOWNBEAT),
    minScore = 0f
)

data class PairScore(
    val total: Float,
    val bpmGapPct: Float,
    val keyDist: Int,
    val effInBpm: Float
)

data class MixPlan(
    val style: Style,
    val bars: Int,
    val score: Float,
    val outAlignDownbeat: Int,
    val inAlignDownbeat: Int,
    val rampBars: Int,
    val targetBpm: Float,
    val cutOutMs: Long
)

object MixPlanner {

    fun camelotDistance(a: String, b: String): Int {
        if (a.isBlank() || b.isBlank()) return 12
        val na = a.dropLast(1).toIntOrNull() ?: return 12
        val la = a.last().uppercaseChar()
        val nb = b.dropLast(1).toIntOrNull() ?: return 12
        val lb = b.last().uppercaseChar()

        val wheel = minOf(Math.floorMod(na - nb, 12), Math.floorMod(nb - na, 12))
        val letter = if (la == lb) 0 else 1
        return if (wheel == 0) letter else wheel + letter // 0 or 1 = compatible
    }

    /**
     * Compare against x1, x2 and x0.5 of the incoming BPM to survive half/double-time errors.
     */
    fun matchBpm(outBpm: Float, inBpm: Float): Pair<Float, Float> {
        if (outBpm <= 0f || inBpm <= 0f) return inBpm to 0f
        val candidates = listOf(inBpm, inBpm * 2f, inBpm / 2f)
        val best = candidates.minByOrNull { abs(it - outBpm) } ?: inBpm
        val gapPct = abs(best - outBpm) / outBpm * 100f
        return best to gapPct
    }

    fun scorePair(a: TrackAnalysis, b: TrackAnalysis): PairScore {
        val (effIn, gap) = matchBpm(a.bpm, b.bpm)
        val keyDist = camelotDistance(a.camelot, b.camelot)
        val aEnergy = if (a.energyPerBar.isNotEmpty()) a.energyPerBar.takeLast(8).average().toFloat() else 0.5f
        val bEnergy = if (b.energyPerBar.isNotEmpty()) b.energyPerBar.take(8).average().toFloat() else 0.5f
        val energyDelta = abs(aEnergy - bEnergy)

        var s = 100f
        s -= gap * 6f // a 5% gap costs 30
        s -= when {
            keyDist <= 1 -> 0f
            keyDist == 2 -> 8f
            else -> 20f + 5f * (keyDist - 2)
        }
        s -= energyDelta * 25f
        s -= (1f - minOf(a.bpmConfidence, b.bpmConfidence)) * 30f
        return PairScore(s.coerceIn(0f, 100f), gap, keyDist, effIn)
    }

    fun chooseStyle(s: PairScore, p: MixPreset, vocalClash: Boolean): Style {
        val raw = when {
            vocalClash -> Style.FILTER_SWEEP
            s.total >= 80 && s.bpmGapPct < 3f && s.keyDist <= 1 -> Style.LONG_BLEND_BASS_SWAP
            s.total >= 60 && s.bpmGapPct < 8f -> Style.RAMP_BASS_SWAP
            s.total >= 45 && s.bpmGapPct < 12f -> Style.FILTER_SWEEP
            s.bpmGapPct < 20f -> Style.ECHO_OUT
            else -> Style.CUT_ON_DOWNBEAT
        }
        return if (raw in p.allowed && s.total >= p.minScore) {
            raw
        } else {
            p.allowed.firstOrNull { it == Style.ECHO_OUT } ?: Style.CUT_ON_DOWNBEAT
        }
    }

    fun planMix(a: TrackAnalysis, b: TrackAnalysis, preset: MixPreset): MixPlan {
        val sc = scorePair(a, b)
        val barMsA = if (a.bpm > 0f) 4f * 60000f / a.bpm else 2000f
        val barMsB = if (sc.effInBpm > 0f) 4f * 60000f / sc.effInBpm else 2000f

        val inIdx = b.downbeatsMs.indexOfFirst { it >= b.startMs }.coerceAtLeast(0)
        val bDownbeat = if (b.downbeatsMs.isNotEmpty()) b.downbeatsMs[inIdx] else 0f
        val introBars = if (barMsB > 0) ((b.introEndMs - bDownbeat) / barMsB).toInt().coerceAtLeast(0) else 0
        val outroBars = if (barMsA > 0) ((a.durationMs - a.outroStartMs) / barMsA).toInt().coerceAtLeast(0) else 0

        val maxBars = minOf(preset.maxBars, introBars, outroBars)
        val bars = listOf(32, 16, 8, 4).firstOrNull { it <= maxBars } ?: 0

        fun vocalIn(t0: Float, len: Float): Boolean {
            val regions = a.vocalRegionsMs.toList()
            for (i in 0 until regions.size - 1 step 2) {
                val s = regions[i].toFloat()
                val e = regions[i + 1].toFloat()
                if (s < t0 + len && e > t0) return true
            }
            return false
        }

        // Candidate mix-out downbeats: section boundaries first, every 8th bar as fallback
        val phraseSet = a.phraseStartsMs.toSet()
        val candidates = a.downbeatsMs.indices.filter { i ->
            val t = a.downbeatsMs[i]
            (t in phraseSet || i % 8 == 0) &&
                t >= a.outroStartMs - barMsA * 4 &&
                t + bars * barMsA <= a.durationMs
        }
        val clean = candidates.firstOrNull { !vocalIn(a.downbeatsMs[it], bars * barMsA) }
        val outIdx = clean ?: candidates.firstOrNull() ?: (a.downbeatsMs.size - 1 - bars).coerceAtLeast(0)
        val clash = clean == null && bars > 0

        val style = if (bars == 0) Style.CUT_ON_DOWNBEAT else chooseStyle(sc, preset, clash)
        val finalBars = when (style) {
            Style.ECHO_OUT, Style.CUT_ON_DOWNBEAT -> 1
            Style.FILTER_SWEEP -> minOf(bars, 8)
            else -> bars
        }
        val ramp = when {
            sc.bpmGapPct < 0.5f -> 0
            sc.bpmGapPct < 5f -> 2
            else -> 4
        }
        val outTime = if (a.downbeatsMs.isNotEmpty() && outIdx < a.downbeatsMs.size) {
            a.downbeatsMs[outIdx]
        } else {
            a.outroStartMs.toFloat()
        }
        val cutOut = (outTime + finalBars * barMsA).toLong()

        val initialPlan = MixPlan(style, finalBars, sc.total, outIdx, inIdx, ramp, sc.effInBpm, cutOut)

        // Run validation and safe style fallback ladder
        var validatedPlan = initialPlan
        var validationFailure = validate(validatedPlan, a, b)
        while (validationFailure != null && validatedPlan.style != Style.CUT_ON_DOWNBEAT) {
            val nextStyle = fallbackStyle(validatedPlan.style)
            val adaptedBars = when (nextStyle) {
                Style.ECHO_OUT, Style.CUT_ON_DOWNBEAT -> 1
                Style.FILTER_SWEEP -> minOf(bars, 8)
                else -> bars
            }
            val adaptedCutOut = (outTime + adaptedBars * barMsA).toLong()
            validatedPlan = validatedPlan.copy(style = nextStyle, bars = adaptedBars, cutOutMs = adaptedCutOut)
            validationFailure = validate(validatedPlan, a, b)
        }

        return validatedPlan
    }

    fun validate(p: MixPlan, a: TrackAnalysis, b: TrackAnalysis): String? {
        if (p.bars > 0 && p.style in setOf(Style.LONG_BLEND_BASS_SWAP, Style.RAMP_BASS_SWAP)) {
            if (a.bpm > 0f && abs(p.targetBpm - a.bpm) / a.bpm > 0.08f) {
                return "stretch over 8 percent"
            }
            if (minOf(a.bpmConfidence, b.bpmConfidence) < 0.5f) {
                return "beat grid not trusted"
            }
        }
        if (abs(a.lufs - b.lufs) > 12f) {
            return "loudness gap too large"
        }
        return null // plan is fine
    }

    fun fallbackStyle(current: Style): Style {
        return when (current) {
            Style.LONG_BLEND_BASS_SWAP -> Style.RAMP_BASS_SWAP
            Style.RAMP_BASS_SWAP -> Style.FILTER_SWEEP
            Style.FILTER_SWEEP -> Style.ECHO_OUT
            Style.ECHO_OUT -> Style.CUT_ON_DOWNBEAT
            Style.CUT_ON_DOWNBEAT -> Style.CUT_ON_DOWNBEAT
        }
    }
}
