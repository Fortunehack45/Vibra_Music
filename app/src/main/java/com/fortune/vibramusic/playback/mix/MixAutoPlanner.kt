package com.fortune.vibramusic.playback.mix

import com.fortune.vibramusic.playback.smart.CamelotKey
import com.fortune.vibramusic.playback.smart.TrackAnalysis
import com.fortune.vibramusic.playback.smart.alignedTransitionStart
import com.fortune.vibramusic.playback.smart.alignTempoOctave
import com.fortune.vibramusic.playback.smart.incomingCuePoint
import com.fortune.vibramusic.playback.smart.simultaneousVocalFraction
import com.fortune.vibramusic.playback.smart.VOCAL_CLASH_TOLERANCE
import kotlin.math.abs

/**
 * Deterministic Auto planner that computes the optimal DJ transition between two tracks
 * based on octave-normalized tempo divergence, beat grid alignment, phrase boundaries,
 * vocal activity masks, and Camelot harmonic distance.
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
        val safeBpm = bpm.takeIf { it in 40.0..240.0 } ?: 120.0
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
        val safeBpm = bpm.takeIf { it in 40.0..240.0 } ?: 120.0
        val barSec = (240.0 / safeBpm)
        val targetBars = if (durationSec >= 200.0) 4 else 2
        return (targetBars * barSec).coerceIn(0.0, 12.0).coerceAtMost(durationSec * 0.10)
    }

    /**
     * Evaluates whether two tempos can be transparently beatmatched within [MAX_STRETCH],
     * accounting for octave relationships (e.g. 70 BPM to 140 BPM).
     */
    fun canBeatmatch(bpmOut: Double, bpmIn: Double): Boolean {
        if (bpmOut <= 0.0 || bpmIn <= 0.0) return false
        val alignedIn = alignTempoOctave(bpmOut, bpmIn)
        val ratio = bpmOut / alignedIn
        return abs(ratio - 1.0) <= MAX_STRETCH
    }

    fun autoPlan(
        from: TrackAnalysis?,
        to: TrackAnalysis?,
        fromEntryId: String,
        toEntryId: String,
        fromDurationSec: Double? = null,
        toDurationSec: Double? = null,
    ): TransitionPlan {
        val base = TransitionPlan.createEmpty(fromEntryId, toEntryId)

        // Fallback for missing analysis or low beat confidence (< 0.2)
        if (from == null || to == null || from.bpm <= 0.0 || to.bpm <= 0.0 ||
            from.beatConfidence < 0.2 || to.beatConfidence < 0.2
        ) {
            val vol = MixOptions.findVolumeOption("smooth-crossfade").build(2)
            val eq = MixOptions.findEqOption("end-bass-swap").build(2)
            val filter = MixOptions.findFilterOption("none").build(2)
            val fx = MixOptions.findEffectsOption("none")
            val loop = MixOptions.findLoopingOption(0)

            val durA = fromDurationSec?.takeIf { it > 10.0 } ?: from?.duration?.takeIf { it > 10.0 } ?: 180.0
            val durB = toDurationSec?.takeIf { it > 10.0 } ?: to?.duration?.takeIf { it > 10.0 } ?: 180.0
            val outroCutA = calculateAutoOutroCutSeconds(durA, from?.bpm ?: 120.0, from?.mixOutTime)
            val introCutB = calculateAutoIntroCutSeconds(durB, to?.bpm ?: 120.0, to?.mixInTime)

            val minCutFallback = (durA * 0.40).coerceAtMost(15.0).coerceAtLeast(1.0)
            val maxCutFallback = (durA - 4.0).coerceAtLeast(minCutFallback)
            val defaultCut = from?.mixOutTime?.takeIf { it > minCutFallback && it < (durA - 4.0) }
                ?: (durA - outroCutA).coerceIn(minCutFallback, maxCutFallback)
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

        // Octave-aware tempo matching
        val alignedInBpm = alignTempoOctave(from.bpm, to.bpm)
        val bpmGap = (abs(from.bpm - alignedInBpm) / from.bpm).toFloat()
        val bpmScore = when {
            bpmGap <= 0.03f -> 1.0f
            bpmGap <= 0.06f -> 0.85f
            bpmGap <= 0.08f -> 0.70f
            bpmGap <= 0.15f -> 0.30f
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

        val meterMismatch = from.meter.confidence >= 0.5 && to.meter.confidence >= 0.5 &&
            (from.meter.beatsPerBar != to.meter.beatsPerBar || from.meter.isAmbiguous || to.meter.isAmbiguous)

        val beatmatching = !meterMismatch && canBeatmatch(from.bpm, to.bpm) &&
            from.beatConfidence >= 0.55 && to.beatConfidence >= 0.55

        val score = bpmScore * 0.6f + keyScore * 0.4f

        var bars: Int
        var volOptionId: String
        var eqOptionId: String
        var filterOptionId: String
        var fxOptionId: String

        when {
            beatmatching && score >= 0.85f -> {
                bars = 16
                volOptionId = "overlap"
                eqOptionId = "center-bass-swap"
                filterOptionId = "none"
                fxOptionId = "none"
            }
            beatmatching && score >= 0.65f -> {
                bars = 8
                volOptionId = "overlap"
                eqOptionId = "end-bass-swap"
                filterOptionId = "none"
                fxOptionId = "none"
            }
            beatmatching && score >= 0.40f -> {
                bars = 4
                volOptionId = "fade-in-fade-out"
                eqOptionId = "end-bass-swap"
                filterOptionId = "none"
                fxOptionId = "none"
            }
            !beatmatching && (bpmScore > 0.0f || keyScore >= 0.5f) -> {
                // Harmonic match with disparate tempo: clean filter sweep handoff
                bars = 4
                volOptionId = "fade-in-fade-out"
                eqOptionId = "end-bass-swap"
                filterOptionId = "lpf-in-hpf-out"
                fxOptionId = "none"
            }
            else -> {
                // Wide clash: short fade with bass cut and optional echo tail
                bars = 2
                volOptionId = "fade-in-fast-out"
                eqOptionId = "quick-bass-cut"
                filterOptionId = "lpf-out"
                fxOptionId = "echo-half-out-end"
            }
        }

        val safeBpm = from.bpm.takeIf { it in 40.0..240.0 } ?: 120.0
        val secondsPerBar = (240.0 / safeBpm)
        var transitionDurationSeconds = bars * secondsPerBar

        val durA = fromDurationSec?.takeIf { it > 10.0 } ?: from.duration.takeIf { it > 10.0 } ?: 180.0
        val durB = toDurationSec?.takeIf { it > 10.0 } ?: to.duration.takeIf { it > 10.0 } ?: 180.0

        // Short-track protection: ensure transition never consumes more than 20% of track
        if (transitionDurationSeconds > durA * 0.20 || transitionDurationSeconds > durB * 0.20) {
            bars = when {
                durA >= 180.0 && durB >= 180.0 -> minOf(bars, 8)
                durA >= 100.0 && durB >= 100.0 -> minOf(bars, 4)
                else -> 2
            }
            transitionDurationSeconds = bars * secondsPerBar
        }

        val rawOutroCut = calculateAutoOutroCutSeconds(durA, from.bpm, from.mixOutTime)
        val minCut = (durA * 0.40).coerceAtMost(15.0).coerceAtLeast(1.0)
        val maxCut = (durA - transitionDurationSeconds).coerceAtLeast(minCut)
        val rawTargetCut = from.mixOutTime.takeIf { it > minCut && it < (durA - transitionDurationSeconds - 1.0) }
            ?: (durA - rawOutroCut).coerceIn(minCut, maxCut)

        // Snap outgoing transition start to phrase boundary or downbeat
        val snappedCut = alignedTransitionStart(
            analysis = from,
            target = rawTargetCut,
            end = durA - 1.0,
            preferEarlier = true,
            minimum = minCut,
        )

        // Snap incoming mix-in point to analyzed candidate or downbeat
        val rawTargetIn = incomingCuePoint(to, latest = durB * 0.35)
        val snappedIn = rawTargetIn.coerceIn(0.0, durB * 0.35)

        // Vocal collision check: avoid simultaneous lead vocals during overlap
        val rate = if (beatmatching && from.bpm > 0.0 && to.bpm > 0.0) from.bpm / alignedInBpm else 1.0
        val vocalClash = simultaneousVocalFraction(
            outgoing = from,
            incoming = to,
            outStart = snappedCut,
            outEnd = snappedCut + transitionDurationSeconds,
            inStart = snappedIn,
            rate = rate,
        ) ?: 0.0

        if (vocalClash > VOCAL_CLASH_TOLERANCE) {
            if (filterOptionId == "none") {
                filterOptionId = "lpf-in-hpf-out"
            }
            if (bars > 8) {
                bars = 8
                transitionDurationSeconds = bars * secondsPerBar
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
            startCutSeconds = snappedCut,
            mixInSeconds = snappedIn,
            volume = VolumePlan(volOptionId, vol.out, vol.`in`),
            eq = EqPlan(eqOptionId, eq.out, eq.`in`),
            filter = FilterPlan(filterOptionId, filter.out, filter.`in`),
            effects = EffectsPlan(fx.id, fx.type, fx.echoBeats, fx.tail, fx.curve),
            looping = LoopingPlan(loop.id, loop.beats),
        )
    }
}
