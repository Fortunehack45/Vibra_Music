package com.fortune.vibramusic.playback.audio

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

/**
 * Interpolation mode used between control points in an [AutomationCurve].
 */
enum class CurveInterpolation {
    /** Straight line interpolation between control points. */
    LINEAR,

    /** Equal-power cosine curve, ideal for outgoing gain curves: cos(π * t / 2). */
    EQUAL_POWER_COS,

    /** Equal-power sine curve, ideal for incoming gain curves: sin(π * t / 2). */
    EQUAL_POWER_SIN,

    /** Geometric/exponential glide, ideal for frequency cutoffs across pitch octaves. */
    EXPONENTIAL,

    /** Smooth cubic hermite S-curve (3t² - 2t³), eliminating sharp inflection points. */
    S_CURVE,

    /** Step hold: maintains previous control point's value until the next point. */
    STEP,
}

/**
 * A single control point on an automation curve.
 *
 * @property time Normalized position in the transition timeline, from 0.0 (start) to 1.0 (end).
 * @property value The parameter value at this control point.
 */
data class CurvePoint(
    val time: Float,
    val value: Float,
) {
    init {
        require(!time.isNaN() && !value.isNaN()) { "CurvePoint values must not be NaN" }
    }
}

/**
 * Portable automation curve describing parameter changes across normalized transition time [0.0, 1.0].
 *
 * Evaluates in real-time to drive gain, EQ band gains, and filter cutoffs without per-sample allocations.
 */
data class AutomationCurve(
    val parameterId: String,
    val points: List<CurvePoint>,
    val interpolation: CurveInterpolation = CurveInterpolation.LINEAR,
    val minValue: Float = 0f,
    val maxValue: Float = 1f,
) {
    private val sortedPoints: List<CurvePoint> = points.sortedBy { it.time }

    /**
     * Evaluates the parameter value at normalized transition time [t] ∈ [0.0, 1.0].
     */
    fun evaluate(t: Float): Float {
        val clampedT = t.coerceIn(0f, 1f)
        if (sortedPoints.isEmpty()) return minValue.coerceIn(minValue, maxValue)
        if (sortedPoints.size == 1 || clampedT <= sortedPoints.first().time) {
            return sortedPoints.first().value.coerceIn(minValue, maxValue)
        }
        if (clampedT >= sortedPoints.last().time) {
            return sortedPoints.last().value.coerceIn(minValue, maxValue)
        }

        // Find surrounding control points
        var i = 0
        while (i < sortedPoints.size - 1 && sortedPoints[i + 1].time < clampedT) {
            i++
        }
        val p0 = sortedPoints[i]
        val p1 = sortedPoints[i + 1]

        val span = (p1.time - p0.time).coerceAtLeast(1e-6f)
        val segmentT = ((clampedT - p0.time) / span).coerceIn(0f, 1f)

        val raw = when (interpolation) {
            CurveInterpolation.LINEAR -> {
                p0.value + (p1.value - p0.value) * segmentT
            }
            CurveInterpolation.EQUAL_POWER_COS -> {
                // p0 down to p1 shaped by cos(pi * t / 2)
                p0.value * cos((PI * 0.5 * segmentT).toFloat()) + p1.value * (1f - cos((PI * 0.5 * segmentT).toFloat()))
            }
            CurveInterpolation.EQUAL_POWER_SIN -> {
                // p0 up to p1 shaped by sin(pi * t / 2)
                p0.value + (p1.value - p0.value) * sin((PI * 0.5 * segmentT).toFloat())
            }
            CurveInterpolation.EXPONENTIAL -> {
                val start = p0.value.coerceAtLeast(1e-4f)
                val end = p1.value.coerceAtLeast(1e-4f)
                start * (end / start).pow(segmentT)
            }
            CurveInterpolation.S_CURVE -> {
                val smooth = segmentT * segmentT * (3f - 2f * segmentT)
                p0.value + (p1.value - p0.value) * smooth
            }
            CurveInterpolation.STEP -> {
                if (segmentT >= 1f) p1.value else p0.value
            }
        }

        return raw.coerceIn(minValue, maxValue)
    }

    companion object {
        const val PARAM_GAIN_OUT = "gain_outgoing"
        const val PARAM_GAIN_IN = "gain_incoming"
        const val PARAM_LOWPASS_OUT = "lowpass_outgoing"
        const val PARAM_HIGHPASS_OUT = "highpass_outgoing"
        const val PARAM_LOWPASS_IN = "lowpass_incoming"
        const val PARAM_HIGHPASS_IN = "highpass_incoming"
        const val PARAM_BASS_OUT = "bass_outgoing"
        const val PARAM_BASS_IN = "bass_incoming"
        const val PARAM_MID_OUT = "mid_outgoing"
        const val PARAM_MID_IN = "mid_incoming"
        const val PARAM_TREBLE_OUT = "treble_outgoing"
        const val PARAM_TREBLE_IN = "treble_incoming"

        /** Generates a linear fade out from 1.0 to 0.0. */
        fun linearFadeOut(parameterId: String = PARAM_GAIN_OUT): AutomationCurve =
            AutomationCurve(
                parameterId = parameterId,
                points = listOf(CurvePoint(0f, 1f), CurvePoint(1f, 0f)),
                interpolation = CurveInterpolation.LINEAR,
            )

        /** Generates a linear fade in from 0.0 to 1.0. */
        fun linearFadeIn(parameterId: String = PARAM_GAIN_IN): AutomationCurve =
            AutomationCurve(
                parameterId = parameterId,
                points = listOf(CurvePoint(0f, 0f), CurvePoint(1f, 1f)),
                interpolation = CurveInterpolation.LINEAR,
            )

        /** Generates an equal-power fade out holding cos(pi * t / 2). */
        fun equalPowerFadeOut(parameterId: String = PARAM_GAIN_OUT): AutomationCurve =
            AutomationCurve(
                parameterId = parameterId,
                points = listOf(CurvePoint(0f, 1f), CurvePoint(1f, 0f)),
                interpolation = CurveInterpolation.EQUAL_POWER_COS,
            )

        /** Generates an equal-power fade in holding sin(pi * t / 2). */
        fun equalPowerFadeIn(parameterId: String = PARAM_GAIN_IN): AutomationCurve =
            AutomationCurve(
                parameterId = parameterId,
                points = listOf(CurvePoint(0f, 0f), CurvePoint(1f, 1f)),
                interpolation = CurveInterpolation.EQUAL_POWER_SIN,
            )

        /** Generates a constant curve holding [value]. */
        fun constant(parameterId: String, value: Float, min: Float = 0f, max: Float = 1f): AutomationCurve =
            AutomationCurve(
                parameterId = parameterId,
                points = listOf(CurvePoint(0f, value), CurvePoint(1f, value)),
                interpolation = CurveInterpolation.STEP,
                minValue = min,
                maxValue = max,
            )
    }
}
