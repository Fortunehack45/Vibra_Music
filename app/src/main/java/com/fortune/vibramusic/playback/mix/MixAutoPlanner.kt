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
     * in Auto mode based on total track length, BPM, and structural analysis.
     * Cuts are scaled by musical bars (4 to 16 bars) to keep the DJ mix punchy and dynamic.
     */
    fun calculateAutoOutroCutSeconds(
        durationSec: Double,
        bpm: Double = 120.0,
        mixOutTime: Double? = null,
    ): Double {
        if (durationSec <= 0.0) return 0.0
        if (mixOutTime != null && mixOutTime > 15.0 && mixOutTime < (durationSec - 5.0)) {
            return (durationSec - mixOutTime).coerceIn(4.0, 45.0)
        }
        val safeBpm = bpm.takeIf { it in 50.0..220.0 } ?: 120.0
        val barSec = (240.0 / safeBpm)
        val targetBars = when {
            durationSec >= 300.0 -> 16
            durationSec >= 210.0 -> 8
            durationSec >= 150.0 -> 4
            else -> 2
        }
        val cutSeconds = (targetBars * barSec).coerceIn(4.0, 45.0)
        return cutSeconds.coerceAtMost(durationSec * 0.20)
    }

    /**
     * Dynamically calculates cue-in / intro cut for the incoming track.
     * Skips pre-roll silence or long ambient build-ups to drop right into the groove.
     */
    fun calculateAutoIntroCutSeconds(
        durationSec: Double,
        bpm: Double = 120.0,
        mixInTime: Double? = null,
    ): Double {
        if (durationSec <= 0.0) return 0.0
        if (mixInTime != null && mixInTime >= 0.0 && mixInTime < (durationSec * 0.25)) {
            return mixInTime
        }
        val safeBpm = bpm.takeIf { it in 50.0..220.0 } ?: 120.0
        val barSec = (240.0 / safeBpm)
        val targetBars = if (durationSec >= 200.0) 4 else 2
        return (targetBars * barSec).coerceIn(0.0, 12.0).coerceAtMost(durationSec * 0.10)
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
            val outroCutA = calculateAutoOutroCutSeconds(durA, from?.bpm ?: 120.0, from?.mixOutTime)
            val introCutB = calculateAutoIntroCutSeconds(durB, to?.bpm ?: 120.0, to?.mixInTime)

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
        val outroCutA = calculateAutoOutroCutSeconds(durA, from.bpm, from.mixOutTime)
        val introCutB = calculateAutoIntroCutSeconds(durB, to.bpm, to.mixInTime)

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
