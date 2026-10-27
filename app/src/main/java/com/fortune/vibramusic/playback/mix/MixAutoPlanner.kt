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

    /**
     * Dynamically calculates how many seconds to shorten/cut from the song outro
     * in Auto mode based on total track length (10% to 30%).
     */
    fun calculateAutoOutroCutSeconds(durationSec: Double): Double {
        if (durationSec <= 0.0) return 0.0
        val cutFraction = when {
            durationSec >= 300.0 -> 0.28 // 28% cut for 5+ min tracks (e.g. 6 min song cuts ~1:40)
            durationSec >= 210.0 -> 0.22 // 22% cut for 3.5 - 5 min tracks (e.g. 4 min song cuts ~53s)
            durationSec >= 150.0 -> 0.16 // 16% cut for 2.5 - 3.5 min tracks (e.g. 2:40 song cuts ~26s)
            durationSec >= 90.0  -> 0.12 // 12% cut for 1.5 - 2.5 min tracks (e.g. 2 min song cuts ~14s)
            else                 -> 0.08 // 8% cut for short tracks
        }
        return durationSec * cutFraction
    }

    /**
     * Dynamically calculates cue-in / intro cut for the incoming track.
     */
    fun calculateAutoIntroCutSeconds(durationSec: Double): Double {
        if (durationSec <= 0.0) return 0.0
        val introCut = when {
            durationSec >= 240.0 -> 8.0
            durationSec >= 150.0 -> 5.0
            else -> 2.0
        }
        return introCut.coerceAtMost(durationSec * 0.15)
    }

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

            val durA = from?.duration?.takeIf { it > 10.0 } ?: 180.0
            val durB = to?.duration?.takeIf { it > 10.0 } ?: 180.0
            val outroCutA = calculateAutoOutroCutSeconds(durA)
            val introCutB = calculateAutoIntroCutSeconds(durB)

            val defaultCut = from?.mixOutTime?.takeIf { it > 15.0 && it < (durA - 5.0) }
                ?: (durA - outroCutA).coerceIn(15.0, durA - 4.0)
            val defaultIn = to?.mixInTime?.takeIf { it >= 0.0 && it < (durB * 0.35) }
                ?: introCutB

            return base.copy(
                mode = TransitionMode.AUTO,
                lengthBars = 2,
                beatmatching = false,
                startCutSeconds = defaultCut,
                mixInSeconds = defaultIn,
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

        val secondsPerBar = (60.0 / from.bpm.coerceAtLeast(40.0)) * 4.0
        val transitionDurationSeconds = bars * secondsPerBar

        val durA = from.duration.takeIf { it > 10.0 } ?: 180.0
        val durB = to.duration.takeIf { it > 10.0 } ?: 180.0
        val outroCutA = calculateAutoOutroCutSeconds(durA)
        val introCutB = calculateAutoIntroCutSeconds(durB)

        val defaultCut = from.mixOutTime.takeIf { it > 15.0 && it < (durA - transitionDurationSeconds - 2.0) }
            ?: (durA - outroCutA).coerceIn(15.0, durA - transitionDurationSeconds)
        val defaultIn = to.mixInTime.takeIf { it >= 0.0 && it < (durB * 0.35) }
            ?: introCutB

        return base.copy(
            mode = TransitionMode.AUTO,
            lengthBars = bars,
            beatmatching = beatmatching,
            startCutSeconds = defaultCut,
            mixInSeconds = defaultIn,
            volume = VolumePlan(volOptionId, vol.out, vol.`in`),
            eq = EqPlan(eqOptionId, eq.out, eq.`in`),
            filter = FilterPlan(filterOptionId, filter.out, filter.`in`),
            effects = EffectsPlan(fx.id, fx.type, fx.echoBeats, fx.tail, fx.curve),
            looping = LoopingPlan(loop.id, loop.beats),
        )
    }
}
