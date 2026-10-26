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

            val outBass = if (plan.eq.out.low.isNotEmpty()) {
                AutomationCurve(
                    parameterId = AutomationCurve.PARAM_BASS_OUT,
                    points = plan.eq.out.low.map { CurvePoint(it.t, (it.v - 1f) * 24f) },
                    minValue = -24f,
                    maxValue = 3f,
                )
            } else null

            val inBass = if (plan.eq.`in`.low.isNotEmpty()) {
                AutomationCurve(
                    parameterId = AutomationCurve.PARAM_BASS_IN,
                    points = plan.eq.`in`.low.map { CurvePoint(it.t, (it.v - 1f) * 24f) },
                    minValue = -24f,
                    maxValue = 3f,
                )
            } else null

            return TransitionProfile(
                id = plan.pairId.ifBlank { PRESET_CUSTOM },
                name = "Mix V2 Custom",
                outgoingGain = outGain,
                incomingGain = inGain,
                outgoingEqBands = if (outBass != null) mapOf(AutomationCurve.PARAM_BASS_OUT to outBass) else emptyMap(),
                incomingEqBands = if (inBass != null) mapOf(AutomationCurve.PARAM_BASS_IN to inBass) else emptyMap(),
            )
        }
    }
}
