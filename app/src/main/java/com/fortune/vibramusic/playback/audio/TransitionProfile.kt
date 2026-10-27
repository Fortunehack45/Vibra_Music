package com.fortune.vibramusic.playback.audio

import com.fortune.vibramusic.playback.TransitionFilterProcessor

/**
 * A complete transition configuration bundle defining gain, filter, and EQ automation.
 */
data class TransitionProfile(
    val id: String,
    val name: String,
    val outgoingGain: AutomationCurve,
    val incomingGain: AutomationCurve,
    val outgoingLowPass: AutomationCurve? = null,
    val outgoingHighPass: AutomationCurve? = null,
    val incomingLowPass: AutomationCurve? = null,
    val incomingHighPass: AutomationCurve? = null,
    val outgoingEqBands: Map<String, AutomationCurve> = emptyMap(),
    val incomingEqBands: Map<String, AutomationCurve> = emptyMap(),
    val effectsCurve: AutomationCurve? = null,
    val effectsType: com.fortune.vibramusic.playback.mix.EffectType? = null,
    val echoBeats: Float? = null,
) {
    companion object {
        const val PRESET_EQUAL_POWER = "equal_power"
        const val PRESET_FADE = "fade"
        const val PRESET_RISE = "rise"
        const val PRESET_BASS_SWAP = "bass_swap"
        const val PRESET_CUSTOM = "custom"

        /**
         * Equal-power crossfade holding constant acoustic power (sin² + cos² = 1.0).
         * Both filters remain open and EQ remains flat throughout.
         */
        fun equalPower(): TransitionProfile = TransitionProfile(
            id = PRESET_EQUAL_POWER,
            name = "Equal Power",
            outgoingGain = AutomationCurve.equalPowerFadeOut(),
            incomingGain = AutomationCurve.equalPowerFadeIn(),
        )

        /**
         * General smooth Fade preset.
         */
        fun linearFade(): TransitionProfile = TransitionProfile(
            id = PRESET_FADE,
            name = "Fade",
            outgoingGain = AutomationCurve.linearFadeOut(),
            incomingGain = AutomationCurve.linearFadeIn(),
        )

        /**
         * Vibra Music's Rise transition:
         * Sweeps an upward resonant high-pass filter on the outgoing track to build tension
         * until [swapFraction] (default 0.70), where the incoming track drops in at full frequency.
         */
        fun rise(swapFraction: Float = 0.70f): TransitionProfile {
            val swapAt = swapFraction.coerceIn(0.4f, 0.9f)
            val openHz = TransitionFilterProcessor.OPEN_HZ
            val offHz = TransitionFilterProcessor.OFF_HZ

            // Outgoing high-pass sweeps from OFF_HZ (20Hz) up to 2000Hz at swapAt
            val outHp = AutomationCurve(
                parameterId = AutomationCurve.PARAM_HIGHPASS_OUT,
                points = listOf(
                    CurvePoint(0.0f, offHz),
                    CurvePoint(swapAt, 2000.0f),
                    CurvePoint(1.0f, 2000.0f),
                ),
                interpolation = CurveInterpolation.EXPONENTIAL,
                minValue = offHz,
                maxValue = 10000f,
            )

            // Outgoing low-pass drops after swapAt to tuck the outgoing tail away
            val outLp = AutomationCurve(
                parameterId = AutomationCurve.PARAM_LOWPASS_OUT,
                points = listOf(
                    CurvePoint(0.0f, openHz),
                    CurvePoint(swapAt, openHz),
                    CurvePoint(1.0f, 400.0f),
                ),
                interpolation = CurveInterpolation.EXPONENTIAL,
                minValue = 100f,
                maxValue = openHz,
            )

            // Incoming high-pass starts at 1200Hz and descends to OFF_HZ by swapAt
            val inHp = AutomationCurve(
                parameterId = AutomationCurve.PARAM_HIGHPASS_IN,
                points = listOf(
                    CurvePoint(0.0f, 1200.0f),
                    CurvePoint(swapAt, offHz),
                    CurvePoint(1.0f, offHz),
                ),
                interpolation = CurveInterpolation.EXPONENTIAL,
                minValue = offHz,
                maxValue = 5000f,
            )

            return TransitionProfile(
                id = PRESET_RISE,
                name = "Rise",
                outgoingGain = AutomationCurve.equalPowerFadeOut(),
                incomingGain = AutomationCurve.equalPowerFadeIn(),
                outgoingLowPass = outLp,
                outgoingHighPass = outHp,
                incomingLowPass = null,
                incomingHighPass = inHp,
            )
        }

        /**
         * DJ Bass Swap transition:
         * Outgoing low frequencies are attenuated into the midpoint/swap point
         * while incoming bass enters attenuated and restores at full energy,
         * preventing low-end masking and muddy kick/sub-bass overlap.
         */
        fun bassSwap(swapFraction: Float = 0.50f): TransitionProfile {
            val swapAt = swapFraction.coerceIn(0.3f, 0.7f)

            // Outgoing bass shelf (dB) reduces from 0 dB to -18 dB by swapAt
            val outBass = AutomationCurve(
                parameterId = AutomationCurve.PARAM_BASS_OUT,
                points = listOf(
                    CurvePoint(0.0f, 0.0f),
                    CurvePoint(swapAt, -18.0f),
                    CurvePoint(1.0f, -24.0f),
                ),
                interpolation = CurveInterpolation.LINEAR,
                minValue = -24.0f,
                maxValue = 3.0f,
            )

            // Incoming bass shelf (dB) enters at -18 dB and restores to 0 dB at swapAt
            val inBass = AutomationCurve(
                parameterId = AutomationCurve.PARAM_BASS_IN,
                points = listOf(
                    CurvePoint(0.0f, -18.0f),
                    CurvePoint(swapAt, 0.0f),
                    CurvePoint(1.0f, 0.0f),
                ),
                interpolation = CurveInterpolation.LINEAR,
                minValue = -24.0f,
                maxValue = 3.0f,
            )

            return TransitionProfile(
                id = PRESET_BASS_SWAP,
                name = "Bass Swap",
                outgoingGain = AutomationCurve.equalPowerFadeOut(),
                incomingGain = AutomationCurve.equalPowerFadeIn(),
                outgoingEqBands = mapOf(AutomationCurve.PARAM_BASS_OUT to outBass),
                incomingEqBands = mapOf(AutomationCurve.PARAM_BASS_IN to inBass),
            )
        }

        /**
         * Converts a Mix V2 [com.fortune.vibramusic.playback.mix.TransitionPlan] into an executable [TransitionProfile].
         */
        fun fromTransitionPlan(plan: com.fortune.vibramusic.playback.mix.TransitionPlan): TransitionProfile {
            val outPoints = if (plan.volume.out.isNotEmpty()) {
                plan.volume.out.map { CurvePoint(it.t, it.v.coerceIn(0f, 1f)) }
            } else {
                listOf(CurvePoint(0f, 1f), CurvePoint(1f, 0f))
            }
            val inPoints = if (plan.volume.`in`.isNotEmpty()) {
                plan.volume.`in`.map { CurvePoint(it.t, it.v.coerceIn(0f, 1f)) }
            } else {
                listOf(CurvePoint(0f, 0f), CurvePoint(1f, 1f))
            }

            val outGain = AutomationCurve(
                parameterId = AutomationCurve.PARAM_GAIN_OUT,
                points = outPoints,
                interpolation = CurveInterpolation.LINEAR,
            )
            val inGain = AutomationCurve(
                parameterId = AutomationCurve.PARAM_GAIN_IN,
                points = inPoints,
                interpolation = CurveInterpolation.LINEAR,
            )

            val outEqBands = mutableMapOf<String, AutomationCurve>()
            if (plan.eq.out.low.isNotEmpty()) {
                outEqBands[AutomationCurve.PARAM_BASS_OUT] = AutomationCurve(
                    parameterId = AutomationCurve.PARAM_BASS_OUT,
                    points = plan.eq.out.low.map { CurvePoint(it.t, if (it.v <= 0.05f) -36f else (it.v - 1f) * 24f) },
                    minValue = -24f,
                    maxValue = 3f,
                )
            }
            if (plan.eq.out.mid.isNotEmpty()) {
                outEqBands[AutomationCurve.PARAM_MID_OUT] = AutomationCurve(
                    parameterId = AutomationCurve.PARAM_MID_OUT,
                    points = plan.eq.out.mid.map { CurvePoint(it.t, (it.v - 1f) * 24f) },
                    minValue = -24f,
                    maxValue = 3f,
                )
            }
            if (plan.eq.out.high.isNotEmpty()) {
                outEqBands[AutomationCurve.PARAM_TREBLE_OUT] = AutomationCurve(
                    parameterId = AutomationCurve.PARAM_TREBLE_OUT,
                    points = plan.eq.out.high.map { CurvePoint(it.t, (it.v - 1f) * 24f) },
                    minValue = -24f,
                    maxValue = 3f,
                )
            }

            val inEqBands = mutableMapOf<String, AutomationCurve>()
            if (plan.eq.`in`.low.isNotEmpty()) {
                inEqBands[AutomationCurve.PARAM_BASS_IN] = AutomationCurve(
                    parameterId = AutomationCurve.PARAM_BASS_IN,
                    points = plan.eq.`in`.low.map { CurvePoint(it.t, if (it.v <= 0.05f) -36f else (it.v - 1f) * 24f) },
                    minValue = -24f,
                    maxValue = 3f,
                )
            }
            if (plan.eq.`in`.mid.isNotEmpty()) {
                inEqBands[AutomationCurve.PARAM_MID_IN] = AutomationCurve(
                    parameterId = AutomationCurve.PARAM_MID_IN,
                    points = plan.eq.`in`.mid.map { CurvePoint(it.t, (it.v - 1f) * 24f) },
                    minValue = -24f,
                    maxValue = 3f,
                )
            }
            if (plan.eq.`in`.high.isNotEmpty()) {
                inEqBands[AutomationCurve.PARAM_TREBLE_IN] = AutomationCurve(
                    parameterId = AutomationCurve.PARAM_TREBLE_IN,
                    points = plan.eq.`in`.high.map { CurvePoint(it.t, (it.v - 1f) * 24f) },
                    minValue = -24f,
                    maxValue = 3f,
                )
            }

            // Map Filter curves into Low-Pass and High-Pass sweeps
            val outLpPoints = mutableListOf<CurvePoint>()
            val outHpPoints = mutableListOf<CurvePoint>()
            if (plan.filter.out.isNotEmpty()) {
                for (p in plan.filter.out) {
                    val v = p.v.coerceIn(0f, 1f)
                    val lpHz = if (v < 0.5f) {
                        val norm = (v / 0.5f).coerceIn(0f, 1f)
                        (60.0 * Math.pow(20000.0 / 60.0, norm.toDouble())).toFloat()
                    } else 20000f
                    val hpHz = if (v > 0.5f) {
                        val norm = ((v - 0.5f) / 0.5f).coerceIn(0f, 1f)
                        (20.0 * Math.pow(8000.0 / 20.0, norm.toDouble())).toFloat()
                    } else 20f
                    outLpPoints.add(CurvePoint(p.t, lpHz))
                    outHpPoints.add(CurvePoint(p.t, hpHz))
                }
            }
            val outLpCurve = if (outLpPoints.any { it.value < 19500f }) {
                AutomationCurve(AutomationCurve.PARAM_LOWPASS_OUT, outLpPoints, minValue = 60f, maxValue = 20000f)
            } else null
            val outHpCurve = if (outHpPoints.any { it.value > 25f }) {
                AutomationCurve(AutomationCurve.PARAM_HIGHPASS_OUT, outHpPoints, minValue = 20f, maxValue = 8000f)
            } else null

            val inLpPoints = mutableListOf<CurvePoint>()
            val inHpPoints = mutableListOf<CurvePoint>()
            if (plan.filter.`in`.isNotEmpty()) {
                for (p in plan.filter.`in`) {
                    val v = p.v.coerceIn(0f, 1f)
                    val lpHz = if (v < 0.5f) {
                        val norm = (v / 0.5f).coerceIn(0f, 1f)
                        (60.0 * Math.pow(20000.0 / 60.0, norm.toDouble())).toFloat()
                    } else 20000f
                    val hpHz = if (v > 0.5f) {
                        val norm = ((v - 0.5f) / 0.5f).coerceIn(0f, 1f)
                        (20.0 * Math.pow(8000.0 / 20.0, norm.toDouble())).toFloat()
                    } else 20f
                    inLpPoints.add(CurvePoint(p.t, lpHz))
                    inHpPoints.add(CurvePoint(p.t, hpHz))
                }
            }
            val inLpCurve = if (inLpPoints.any { it.value < 19500f }) {
                AutomationCurve(AutomationCurve.PARAM_LOWPASS_IN, inLpPoints, minValue = 60f, maxValue = 20000f)
            } else null
            val inHpCurve = if (inHpPoints.any { it.value > 25f }) {
                AutomationCurve(AutomationCurve.PARAM_HIGHPASS_IN, inHpPoints, minValue = 20f, maxValue = 8000f)
            } else null

            val fxCurve = if (plan.effects.curve.isNotEmpty()) {
                AutomationCurve(
                    parameterId = "effects_wet",
                    points = plan.effects.curve.map { CurvePoint(it.t, it.v.coerceIn(0f, 1f)) },
                    minValue = 0f,
                    maxValue = 1f,
                )
            } else null

            val fxOption = com.fortune.vibramusic.playback.mix.MixOptions.findEffectsOption(plan.effects.option)
            val fxType = plan.effects.type ?: fxOption.type
            val fxEchoBeats = plan.effects.echoBeats ?: fxOption.echoBeats

            return TransitionProfile(
                id = plan.pairId.ifBlank { PRESET_CUSTOM },
                name = "Mix V2 Custom",
                outgoingGain = outGain,
                incomingGain = inGain,
                outgoingLowPass = outLpCurve,
                outgoingHighPass = outHpCurve,
                incomingLowPass = inLpCurve,
                incomingHighPass = inHpCurve,
                outgoingEqBands = outEqBands,
                incomingEqBands = inEqBands,
                effectsCurve = fxCurve,
                effectsType = fxType,
                echoBeats = fxEchoBeats,
            )
        }
    }
}
