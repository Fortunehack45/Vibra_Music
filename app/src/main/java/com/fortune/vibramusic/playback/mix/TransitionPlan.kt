package com.fortune.vibramusic.playback.mix

import kotlinx.serialization.Serializable

@Serializable
enum class TransitionMode {
    AUTO,
    PRESET,
    CUSTOM,
}

@Serializable
data class VolumePlan(
    val option: String,
    val out: List<Point>,
    val `in`: List<Point>,
)

@Serializable
data class EqPlan(
    val option: String,
    val out: BandCurves,
    val `in`: BandCurves,
)

@Serializable
data class FilterPlan(
    val option: String,
    val out: List<Point>,
    val `in`: List<Point>,
)

@Serializable
data class EffectsPlan(
    val option: String,
    val type: EffectType? = null,
    val echoBeats: Float? = null,
    val tail: TailMode = TailMode.CUT,
    val curve: List<Point>,
)

@Serializable
data class LoopingPlan(
    val option: String,
    val beats: Int = 0,
)

/**
 * Complete transition plan for a specific adjacent pair of tracks in a playlist.
 */
@Serializable
data class TransitionPlan(
    val pairId: String,
    val fromEntryId: String,
    val toEntryId: String,
    val mode: TransitionMode = TransitionMode.AUTO,
    val presetId: String? = null,
    val lengthBars: Int = 4,
    val beatmatching: Boolean = true,
    val startOffsetBeats: Float = 0f,
    val startCutSeconds: Double? = null,
    val mixInSeconds: Double = 0.0,
    val volume: VolumePlan,
    val eq: EqPlan,
    val filter: FilterPlan,
    val effects: EffectsPlan,
    val looping: LoopingPlan,
    val updatedAt: Long = 0L,
    val updatedBy: String = "",
) {
    val durationSeconds: Double get() = lengthBars * 2.0

    companion object {
        fun pairIdOf(fromEntryId: String, toEntryId: String): String =
            "${fromEntryId}__${toEntryId}"

        fun createEmpty(fromEntryId: String, toEntryId: String): TransitionPlan {
            val vol = MixOptions.findVolumeOption("smooth-crossfade").build(4)
            val eq = MixOptions.findEqOption("end-bass-swap").build(4)
            val filter = MixOptions.findFilterOption("none").build(4)
            val fx = MixOptions.findEffectsOption("none")
            val loop = MixOptions.findLoopingOption(0)

            return TransitionPlan(
                pairId = pairIdOf(fromEntryId, toEntryId),
                fromEntryId = fromEntryId,
                toEntryId = toEntryId,
                mode = TransitionMode.AUTO,
                presetId = null,
                lengthBars = 4,
                beatmatching = true,
                startOffsetBeats = 0f,
                volume = VolumePlan("smooth-crossfade", vol.out, vol.`in`),
                eq = EqPlan("end-bass-swap", eq.out, eq.`in`),
                filter = FilterPlan("none", filter.out, filter.`in`),
                effects = EffectsPlan(fx.id, fx.type, fx.echoBeats, fx.tail, fx.curve),
                looping = LoopingPlan(loop.id, loop.beats),
            )
        }

        fun applyPreset(base: TransitionPlan, preset: Preset): TransitionPlan {
            val bars = preset.lengthBars
            val vol = MixOptions.findVolumeOption(preset.volumeOptionId).build(bars)
            val eq = MixOptions.findEqOption(preset.eqOptionId).build(bars)
            val filter = MixOptions.findFilterOption(preset.filterOptionId).build(bars)
            val fx = MixOptions.findEffectsOption(preset.effectsOptionId)
            val loop = MixOptions.findLoopingOption(preset.loopBeats)

            return base.copy(
                mode = TransitionMode.PRESET,
                presetId = preset.id,
                lengthBars = bars,
                beatmatching = preset.beatmatching,
                volume = VolumePlan(preset.volumeOptionId, vol.out, vol.`in`),
                eq = EqPlan(preset.eqOptionId, eq.out, eq.`in`),
                filter = FilterPlan(preset.filterOptionId, filter.out, filter.`in`),
                effects = EffectsPlan(fx.id, fx.type, fx.echoBeats, fx.tail, fx.curve),
                looping = LoopingPlan(loop.id, loop.beats),
            )
        }

        fun validatePlan(plan: TransitionPlan): List<String> {
            val errors = mutableListOf<String>()

            fun checkPoints(lane: String, points: List<Point>) {
                if (points.size > Curves.MAX_POINTS) {
                    errors.add("$lane has more than ${Curves.MAX_POINTS} points (${points.size})")
                }
                for (p in points) {
                    if (p.t !in 0f..1f) errors.add("$lane point t out of range: ${p.t}")
                    if (p.v !in 0f..1f) errors.add("$lane point v out of range: ${p.v}")
                }
                for (i in 1 until points.size) {
                    if (points[i].t < points[i - 1].t) {
                        errors.add("$lane points are not sorted at index $i: ${points[i].t} < ${points[i - 1].t}")
                    }
                }
            }

            checkPoints("volume.out", plan.volume.out)
            checkPoints("volume.in", plan.volume.`in`)
            checkPoints("filter.out", plan.filter.out)
            checkPoints("filter.in", plan.filter.`in`)
            checkPoints("effects.curve", plan.effects.curve)

            checkPoints("eq.out.low", plan.eq.out.low)
            checkPoints("eq.out.mid", plan.eq.out.mid)
            checkPoints("eq.out.high", plan.eq.out.high)
            checkPoints("eq.in.low", plan.eq.`in`.low)
            checkPoints("eq.in.mid", plan.eq.`in`.mid)
            checkPoints("eq.in.high", plan.eq.`in`.high)

            if (plan.lengthBars !in listOf(2, 4, 8, 16)) {
                errors.add("Invalid lengthBars: ${plan.lengthBars}")
            }
            if (plan.looping.beats !in listOf(0, 1, 2, 4, 8, 16)) {
                errors.add("Invalid looping beats: ${plan.looping.beats}")
            }

            return errors
        }
    }
}
