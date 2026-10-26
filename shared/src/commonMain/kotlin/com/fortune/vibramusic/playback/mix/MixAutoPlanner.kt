package com.fortune.vibramusic.playback.mix

import com.fortune.vibramusic.playback.smart.CamelotKey
import com.fortune.vibramusic.playback.smart.TrackAnalysis
import kotlin.math.abs

/**
 * Deterministic Auto planner that computes the optimal DJ transition between two tracks
 * based on tempo divergence, beat grid alignment, and Camelot harmonic distance.
 */
object MixAutoPlanner {
    const val MAX_STRETCH: Float = 0.08f // 8% maximum allowable tempo stretch

    fun canBeatmatch(bpmOut: Double, bpmIn: Double): Boolean {
        if (bpmOut <= 0.0 || bpmIn <= 0.0) return false
        val ratio = bpmOut / bpmIn
        return abs(ratio - 1.0) <= MAX_STRETCH
    }

    fun autoPlan(
        from: TrackAnalysis?,
        to: TrackAnalysis?,
        fromEntryId: String,
        toEntryId: String,
    ): TransitionPlan {
        val base = TransitionPlan.createEmpty(fromEntryId, toEntryId)

        // Fallback for missing analysis or low beat confidence
        if (from == null || to == null || from.bpm <= 0.0 || to.bpm <= 0.0 ||
            from.beatConfidence < 0.5 || to.beatConfidence < 0.5
        ) {
            val vol = MixOptions.findVolumeOption("smooth-crossfade").build(2)
            val eq = MixOptions.findEqOption("end-bass-swap").build(2)
            val filter = MixOptions.findFilterOption("none").build(2)
            val fx = MixOptions.findEffectsOption("none")
            val loop = MixOptions.findLoopingOption(0)

            return base.copy(
                mode = TransitionMode.AUTO,
                lengthBars = 2,
                beatmatching = false,
                volume = VolumePlan("smooth-crossfade", vol.out, vol.`in`),
                eq = EqPlan("end-bass-swap", eq.out, eq.`in`),
                filter = FilterPlan("none", filter.out, filter.`in`),
                effects = EffectsPlan(fx.id, fx.type, fx.echoBeats, fx.tail, fx.curve),
                looping = LoopingPlan(loop.id, loop.beats),
            )
        }

        val bpmGap = (abs(from.bpm - to.bpm) / from.bpm).toFloat()
        val bpmScore = when {
            bpmGap <= 0.03f -> 1.0f
            bpmGap <= 0.08f -> 0.7f
            bpmGap <= 0.15f -> 0.3f
            else -> 0.0f
        }

        val fromKey = CamelotKey.parse(from.key)
        val toKey = CamelotKey.parse(to.key)
        val keyDist = if (fromKey != null && toKey != null) fromKey.keyDistance(toKey) else 2
        val keyScore = when (keyDist) {
            0 -> 1.0f
            1 -> 0.85f
            2 -> 0.50f
            else -> 0.10f
        }

        val score = bpmScore * 0.6f + keyScore * 0.4f
        val beatmatching = canBeatmatch(from.bpm, to.bpm)

        val bars: Int
        val volOptionId: String
        val eqOptionId: String
        val filterOptionId: String
        val fxOptionId: String

        when {
            score >= 0.85f -> {
                bars = 16
                volOptionId = "overlap"
                eqOptionId = "center-bass-swap"
                filterOptionId = "none"
                fxOptionId = "none"
            }
            score >= 0.65f -> {
                bars = 8
                volOptionId = "overlap"
                eqOptionId = "end-bass-swap"
                filterOptionId = "lpf-in-hpf-out"
                fxOptionId = "none"
            }
            score >= 0.40f -> {
                bars = 4
                volOptionId = "fade-in-fade-out"
                eqOptionId = "end-bass-swap"
                filterOptionId = "none"
                fxOptionId = "none"
            }
            else -> {
                bars = 2
                volOptionId = "fade-in-fast-out"
                eqOptionId = "quick-bass-cut"
                filterOptionId = "lpf-out"
                fxOptionId = "echo-half-out-end"
            }
        }

        val vol = MixOptions.findVolumeOption(volOptionId).build(bars)
        val eq = MixOptions.findEqOption(eqOptionId).build(bars)
        val filter = MixOptions.findFilterOption(filterOptionId).build(bars)
        val fx = MixOptions.findEffectsOption(fxOptionId)
        val loop = MixOptions.findLoopingOption(0)

        return base.copy(
            mode = TransitionMode.AUTO,
            lengthBars = bars,
            beatmatching = beatmatching,
            volume = VolumePlan(volOptionId, vol.out, vol.`in`),
            eq = EqPlan(eqOptionId, eq.out, eq.`in`),
            filter = FilterPlan(filterOptionId, filter.out, filter.`in`),
            effects = EffectsPlan(fx.id, fx.type, fx.echoBeats, fx.tail, fx.curve),
            looping = LoopingPlan(loop.id, loop.beats),
        )
    }
}
